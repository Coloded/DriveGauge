import Darwin
import Foundation

enum TestSize: Int64, CaseIterable, Identifiable, Sendable {
    case quick = 268_435_456
    case standard = 1_073_741_824
    case accurate = 4_294_967_296

    var id: Int64 { rawValue }
    var title: String {
        switch self {
        case .quick: return "256 МБ"
        case .standard: return "1 ГБ"
        case .accurate: return "4 ГБ"
        }
    }
}

enum BenchmarkMode: String, CaseIterable, Identifiable, Sendable {
    case standard, maximum, applications, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Стандартный"
        case .maximum: return "Максимальная скорость"
        case .applications: return "Работа приложений"
        case .full: return "Полный тест"
        }
    }
    var detail: String {
        switch self {
        case .standard: return "Последовательный 1 МиБ · QD1 · 3 прохода"
        case .maximum: return "Последовательный 1 МиБ · QD8 · 3 прохода"
        case .applications: return "Случайный 4 КиБ · QD1 и QD32"
        case .full: return "Все последовательные и случайные профили"
        }
    }
}

enum BenchmarkPhase: Equatable, Sendable {
    case idle, preparing, writing, reading, finished
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "ГОТОВ К ТЕСТУ"
        case .preparing: return "ПОДГОТОВКА"
        case .writing: return "ЗАПИСЬ"
        case .reading: return "ЧТЕНИЕ"
        case .finished: return "ГОТОВО"
        case .failed: return "ОШИБКА"
        }
    }
}

struct BenchmarkUpdate: Sendable {
    let phase: BenchmarkPhase
    let currentMBps: Double
    let progress: Double
    let transferredBytes: Int64
    let stage: String
    let completedMetric: BenchmarkMetric?
}

struct BenchmarkMetric: Identifiable, Sendable {
    let id: String
    let title: String
    let writeMBps: Double
    let readMBps: Double
    let writeIOPS: Double
    let readIOPS: Double
    let blockSize: Int
    let queueDepth: Int
    let iterations: Int
}

struct BenchmarkResult: Sendable {
    let writeMBps: Double
    let readMBps: Double
    let metrics: [BenchmarkMetric]
    let recommendationWriteMBps: Double?
    let recommendationReadMBps: Double?
}

enum BenchmarkError: LocalizedError {
    case readOnly, capacityUnavailable, cancelled
    case notWritable(String)
    case notEnoughSpace(required: Int64, available: Int64)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .readOnly: return "Том доступен только для чтения"
        case .capacityUnavailable: return "Не удалось безопасно определить свободное место"
        case let .notWritable(path): return "Запись запрещена: нет доступа к \(path)"
        case let .notEnoughSpace(required, available):
            return "Недостаточно места: нужно \(Self.bytes(required)), доступно \(Self.bytes(available))"
        case let .posix(operation, code): return "\(operation): \(String(cString: strerror(code)))"
        case .cancelled: return "Тест остановлен"
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct Workload: Sendable {
    let id: String
    let title: String
    let blockSize: Int
    let queueDepth: Int
    let random: Bool
    let iterations: Int
}

enum BenchmarkEngine {
    typealias Reporter = @Sendable (BenchmarkUpdate) async -> Void
    static let safetyReserve: Int64 = 67_108_864

    static func preflightError(at volumeURL: URL, declaredReadOnly: Bool, byteCount: Int64) -> BenchmarkError? {
        if declaredReadOnly { return .readOnly }
        guard let available = FileSystemCapacity.availableBytes(at: volumeURL) else { return .capacityUnavailable }
        let required = byteCount + safetyReserve
        if available < required { return .notEnoughSpace(required: required, available: available) }

        let directory = writableTestDirectory(for: volumeURL)
        let canWrite = directory.path.withCString { Darwin.access($0, W_OK) == 0 }
        if !canWrite || !FileManager.default.isWritableFile(atPath: directory.path) {
            return .notWritable(directory.path)
        }
        return nil
    }

