import Darwin
import Foundation

enum FileSystemCapacity {
    static func availableBytes(at url: URL) -> Int64? {
        var information = statfs()
        guard url.path.withCString({ statfs($0, &information) }) == 0 else { return nil }
        return Int64(clamping: UInt64(information.f_bavail) * UInt64(information.f_bsize))
    }
}

@main
struct LocalBenchmarkSmoke {
    static func main() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivegauge-local-smoke-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let result = try await BenchmarkEngine.run(
                at: root, byteCount: 8 * 1_048_576, mode: .standard,
                reporter: { _ in }
            )
            guard result.writeMBps > 0, result.readMBps > 0, result.metrics.count == 1 else {
                throw BenchmarkError.cancelled
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            guard leftovers.isEmpty else { throw BenchmarkError.notWritable("temporary file was not removed") }
            print("Local benchmark smoke: PASS")
        } catch {
            FileHandle.standardError.write(Data("Local benchmark smoke: FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
