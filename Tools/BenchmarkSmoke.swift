import Foundation

@main
struct BenchmarkSmoke {
    static func main() async {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--smart" {
            let info = SMARTReader.read(volumeURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            print("SMART: \(info.status), wear=\(info.percentageUsed.map(String.init) ?? "n/a"), temperature=\(info.temperatureCelsius.map(String.init) ?? "n/a"), issues=\(info.issues.map(\.text).joined(separator: "; "))")
            return
        }
        if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--run" {
            let url = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let bytes = Int64(CommandLine.arguments[3]) ?? 16 * 1_024 * 1_024
            guard let mode = BenchmarkMode(rawValue: CommandLine.arguments[4]) else {
                fputs("unknown mode\n", stderr)
                exit(2)
            }
            do {
                let result = try await BenchmarkEngine.run(at: url, byteCount: bytes, mode: mode) { _ in }
                print("mode \(mode.rawValue): \(result.metrics.count) profile(s), write \(String(format: "%.1f", result.writeMBps)), read \(String(format: "%.1f", result.readMBps)) MB/s")
            } catch {
                fputs("smoke test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--preflight" {
            let url = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let readOnly = CommandLine.arguments[3] == "true"
            let bytes = Int64(CommandLine.arguments[4]) ?? 0
            let error = BenchmarkEngine.preflightError(
                at: url,
                declaredReadOnly: readOnly,
                byteCount: bytes
            )
            print(error?.localizedDescription ?? "allowed")
            return
        }
        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let free = FileSystemCapacity.availableBytes(at: url) ?? -1
            let total = FileSystemCapacity.totalBytes(at: url) ?? -1
            print("capacity — total \(total), available \(free)")
            return
        }
        do {
            let result = try await BenchmarkEngine.run(
                at: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                byteCount: 16 * 1_024 * 1_024
            ) { _ in }
            print(String(format: "smoke test passed — write %.1f MB/s, read %.1f MB/s", result.writeMBps, result.readMBps))
        } catch {
            fputs("smoke test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
