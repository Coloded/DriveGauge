import Darwin
import Foundation
import NetworkBenchmarkProtocol

private enum WorkerFailure: LocalizedError {
    case argument(String)
    case posix(String, Int32)
    case insufficientSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case let .argument(message): return message
        case let .posix(operation, code): return "\(operation): \(String(cString: strerror(code)))"
        case let .insufficientSpace(required, available):
            return "Недостаточно места: нужно \(required) байт, доступно \(available) байт"
        }
    }
}

private struct Arguments {
    let root: URL
    let runID: UUID
    let maximumBytes: Int64
    let targetSeconds: Double
    let blockSize: Int
    let fault: String?
    let cleanupOnly: Bool
    let availableBytesOverride: Int64?

    init(_ values: [String]) throws {
        var map: [String: String] = [:]
        var index = 1
        while index + 1 < values.count {
            map[values[index]] = values[index + 1]
            index += 2
        }
        guard let root = map["--root"], let run = map["--run-id"], let runID = UUID(uuidString: run),
              let maximum = map["--max-bytes"].flatMap(Int64.init), maximum > 0,
              let seconds = map["--target-seconds"].flatMap(Double.init), seconds > 0,
              let block = map["--block-size"].flatMap(Int.init), block > 0 else {
            throw WorkerFailure.argument("Некорректные параметры сетевого теста")
        }
        self.root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        self.runID = runID
        self.maximumBytes = maximum
        self.targetSeconds = seconds
        self.blockSize = block
        self.fault = map["--fault"]
        self.cleanupOnly = map["--cleanup-only"] == "1"
        #if DEBUG
        self.availableBytesOverride = map["--available-bytes"].flatMap(Int64.init)
        #else
        self.availableBytesOverride = nil
        #endif
    }
}

