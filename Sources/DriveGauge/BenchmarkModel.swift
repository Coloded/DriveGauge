import Foundation

@MainActor
final class BenchmarkModel: ObservableObject {
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published var selectedVolumeID: String?
    @Published var testSize: TestSize = .standard
    @Published var benchmarkMode: BenchmarkMode = .standard
    @Published private(set) var phase: BenchmarkPhase = .idle
    @Published private(set) var currentSpeed = 0.0
    @Published private(set) var progress = 0.0
    @Published private(set) var transferredBytes: Int64 = 0
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

    private var benchmarkTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
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
        phase == .preparing || phase == .writing || phase == .reading
    }

    var startBlockReason: String? {
        guard let volume = selectedVolume else { return "Выберите диск для теста" }
        return BenchmarkEngine.preflightError(
            at: volume.url,
            declaredReadOnly: volume.isReadOnly,
            byteCount: testSize.rawValue
        )?.localizedDescription
    }

    func refreshVolumes() {
        let previous = selectedVolumeID
        volumes = VolumeScanner.mountedVolumes()
        if let previous, volumes.contains(where: { $0.id == previous }) {
            selectedVolumeID = previous
        } else {
            selectedVolumeID = volumes.first(where: { !$0.isReadOnly })?.id ?? volumes.first?.id
        }
        refreshSMART()
        if !isRunning { loadHistory(selecting: selectedHistoryID) }
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
        currentStage = ""
        loadHistory()
        refreshSMART()
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
        if isRunning {
            benchmarkTask?.cancel()
            benchmarkTask = nil
            phase = .idle
            currentSpeed = 0
            progress = 0
            transferredBytes = 0
            return
        }
        startTest()
    }

    private func startTest() {
        guard let volume = selectedVolume else { return }
        guard startBlockReason == nil else { return }
        writeSpeed = nil
        readSpeed = nil
        result = nil
        completedMetrics = []
        selectedHistoryID = nil
        currentSpeed = 0
        progress = 0
        transferredBytes = 0
        currentStage = "Проверка диска"
        phase = .preparing

        let byteCount = testSize.rawValue
        let mode = benchmarkMode
        benchmarkTask = Task.detached(priority: .userInitiated) { [self] in
            do {
                let result = try await BenchmarkEngine.run(at: volume.url, byteCount: byteCount, mode: mode) { update in
                    await self.apply(update)
                }
                await self.apply(result)
            } catch is CancellationError {
                await self.resetAfterCancellation()
            } catch {
                await self.apply(error)
            }
        }
    }

    private func apply(_ update: BenchmarkUpdate) {
        phase = update.phase
        currentSpeed = update.currentMBps
        progress = update.progress
        transferredBytes = update.transferredBytes
        currentStage = update.stage
        if let metric = update.completedMetric,
           !completedMetrics.contains(where: { $0.id == metric.id }) {
            completedMetrics.append(metric)
        }
        switch update.phase {
        case .writing:
            writeSpeed = update.currentMBps
        case .reading:
            readSpeed = update.currentMBps
        default:
            break
        }
    }

    private func apply(_ result: BenchmarkResult) {
        writeSpeed = result.writeMBps
        readSpeed = result.readMBps
        self.result = result
        completedMetrics = result.metrics
        phase = .finished
        currentSpeed = result.readMBps
        progress = 1
        transferredBytes = testSize.rawValue
        benchmarkTask = nil
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

    private func apply(_ error: Error) {
        phase = .failed(error.localizedDescription)
        currentSpeed = 0
        progress = 0
        transferredBytes = 0
        benchmarkTask = nil
    }

    private func resetAfterCancellation() {
        phase = .idle
        currentSpeed = 0
        progress = 0
        transferredBytes = 0
        benchmarkTask = nil
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
        phase = .finished
        currentStage = "Сохранённый тест"
    }
}
