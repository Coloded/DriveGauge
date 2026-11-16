import Foundation
import NetworkBenchmarkProtocol

enum StartEligibility: Equatable {
    case unknown, checking, ready, blocked(String)
}

@MainActor
final class BenchmarkModel: ObservableObject {
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published var selectedVolumeID: String?
    @Published var testSize: TestSize = .standard { didSet { if oldValue != testSize { refreshEligibility() } } }
    @Published var benchmarkMode: BenchmarkMode = .standard { didSet { if oldValue != benchmarkMode { refreshEligibility() } } }
    @Published private(set) var phase: BenchmarkPhase = .idle
    @Published private(set) var currentSpeed = 0.0
    @Published private(set) var progress = 0.0
    @Published private(set) var transferredBytes: Int64 = 0
    @Published private(set) var transferTotalBytes: Int64 = 0
    @Published private(set) var elapsedSeconds: Double?
    @Published private(set) var idleSeconds: Double?
    @Published private(set) var currentStage = ""
    @Published private(set) var writeSpeed: Double?
    @Published private(set) var readSpeed: Double?
    @Published private(set) var result: BenchmarkResult?
    @Published private(set) var completedMetrics: [BenchmarkMetric] = []
    @Published private(set) var testHistory: [StoredBenchmark] = []
    @Published private(set) var selectedHistoryID: Int64?
    @Published private(set) var historyError: String?
    @Published private(set) var smartInfo: SMARTInfo?
    @Published private(set) var isLoadingSMART = false
    @Published private(set) var startEligibility: StartEligibility = .unknown

    private var benchmarkTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var eligibilityTask: Task<Void, Never>?
    private var eligibilityGate = EligibilityGenerationGate()
    private var completionGate = BenchmarkCompletionGate()
    private let store: BenchmarkStore?

    init() {
        do {
            store = try BenchmarkStore()
        } catch {
            store = nil
            historyError = error.localizedDescription
        }
        refreshVolumes()
    }

    var selectedVolume: VolumeInfo? {
        volumes.first { $0.id == selectedVolumeID }
    }

    var isRunning: Bool {
        phase == .preparing || phase == .writing || phase == .reading || phase == .stopping
    }

    var startBlockReason: String? {
        switch startEligibility {
        case .unknown: return "Выберите диск для теста"
        case .checking: return "Проверяем доступ…"
        case .ready: return nil
        case let .blocked(reason): return reason
        }
    }

