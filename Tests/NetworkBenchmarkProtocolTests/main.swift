import Foundation
import NetworkBenchmarkProtocol
import BenchmarkPersistence
import CSQLite

enum SelfTestFailure: Error { case failed(String) }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SelfTestFailure.failed(message) }
}

func workerURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("DriveGaugeNetworkWorker")
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("drivegauge-worker-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func runWorker(
    root: URL, runID: UUID, fault: String? = nil, cleanup: Bool = false,
    terminateAfter: TimeInterval? = nil, availableBytes: Int64? = nil
) throws -> (Int32, Data) {
    let process = Process()
    process.executableURL = workerURL()
    var arguments = [
        "--root", root.path, "--run-id", runID.uuidString,
        "--max-bytes", String(8 * 1_048_576), "--target-seconds", "0.05",
        "--block-size", String(1_048_576)
    ]
    if let fault { arguments += ["--fault", fault] }
    if cleanup { arguments += ["--cleanup-only", "1"] }
    if let availableBytes { arguments += ["--available-bytes", String(availableBytes)] }
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    if let terminateAfter {
        DispatchQueue.global().asyncAfter(deadline: .now() + terminateAfter) {
            if process.isRunning { process.terminate() }
        }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

func runSelfTests() throws {
    let planned = NetworkBenchmarkPlanning.adaptiveByteCount(
        probeMBps: 10, targetSeconds: 12, minimumBytes: 8 * 1_048_576,
        maximumBytes: 256_000_000, availableBytes: 2_000_000_000, blockSize: 1_048_576
    )
    try check(planned % 1_048_576 == 0, "adaptive size is not block aligned")
    try check(planned <= 120_000_000 && planned > 100_000_000, "adaptive size is not speed limited")

    let available = NetworkBenchmarkPlanning.safetyReserve + 10 * 1_048_576
    let limited = NetworkBenchmarkPlanning.adaptiveByteCount(
        probeMBps: 1_000, targetSeconds: 12, minimumBytes: 8 * 1_048_576,
        maximumBytes: 4_000_000_000, availableBytes: available, blockSize: 1_048_576
    )
    try check(limited == 10 * 1_048_576, "reserve limit failed")
    let slow = NetworkBenchmarkPlanning.adaptiveByteCount(
        probeMBps: 0.01, targetSeconds: 12, minimumBytes: 8 * 1_048_576,
        maximumBytes: 256_000_000, availableBytes: 1_000_000_000, blockSize: 1_048_576
    )
    try check(slow == 8 * 1_048_576, "slow link minimum failed")
    let capped = NetworkBenchmarkPlanning.adaptiveByteCount(
        probeMBps: 10_000, targetSeconds: 12, minimumBytes: 8 * 1_048_576,
        maximumBytes: 256_000_000, availableBytes: 10_000_000_000, blockSize: 1_048_576
    )
    try check(capped <= 256_000_000 && capped > 250_000_000, "maximum cap failed")

    let pathRoot = URL(fileURLWithPath: "/tmp/network-test", isDirectory: true)
    let pathRun = UUID()
    let valid = pathRoot.appendingPathComponent(".drive-gauge-\(pathRun.uuidString).tmp")
    try check(NetworkBenchmarkPlanning.isSafeTemporaryFile(valid, root: pathRoot, runID: pathRun), "valid temp rejected")
    try check(!NetworkBenchmarkPlanning.isSafeTemporaryFile(pathRoot.appendingPathComponent("user.txt"), root: pathRoot, runID: pathRun), "user file accepted")
    try check(NetworkFileSystemClassification.isRemote("smbfs"), "SMB was not classified as remote")
    try check(NetworkFileSystemClassification.isRemote("NFS"), "NFS was not classified as remote")
    try check(!NetworkFileSystemClassification.isRemote("apfs"), "APFS was classified as remote")

    let unknownJSON = "{\"protocolVersion\":1,\"kind\":\"writing\",\"runID\":\"r\",\"transferredBytes\":12,\"extra\":true}".data(using: .utf8)!
    try check(try JSONDecoder().decode(NetworkWorkerEvent.self, from: unknownJSON).transferredBytes == 12, "unknown JSON field failed")
    let expectedRun = UUID().uuidString
    let encoder = JSONEncoder()
    let first = try encoder.encode(NetworkWorkerEvent(kind: .writing, runID: expectedRun, transferredBytes: 1))
    let wrong = try encoder.encode(NetworkWorkerEvent(kind: .writing, runID: "wrong", transferredBytes: 2))
    let third = try encoder.encode(NetworkWorkerEvent(kind: .reading, runID: expectedRun, transferredBytes: 3))
    var stream = NetworkEventStreamDecoder(expectedRunID: expectedRun)
    let streamData = first + Data([0x0A]) + Data("{broken}\n".utf8) + wrong + Data([0x0A]) + third + Data([0x0A])
    let decoded = stream.append(streamData)
    try check(decoded.map(\.transferredBytes) == [1, 3], "stream ordering/run filtering failed")
    try check(stream.invalidLineCount == 2, "invalid line count failed")
    try check(NetworkWatchdogPolicy.idleNoticeSeconds == 3, "idle notice threshold changed")
    try check(NetworkWatchdogPolicy.transferStallSeconds == 15, "transfer stall threshold changed")
    try check(NetworkWatchdogPolicy.syncStallSeconds == 20, "sync stall threshold changed")
    try check(NetworkWatchdogPolicy.totalLimitSeconds == 60, "total timeout changed")
    try check(NetworkWatchdogPolicy.maximumStopMilliseconds < 3_000, "stop budget exceeds UI requirement")
    try check(NetworkWatchdogPolicy.evaluate(kind: .writing, idleSeconds: 3, phaseSeconds: 3, totalSeconds: 3) == .showIdle, "idle watchdog failed")
    try check(NetworkWatchdogPolicy.evaluate(kind: nil, idleSeconds: 3, phaseSeconds: 3, totalSeconds: 3) == .showIdle, "pre-ready idle watchdog failed")
    try check(NetworkWatchdogPolicy.evaluate(kind: .ready, idleSeconds: 15, phaseSeconds: 15, totalSeconds: 15) == .transferStalled, "ready stall watchdog failed")
    try check(NetworkWatchdogPolicy.evaluate(kind: .reading, idleSeconds: 15, phaseSeconds: 15, totalSeconds: 15) == .transferStalled, "transfer watchdog failed")
    try check(NetworkWatchdogPolicy.evaluate(kind: .syncing, idleSeconds: 0, phaseSeconds: 20, totalSeconds: 20) == .syncStalled, "sync watchdog failed")
    try check(NetworkWatchdogPolicy.evaluate(kind: .ready, idleSeconds: 0, phaseSeconds: 0, totalSeconds: 60) == .totalTimedOut, "total watchdog failed")
    var gate = EligibilityGenerationGate()
    let stale = gate.generation
    let current = gate.next()
    try check(!gate.accepts(stale) && gate.accepts(current), "eligibility generation gate failed")
    var completionGate = BenchmarkCompletionGate()
    let cancelledRun = completionGate.begin()
    try check(completionGate.accepts(cancelledRun), "completion gate rejected active run")
    completionGate.cancel(cancelledRun)
    try check(!completionGate.accepts(cancelledRun), "cancelled run could reach persistence")
    try check(!completionGate.finish(cancelledRun), "cancelled run was accepted as complete")

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let userFile = root.appendingPathComponent("user.txt")
    try Data("keep".utf8).write(to: userFile)
    let successful = try runWorker(root: root, runID: UUID())
    try check(successful.0 == 0, "worker failed")
    let events = successful.1.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(NetworkWorkerEvent.self, from: Data($0)) }
    try check(events.contains { $0.kind == .completed }, "completion missing")
    try check(events.contains { $0.kind == .cleanupCompleted }, "cleanup missing")
    let mainWrites = events.filter { $0.kind == .writing && $0.message == "Основная запись" }.compactMap(\.transferredBytes)
    let reads = events.filter { $0.kind == .reading }.compactMap(\.transferredBytes)
    try check(zip(mainWrites, mainWrites.dropFirst()).allSatisfy { $0 <= $1 }, "writing counter is not monotonic")
    try check(zip(reads, reads.dropFirst()).allSatisfy { $0 <= $1 }, "reading counter is not monotonic")
    try check(try String(contentsOf: userFile, encoding: .utf8) == "keep", "user file changed")

    let enospc = try runWorker(root: root, runID: UUID(), fault: "enospc")
    try check(enospc.0 != 0, "ENOSPC fault succeeded")
    try check((try FileManager.default.contentsOfDirectory(atPath: root.path)).sorted() == ["user.txt"], "ENOSPC left temp")
    let insufficient = try runWorker(
        root: root, runID: UUID(),
        availableBytes: NetworkBenchmarkPlanning.safetyReserve + 1_048_576
    )
    try check(insufficient.0 != 0, "insufficient-space injection succeeded")
    try check((try FileManager.default.contentsOfDirectory(atPath: root.path)).sorted() == ["user.txt"], "insufficient-space test created temp")

    let denied = root.appendingPathComponent("denied", isDirectory: true)
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: denied.path)
    let deniedResult = try runWorker(root: denied, runID: UUID())
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
    try check(deniedResult.0 != 0, "read-only directory test succeeded")

    let crashRun = UUID()
    let crashed = try runWorker(root: root, runID: crashRun, fault: "crash")
    try check(crashed.0 != 0, "crash fault succeeded")
    let crashTemp = root.appendingPathComponent(".drive-gauge-\(crashRun.uuidString).tmp")
    try check(FileManager.default.fileExists(atPath: crashTemp.path), "crash fixture did not leave temp")
    let cleanup = try runWorker(root: root, runID: crashRun, cleanup: true)
    try check(cleanup.0 == 0 && !FileManager.default.fileExists(atPath: crashTemp.path), "exact cleanup failed")

    let collisionRun = UUID()
    let collisionFile = root.appendingPathComponent(".drive-gauge-\(collisionRun.uuidString).tmp")
    try Data("do-not-touch".utf8).write(to: collisionFile)
    let collision = try runWorker(root: root, runID: collisionRun)
    try check(collision.0 != 0, "O_EXCL collision unexpectedly succeeded")
    try check(try String(contentsOf: collisionFile, encoding: .utf8) == "do-not-touch", "collision file was changed or deleted")
    try FileManager.default.removeItem(at: collisionFile)

    let corrupt = try runWorker(root: root, runID: UUID(), fault: "corrupt")
    try check(corrupt.0 == 0, "corrupt-line fixture did not complete")
    try check(String(decoding: corrupt.1, as: UTF8.self).contains("{invalid-json}"), "corrupt line missing")

    let stallRun = UUID()
    let stalled = try runWorker(root: root, runID: stallRun, fault: "stall", terminateAfter: 0.3)
    try check(stalled.0 != 0, "stall fixture was not terminated")
    let stallCleanup = try runWorker(root: root, runID: stallRun, cleanup: true)
    try check(stallCleanup.0 == 0, "stall cleanup failed")

    let databaseURL = root.appendingPathComponent("legacy.sqlite")
    var database: OpaquePointer?
    try check(sqlite3_open(databaseURL.path, &database) == SQLITE_OK, "legacy database open failed")
    defer { sqlite3_close(database) }
    let legacySQL = "CREATE TABLE benchmark_tests (id INTEGER PRIMARY KEY AUTOINCREMENT, volume_id TEXT NOT NULL, volume_name TEXT NOT NULL, created_at REAL NOT NULL, mode TEXT NOT NULL, size_bytes INTEGER NOT NULL, write_mbps REAL NOT NULL, read_mbps REAL NOT NULL, recommendation_write REAL, recommendation_read REAL, metrics_json BLOB NOT NULL);"
    try check(sqlite3_exec(database, legacySQL, nil, nil, nil) == SQLITE_OK, "legacy schema fixture failed")
    try check(sqlite3_exec(database, "INSERT INTO benchmark_tests (volume_id,volume_name,created_at,mode,size_bytes,write_mbps,read_mbps,metrics_json) VALUES ('legacy','Legacy',1,'standard',268435456,10,20,X'5B5D');", nil, nil, nil) == SQLITE_OK, "legacy row fixture failed")
    try BenchmarkStoreSchema.migrate(database)
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(database, "PRAGMA table_info(benchmark_tests);", -1, &statement, nil) == SQLITE_OK, "schema inspection failed")
    defer { sqlite3_finalize(statement) }
    var columns = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
        if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
    }
    try check(columns.isSuperset(of: ["engine", "filesystem", "tested_bytes", "write_seconds", "sync_seconds", "read_seconds", "adaptive", "algorithm_version"]), "legacy migration missed metadata columns")
    try check(sqlite3_exec(database, "UPDATE benchmark_tests SET engine='network-adaptive', filesystem='smbfs', tested_bytes=8388608, write_seconds=1.2, sync_seconds=0.2, read_seconds=0.8, adaptive=1, algorithm_version=1 WHERE volume_id='legacy';", nil, nil, nil) == SQLITE_OK, "metadata write failed")
    sqlite3_finalize(statement)
    statement = nil
    try check(sqlite3_prepare_v2(database, "SELECT volume_name,engine,filesystem,tested_bytes,adaptive,algorithm_version,metrics_json FROM benchmark_tests WHERE volume_id='legacy';", -1, &statement, nil) == SQLITE_OK, "metadata read prepare failed")
    try check(sqlite3_step(statement) == SQLITE_ROW, "legacy row disappeared")
    try check(String(cString: sqlite3_column_text(statement, 0)) == "Legacy", "legacy row changed")
    try check(String(cString: sqlite3_column_text(statement, 1)) == "network-adaptive", "engine roundtrip failed")
    try check(String(cString: sqlite3_column_text(statement, 2)) == "smbfs", "filesystem roundtrip failed")
    try check(sqlite3_column_int64(statement, 3) == 8_388_608, "tested bytes roundtrip failed")
    try check(sqlite3_column_int(statement, 4) == 1 && sqlite3_column_int(statement, 5) == 1, "metadata flags roundtrip failed")
}

do {
    try runSelfTests()
    print("Network benchmark self-tests: PASS")
} catch {
    FileHandle.standardError.write(Data("Network benchmark self-tests: FAIL: \(error)\n".utf8))
    exit(1)
}