private final class Emitter {
    private let encoder = JSONEncoder()
    func send(_ event: NetworkWorkerEvent) {
        guard let data = try? encoder.encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private func availableBytes(at url: URL) throws -> Int64 {
    var info = statfs()
    guard url.path.withCString({ statfs($0, &info) }) == 0 else {
        throw WorkerFailure.posix("Проверка свободного места", errno)
    }
    return Int64(clamping: UInt64(info.f_bavail) * UInt64(info.f_bsize))
}

private func elapsed(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

private func writeBlock(_ fd: Int32, buffer: UnsafeRawPointer, count: Int, offset: Int64) throws -> Int {
    var done = 0
    while done < count {
        let result = pwrite(fd, buffer.advanced(by: done), count - done, off_t(offset + Int64(done)))
        guard result > 0 else { throw WorkerFailure.posix("Ошибка записи", errno) }
        done += result
    }
    return done
}

private func readBlock(_ fd: Int32, buffer: UnsafeMutableRawPointer, count: Int, offset: Int64) throws -> Int {
    var done = 0
    while done < count {
        let result = pread(fd, buffer.advanced(by: done), count - done, off_t(offset + Int64(done)))
        guard result > 0 else { throw WorkerFailure.posix("Ошибка чтения", result == 0 ? EIO : errno) }
        done += result
    }
    return done
}

private func run(_ args: Arguments, emitter: Emitter) throws {
    let run = args.runID.uuidString
    guard FileManager.default.fileExists(atPath: args.root.path) else {
        throw WorkerFailure.argument("Сетевой том недоступен")
    }
    let fileURL = args.root.appendingPathComponent(".drive-gauge-\(run).tmp").standardizedFileURL
    guard NetworkBenchmarkPlanning.isSafeTemporaryFile(fileURL, root: args.root, runID: args.runID) else {
        throw WorkerFailure.argument("Небезопасный путь временного файла")
    }
    if args.cleanupOnly {
        if unlink(fileURL.path) != 0, errno != ENOENT {
            throw WorkerFailure.posix("Удаление временного файла", errno)
        }
        emitter.send(.init(kind: .cleanupCompleted, runID: run, temporaryPath: fileURL.path))
        return
    }

    let available: Int64
    if let override = args.availableBytesOverride { available = override }
    else { available = try availableBytes(at: args.root) }
    let minimum = Int64(max(args.blockSize, 8 * 1_048_576))
    let required = minimum + NetworkBenchmarkPlanning.safetyReserve
    guard available >= required else { throw WorkerFailure.insufficientSpace(required: required, available: available) }

    var fd = open(fileURL.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw WorkerFailure.posix("Создание тестового файла", errno) }
    _ = fcntl(fd, F_NOCACHE, 1)
    var cleaned = false
    defer {
        if fd >= 0 { close(fd) }
        if !cleaned, unlink(fileURL.path) == 0 {
            emitter.send(.init(kind: .cleanupCompleted, runID: run, temporaryPath: fileURL.path))
        }
    }

    emitter.send(.init(kind: .ready, runID: run, temporaryPath: fileURL.path))
    if args.fault == "corrupt" {
        FileHandle.standardOutput.write(Data("{invalid-json}\n".utf8))
    } else if args.fault == "wrongid" {
        emitter.send(.init(kind: .writing, runID: UUID().uuidString, transferredBytes: 1, totalBytes: 2))
    } else if args.fault == "crash" {
        Darwin.exit(70)
    } else if args.fault == "stall" {
        sleep(120)
    } else if args.fault == "enospc" {
        throw WorkerFailure.posix("Ошибка записи", ENOSPC)
    }

    guard let buffer = malloc(args.blockSize) else { throw WorkerFailure.posix("Выделение буфера", ENOMEM) }
    defer { free(buffer) }
    arc4random_buf(buffer, args.blockSize)

    let probeTarget = min(Int64(4 * 1_048_576), available - NetworkBenchmarkPlanning.safetyReserve)
    emitter.send(.init(kind: .probeStarted, runID: run, transferredBytes: 0, totalBytes: probeTarget, temporaryPath: fileURL.path))
    let probeStart = DispatchTime.now().uptimeNanoseconds
    var probeBytes: Int64 = 0
    while probeBytes < probeTarget {
        buffer.storeBytes(of: UInt64(probeBytes).littleEndian, as: UInt64.self)
        let count = min(args.blockSize, Int(probeTarget - probeBytes))
        probeBytes += Int64(try writeBlock(fd, buffer: buffer, count: count, offset: probeBytes))
        let seconds = elapsed(probeStart)
        emitter.send(.init(kind: .writing, runID: run, transferredBytes: probeBytes, totalBytes: probeTarget,
                           currentMBps: Double(probeBytes) / 1_000_000 / max(seconds, 0.000_001),
                           averageMBps: Double(probeBytes) / 1_000_000 / max(seconds, 0.000_001),
                           elapsedSeconds: seconds, idleSeconds: 0, temporaryPath: fileURL.path,
                           message: "Пробная запись"))
    }
    emitter.send(.init(kind: .syncing, runID: run, transferredBytes: probeBytes, totalBytes: probeTarget,
                       temporaryPath: fileURL.path, message: "Подтверждаем пробную запись"))
    guard fsync(fd) == 0 else { throw WorkerFailure.posix("Синхронизация пробного файла", errno) }
    let probeSeconds = elapsed(probeStart)
    let probeMBps = Double(probeBytes) / 1_000_000 / max(probeSeconds, 0.000_001)
    var verifiedProbeBytes: Int64 = 0
    while verifiedProbeBytes < probeTarget {
        let count = min(args.blockSize, Int(probeTarget - verifiedProbeBytes))
        verifiedProbeBytes += Int64(try readBlock(fd, buffer: buffer, count: count, offset: verifiedProbeBytes))
    }
    let target = NetworkBenchmarkPlanning.adaptiveByteCount(
        probeMBps: probeMBps, targetSeconds: args.targetSeconds, minimumBytes: minimum,
        maximumBytes: args.maximumBytes, availableBytes: available, blockSize: args.blockSize
    )
    guard target >= Int64(args.blockSize) else { throw WorkerFailure.insufficientSpace(required: required, available: available) }
    guard ftruncate(fd, 0) == 0 else { throw WorkerFailure.posix("Подготовка тестового файла", errno) }

    let writeStart = DispatchTime.now().uptimeNanoseconds
    var written: Int64 = 0
    emitter.send(.init(kind: .writing, runID: run, transferredBytes: 0, totalBytes: target,
                       currentMBps: 0, averageMBps: 0, elapsedSeconds: 0, idleSeconds: 0,
                       temporaryPath: fileURL.path, message: "Основная запись"))
    while written < target {
        buffer.storeBytes(of: UInt64(written).littleEndian, as: UInt64.self)
        let count = min(args.blockSize, Int(target - written))
        written += Int64(try writeBlock(fd, buffer: buffer, count: count, offset: written))
        let seconds = elapsed(writeStart)
        emitter.send(.init(kind: .writing, runID: run, transferredBytes: written, totalBytes: target,
                           currentMBps: Double(written) / 1_000_000 / max(seconds, 0.000_001),
                           averageMBps: Double(written) / 1_000_000 / max(seconds, 0.000_001),
                           elapsedSeconds: seconds, idleSeconds: 0, temporaryPath: fileURL.path,
                           message: "Основная запись"))
        if seconds >= args.targetSeconds { break }
    }
    let streamingWriteSeconds = elapsed(writeStart)
    emitter.send(.init(kind: .syncing, runID: run, transferredBytes: written, totalBytes: written,
                       elapsedSeconds: streamingWriteSeconds, idleSeconds: 0, temporaryPath: fileURL.path,
                       message: "Ожидаем подтверждение сервера"))
    let syncStart = DispatchTime.now().uptimeNanoseconds
    guard fsync(fd) == 0 else { throw WorkerFailure.posix("Синхронизация с сервером", errno) }
    let syncSeconds = elapsed(syncStart)
    let confirmedWriteSeconds = streamingWriteSeconds + syncSeconds
    let writeMBps = Double(written) / 1_000_000 / max(confirmedWriteSeconds, 0.000_001)

    close(fd)
    fd = open(fileURL.path, O_RDONLY)
    guard fd >= 0 else { throw WorkerFailure.posix("Повторное открытие файла для чтения", errno) }
    _ = fcntl(fd, F_NOCACHE, 1)
    _ = fcntl(fd, F_RDAHEAD, 0)

    let readStart = DispatchTime.now().uptimeNanoseconds
    var readBytes: Int64 = 0
    while readBytes < written {
        let count = min(args.blockSize, Int(written - readBytes))
        readBytes += Int64(try readBlock(fd, buffer: buffer, count: count, offset: readBytes))
        let seconds = elapsed(readStart)
        emitter.send(.init(kind: .reading, runID: run, transferredBytes: readBytes, totalBytes: written,
                           currentMBps: Double(readBytes) / 1_000_000 / max(seconds, 0.000_001),
                           averageMBps: Double(readBytes) / 1_000_000 / max(seconds, 0.000_001),
                           elapsedSeconds: seconds, idleSeconds: 0, temporaryPath: fileURL.path))
    }
    let readSeconds = elapsed(readStart)
    let readMBps = Double(readBytes) / 1_000_000 / max(readSeconds, 0.000_001)
    guard unlink(fileURL.path) == 0 else { throw WorkerFailure.posix("Удаление временного файла", errno) }
    cleaned = true
    emitter.send(.init(kind: .cleanupCompleted, runID: run, temporaryPath: fileURL.path))
    emitter.send(.init(kind: .completed, runID: run, transferredBytes: readBytes, totalBytes: written,
                       currentMBps: readMBps, averageMBps: readMBps, elapsedSeconds: readSeconds,
                       writeMBps: writeMBps, readMBps: readMBps, writeSeconds: confirmedWriteSeconds,
                       syncSeconds: syncSeconds, readSeconds: readSeconds, temporaryPath: fileURL.path))
}

private let emitter = Emitter()
do {
    let arguments = try Arguments(CommandLine.arguments)
    do {
        try run(arguments, emitter: emitter)
    } catch {
        emitter.send(.init(kind: .failed, runID: arguments.runID.uuidString,
                           message: error.localizedDescription,
                           errorCode: (error as? WorkerFailure).flatMap {
                               if case let .posix(_, code) = $0 { return code }
                               return nil
                           }))
        Darwin.exit(1)
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    Darwin.exit(64)
}