    static func run(
        at volumeURL: URL,
        byteCount: Int64,
        mode: BenchmarkMode = .standard,
        reporter: @escaping Reporter
    ) async throws -> BenchmarkResult {
        try Task.checkCancellation()
        await reporter(.init(phase: .preparing, currentMBps: 0, progress: 0, transferredBytes: 0, stage: "Проверка диска", completedMetric: nil))

        let values = try? volumeURL.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsLocalKey])
        if let error = preflightError(at: volumeURL, declaredReadOnly: values?.volumeIsReadOnly == true, byteCount: byteCount) {
            throw error
        }

        let directory = writableTestDirectory(for: volumeURL)
        let fileURL = directory.appendingPathComponent(".drive-gauge-\(UUID().uuidString).tmp")
        let path = fileURL.path
        var descriptor = open(path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw BenchmarkError.posix(operation: "Не удалось создать тестовый файл", code: errno)
        }
        defer {
            if descriptor >= 0 { close(descriptor) }
            // Only this exact O_EXCL-created path is removed. No scanning or masks.
            unlink(path)
        }

        await reporter(.init(
            phase: .preparing, currentMBps: 0, progress: 0,
            transferredBytes: 0,
            stage: values?.volumeIsLocal == false
                ? "Создаём тестовый файл на сетевом диске"
                : "Выделяем место для тестового файла",
            completedMetric: nil
        ))
        try preallocate(
            descriptor: descriptor,
            byteCount: byteCount,
            useNativePreallocation: values?.volumeIsLocal != false
        )
        configureUncached(descriptor: descriptor, disableReadAhead: false)

        let profiles = workloads(for: mode)
        var metrics: [BenchmarkMetric] = []
        for (profileIndex, workload) in profiles.enumerated() {
            var writes: [Double] = []
            var reads: [Double] = []

            for iteration in 0..<workload.iterations {
                try Task.checkCancellation()
                if descriptor < 0 {
                    descriptor = open(path, O_RDWR)
                    guard descriptor >= 0 else {
                        throw BenchmarkError.posix(operation: "Открытие тестового файла", code: errno)
                    }
                    configureUncached(descriptor: descriptor, disableReadAhead: false)
                }

                let pass = "\(workload.title) · проход \(iteration + 1)/\(workload.iterations)"
                let offsets = workload.random ? shuffledOffsets(byteCount: byteCount, blockSize: workload.blockSize) : nil
                let write = try await transfer(
                    descriptor: descriptor, byteCount: byteCount, workload: workload,
                    offsets: offsets, phase: .writing, stage: pass, writeMode: true, reporter: reporter
                )
                let syncStarted = DispatchTime.now().uptimeNanoseconds
                guard fsync(descriptor) == 0 else {
                    throw BenchmarkError.posix(operation: "Синхронизация файла", code: errno)
                }
                let syncSeconds = Double(DispatchTime.now().uptimeNanoseconds - syncStarted) / 1_000_000_000
                writes.append(Double(byteCount) / 1_000_000 / max(write.seconds + syncSeconds, 0.000_001))

                close(descriptor)
                descriptor = open(path, O_RDONLY)
                guard descriptor >= 0 else {
                    throw BenchmarkError.posix(operation: "Открытие файла для чтения", code: errno)
                }
                configureUncached(descriptor: descriptor, disableReadAhead: true)
                let read = try await transfer(
                    descriptor: descriptor, byteCount: byteCount, workload: workload,
                    offsets: offsets, phase: .reading, stage: pass, writeMode: false, reporter: reporter
                )
                reads.append(read.mbPerSecond)
                close(descriptor)
                descriptor = -1
            }

            let writeMedian = median(writes)
            let readMedian = median(reads)
            let metric = BenchmarkMetric(
                id: workload.id, title: workload.title,
                writeMBps: writeMedian, readMBps: readMedian,
                writeIOPS: writeMedian * 1_000_000 / Double(workload.blockSize),
                readIOPS: readMedian * 1_000_000 / Double(workload.blockSize),
                blockSize: workload.blockSize, queueDepth: workload.queueDepth,
                iterations: workload.iterations
            )
            metrics.append(metric)
            await reporter(.init(
                phase: .preparing, currentMBps: readMedian,
                progress: Double(profileIndex + 1) / Double(profiles.count),
                transferredBytes: byteCount,
                stage: "Профиль завершён", completedMetric: metric
            ))
        }