    func refreshVolumes() {
        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let scanned = VolumeScanner.mountedVolumes()
            guard !Task.isCancelled else { return }
            await self?.applyVolumes(scanned)
        }
    }

    private func applyVolumes(_ scanned: [VolumeInfo]) {
        let previous = selectedVolumeID
        volumes = scanned
        if let previous, volumes.contains(where: { $0.id == previous }) {
            selectedVolumeID = previous
        } else {
            selectedVolumeID = volumes.first(where: { !$0.isReadOnly })?.id ?? volumes.first?.id
        }
        refreshSMART()
        if !isRunning { loadHistory(selecting: selectedHistoryID) }
        refreshEligibility()
    }

    func selectVolume(_ id: String) {
        guard !isRunning else { return }
        selectedVolumeID = id
        writeSpeed = nil
        readSpeed = nil
        result = nil
        completedMetrics = []
        selectedHistoryID = nil
        phase = .idle
        currentSpeed = 0
        progress = 0
        transferredBytes = 0
        transferTotalBytes = testSize.rawValue
        currentStage = ""
        loadHistory()
        refreshSMART()
        refreshEligibility()
    }

    private func refreshEligibility() {
        eligibilityTask?.cancel()
        let generation = eligibilityGate.next()
        guard let volume = selectedVolume else {
            startEligibility = .unknown
            return
        }
        if !volume.isLocal, benchmarkMode != .standard {
            startEligibility = .blocked("Для сетевого тома сейчас доступен безопасный режим «Стандартный»")
            return
        }
        startEligibility = .checking
        let bytes = volume.isLocal ? testSize.rawValue : Int64(8 * 1_048_576)
        eligibilityTask = Task.detached(priority: .utility) { [weak self] in
            let error = BenchmarkEngine.preflightError(
                at: volume.url, declaredReadOnly: volume.isReadOnly, byteCount: bytes
            )
            guard !Task.isCancelled else { return }
            await self?.applyEligibility(error.map { .blocked($0.localizedDescription) } ?? .ready, generation: generation)
        }
    }

    private func applyEligibility(_ value: StartEligibility, generation: UUID) {
        guard eligibilityGate.accepts(generation) else { return }
        startEligibility = value
    }

    func refreshSMART() {
        smartTask?.cancel()
        smartInfo = nil
        guard let volume = selectedVolume, volume.isLocal else {
            isLoadingSMART = false
            if selectedVolume != nil {
                smartInfo = SMARTInfo(
                    health: .unsupported, status: "Недоступен для сетевого тома",
                    model: nil, device: nil, interface: nil, isSSD: nil,
                    temperatureCelsius: nil, percentageUsed: nil, availableSpare: nil,
                    powerOnHours: nil, powerCycles: nil, unsafeShutdowns: nil,
                    mediaErrors: nil, errorLogEntries: nil, dataReadBytes: nil, dataWrittenBytes: nil,
                    issues: [.init(id: "network", severity: .info, text: "SMART читается на сервере, а не через сетевой том")]
                )
            }
            return
        }
        isLoadingSMART = true
        smartTask = Task.detached(priority: .utility) { [weak self] in
            let info = SMARTReader.read(volumeURL: volume.url)
            guard !Task.isCancelled else { return }
            await self?.applySMART(info)
        }
    }

    func selectHistory(_ record: StoredBenchmark) {
        guard !isRunning else { return }
        benchmarkMode = record.mode
        testSize = record.size
        showStored(record)
    }

    func toggleTest() {
        if phase == .stopping { return }
        if isRunning {
            benchmarkTask?.cancel()
            phase = .stopping
            currentStage = selectedVolume?.isLocal == false ? "Останавливаем сетевой тест…" : "Останавливаем тест…"
            currentSpeed = 0
            return
        }
        startTest()
    }

    private func startTest() {
        guard let volume = selectedVolume else { return }
        guard startEligibility == .ready else { return }
        writeSpeed = nil
        readSpeed = nil
        result = nil
        completedMetrics = []
        selectedHistoryID = nil
        currentSpeed = 0
        progress = 0
        transferredBytes = 0
        transferTotalBytes = testSize.rawValue
        currentStage = "Проверка диска"
        phase = .preparing

        let byteCount = testSize.rawValue
        let mode = benchmarkMode
        let runID = completionGate.begin()
        benchmarkTask = Task.detached(priority: .userInitiated) { [self] in
            do {
                let result: BenchmarkResult
                if volume.isLocal {
                    result = try await BenchmarkEngine.run(at: volume.url, byteCount: byteCount, mode: mode) { update in
                        await self.apply(update)
                    }
                } else {
                    result = try await NetworkBenchmarkEngine.run(at: volume, byteCount: byteCount, mode: mode) { update in
                        await self.apply(update)
                    }
                }
                try Task.checkCancellation()
                await self.apply(result, runID: runID)
            } catch is CancellationError {
                await self.resetAfterCancellation(runID: runID)
            } catch {
                await self.apply(error, runID: runID)
            }
        }
    }

    private func apply(_ update: BenchmarkUpdate) {
        guard phase != .stopping, phase != .finished else { return }
        phase = update.phase
        currentSpeed = update.currentMBps
        progress = update.progress
        transferredBytes = update.transferredBytes
        transferTotalBytes = update.totalBytes
        currentStage = update.stage
        elapsedSeconds = update.elapsedSeconds
        idleSeconds = update.idleSeconds
        if let metric = update.completedMetric,
           !completedMetrics.contains(where: { $0.id == metric.id }) {
            completedMetrics.append(metric)
        }
        switch update.phase {
        case .writing:
            writeSpeed = update.currentMBps
        case .reading:
            readSpeed = update.currentMBps
        case .stopping:
            break
        default:
            break
        }
    }

    private func apply(_ result: BenchmarkResult, runID: UUID) {
        guard completionGate.accepts(runID), phase != .stopping else { return }
        writeSpeed = result.writeMBps
        readSpeed = result.readMBps
        self.result = result
        completedMetrics = result.metrics
        phase = .finished
        currentSpeed = result.readMBps
        progress = 1
        transferredBytes = result.metadata?.testedBytes ?? testSize.rawValue
        transferTotalBytes = result.metadata?.testedBytes ?? testSize.rawValue
        benchmarkTask = nil
        _ = completionGate.finish(runID)
        if let volume = selectedVolume, let store {
            do {
                selectedHistoryID = try store.save(
                    volume: volume, mode: benchmarkMode, size: testSize, result: result
                )
                historyError = nil
            } catch {
                historyError = error.localizedDescription
            }
        }
        refreshVolumes()
    }

    private func apply(_ error: Error, runID: UUID) {
        guard completionGate.accepts(runID) else { return }
        phase = .failed(error.localizedDescription)
        currentSpeed = 0
        progress = 0
        transferredBytes = 0
        transferTotalBytes = testSize.rawValue
        benchmarkTask = nil
        _ = completionGate.finish(runID)
    }

    private func resetAfterCancellation(runID: UUID) {
        guard completionGate.accepts(runID) else { return }
        phase = .idle
        currentSpeed = 0
        progress = 0
        transferredBytes = 0
        transferTotalBytes = testSize.rawValue
        benchmarkTask = nil
        completionGate.cancel(runID)
    }

    private func applySMART(_ info: SMARTInfo) {
        smartInfo = info
        isLoadingSMART = false
        smartTask = nil
    }

    private func loadHistory(selecting preferredID: Int64? = nil) {
        guard let volume = selectedVolume, let store else {
            testHistory = []
            return
        }
        do {
            testHistory = try store.history(volumeID: volume.id)
            historyError = nil
            guard !isRunning else { return }
            let record = preferredID.flatMap { id in testHistory.first(where: { $0.id == id }) }
                ?? testHistory.first
            if let record { showStored(record) }
        } catch {
            testHistory = []
            historyError = error.localizedDescription
        }
    }

    private func showStored(_ record: StoredBenchmark) {
        selectedHistoryID = record.id
        result = record.result
        completedMetrics = record.result.metrics
        writeSpeed = record.result.writeMBps
        readSpeed = record.result.readMBps
        currentSpeed = record.result.readMBps
        progress = 1
        transferredBytes = record.size.rawValue
        transferTotalBytes = record.result.metadata?.testedBytes ?? record.size.rawValue
        phase = .finished
        currentStage = "Сохранённый тест"
    }
}
