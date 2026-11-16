import Foundation

public let networkBenchmarkProtocolVersion = 1

public enum NetworkEventKind: String, Codable, Sendable {
    case ready, probeStarted, writing, syncing, reading, completed, failed, cleanupCompleted
}

public struct NetworkWorkerEvent: Codable, Sendable {
    public let protocolVersion: Int
    public let kind: NetworkEventKind
    public let runID: String
    public let transferredBytes: Int64?
    public let totalBytes: Int64?
    public let currentMBps: Double?
    public let averageMBps: Double?
    public let elapsedSeconds: Double?
    public let idleSeconds: Double?
    public let pass: Int?
    public let writeMBps: Double?
    public let readMBps: Double?
    public let writeSeconds: Double?
    public let syncSeconds: Double?
    public let readSeconds: Double?
    public let temporaryPath: String?
    public let message: String?
    public let errorCode: Int32?

    public init(
        kind: NetworkEventKind, runID: String,
        transferredBytes: Int64? = nil, totalBytes: Int64? = nil,
        currentMBps: Double? = nil, averageMBps: Double? = nil,
        elapsedSeconds: Double? = nil, idleSeconds: Double? = nil,
        pass: Int? = 1, writeMBps: Double? = nil, readMBps: Double? = nil,
        writeSeconds: Double? = nil, syncSeconds: Double? = nil, readSeconds: Double? = nil,
        temporaryPath: String? = nil, message: String? = nil, errorCode: Int32? = nil
    ) {
        self.protocolVersion = networkBenchmarkProtocolVersion
        self.kind = kind
        self.runID = runID
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
        self.currentMBps = currentMBps
        self.averageMBps = averageMBps
        self.elapsedSeconds = elapsedSeconds
        self.idleSeconds = idleSeconds
        self.pass = pass
        self.writeMBps = writeMBps
        self.readMBps = readMBps
        self.writeSeconds = writeSeconds
        self.syncSeconds = syncSeconds
        self.readSeconds = readSeconds
        self.temporaryPath = temporaryPath
        self.message = message
        self.errorCode = errorCode
    }
}

public enum NetworkBenchmarkPlanning {
    public static let safetyReserve: Int64 = 64 * 1_048_576

    public static func adaptiveByteCount(
        probeMBps: Double, targetSeconds: Double, minimumBytes: Int64,
        maximumBytes: Int64, availableBytes: Int64, blockSize: Int
    ) -> Int64 {
        guard blockSize > 0, maximumBytes > 0 else { return 0 }
        let safeAvailable = max(0, availableBytes - safetyReserve)
        let estimated = Int64(max(0, probeMBps) * 1_000_000 * max(0, targetSeconds))
        let desired = max(minimumBytes, estimated)
        let limited = min(desired, maximumBytes, safeAvailable)
        return limited - limited % Int64(blockSize)
    }

    public static func isSafeTemporaryFile(_ url: URL, root: URL, runID: UUID) -> Bool {
        let expected = root.standardizedFileURL
            .appendingPathComponent(".drive-gauge-\(runID.uuidString).tmp")
            .standardizedFileURL
        return url.standardizedFileURL == expected
    }
}

public enum NetworkFileSystemClassification {
    public static let remoteTypes: Set<String> = ["smbfs", "nfs", "webdav", "afpfs", "cifs"]
    public static func isRemote(_ value: String?) -> Bool {
        value.map { remoteTypes.contains($0.lowercased()) } ?? false
    }
}

public struct NetworkEventStreamDecoder: Sendable {
    private var buffer = Data()
    private let expectedRunID: String
    public private(set) var invalidLineCount = 0

    public init(expectedRunID: String) { self.expectedRunID = expectedRunID }

    public mutating func append(_ data: Data) -> [NetworkWorkerEvent] {
        buffer.append(data)
        var events: [NetworkWorkerEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            if let event = try? JSONDecoder().decode(NetworkWorkerEvent.self, from: Data(line)),
               event.protocolVersion == networkBenchmarkProtocolVersion,
               event.runID == expectedRunID {
                events.append(event)
            } else { invalidLineCount += 1 }
        }
        return events
    }
}

