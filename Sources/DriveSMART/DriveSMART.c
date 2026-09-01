#include "DriveSMART.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <stdio.h>
#include <string.h>

static void setError(char *buffer, size_t size, const char *message, IOReturn code) {
    if (!buffer || size == 0) return;
    if (code) snprintf(buffer, size, "%s (0x%x)", message, code);
    else snprintf(buffer, size, "%s", message);
}

static int copyDictionaryString(io_service_t service, CFStringRef dictionaryKey, CFStringRef valueKey, char *output, size_t size) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(service, dictionaryKey, kCFAllocatorDefault, 0);
    if (!property || CFGetTypeID(property) != CFDictionaryGetTypeID()) {
        if (property) CFRelease(property);
        return 0;
    }
    CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)property, valueKey);
    int copied = value && CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringGetCString((CFStringRef)value, output, size, kCFStringEncodingUTF8);
    CFRelease(property);
    return copied;
}

static int isSMARTCapable(io_service_t service) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        service, CFSTR(kIOPropertySMARTCapableKey), kCFAllocatorDefault, 0
    );
    if (!value) return 0;
    int capable = CFGetTypeID(value) != CFBooleanGetTypeID() || CFBooleanGetValue((CFBooleanRef)value);
    CFRelease(value);
    return capable;
}

int DGReadATASMART(
    const char *bsdName,
    DGSMARTSnapshot *snapshot,
    char *errorBuffer,
    size_t errorBufferSize
) {
    if (!bsdName || !snapshot) return -1;
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->solidState = -1;
    if (errorBuffer && errorBufferSize) errorBuffer[0] = 0;

    const char *name = strncmp(bsdName, "/dev/", 5) == 0 ? bsdName + 5 : bsdName;
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name)
    );
    if (!service) {
        setError(errorBuffer, errorBufferSize, "Устройство не найдено в IOKit", 0);
        return 0;
    }

    while (service && !isSMARTCapable(service)) {
        io_service_t parent = IO_OBJECT_NULL;
        IOReturn result = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent);
        IOObjectRelease(service);
        service = result == kIOReturnSuccess ? parent : IO_OBJECT_NULL;
    }
    if (!service) {
        setError(errorBuffer, errorBufferSize, "Прямой ATA SMART не поддерживается", 0);
        return 0;
    }

    copyDictionaryString(
        service, CFSTR("Device Characteristics"), CFSTR("Product Name"),
        snapshot->model, sizeof(snapshot->model)
    );
    copyDictionaryString(
        service, CFSTR("Protocol Characteristics"), CFSTR("Physical Interconnect"),
        snapshot->interfaceName, sizeof(snapshot->interfaceName)
    );
    char medium[64] = {0};
    if (copyDictionaryString(
        service, CFSTR("Device Characteristics"), CFSTR("Medium Type"),
        medium, sizeof(medium)
    )) {
        snapshot->solidState = strstr(medium, "Solid State") ? 1 : 0;
    }

    IOCFPlugInInterface **plugin = NULL;
    IOATASMARTInterface **smart = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(
        service, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score
    );
    if (result != kIOReturnSuccess || !plugin) {
        setError(errorBuffer, errorBufferSize, "SMARTLib недоступен", result);
        IOObjectRelease(service);
        return 0;
    }

    HRESULT query = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart
    );
    if (query || !smart) {
        setError(errorBuffer, errorBufferSize, "IOATASMARTInterface недоступен", (IOReturn)query);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(service);
        return 0;
    }

    ATASMARTData data;
    ATASMARTDataThresholds thresholds;
    memset(&data, 0, sizeof(data));
    memset(&thresholds, 0, sizeof(thresholds));
    result = (*smart)->SMARTReadData(smart, &data);
    if (result != kIOReturnSuccess) {
        setError(errorBuffer, errorBufferSize, "Не удалось прочитать SMART", result);
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(service);
        return -1;
    }

    const uint8_t *raw = (const uint8_t *)&data;
    unsigned checksum = 0;
    for (int index = 0; index < 512; index++) checksum = (checksum + raw[index]) & 0xff;
    snapshot->checksumValid = checksum == 0;

    Boolean exceeded = false;
    if ((*smart)->SMARTReturnStatus(smart, &exceeded) == kIOReturnSuccess) {
        snapshot->thresholdExceeded = exceeded ? 1 : 0;
    }

    int hasThresholds = (*smart)->SMARTReadDataThresholds(smart, &thresholds) == kIOReturnSuccess;
    const uint8_t *thresholdRaw = (const uint8_t *)&thresholds;
    for (int index = 0; index < 30; index++) {
        const uint8_t *entry = raw + 2 + index * 12;
        if (!entry[0]) continue;
        DGSMARTAttribute attribute = {0};
        attribute.identifier = entry[0];
        attribute.current = entry[3];
        attribute.worst = entry[4];
        for (int byte = 0; byte < 6; byte++) {
            attribute.rawValue |= ((uint64_t)entry[5 + byte]) << (8 * byte);
        }
        if (hasThresholds) {
            for (int thresholdIndex = 0; thresholdIndex < 30; thresholdIndex++) {
                const uint8_t *thresholdEntry = thresholdRaw + 2 + thresholdIndex * 12;
                if (thresholdEntry[0] == attribute.identifier) {
                    attribute.threshold = thresholdEntry[1];
                    break;
                }
            }
        }
        snapshot->attributes[snapshot->attributeCount++] = attribute;
    }

    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    IOObjectRelease(service);
    return 1;
}
