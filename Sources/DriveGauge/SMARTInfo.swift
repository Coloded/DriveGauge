import Darwin
import DriveSMART
import Foundation

struct SMARTIssue: Identifiable, Sendable {
    enum Severity: Int, Sendable { case info, warning, critical }
    let id: String
    let severity: Severity
    let text: String
}

struct SMARTInfo: Sendable {
    enum Health: Sendable {
        case healthy, limited, warning, failing, unsupported
    }

    let health: Health
    let status: String
    let model: String?
    let device: String?
    let interface: String?
    let isSSD: Bool?
    let temperatureCelsius: Int?
    let percentageUsed: Int?
    let availableSpare: Int?
    let powerOnHours: UInt64?
    let powerCycles: UInt64?
    let unsafeShutdowns: UInt64?
    let mediaErrors: UInt64?
    let errorLogEntries: UInt64?
    let dataReadBytes: UInt64?
    let dataWrittenBytes: UInt64?
    let issues: [SMARTIssue]

    var remainingLife: Int? {
        percentageUsed.map { max(0, 100 - $0) }
    }
}

enum SMARTReader {
    static func read(volumeURL: URL) -> SMARTInfo {
        guard !volumeURL.path.isEmpty else { return unsupported("Путь тома недоступен") }
        if let direct = readDirectATA(volumeURL: volumeURL) {
            return direct
        }
        guard let volumeDictionary = diskutilDictionary(volumeURL.path) else {
            return unsupported("macOS не вернула сведения о накопителе")
        }

        var dictionary = volumeDictionary
        if let stores = volumeDictionary["APFSPhysicalStores"] as? [[String: Any]],
           let identifier = stores.first?["APFSPhysicalStore"] as? String,
           let store = diskutilDictionary(identifier) {
            if let parent = store["ParentWholeDisk"] as? String,
               let physical = diskutilDictionary(parent) {
                dictionary = physical
            } else {
                dictionary = store
            }
        } else if let parent = volumeDictionary["ParentWholeDisk"] as? String,
                  parent != volumeDictionary["DeviceIdentifier"] as? String,
                  let physical = diskutilDictionary(parent) {
            dictionary = physical
        }
        return parse(dictionary)
    }

