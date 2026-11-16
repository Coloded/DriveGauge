import Darwin
import Foundation
import NetworkBenchmarkProtocol

enum NetworkBenchmarkError: LocalizedError {
    case workerMissing
    case launch(String)
    case protocolFailure(String)
    case stalled(String)
    case timedOut
    case workerFailed(String)
    case unsafeTemporaryPath

    var errorDescription: String? {
        switch self {
        case .workerMissing: return "Компонент сетевого теста не найден"
        case let .launch(message): return "Не удалось запустить сетевой тест: \(message)"
        case let .protocolFailure(message): return "Ошибка протокола сетевого теста: \(message)"
        case let .stalled(stage): return "Сетевой диск не отвечает на этапе «\(stage)»"
        case .timedOut: return "Превышено максимальное время сетевого теста"
        case let .workerFailed(message): return message
        case .unsafeTemporaryPath: return "Worker сообщил небезопасный путь временного файла"
        }
    }
}

private final class NetworkProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var latest: NetworkWorkerEvent?
    private(set) var completed: NetworkWorkerEvent?
    private(set) var failure: String?
    private(set) var invalidLines = 0
    private(set) var lastAdvance = ContinuousClock.now
    private(set) var phaseStarted = ContinuousClock.now
    private var lastBytes: Int64 = 0
    private var lastKind: NetworkEventKind?
    private var lastDelivery: UInt64 = 0
    private var streamDecoder: NetworkEventStreamDecoder

    init(expectedRunID: String) { streamDecoder = .init(expectedRunID: expectedRunID) }

    func append(_ data: Data) -> [NetworkWorkerEvent] {
        lock.lock()
        var decoded: [NetworkWorkerEvent] = []
        for event in streamDecoder.append(data) {
                let phaseChanged = event.kind != lastKind
                if phaseChanged {
                    phaseStarted = .now
                    lastAdvance = .now
                    lastBytes = 0
                    lastKind = event.kind
                }
                if let bytes = event.transferredBytes, bytes < lastBytes {
                    lastBytes = 0
                    lastAdvance = .now
                }
                if let bytes = event.transferredBytes, bytes > lastBytes {
                    lastAdvance = .now
                    lastBytes = bytes
                }
                latest = event
                if event.kind == .completed { completed = event }
                if event.kind == .failed { failure = event.message ?? "Сетевой тест завершился с ошибкой" }
                let now = DispatchTime.now().uptimeNanoseconds
                let terminal = [.completed, .failed, .cleanupCompleted].contains(event.kind)
                if phaseChanged || terminal || now - lastDelivery >= 100_000_000 {
                    decoded.append(event)
                    lastDelivery = now
                }
        }
        invalidLines = streamDecoder.invalidLineCount
        lock.unlock()
        return decoded
    }

    func snapshot() -> (NetworkWorkerEvent?, NetworkWorkerEvent?, String?, Int, Duration, Duration) {
        lock.lock()
        defer { lock.unlock() }
        return (latest, completed, failure, invalidLines, lastAdvance.duration(to: .now), phaseStarted.duration(to: .now))
    }
}