        guard let primary = primaryMetric(in: metrics, mode: mode) else { throw BenchmarkError.cancelled }
        let stable = metrics.first(where: { $0.id == "seq-q1" })
        await reporter(.init(phase: .finished, currentMBps: primary.readMBps, progress: 1, transferredBytes: byteCount, stage: "Тест завершён", completedMetric: nil))
        return .init(
            writeMBps: primary.writeMBps, readMBps: primary.readMBps, metrics: metrics,
            recommendationWriteMBps: stable?.writeMBps,
            recommendationReadMBps: stable?.readMBps
        )
    }

    static func writableTestDirectory(for volumeURL: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        volumeURL.standardizedFileURL.path == "/" ? homeDirectory : volumeURL
    }

    private static func workloads(for mode: BenchmarkMode) -> [Workload] {
        let seqQ1 = Workload(id: "seq-q1", title: "Последовательный 1 МиБ · QD1", blockSize: 1_048_576, queueDepth: 1, random: false, iterations: 3)
        let seqQ8 = Workload(id: "seq-q8", title: "Последовательный 1 МиБ · QD8", blockSize: 1_048_576, queueDepth: 8, random: false, iterations: 3)
        let rndQ1 = Workload(id: "rnd-q1", title: "Случайный 4 КиБ · QD1", blockSize: 4_096, queueDepth: 1, random: true, iterations: 1)
        let rndQ32 = Workload(id: "rnd-q32", title: "Случайный 4 КиБ · QD32", blockSize: 4_096, queueDepth: 32, random: true, iterations: 1)
        switch mode {
        case .standard: return [seqQ1]
        case .maximum: return [seqQ8]
        case .applications: return [rndQ1, rndQ32]
        case .full: return [seqQ1, seqQ8, rndQ1, rndQ32]
        }
    }

    private static func primaryMetric(in metrics: [BenchmarkMetric], mode: BenchmarkMode) -> BenchmarkMetric? {
        let id: String
        switch mode {
        case .standard, .full: id = "seq-q1"
        case .maximum: id = "seq-q8"
        case .applications: id = "rnd-q1"
        }
        return metrics.first { $0.id == id } ?? metrics.first
    }

    private static func preallocate(
        descriptor: Int32,
        byteCount: Int64,
        useNativePreallocation: Bool
    ) throws {
        // F_PREALLOCATE can block for a long time on SMB/NFS and provides no
        // progress. Network files are sized with ftruncate and allocated by
        // the server as the measured writes arrive.
        if useNativePreallocation {
            var store = fstore_t(
                fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL),
                fst_posmode: F_PEOFPOSMODE, fst_offset: 0,
                fst_length: off_t(byteCount), fst_bytesalloc: 0
            )
            if fcntl(descriptor, F_PREALLOCATE, &store) == -1 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                _ = fcntl(descriptor, F_PREALLOCATE, &store)
            }
        }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            throw BenchmarkError.posix(operation: "Выделение места для теста", code: errno)
        }
    }

    private static func configureUncached(descriptor: Int32, disableReadAhead: Bool) {
        _ = fcntl(descriptor, F_NOCACHE, 1)
        if disableReadAhead { _ = fcntl(descriptor, F_RDAHEAD, 0) }
    }

    private struct TransferResult {
        let bytes: Int64
        let seconds: Double
        var mbPerSecond: Double { Double(bytes) / 1_000_000 / max(seconds, 0.000_001) }
    }

    private final class BatchStorage: @unchecked Sendable {
        let buffers: [UnsafeMutableRawPointer]
        let results: UnsafeMutablePointer<Int>
        let errors: UnsafeMutablePointer<Int32>
        let count: Int

        init?(count: Int, blockSize: Int) {
            var allocated: [UnsafeMutableRawPointer] = []
            for _ in 0..<count {
                guard let pointer = malloc(blockSize) else {
                    allocated.forEach(free)
                    return nil
                }
                arc4random_buf(pointer, blockSize)
                allocated.append(pointer)
            }
            self.buffers = allocated
            self.count = count
            self.results = .allocate(capacity: count)
            self.errors = .allocate(capacity: count)
            self.results.initialize(repeating: 0, count: count)
            self.errors.initialize(repeating: 0, count: count)
        }

        deinit {
            buffers.forEach(free)
            results.deinitialize(count: count)
            errors.deinitialize(count: count)
            results.deallocate()
            errors.deallocate()
        }
    }

    private static func transfer(
        descriptor: Int32, byteCount: Int64, workload: Workload,
        offsets: [Int64]?, phase: BenchmarkPhase, stage: String,
        writeMode: Bool, reporter: @escaping Reporter
    ) async throws -> TransferResult {
        let operationCount = Int((byteCount + Int64(workload.blockSize) - 1) / Int64(workload.blockSize))
        guard let storage = BatchStorage(count: workload.queueDepth, blockSize: workload.blockSize) else {
            throw BenchmarkError.posix(operation: "Выделение буфера", code: ENOMEM)
        }

        var completedOps = 0
        var completedBytes: Int64 = 0
        let started = DispatchTime.now().uptimeNanoseconds
        var lastReport = started

        while completedOps < operationCount {
            try Task.checkCancellation()
            let batchCount = min(workload.queueDepth, operationCount - completedOps)
            let batchStart = completedOps
            for index in 0..<batchCount {
                storage.results[index] = 0
                storage.errors[index] = 0
            }

            DispatchQueue.concurrentPerform(iterations: batchCount) { worker in
                let operation = batchStart + worker
                let logicalOffset = Int64(operation) * Int64(workload.blockSize)
                let offset = offsets?[operation] ?? logicalOffset
                let requested = min(workload.blockSize, Int(byteCount - logicalOffset))
                let buffer = storage.buffers[worker]
                if writeMode {
                    // A per-operation nonce prevents the file from containing one repeated block.
                    buffer.storeBytes(of: UInt64(operation).littleEndian, as: UInt64.self)
                    storage.results[worker] = pwrite(descriptor, buffer, requested, off_t(offset))
                } else {
                    storage.results[worker] = pread(descriptor, buffer, requested, off_t(offset))
                }
                if storage.results[worker] <= 0 { storage.errors[worker] = errno }
            }

            if let failed = (0..<batchCount).first(where: { storage.results[$0] <= 0 }) {
                throw BenchmarkError.posix(operation: writeMode ? "Ошибка записи" : "Ошибка чтения", code: storage.errors[failed])
            }
            completedOps += batchCount
            for index in 0..<batchCount { completedBytes += Int64(storage.results[index]) }

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport >= 80_000_000 || completedOps == operationCount {
                let seconds = Double(now - started) / 1_000_000_000
                await reporter(.init(
                    phase: phase,
                    currentMBps: Double(completedBytes) / 1_000_000 / max(seconds, 0.000_001),
                    progress: Double(completedOps) / Double(operationCount),
                    transferredBytes: completedBytes, stage: stage,
                    completedMetric: nil
                ))
                lastReport = now
            }
        }

        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return .init(bytes: completedBytes, seconds: seconds)
    }

    private static func shuffledOffsets(byteCount: Int64, blockSize: Int) -> [Int64] {
        let count = Int(byteCount / Int64(blockSize))
        var values = (0..<count).map { Int64($0) * Int64(blockSize) }
        guard values.count > 1 else { return values }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            let other = Int.random(in: 0...index)
            if other != index { values.swapAt(index, other) }
        }
        return values
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