    private static func readDirectATA(volumeURL: URL) -> SMARTInfo? {
        guard let deviceSource = mountedDeviceSource(volumeURL), deviceSource.hasPrefix("/dev/") else {
            return nil
        }
        var snapshot = DGSMARTSnapshot()
        var error = [CChar](repeating: 0, count: 256)
        let result = deviceSource.withCString { source in
            DGReadATASMART(source, &snapshot, &error, error.count)
        }
        guard result == 1 else { return nil }

        let count = max(0, min(Int(snapshot.attributeCount), 30))
        let attributes: [DGSMARTAttribute] = withUnsafeBytes(of: snapshot.attributes) { bytes in
            Array(bytes.bindMemory(to: DGSMARTAttribute.self).prefix(count))
        }
        var values: [Int: DGSMARTAttribute] = [:]
        for attribute in attributes {
            values[Int(attribute.identifier)] = attribute
        }
        let model = cString(snapshot.model)
        let interface = cString(snapshot.interfaceName)
        let isSamsung = model.localizedCaseInsensitiveContains("Samsung")
            || model.localizedCaseInsensitiveContains("PSSD")

        func attribute(_ identifier: Int) -> DGSMARTAttribute? { values[identifier] }
        func raw(_ identifier: Int) -> UInt64? { attribute(identifier)?.rawValue }
        func sum(_ identifiers: [Int]) -> UInt64? {
            let present = identifiers.compactMap(raw)
            guard !present.isEmpty else { return nil }
            return present.reduce(0) { partial, value in
                let (sum, overflow) = partial.addingReportingOverflow(value)
                return overflow ? UInt64.max : sum
            }
        }

        let used: Int?
        if isSamsung, let wear = attribute(177) {
            used = max(0, min(100, 100 - Int(wear.current)))
        } else if let remaining = attribute(202) {
            used = max(0, min(100, 100 - Int(remaining.current)))
        } else {
            used = nil
        }
        let temperatureRaw = raw(190) ?? raw(194)
        let temperature = temperatureRaw.map { Int($0 & 0xff) }.flatMap { (1...125).contains($0) ? $0 : nil }
        let mediaErrors = sum([5, 181, 182, 183, 187, 198])
        let crcErrors = raw(199)
        let thresholdFailures = attributes.filter {
            $0.threshold > 0 && $0.current <= $0.threshold
        }

        var health: SMARTInfo.Health = .healthy
        if snapshot.thresholdExceeded != 0 || !thresholdFailures.isEmpty {
            health = .failing
        } else if snapshot.checksumValid == 0 {
            health = .warning
        }
        if [187, 197, 198].contains(where: { (raw($0) ?? 0) > 0 }) {
            health = .failing
        } else if [5, 181, 182, 183, 199].contains(where: { (raw($0) ?? 0) > 0 }),
                  health == .healthy {
            health = .warning
        }

        var issues: [SMARTIssue] = []
        if snapshot.checksumValid == 0 {
            issues.append(.init(id: "checksum", severity: .warning, text: "Контрольная сумма SMART повреждена"))
        }
        if snapshot.thresholdExceeded != 0 {
            issues.append(.init(id: "threshold", severity: .critical, text: "Накопитель сообщает о превышении критического порога SMART"))
        }
        for failure in thresholdFailures {
            issues.append(.init(
                id: "attribute-\(failure.identifier)", severity: .critical,
                text: "SMART-атрибут \(failure.identifier) достиг критического порога"
            ))
        }
        if let reallocated = raw(5), reallocated > 0 {
            issues.append(.init(id: "reallocated", severity: .warning, text: "Переназначенные блоки: \(reallocated)"))
        }
        if let uncorrectable = raw(187), uncorrectable > 0 {
            issues.append(.init(id: "uncorrectable", severity: .critical, text: "Неисправимые ошибки: \(uncorrectable)"))
        }
        if let programFailures = raw(181), programFailures > 0 {
            issues.append(.init(id: "program-fail", severity: .warning, text: "Ошибки программирования NAND: \(programFailures)"))
        }
        if let eraseFailures = raw(182), eraseFailures > 0 {
            issues.append(.init(id: "erase-fail", severity: .warning, text: "Ошибки стирания NAND: \(eraseFailures)"))
        }
        if let badBlocks = raw(183), badBlocks > 0 {
            issues.append(.init(id: "bad-blocks", severity: .warning, text: "Сбои блоков во время работы: \(badBlocks)"))
        }
        if let pending = raw(197), pending > 0 {
            issues.append(.init(id: "pending", severity: .critical, text: "Нестабильные секторы: \(pending)"))
        }
        if let offline = raw(198), offline > 0 {
            issues.append(.init(id: "offline", severity: .critical, text: "Неисправимые секторы: \(offline)"))
        }
        if let crcErrors, crcErrors > 0 {
            issues.append(.init(id: "crc", severity: .warning, text: "Ошибки передачи USB/SATA: \(crcErrors)"))
        }
        if let temperature, temperature >= 60 {
            issues.append(.init(
                id: "temperature", severity: temperature >= 70 ? .critical : .warning,
                text: "Высокая температура: \(temperature) °C"
            ))
        }
        if let used, used >= 70 {
            issues.append(.init(
                id: "wear", severity: used >= 90 ? .critical : .warning,
                text: "Высокий износ SSD: использовано \(used)%"
            ))
        }
        if isSamsung, let recoveries = raw(235), recoveries > 0 {
            issues.append(.init(
                id: "power-recovery", severity: .info,
                text: "Восстановлений после потери питания: \(recoveries)"
            ))
        }

        return SMARTInfo(
            health: health,
            status: health == .healthy ? "Исправен" : (health == .failing ? "Возможен отказ" : "Требует внимания"),
            model: model.isEmpty ? nil : model,
            device: deviceSource.replacingOccurrences(of: "/dev/", with: ""),
            interface: interface.isEmpty ? nil : interface,
            isSSD: snapshot.solidState < 0 ? nil : snapshot.solidState == 1,
            temperatureCelsius: temperature,
            percentageUsed: used,
            availableSpare: nil,
            powerOnHours: raw(9),
            powerCycles: raw(12),
            unsafeShutdowns: isSamsung ? raw(235) : nil,
            mediaErrors: mediaErrors,
            errorLogEntries: raw(187),
            dataReadBytes: multiplied(raw(242), by: 512),
            dataWrittenBytes: multiplied(raw(241), by: 512),
            issues: issues
        )
    }