private final class NetworkProcessController: @unchecked Sendable {
    let process: Process
    let policy: NetworkWatchdogConfiguration
    init(_ process: Process, policy: NetworkWatchdogConfiguration) {
        self.process = process
        self.policy = policy
    }
    func requestStop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let forcedKillDelay = Double(policy.terminateGraceMilliseconds + policy.killWaitMilliseconds) / 1_000
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + forcedKillDelay) {
            if self.process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    func stopAndWaitBlocking() {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<max(1, policy.terminateGraceMilliseconds / 100) where process.isRunning { usleep(100_000) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<max(1, policy.killWaitMilliseconds / 100) where process.isRunning { usleep(100_000) }
    }
}

private final class BoundedErrorDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 65_536 { data.removeFirst(data.count - 65_536) }
        lock.unlock()
    }
    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data.suffix(4_096), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private enum NetworkDiagnosticLog {
    static func append(runID: UUID, fileSystem: String?, message: String) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = support.appendingPathComponent("DriveGauge", isDirectory: true)
        let url = directory.appendingPathComponent("NetworkBenchmark.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber, size.intValue > 512_000 {
            try? Data().write(to: url, options: .atomic)
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) run=\(runID.uuidString) fs=\(fileSystem ?? "unknown") \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

private final class NetworkReportRelay: @unchecked Sendable {
    private var active = true
    private let queue = DispatchQueue(label: "DriveGauge.NetworkReportRelay")
    private let reporter: NetworkBenchmarkEngine.Reporter
    init(_ reporter: @escaping NetworkBenchmarkEngine.Reporter) { self.reporter = reporter }
    func enqueue(_ events: [NetworkWorkerEvent]) {
        queue.async {
            guard self.active else { return }
            for event in events {
                guard self.active else { return }
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    await self.reporter(NetworkBenchmarkEngine.update(for: event))
                    semaphore.signal()
                }
                semaphore.wait()
            }
        }
    }
    func stop() { queue.sync { active = false } }
}

enum NetworkBenchmarkEngine {
    typealias Reporter = BenchmarkEngine.Reporter

    struct Configuration: Sendable {
        let workerURL: URL?
        let additionalWorkerArguments: [String]
        let targetSeconds: Double
        let pollMilliseconds: UInt64
        let watchdog: NetworkWatchdogConfiguration

        static let production = Self(
            workerURL: nil, additionalWorkerArguments: [], targetSeconds: 12,
            pollMilliseconds: 250, watchdog: .production
        )
    }

