import Foundation
import NetworkBenchmarkProtocol

enum IntegrationFailure: Error { case failed(String) }

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw IntegrationFailure.failed(message) }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("drivegauge-engine-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func configuration(worker: URL, fault: String? = nil) -> NetworkBenchmarkEngine.Configuration {
    var arguments: [String] = []
    if let fault { arguments += ["--fault", fault] }
    return .init(
        workerURL: worker, additionalWorkerArguments: arguments,
        targetSeconds: 0.05, pollMilliseconds: 50,
        watchdog: .init(
            idleNoticeSeconds: 1, transferStallSeconds: 2,
            syncStallSeconds: 2, totalLimitSeconds: 5,
            terminateGraceMilliseconds: 200, killWaitMilliseconds: 200,
            cleanupLimitMilliseconds: 400
        )
    )
}

func runCompleted(worker: URL, root: URL, fault: String) async throws {
    let volume = VolumeInfo(url: root, fileSystemType: "smbfs")
    let result = try await NetworkBenchmarkEngine.run(
        at: volume, byteCount: 8 * 1_048_576, mode: .standard,
        reporter: { _ in }, configuration: configuration(worker: worker, fault: fault)
    )
    try require(result.metadata?.engine == "network-adaptive", "engine did not return a validated result for \(fault)")
}

@main
struct NetworkEngineIntegrationTests {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw IntegrationFailure.failed("worker path missing") }
            let worker = URL(fileURLWithPath: CommandLine.arguments[1])
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            // Malformed and wrong-run events must be ignored while subsequent valid
            // events continue through the real engine decoder and process lifecycle.
            try await runCompleted(worker: worker, root: root, fault: "corrupt")
            try await runCompleted(worker: worker, root: root, fault: "wrongid")

            let volume = VolumeInfo(url: root, fileSystemType: "smbfs")
            let stallStart = ContinuousClock.now
            do {
                _ = try await NetworkBenchmarkEngine.run(
                    at: volume, byteCount: 8 * 1_048_576, mode: .standard,
                    reporter: { _ in }, configuration: configuration(worker: worker, fault: "stall")
                )
                throw IntegrationFailure.failed("stalled worker unexpectedly succeeded")
            } catch let error as NetworkBenchmarkError {
                guard case .stalled = error else { throw error }
            }
            let stallElapsed = stallStart.duration(to: .now).components.seconds
            try require(stallElapsed >= 2 && stallElapsed < 4, "production watchdog did not terminate fixture in configured budget")
            try require(
                try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "watchdog path left a temporary file"
            )

            let cancellationStart = ContinuousClock.now
            let task = Task {
                try await NetworkBenchmarkEngine.run(
                    at: volume, byteCount: 8 * 1_048_576, mode: .standard,
                    reporter: { _ in }, configuration: configuration(worker: worker, fault: "stall")
                )
            }
            try await Task.sleep(for: .milliseconds(250))
            task.cancel()
            do {
                _ = try await task.value
                throw IntegrationFailure.failed("cancelled engine unexpectedly succeeded")
            } catch is CancellationError { }
            let cancellationElapsed = cancellationStart.duration(to: .now).components.seconds
            try require(cancellationElapsed < 3, "engine cancellation exceeded the UI stop budget")
            try require(
                try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                "cancellation path left a temporary file"
            )
            print("Network engine integration tests: PASS")
        } catch {
            FileHandle.standardError.write(Data("Network engine integration tests: FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