public enum NetworkWatchdogPolicy {
    public enum Decision: Equatable, Sendable { case proceed, showIdle, transferStalled, syncStalled, totalTimedOut }
    public static let idleNoticeSeconds: Int64 = 3
    public static let transferStallSeconds: Int64 = 15
    public static let syncStallSeconds: Int64 = 20
    public static let totalLimitSeconds: Int64 = 60
    public static let terminateGraceMilliseconds = 1_000
    public static let killWaitMilliseconds = 300
    public static let cleanupLimitMilliseconds = 600
    public static var maximumStopMilliseconds: Int {
        terminateGraceMilliseconds + killWaitMilliseconds + cleanupLimitMilliseconds
    }
    public static func evaluate(kind: NetworkEventKind?, idleSeconds: Int64, phaseSeconds: Int64, totalSeconds: Int64) -> Decision {
        if totalSeconds >= totalLimitSeconds { return .totalTimedOut }
        if kind == .syncing, phaseSeconds >= syncStallSeconds { return .syncStalled }
        if kind == nil || kind == .ready || kind == .probeStarted || kind == .writing || kind == .reading {
            if idleSeconds >= transferStallSeconds { return .transferStalled }
            if idleSeconds >= idleNoticeSeconds { return .showIdle }
        }
        return .proceed
    }
}

public struct NetworkWatchdogConfiguration: Sendable {
    public let idleNoticeSeconds: Int64
    public let transferStallSeconds: Int64
    public let syncStallSeconds: Int64
    public let totalLimitSeconds: Int64
    public let terminateGraceMilliseconds: Int
    public let killWaitMilliseconds: Int
    public let cleanupLimitMilliseconds: Int

    public init(
        idleNoticeSeconds: Int64, transferStallSeconds: Int64,
        syncStallSeconds: Int64, totalLimitSeconds: Int64,
        terminateGraceMilliseconds: Int, killWaitMilliseconds: Int,
        cleanupLimitMilliseconds: Int
    ) {
        self.idleNoticeSeconds = idleNoticeSeconds
        self.transferStallSeconds = transferStallSeconds
        self.syncStallSeconds = syncStallSeconds
        self.totalLimitSeconds = totalLimitSeconds
        self.terminateGraceMilliseconds = terminateGraceMilliseconds
        self.killWaitMilliseconds = killWaitMilliseconds
        self.cleanupLimitMilliseconds = cleanupLimitMilliseconds
    }

    public static let production = Self(
        idleNoticeSeconds: NetworkWatchdogPolicy.idleNoticeSeconds,
        transferStallSeconds: NetworkWatchdogPolicy.transferStallSeconds,
        syncStallSeconds: NetworkWatchdogPolicy.syncStallSeconds,
        totalLimitSeconds: NetworkWatchdogPolicy.totalLimitSeconds,
        terminateGraceMilliseconds: NetworkWatchdogPolicy.terminateGraceMilliseconds,
        killWaitMilliseconds: NetworkWatchdogPolicy.killWaitMilliseconds,
        cleanupLimitMilliseconds: NetworkWatchdogPolicy.cleanupLimitMilliseconds
    )

    public var maximumStopMilliseconds: Int {
        terminateGraceMilliseconds + killWaitMilliseconds + cleanupLimitMilliseconds
    }

    public func evaluate(
        kind: NetworkEventKind?, idleSeconds: Int64,
        phaseSeconds: Int64, totalSeconds: Int64
    ) -> NetworkWatchdogPolicy.Decision {
        if totalSeconds >= totalLimitSeconds { return .totalTimedOut }
        if kind == .syncing, phaseSeconds >= syncStallSeconds { return .syncStalled }
        if kind == nil || kind == .ready || kind == .probeStarted || kind == .writing || kind == .reading {
            if idleSeconds >= transferStallSeconds { return .transferStalled }
            if idleSeconds >= idleNoticeSeconds { return .showIdle }
        }
        return .proceed
    }
}

public struct EligibilityGenerationGate: Sendable {
    public private(set) var generation = UUID()
    public init() {}
    public mutating func next() -> UUID { generation = UUID(); return generation }
    public func accepts(_ candidate: UUID) -> Bool { candidate == generation }
}

public struct BenchmarkCompletionGate: Sendable {
    public private(set) var activeRunID: UUID?
    public init() {}
    @discardableResult public mutating func begin() -> UUID {
        let runID = UUID()
        activeRunID = runID
        return runID
    }
    public mutating func cancel(_ runID: UUID) {
        if activeRunID == runID { activeRunID = nil }
    }
    public mutating func finish(_ runID: UUID) -> Bool {
        guard activeRunID == runID else { return false }
        activeRunID = nil
        return true
    }
    public func accepts(_ runID: UUID) -> Bool { activeRunID == runID }
}
