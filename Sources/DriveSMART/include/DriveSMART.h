#ifndef DRIVE_SMART_H
#define DRIVE_SMART_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t identifier;
    uint8_t current;
    uint8_t worst;
    uint8_t threshold;
    uint64_t rawValue;
} DGSMARTAttribute;

typedef struct {
    int checksumValid;
    int thresholdExceeded;
    int solidState;
    char model[128];
    char interfaceName[32];
    DGSMARTAttribute attributes[30];
    int attributeCount;
} DGSMARTSnapshot;

// Returns 1 on success, 0 when direct ATA SMART is unavailable, and -1 on read failure.
// This function only reads SMART/IDENTIFY data and never changes drive settings.
int DGReadATASMART(
    const char *bsdName,
    DGSMARTSnapshot *snapshot,
    char *errorBuffer,
    size_t errorBufferSize
);

#endif