    static func run(
        at volume: VolumeInfo, byteCount: Int64, mode: BenchmarkMode,
        reporter: @escaping Reporter, configuration: Configuration = .production
    ) async throws -> BenchmarkResult {
        guard mode == .standard else {
            throw NetworkBenchmarkError.workerFailed("Для сетевого тома сейчас доступен безопасный режим «Стандартный»")
        }
        let runID = UUID()
        let worker = try configuration.workerURL ?? workerURL()
        let process = Process()
        process.executableURL = worker
        process.arguments = [
            "--root", volume.url.path,
            "--run-id", runID.uuidString,
            "--max-bytes", String(byteCount),
            "--target-seconds", String(configuration.targetSeconds),
            "--block-size", String(1_048_576)
        ] + configuration.additionalWorkerArguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let state = NetworkProcessState(expectedRunID: runID.uuidString)
        let controller = NetworkProcessController(process, policy: configuration.watchdog)
        let errorDrain = BoundedErrorDrain()
        let relay = NetworkReportRelay(reporter)
        let expectedRoot = volume.url.standardizedFileURL
        NetworkDiagnosticLog.append(runID: runID, fileSystem: volume.fileSystemType, message: "started mode=standard maxBytes=\(byteCount)")

        do {
            try process.run()
        } catch {
            throw NetworkBenchmarkError.launch(error.localizedDescription)
        }

        let stdoutReader = Task.detached(priority: .utility) {
            let handle = output.fileHandleForReading
            while let data = try? handle.read(upToCount: 65_536), !data.isEmpty {
                let events = state.append(data)
                if !events.isEmpty {
                    relay.enqueue(events)
                    for event in events where event.kind == .ready || event.kind == .probeStarted || event.kind == .syncing || event.kind == .reading || event.kind == .failed {
                        NetworkDiagnosticLog.append(
                            runID: runID, fileSystem: volume.fileSystemType,
                            message: "stage=\(event.kind.rawValue) elapsed=\(event.elapsedSeconds ?? 0) code=\(event.errorCode.map(String.init) ?? "none")"
                        )
                    }
                }
            }
        }
        let stderrReader = Task.detached(priority: .utility) {
            let handle = errors.fileHandleForReading
            while let data = try? handle.read(upToCount: 65_536), !data.isEmpty {
                errorDrain.append(data)
            }
        }

        let started = ContinuousClock.now
        do {
            return try await withTaskCancellationHandler(operation: {
                while process.isRunning {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(configuration.pollMilliseconds))
                    let snapshot = state.snapshot()
                    if let path = snapshot.0?.temporaryPath {
                        let url = URL(fileURLWithPath: path)
                        guard NetworkBenchmarkPlanning.isSafeTemporaryFile(url, root: expectedRoot, runID: runID) else {
                            controller.requestStop()
                            throw NetworkBenchmarkError.unsafeTemporaryPath
                        }
                    }
                    let idle = snapshot.4.components.seconds
                    let phaseSeconds = snapshot.5.components.seconds
                    let totalSeconds = started.duration(to: .now).components.seconds
                    let watchdog = configuration.watchdog.evaluate(
                        kind: snapshot.0?.kind, idleSeconds: idle,
                        phaseSeconds: phaseSeconds, totalSeconds: totalSeconds
                    )
                    if watchdog == .showIdle {
                        if let latest = snapshot.0 {
                            let stalled = NetworkWorkerEvent(
                                kind: latest.kind, runID: latest.runID,
                                transferredBytes: latest.transferredBytes, totalBytes: latest.totalBytes,
                                currentMBps: latest.currentMBps, averageMBps: latest.averageMBps,
                                elapsedSeconds: latest.elapsedSeconds, idleSeconds: Double(idle),
                                temporaryPath: latest.temporaryPath,
                                message: "Нет передачи данных · \(idle) с"
                            )
                            await reporter(update(for: stalled))
                        } else {
                            await reporter(.init(
                                phase: .preparing, currentMBps: 0, progress: 0,
                                transferredBytes: 0, totalBytes: byteCount,
                                elapsedSeconds: Double(totalSeconds), idleSeconds: Double(idle),
                                stage: "Сетевой том не отвечает · \(idle) с", completedMetric: nil
                            ))
                        }
                    }
                    if watchdog == .transferStalled {
                        controller.requestStop()
                        let stage = snapshot.0?.kind == .reading ? "чтение" : (snapshot.0 == nil || snapshot.0?.kind == .ready ? "подготовка" : "запись")
                        throw NetworkBenchmarkError.stalled(stage)
                    }
                    if watchdog == .syncStalled {
                        controller.requestStop()
                        throw NetworkBenchmarkError.stalled("синхронизация")
                    }
                    if watchdog == .totalTimedOut {
                        controller.requestStop()
                        throw NetworkBenchmarkError.timedOut
                    }
                }

                await stdoutReader.value
                await stderrReader.value
                let snapshot = state.snapshot()
                if let failure = snapshot.2 { throw NetworkBenchmarkError.workerFailed(failure) }
                guard process.terminationStatus == 0, let event = snapshot.1,
                      let write = event.writeMBps, let read = event.readMBps,
                      let bytes = event.totalBytes else {
                    if snapshot.3 > 0 { throw NetworkBenchmarkError.protocolFailure("получены повреждённые данные") }
                    throw NetworkBenchmarkError.protocolFailure("worker завершился без результата")
                }
                let metric = BenchmarkMetric(
                    id: "network-adaptive", title: "Сетевой адаптивный · 1 МиБ · QD1",
                    writeMBps: write, readMBps: read,
                    writeIOPS: write * 1_000_000 / 1_048_576,
                    readIOPS: read * 1_000_000 / 1_048_576,
                    blockSize: 1_048_576, queueDepth: 1, iterations: 1
                )
                relay.stop()
                NetworkDiagnosticLog.append(
                    runID: runID, fileSystem: volume.fileSystemType,
                    message: "completed bytes=\(bytes) writeSeconds=\(event.writeSeconds ?? 0) syncSeconds=\(event.syncSeconds ?? 0) readSeconds=\(event.readSeconds ?? 0)"
                )
                return BenchmarkResult(
                    writeMBps: write, readMBps: read, metrics: [metric],
                    recommendationWriteMBps: write, recommendationReadMBps: read,
                    metadata: .init(
                        engine: "network-adaptive", fileSystem: volume.fileSystemType,
                        testedBytes: bytes, writeSeconds: event.writeSeconds,
                        syncSeconds: event.syncSeconds, readSeconds: event.readSeconds,
                        adaptive: true, algorithmVersion: 1
                    )
                )
            }, onCancel: {
                controller.requestStop()
            })
        } catch {
            relay.stop()
            await Task.detached(priority: .utility) { controller.stopAndWaitBlocking() }.value
            await stdoutReader.value
            await stderrReader.value
            let cleaned = await cleanup(
                worker: worker, volume: volume.url, runID: runID,
                maximumBytes: byteCount, policy: configuration.watchdog
            )
            NetworkDiagnosticLog.append(
                runID: runID, fileSystem: volume.fileSystemType,
                message: "failed error=\(String(describing: error)) cleanup=\(cleaned ? "ok" : "failed") stderr=\(errorDrain.snapshot())"
            )
            if !cleaned {
                let path = volume.url.appendingPathComponent(".drive-gauge-\(runID.uuidString).tmp").path
                throw NetworkBenchmarkError.workerFailed("Тест остановлен, но не удалось подтвердить удаление временного файла: \(path)")
            }
            throw error
        }
    }

    private static func workerURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["DRIVEGAUGE_NETWORK_WORKER"] {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/DriveGaugeNetworkWorker")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            throw NetworkBenchmarkError.workerMissing
        }
        return bundled
    }

    fileprivate static func update(for event: NetworkWorkerEvent) -> BenchmarkUpdate {
        let phase: BenchmarkPhase
        let stage: String
        switch event.kind {
        case .ready: phase = .preparing; stage = "Сетевой worker готов"
        case .probeStarted: phase = .preparing; stage = "Пробная запись на сетевой диск"
        case .writing: phase = .writing; stage = event.message ?? "Сетевая запись"
        case .syncing: phase = .writing; stage = "Ожидаем подтверждение сервера"
        case .reading: phase = .reading; stage = event.message ?? "Сетевое чтение"
        case .completed: phase = .preparing; stage = "Сохраняем результат сетевого теста"
        case .cleanupCompleted: phase = .preparing; stage = "Временный файл удалён"
        case .failed: phase = .preparing; stage = event.message ?? "Ошибка сетевого теста"
        }
        let bytes = event.transferredBytes ?? 0
        let total = max(1, event.totalBytes ?? bytes)
        return .init(
            phase: phase, currentMBps: event.currentMBps ?? event.averageMBps ?? 0,
            progress: min(1, Double(bytes) / Double(total)), transferredBytes: bytes,
            totalBytes: total, elapsedSeconds: event.elapsedSeconds, idleSeconds: event.idleSeconds,
            stage: stage, completedMetric: nil
        )
    }

    private static func cleanup(
        worker: URL, volume: URL, runID: UUID, maximumBytes: Int64,
        policy: NetworkWatchdogConfiguration
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = worker
            process.arguments = [
                "--root", volume.path, "--run-id", runID.uuidString,
                "--max-bytes", String(maximumBytes), "--target-seconds", "1",
                "--block-size", String(1_048_576), "--cleanup-only", "1"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            for _ in 0..<max(1, policy.cleanupLimitMilliseconds / 100) where process.isRunning { usleep(100_000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            for _ in 0..<max(1, policy.killWaitMilliseconds / 100) where process.isRunning { usleep(100_000) }
            return !process.isRunning && process.terminationStatus == 0
        }.value
    }

}
