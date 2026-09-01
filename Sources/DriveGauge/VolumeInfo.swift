import Darwin
import Foundation

enum FileSystemCapacity {
    static func availableBytes(at url: URL) -> Int64? {
        var information = statfs()
        let status = url.path.withCString { path in
            statfs(path, &information)
        }
        guard status == 0 else { return nil }
        let bytes = UInt64(information.f_bavail) * UInt64(information.f_bsize)
        return Int64(clamping: bytes)
    }

    static func totalBytes(at url: URL) -> Int64? {
        var information = statfs()
        let status = url.path.withCString { path in
            statfs(path, &information)
        }
        guard status == 0 else { return nil }
        let bytes = UInt64(information.f_blocks) * UInt64(information.f_bsize)
        return Int64(clamping: bytes)
    }
}

struct VolumeInfo: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let format: String
    let totalBytes: Int64?
    let availableBytes: Int64?
    let isLocal: Bool
    let isInternal: Bool
    let isRemovable: Bool
    let isReadOnly: Bool

    var kind: String {
        if !isLocal { return "Сетевой" }
        if isInternal { return "Встроенный" }
        if isRemovable { return "USB / внешний" }
        return "Внешний"
    }

    var icon: String {
        if !isLocal { return "network" }
        if isInternal { return "internaldrive" }
        return "externaldrive"
    }

    var capacityText: String {
        guard let totalBytes else { return format }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var freeText: String? {
        guard let availableBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
    }
}

enum VolumeScanner {
    static func mountedVolumes(fileManager: FileManager = .default) -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeIsReadOnlyKey, .volumeIsBrowsableKey, .volumeUUIDStringKey
        ]

        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false else { return nil }

            let name = values.volumeName ?? url.lastPathComponent
            let statAvailable = FileSystemCapacity.availableBytes(at: url)
            let reportedAvailable = values.volumeAvailableCapacity.map(Int64.init)
            let importantAvailable = values.volumeAvailableCapacityForImportantUsage
            let available = [statAvailable, reportedAvailable, importantAvailable]
                .compactMap { $0 }
                .filter { $0 > 0 }
                .min()
            let reportedTotal = values.volumeTotalCapacity.map(Int64.init)
            let total = reportedTotal.flatMap { $0 > 0 ? $0 : nil }
                ?? FileSystemCapacity.totalBytes(at: url)
            return VolumeInfo(
                id: values.volumeUUIDString ?? url.standardizedFileURL.path,
                url: url,
                name: name.isEmpty ? "Macintosh HD" : name,
                format: values.volumeLocalizedFormatDescription ?? "Файловая система",
                totalBytes: total,
                availableBytes: available,
                isLocal: values.volumeIsLocal ?? true,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isReadOnly: values.volumeIsReadOnly ?? false
            )
        }
        .sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
