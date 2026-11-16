import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = BenchmarkModel()
    @State private var showsSMART = false
    @State private var showsResults = false
    @State private var showsHistory = false

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.043, blue: 0.055).ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 1)
                dashboard
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshVolumes()
        }
        .sheet(isPresented: $showsSMART) {
            SMARTDetailView(info: model.smartInfo, isLoading: model.isLoadingSMART)
        }
        .sheet(isPresented: $showsResults) {
            BenchmarkResultsView(result: model.result)
        }
        .sheet(isPresented: $showsHistory) {
            TestHistoryView(
                records: model.testHistory,
                selectedID: model.selectedHistoryID
            ) { record in
                model.selectHistory(record)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("DriveGauge")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button(action: model.refreshVolumes) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Обновить список дисков")
                .disabled(model.isRunning)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 22)

            Text("ДИСКИ И ТОМА")
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.volumes) { volume in
                        VolumeRow(
                            volume: volume,
                            isSelected: model.selectedVolumeID == volume.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectVolume(volume.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            if model.volumes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.largeTitle)
                    Text("Диски не найдены")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.selectedVolume != nil {
                SMARTSidebarCard(info: model.smartInfo, isLoading: model.isLoadingSMART) {
                    showsSMART = true
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                HistorySidebarCard(
                    latest: model.testHistory.first,
                    count: model.testHistory.count,
                    error: model.historyError
                ) {
                    showsHistory = true
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    UpdateController.shared.checkForUpdates()
                } label: {
                    Label("Проверить обновления", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
                Label("Сетевые диски появятся после подключения в Finder", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("DriveGauge · сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
        }
        .frame(width: 300)
        .background(Color.white.opacity(0.025))
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 10)

            HStack(alignment: .top, spacing: 18) {
                TestHistoryPanel(
                    mode: model.benchmarkMode,
                    metrics: model.completedMetrics,
                    phase: model.phase,
                    currentStage: model.currentStage,
                    currentSpeed: model.currentSpeed
                )
                .frame(width: 290)

                VStack(spacing: 12) {
                    Speedometer(
                        speed: model.currentSpeed,
                        phase: model.phase,
                        detail: speedometerDetail
                    )
                        .frame(maxWidth: 520, maxHeight: 350)

                    HStack(spacing: 12) {
                        ResultCard(
                            title: "ЗАПИСЬ",
                            value: model.writeSpeed,
                            color: .orange,
                            isActive: model.phase == .writing,
                            progress: model.phase == .writing ? model.progress : nil,
                            icon: "arrow.down.to.line"
                        )
                        ResultCard(
                            title: "ЧТЕНИЕ",
                            value: model.readSpeed,
                            color: .cyan,
                            isActive: model.phase == .reading,
                            progress: model.phase == .reading ? model.progress : nil,
                            icon: "arrow.up.to.line"
                        )
                    }

                    CapabilityPanel(
                        writeSpeed: model.result?.recommendationWriteMBps,
                        readSpeed: model.result?.recommendationReadMBps
                    )
                }
                .frame(maxWidth: 520)
            }
            .frame(maxWidth: 880, maxHeight: 555)
            .padding(.horizontal, 24)

            Spacer(minLength: 12)
            controls
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedVolume?.name ?? "Выберите диск")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if let volume = model.selectedVolume {
                    HStack(spacing: 7) {
                        Text(volume.kind)
                        Text("•")
                        Text(volume.capacityText)
                        if let free = volume.freeText {
                            Text("•")
                            Text("свободно \(free)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Режим", selection: $model.benchmarkMode) {
                ForEach(BenchmarkMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 185)
            .disabled(model.isRunning)
            .help(model.benchmarkMode.detail)

            Picker("Размер", selection: $model.testSize) {
                ForEach(TestSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .disabled(model.isRunning)
        }
        .padding(.horizontal, 30)
        .padding(.top, 23)
    }

    private var controls: some View {
        VStack(spacing: 9) {
            Button(action: model.toggleTest) {
                HStack(spacing: 9) {
                    Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                    Text(model.isRunning ? "ОСТАНОВИТЬ" : "НАЧАТЬ ТЕСТ")
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .tracking(0.7)
                .frame(width: 205, height: 48)
                .background(
                    Capsule().fill(
                        model.isRunning
                            ? Color.red
                            : (model.startBlockReason == nil ? Color.cyan : Color.gray.opacity(0.35))
                    )
                )
                .foregroundStyle(Color(red: 0.03, green: 0.045, blue: 0.055))
                .shadow(color: (model.isRunning ? Color.red : Color.cyan).opacity(0.25), radius: 18)
                .opacity(!model.isRunning && model.startBlockReason != nil ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!model.isRunning && model.startBlockReason != nil)

            if case let .failed(message) = model.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if !model.isRunning, let reason = model.startBlockReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else {
                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(model.isRunning ? .secondary : .tertiary)
            }

            if model.result != nil {
                Button("Подробные результаты") { showsResults = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var statusCaption: String {
        let percentage = Int((model.progress * 100).rounded())
        switch model.phase {
        case .preparing:
            return model.currentStage.isEmpty ? "Подготавливаем тестовый файл \(model.testSize.title)…" : model.currentStage
        case .writing:
            return "\(model.currentStage) • запись \(percentage)%"
        case .reading:
            return "\(model.currentStage) • чтение \(percentage)%"
        case .finished:
            return model.selectedVolume?.isLocal == false
                ? "Тест завершён • измерен путь Mac → сеть → сервер → файловая система/накопитель"
                : "Тест завершён • временный файл удалён"
        default:
            return model.selectedVolume?.isLocal == false
                ? "Измеряется весь путь: Mac → сеть → сервер → файловая система/накопитель"
                : "Будет создан и автоматически удалён временный файл \(model.testSize.title)"
        }
    }

    private var speedometerDetail: String? {
        switch model.phase {
        case .preparing:
            return model.currentStage
        case .writing:
            return "Записано \(transferredText)\(timingText)"
        case .reading:
            return "Прочитано \(transferredText)\(timingText)"
        case .stopping:
            return "Останавливаем worker и удаляем временный файл"
        default:
            return nil
        }
    }

    private var transferredText: String {
        let completed = model.transferredBytes.formatted(
            .number.grouping(.automatic).locale(Locale(identifier: "ru_RU"))
        )
        let total = model.transferTotalBytes.formatted(
            .number.grouping(.automatic).locale(Locale(identifier: "ru_RU"))
        )
        return "\(completed) байт из \(total)"
    }

    private var timingText: String {
        if let idle = model.idleSeconds, idle >= 3 { return " · нет передачи \(Int(idle)) с" }
        guard let elapsed = model.elapsedSeconds else { return "" }
        let remainingBytes = max(0, model.transferTotalBytes - model.transferredBytes)
        let remaining = model.currentSpeed > 0
            ? Int((Double(remainingBytes) / 1_000_000 / model.currentSpeed).rounded())
            : 0
        return remaining > 0 ? " · \(Int(elapsed)) с · осталось ≈\(remaining) с" : " · \(Int(elapsed)) с"
    }
}

private struct TestHistoryPanel: View {
    struct Profile: Identifiable {
        let id: String
        let title: String
        let shortTitle: String
        let random: Bool
    }

    let mode: BenchmarkMode
    let metrics: [BenchmarkMetric]
    let phase: BenchmarkPhase
    let currentStage: String
    let currentSpeed: Double

    private var profiles: [Profile] {
        let sequentialQ1 = Profile(id: "seq-q1", title: "Последовательный 1 МиБ · QD1", shortTitle: "SEQ 1M · QD1", random: false)
        let sequentialQ8 = Profile(id: "seq-q8", title: "Последовательный 1 МиБ · QD8", shortTitle: "SEQ 1M · QD8", random: false)
        let randomQ1 = Profile(id: "rnd-q1", title: "Случайный 4 КиБ · QD1", shortTitle: "RND 4K · QD1", random: true)
        let randomQ32 = Profile(id: "rnd-q32", title: "Случайный 4 КиБ · QD32", shortTitle: "RND 4K · QD32", random: true)
        switch mode {
        case .standard: return [sequentialQ1]
        case .maximum: return [sequentialQ8]
        case .applications: return [randomQ1, randomQ32]
        case .full: return [sequentialQ1, sequentialQ8, randomQ1, randomQ32]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("РЕЗУЛЬТАТЫ ТЕСТОВ")
                        .font(.caption2.bold())
                        .tracking(1.2)
                    Text("Каждый способ измеряется отдельно")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(metrics.count)/\(profiles.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(15)

            Divider().opacity(0.35)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        profileRow(profile, number: index + 1)
                    }
                }
                .padding(10)
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 17).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile, number: Int) -> some View {
        let metric = metrics.first(where: { $0.id == profile.id })
        let active = metric == nil && currentStage.contains(profile.title)

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(metric != nil ? Color.green.opacity(0.18) : (active ? Color.cyan.opacity(0.18) : Color.white.opacity(0.055)))
                        .frame(width: 27, height: 27)
                    if metric != nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(active ? .cyan : .secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.shortTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(profile.random ? "Отзывчивость и мелкие файлы" : (profile.id == "seq-q8" ? "Пиковая пропускная способность" : "Большие файлы и видео"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Text(phase == .writing ? "ЗАПИСЬ" : "ЧТЕНИЕ")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(phase == .writing ? .orange : .cyan)
                }
            }

            if let metric {
                HStack(spacing: 8) {
                    historyValue("ЗАПИСЬ", metric.writeMBps, metric.writeIOPS, .orange, profile.random)
                    historyValue("ЧТЕНИЕ", metric.readMBps, metric.readIOPS, .cyan, profile.random)
                }
            } else if active {
                let display = SpeedDisplay.make(currentSpeed)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(display.value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(display.unit).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("выполняется")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(isFinished ? "Не выполнялся" : "Ожидает")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(active ? Color.cyan.opacity(0.055) : Color.white.opacity(metric == nil ? 0.018 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(active ? Color.cyan.opacity(0.32) : Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    private func historyValue(
        _ title: String, _ speed: Double, _ iops: Double,
        _ color: Color, _ showsIOPS: Bool
    ) -> some View {
        let display = SpeedDisplay.make(speed)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(color)
            Text("\(display.value) \(display.unit)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            if showsIOPS {
                Text(String(format: "%.0f IOPS", iops))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.07)))
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        if case .failed = phase { return true }
        return false
    }
}

private struct CapabilityPanel: View {
    let writeSpeed: Double?
    let readSpeed: Double?

    var body: some View {
        Group {
            if let writeSpeed, let readSpeed {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("КОМФОРТНО НА ЭТОМ ДИСКЕ", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(.green)
                        Text("Оценка по стабильной последовательной скорости")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().frame(height: 44)

                    CapabilityValue(
                        icon: "play.rectangle.fill",
                        label: "ПРОСМОТР",
                        value: viewingRecommendation(readMBps: readSpeed),
                        color: .cyan
                    )
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 44)

                    CapabilityValue(
                        icon: "film.stack.fill",
                        label: "РАБОТА И МОНТАЖ",
                        value: workRecommendation(sustainedMBps: min(writeSpeed, readSpeed)),
                        color: .orange
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 17)
            } else {
                HStack(spacing: 11) {
                    Image(systemName: "sparkles.tv")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("КОМФОРТНО НА ЭТОМ ДИСКЕ")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                        Text("Рекомендации появятся после полного теста чтения и записи")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 17)
            }
        }
        .frame(height: 68)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private func viewingRecommendation(readMBps: Double) -> String {
        switch readMBps {
        case ..<10: return "Музыка и файлы"
        case ..<25: return "Видео HD"
        case ..<60: return "Видео Full HD"
        case ..<160: return "Видео 4K"
        case ..<350: return "Видео 8K"
        default: return "Несколько потоков 8K"
        }
    }

    private func workRecommendation(sustainedMBps: Double) -> String {
        switch sustainedMBps {
        case ..<25: return "Документы и копии"
        case ..<80: return "Фото и монтаж Full HD"
        case ..<180: return "Монтаж 4K H.265"
        case ..<400: return "Монтаж 4K ProRes"
        case ..<900: return "Монтаж 8K H.265"
        default: return "Монтаж 8K / multicam"
        }
    }
}

private struct CapabilityValue: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.cyan.opacity(0.16) : Color.white.opacity(0.055))
                    .frame(width: 38, height: 38)
                Image(systemName: volume.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? .cyan : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if volume.isReadOnly {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(volume.kind)  ·  \(volume.capacityText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.white.opacity(0.075) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.cyan.opacity(0.24) : Color.clear, lineWidth: 1)
        )
    }
}

private struct ResultCard: View {
    let title: String
    let value: Double?
    let color: Color
    let isActive: Bool
    let progress: Double?
    let icon: String

    private var speedDisplay: SpeedDisplay { .make(value) }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(Circle().fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(speedDisplay.value)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(speedDisplay.unit)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 17)
        .frame(height: 76)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isActive ? color.opacity(0.4) : Color.white.opacity(0.055), lineWidth: 1)
        )
    }
}

private struct SMARTSidebarCard: View {
    let info: SMARTInfo?
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: healthIcon)
                    .foregroundStyle(healthColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SMART И ЗДОРОВЬЕ")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                    Text(isLoading ? "Чтение данных…" : (info?.status ?? "Нет данных"))
                        .font(.caption.weight(.semibold))
                    if let remaining = info?.remainingLife {
                        Text("Ресурс SSD: \(remaining)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
        }
        .buttonStyle(.plain)
    }

    private var healthIcon: String {
        guard let health = info?.health else { return "waveform.path.ecg" }
        switch health {
        case .healthy: return "checkmark.shield.fill"
        case .limited: return "questionmark.diamond.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "xmark.octagon.fill"
        case .unsupported: return "questionmark.circle"
        }
    }

    private var healthColor: Color {
        guard let health = info?.health else { return .secondary }
        switch health {
        case .healthy: return .green
        case .limited: return .orange
        case .warning: return .orange
        case .failing: return .red
        case .unsupported: return .secondary
        }
    }
}

private struct HistorySidebarCard: View {
    let latest: StoredBenchmark?
    let count: Int
    let error: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ИСТОРИЯ ТЕСТОВ")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                    if let error {
                        Text(error).lineLimit(1).foregroundStyle(.orange)
                    } else if let latest {
                        Text(latest.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.weight(.semibold))
                        Text("\(latest.mode.title) · всего \(count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Тестов пока нет")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045)))
        }
        .buttonStyle(.plain)
        .disabled(error == nil && latest == nil)
    }
}

private struct TestHistoryView: View {
    let records: [StoredBenchmark]
    let selectedID: Int64?
    let onSelect: (StoredBenchmark) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("История тестов")
                        .font(.title2.bold())
                    Text(records.first?.volumeName ?? "Выбранный диск")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Готово") { dismiss() }
            }

            if records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.largeTitle)
                    Text("История пуста")
                        .font(.headline)
                    Text("Завершённые тесты появятся здесь автоматически")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in
                            Button {
                                onSelect(record)
                                dismiss()
                            } label: {
                                historyRow(record)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 680, height: 560)
    }

    private func historyRow(_ record: StoredBenchmark) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(selectedID == record.id ? Color.cyan.opacity(0.18) : Color.white.opacity(0.055))
                    .frame(width: 38, height: 38)
                Image(systemName: selectedID == record.id ? "checkmark" : "gauge.with.needle")
                    .foregroundStyle(selectedID == record.id ? .cyan : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.date.formatted(date: .long, time: .shortened))
                    .font(.headline)
                Text("\(record.mode.title) · \(record.size.title) · \(record.result.metrics.count) профиль(я)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            historySpeed("ЗАПИСЬ", record.result.writeMBps, .orange)
            historySpeed("ЧТЕНИЕ", record.result.readMBps, .cyan)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(selectedID == record.id ? Color.cyan.opacity(0.055) : Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(selectedID == record.id ? Color.cyan.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func historySpeed(_ title: String, _ value: Double, _ color: Color) -> some View {
        let display = SpeedDisplay.make(value)
        return VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(color)
            Text(display.value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(display.unit)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .frame(width: 66)
    }
}

private struct SMARTDetailView: View {
    let info: SMARTInfo?
    let isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SMART и состояние диска")
                        .font(.title2.bold())
                    Text("Прямое чтение IOKit; diskutil используется только как резерв")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Готово") { dismiss() }
            }

            if isLoading {
                HStack { ProgressView(); Text("Чтение SMART…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info {
                HStack(spacing: 12) {
                    Image(systemName: info.health == .healthy ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(info.health == .healthy ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(info.status).font(.headline)
                        Text(info.model ?? "Модель не сообщается").foregroundStyle(.secondary)
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    SMARTValue(title: "ИЗНОС", value: info.percentageUsed.map { "\($0)% использовано" } ?? "—")
                    SMARTValue(title: "ОСТАЛОСЬ РЕСУРСА", value: info.remainingLife.map { "\($0)%" } ?? "—")
                    SMARTValue(title: "ТЕМПЕРАТУРА", value: info.temperatureCelsius.map { "\($0) °C" } ?? "—")
                    SMARTValue(title: "НАРАБОТКА", value: info.powerOnHours.map { "\($0) ч" } ?? "—")
                    SMARTValue(title: "ВКЛЮЧЕНИЯ", value: info.powerCycles.map(String.init) ?? "—")
                    SMARTValue(title: "ОШИБКИ НОСИТЕЛЯ", value: info.mediaErrors.map(String.init) ?? "—")
                    SMARTValue(title: "ПРОЧИТАНО", value: formattedBytes(info.dataReadBytes))
                    SMARTValue(title: "ЗАПИСАНО", value: formattedBytes(info.dataWrittenBytes))
                    SMARTValue(title: "ИНТЕРФЕЙС", value: info.interface ?? "—")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("СОСТОЯНИЕ И ЗАМЕЧАНИЯ")
                        .font(.caption2.bold()).tracking(1.1).foregroundStyle(.secondary)
                    if info.issues.isEmpty {
                        Label("Проблем не обнаружено", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(info.issues) { issue in
                            Label(issue.text, systemImage: issue.severity == .critical ? "xmark.octagon.fill" : "info.circle.fill")
                                .foregroundStyle(issue.severity == .critical ? .red : (issue.severity == .warning ? .orange : .secondary))
                        }
                    }
                }
            } else {
                Text("Данные SMART недоступны").foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 650, height: 500)
    }

    private func formattedBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
    }
}

private struct SMARTValue: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.045)))
    }
}

private struct BenchmarkResultsView: View {
    let result: BenchmarkResult?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Подробные результаты").font(.title2.bold())
                    Text("Медиана проходов; единицы меняются автоматически").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Готово") { dismiss() }
            }

            if let result {
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                    GridRow {
                        Text("ПРОФИЛЬ")
                        Text("ЗАПИСЬ")
                        Text("ЧТЕНИЕ")
                        Text("IOPS ЗАП.")
                        Text("IOPS ЧТ.")
                    }
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                    Divider().gridCellColumns(5)
                    ForEach(result.metrics) { metric in
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(metric.title).font(.headline)
                                Text("\(metric.iterations) проход(а)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(speedText(metric.writeMBps)).monospacedDigit()
                            Text(speedText(metric.readMBps)).monospacedDigit()
                            Text(String(format: "%.0f", metric.writeIOPS)).monospacedDigit()
                            Text(String(format: "%.0f", metric.readIOPS)).monospacedDigit()
                        }
                    }
                }
            } else {
                Text("Сначала выполните тест").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .frame(width: 780, height: 390)
    }

    private func speedText(_ value: Double) -> String {
        let display = SpeedDisplay.make(value)
        return "\(display.value) \(display.unit)"
    }
}
