import CSQLite
import Foundation
import BenchmarkPersistence

struct StoredBenchmark: Identifiable, Sendable {
    let id: Int64
    let volumeID: String
    let volumeName: String
    let date: Date
    let mode: BenchmarkMode
    let size: TestSize
    let result: BenchmarkResult
}

private struct StoredMetric: Codable {
    let id: String
    let title: String
    let writeMBps: Double
    let readMBps: Double
    let writeIOPS: Double
    let readIOPS: Double
    let blockSize: Int
    let queueDepth: Int
    let iterations: Int

    init(_ metric: BenchmarkMetric) {
        id = metric.id
        title = metric.title
        writeMBps = metric.writeMBps
        readMBps = metric.readMBps
        writeIOPS = metric.writeIOPS
        readIOPS = metric.readIOPS
        blockSize = metric.blockSize
        queueDepth = metric.queueDepth
        iterations = metric.iterations
    }

    var metric: BenchmarkMetric {
        .init(
            id: id, title: title, writeMBps: writeMBps, readMBps: readMBps,
            writeIOPS: writeIOPS, readIOPS: readIOPS, blockSize: blockSize,
            queueDepth: queueDepth, iterations: iterations
        )
    }
}

enum BenchmarkStoreError: LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        switch self {
        case let .sqlite(message): return "Ошибка базы результатов: \(message)"
        }
    }
}

final class BenchmarkStore {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL? = nil) throws {
        let url: URL
        if let databaseURL {
            url = databaseURL
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw BenchmarkStoreError.sqlite("папка Application Support недоступна")
            }
            let directory = support.appendingPathComponent("DriveGauge", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("History.sqlite")
        }

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "не удалось открыть файл"
            if let database { sqlite3_close(database) }
            database = nil
            throw BenchmarkStoreError.sqlite(message)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try BenchmarkStoreSchema.migrate(database)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    @discardableResult
    func save(
        volume: VolumeInfo,
        mode: BenchmarkMode,
        size: TestSize,
        result: BenchmarkResult,
        date: Date = Date()
    ) throws -> Int64 {
        let sql = """
            INSERT INTO benchmark_tests (
                volume_id, volume_name, created_at, mode, size_bytes,
                write_mbps, read_mbps, recommendation_write,
                recommendation_read, metrics_json, engine, filesystem,
                tested_bytes, write_seconds, sync_seconds, read_seconds,
                adaptive, algorithm_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let metrics = try encoder.encode(result.metrics.map(StoredMetric.init))
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bind(volume.id, to: 1, in: statement)
        bind(volume.name, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        bind(mode.rawValue, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, size.rawValue)
        sqlite3_bind_double(statement, 6, result.writeMBps)
        sqlite3_bind_double(statement, 7, result.readMBps)
        bind(result.recommendationWriteMBps, to: 8, in: statement)
        bind(result.recommendationReadMBps, to: 9, in: statement)
        _ = metrics.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 10, bytes.baseAddress, Int32(bytes.count), transient)
        }
        bind(result.metadata?.engine, to: 11, in: statement)
        bind(result.metadata?.fileSystem, to: 12, in: statement)
        bind(result.metadata?.testedBytes, to: 13, in: statement)
        bind(result.metadata?.writeSeconds, to: 14, in: statement)
        bind(result.metadata?.syncSeconds, to: 15, in: statement)
        bind(result.metadata?.readSeconds, to: 16, in: statement)
        if let adaptive = result.metadata?.adaptive { sqlite3_bind_int(statement, 17, adaptive ? 1 : 0) }
        else { sqlite3_bind_null(statement, 17) }
        if let version = result.metadata?.algorithmVersion { sqlite3_bind_int(statement, 18, Int32(version)) }
        else { sqlite3_bind_null(statement, 18) }

        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        return sqlite3_last_insert_rowid(database)
    }

    func history(volumeID: String, limit: Int = 200) throws -> [StoredBenchmark] {
        let sql = """
            SELECT id, volume_id, volume_name, created_at, mode, size_bytes,
                   write_mbps, read_mbps, recommendation_write,
                   recommendation_read, metrics_json, engine, filesystem,
                   tested_bytes, write_seconds, sync_seconds, read_seconds,
                   adaptive, algorithm_version
            FROM benchmark_tests
            WHERE volume_id = ?
            ORDER BY created_at DESC, id DESC
            LIMIT ?;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(volumeID, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var records: [StoredBenchmark] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let mode = BenchmarkMode(rawValue: text(statement, 4)),
                  let size = TestSize(rawValue: sqlite3_column_int64(statement, 5)),
                  let bytes = sqlite3_column_blob(statement, 10) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 10)))
            guard let storedMetrics = try? decoder.decode([StoredMetric].self, from: data) else { continue }

            let recommendationWrite = nullableDouble(statement, 8)
            let recommendationRead = nullableDouble(statement, 9)
            let metadata: BenchmarkMetadata?
            if sqlite3_column_type(statement, 11) != SQLITE_NULL {
                metadata = .init(
                    engine: text(statement, 11),
                    fileSystem: nullableText(statement, 12),
                    testedBytes: nullableInt64(statement, 13),
                    writeSeconds: nullableDouble(statement, 14),
                    syncSeconds: nullableDouble(statement, 15),
                    readSeconds: nullableDouble(statement, 16),
                    adaptive: sqlite3_column_type(statement, 17) != SQLITE_NULL && sqlite3_column_int(statement, 17) != 0,
                    algorithmVersion: sqlite3_column_type(statement, 18) == SQLITE_NULL ? 0 : Int(sqlite3_column_int(statement, 18))
                )
            } else { metadata = nil }
            let result = BenchmarkResult(
                writeMBps: sqlite3_column_double(statement, 6),
                readMBps: sqlite3_column_double(statement, 7),
                metrics: storedMetrics.map(\.metric),
                recommendationWriteMBps: recommendationWrite,
                recommendationReadMBps: recommendationRead,
                metadata: metadata
            )
            records.append(.init(
                id: sqlite3_column_int64(statement, 0),
                volumeID: text(statement, 1),
                volumeName: text(statement, 2),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                mode: mode, size: size, result: result
            ))
        }
        return records
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw lastError() }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_int64(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value { bind(value, to: index, in: statement) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func nullableDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func nullableInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private func nullableText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func lastError() -> BenchmarkStoreError {
        .sqlite(database.map { String(cString: sqlite3_errmsg($0)) } ?? "неизвестная ошибка")
    }
}