    private static func mountedDeviceSource(_ url: URL) -> String? {
        var information = statfs()
        guard url.path.withCString({ statfs($0, &information) }) == 0 else { return nil }
        return withUnsafePointer(to: &information.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
    }

    private static func cString<T>(_ tuple: T) -> String {
        var copy = tuple
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }

    private static func multiplied(_ value: UInt64?, by multiplier: UInt64) -> UInt64? {
        guard let value else { return nil }
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? UInt64.max : result
    }

    private static func diskutilDictionary(_ target: String) -> [String: Any]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", target]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else { return nil }
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func parse(_ dictionary: [String: Any]) -> SMARTInfo {
        let rawStatus = string(dictionary["SMARTStatus"]) ?? "Not Supported"
        let details = dictionary["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        let used = integer(details["PERCENTAGE_USED"]).map(Int.init)
        let spare = integer(details["AVAILABLE_SPARE"]).map(Int.init)
        let temperatureRaw = integer(details["TEMPERATURE"]).map(Int.init)
        let temperature = temperatureRaw.map { $0 > 200 ? $0 - 273 : $0 }
        let mediaErrors = combined(details, "MEDIA_ERRORS")
        let errorEntries = combined(details, "NUM_ERROR_INFO_LOG_ENTRIES")
        let unsafe = combined(details, "UNSAFE_SHUTDOWNS")
        let hours = combined(details, "POWER_ON_HOURS")
        let cycles = combined(details, "POWER_CYCLES")
        let readUnits = combined(details, "DATA_UNITS_READ")
        let writtenUnits = combined(details, "DATA_UNITS_WRITTEN")

        let normalized = rawStatus.lowercased()
        var health: SMARTInfo.Health
        let hasDetailedHealthData = !details.isEmpty && [
            used != nil, spare != nil, temperature != nil, mediaErrors != nil,
            errorEntries != nil, hours != nil
        ].contains(true)
        if normalized.contains("verified") || normalized.contains("passed") {
            health = hasDetailedHealthData ? .healthy : .limited
        } else if normalized.contains("not supported") {
            health = .unsupported
        } else if normalized.contains("fail") {
            health = .failing
        } else {
            health = .warning
        }

        var issues: [SMARTIssue] = []
        if health == .failing {
            issues.append(.init(id: "smart-fail", severity: .critical, text: "SMART сообщает о возможном отказе накопителя"))
        }
        if health == .limited {
            issues.append(.init(
                id: "limited", severity: .warning,
                text: "Общий SMART-тест пройден, но накопитель не передал износ, температуру и счётчики ошибок. Полностью оценить состояние нельзя"
            ))
        }
        if let used {
            if used >= 90 {
                issues.append(.init(id: "wear-critical", severity: .critical, text: "Ресурс SSD почти исчерпан: использовано \(used)%"))
            } else if used >= 70 {
                issues.append(.init(id: "wear-warning", severity: .warning, text: "Высокий износ SSD: использовано \(used)%"))
            }
        }
        if let temperature {
            if temperature >= 70 {
                issues.append(.init(id: "temperature-critical", severity: .critical, text: "Критическая температура: \(temperature) °C"))
            } else if temperature >= 60 {
                issues.append(.init(id: "temperature-warning", severity: .warning, text: "Высокая температура: \(temperature) °C"))
            }
        }
        if let mediaErrors, mediaErrors > 0 {
            issues.append(.init(id: "media-errors", severity: .critical, text: "Ошибки носителя: \(mediaErrors)"))
        }
        if let errorEntries, errorEntries > 0 {
            issues.append(.init(id: "error-log", severity: .warning, text: "Записей в журнале ошибок: \(errorEntries)"))
        }
        if let unsafe, unsafe > 0 {
            issues.append(.init(id: "unsafe", severity: .info, text: "Небезопасных отключений: \(unsafe)"))
        }
        if health == .unsupported {
            issues.append(.init(
                id: "unsupported", severity: .info,
                text: "Контроллер или USB-мост не передаёт SMART в macOS"
            ))
        }

        return SMARTInfo(
            health: health, status: localizedStatus(health),
            model: nonEmpty(string(dictionary["MediaName"])) ?? nonEmpty(string(dictionary["IORegistryEntryName"])),
            device: string(dictionary["ParentWholeDisk"]) ?? string(dictionary["DeviceIdentifier"]),
            interface: string(dictionary["BusProtocol"]),
            isSSD: dictionary["SolidState"] as? Bool,
            temperatureCelsius: temperature, percentageUsed: used, availableSpare: spare,
            powerOnHours: hours, powerCycles: cycles, unsafeShutdowns: unsafe,
            mediaErrors: mediaErrors, errorLogEntries: errorEntries,
            dataReadBytes: nvmeBytes(readUnits), dataWrittenBytes: nvmeBytes(writtenUnits),
            issues: issues
        )
    }

    private static func unsupported(_ reason: String) -> SMARTInfo {
        SMARTInfo(
            health: .unsupported, status: "Не поддерживается",
            model: nil, device: nil, interface: nil, isSSD: nil,
            temperatureCelsius: nil, percentageUsed: nil, availableSpare: nil,
            powerOnHours: nil, powerCycles: nil, unsafeShutdowns: nil,
            mediaErrors: nil, errorLogEntries: nil, dataReadBytes: nil, dataWrittenBytes: nil,
            issues: [.init(id: "unavailable", severity: .info, text: reason)]
        )
    }

    private static func localizedStatus(_ health: SMARTInfo.Health) -> String {
        switch health {
        case .healthy: return "Исправен"
        case .limited: return "Недостаточно данных"
        case .warning: return "Требует внимания"
        case .failing: return "Возможен отказ"
        case .unsupported: return "Не поддерживается"
        }
    }

    private static func combined(_ dictionary: [String: Any], _ key: String) -> UInt64? {
        guard let low = integer(dictionary["\(key)_0"]) ?? integer(dictionary[key]) else { return nil }
        // Values exposed by current macOS fit in the low 64 bits. A non-zero high part means saturation.
        if let high = integer(dictionary["\(key)_1"]), high > 0 { return UInt64.max }
        return low
    }

    private static func nvmeBytes(_ units: UInt64?) -> UInt64? {
        guard let units else { return nil }
        let (value, overflow) = units.multipliedReportingOverflow(by: 512_000)
        return overflow ? UInt64.max : value
    }

    private static func integer(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String { return UInt64(string) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
