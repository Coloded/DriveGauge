import CSQLite
import Foundation

public enum BenchmarkStoreSchema {
    public static func migrate(_ database: OpaquePointer?) throws {
        try execute(database, """
            CREATE TABLE IF NOT EXISTS benchmark_tests (
                id INTEGER PRIMARY KEY AUTOINCREMENT, volume_id TEXT NOT NULL,
                volume_name TEXT NOT NULL, created_at REAL NOT NULL, mode TEXT NOT NULL,
                size_bytes INTEGER NOT NULL, write_mbps REAL NOT NULL, read_mbps REAL NOT NULL,
                recommendation_write REAL, recommendation_read REAL, metrics_json BLOB NOT NULL
            );
            """)
        try execute(database, "CREATE INDEX IF NOT EXISTS benchmark_tests_volume_date ON benchmark_tests(volume_id, created_at DESC);")
        for (name, definition) in [
            ("engine", "TEXT"), ("filesystem", "TEXT"), ("tested_bytes", "INTEGER"),
            ("write_seconds", "REAL"), ("sync_seconds", "REAL"), ("read_seconds", "REAL"),
            ("adaptive", "INTEGER"), ("algorithm_version", "INTEGER")
        ] { try ensureColumn(database, name: name, definition: definition) }
    }

    private static func ensureColumn(_ database: OpaquePointer?, name: String, definition: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(benchmark_tests);", -1, &statement, nil) == SQLITE_OK else { throw error(database) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1), String(cString: value) == name { return }
        }
        try execute(database, "ALTER TABLE benchmark_tests ADD COLUMN \(name) \(definition);")
    }

    private static func execute(_ database: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error(database) }
    }

    private static func error(_ database: OpaquePointer?) -> NSError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable"
        return NSError(domain: "DriveGauge.BenchmarkStoreSchema", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
