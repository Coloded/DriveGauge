import Foundation

enum BenchmarkMode: String, Sendable { case standard, maximum, applications, full }
enum BenchmarkPhase: Equatable, Sendable { case idle, preparing, writing, reading, stopping, finished; case failed(String) }

struct BenchmarkMetric: Sendable {
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

struct BenchmarkMetadata: Sendable {
    let engine: String
    let fileSystem: String?
    let testedBytes: Int64?
    let writeSeconds: Double?
    let syncSeconds: Double?
    let readSeconds: Double?
    let adaptive: Bool
    let algorithmVersion: Int
}

struct BenchmarkResult: Sendable {
    let writeMBps: Double
    let readMBps: Double
    let metrics: [BenchmarkMetric]
    let recommendationWriteMBps: Double?
    let recommendationReadMBps: Double?
    let metadata: BenchmarkMetadata?
}

struct BenchmarkUpdate: Sendable {
    let phase: BenchmarkPhase
    let currentMBps: Double
    let progress: Double
    let transferredBytes: Int64
    let totalBytes: Int64
    let elapsedSeconds: Double?
    let idleSeconds: Double?
    let stage: String
    let completedMetric: BenchmarkMetric?
}

enum BenchmarkEngine {
    typealias Reporter = @Sendable (BenchmarkUpdate) async -> Void
}

struct VolumeInfo: Sendable {
    let url: URL
    let fileSystemType: String?
}
