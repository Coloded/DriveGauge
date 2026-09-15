import SwiftUI

struct Speedometer: View {
    let speed: Double
    let phase: BenchmarkPhase
    let detail: String?

    private var speedDisplay: SpeedDisplay { .make(speed) }

    private var maximum: Double {
        if speed > 0, speed < 1 {
            let slowCandidates: [Double] = [0.1, 0.25, 0.5, 1, 2]
            return slowCandidates.first(where: { speed <= $0 * 0.88 }) ?? 2
        }
        let candidates: [Double] = [50, 100, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        return candidates.first(where: { speed <= $0 * 0.88 }) ?? 20_000
    }

    private var normalized: Double { min(max(speed / maximum, 0), 1) }
    private let startAngle = Angle.degrees(215)
    private let sweep = 250.0

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.51)
            let radius = side * 0.40

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 0.08, green: 0.10, blue: 0.125), Color(red: 0.025, green: 0.03, blue: 0.04)],
                            center: .center,
                            startRadius: 10,
                            endRadius: radius * 1.25
                        )
                    )
                    .frame(width: radius * 2.28, height: radius * 2.28)
                    .position(center)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.07), lineWidth: 2)
                            .frame(width: radius * 2.28, height: radius * 2.28)
                            .position(center)
                    }
                    .shadow(color: .black.opacity(0.55), radius: 26, y: 12)

                Canvas { context, _ in
                    drawTrack(context: &context, center: center, radius: radius)
                    drawTicks(context: &context, center: center, radius: radius)
                }

                needle(center: center, radius: radius)

                VStack(spacing: 2) {
                    Text(phase.title)
                        .font(.caption2.weight(.bold))
                        .tracking(1.8)
                        .foregroundStyle(phaseColor)
                    Text(speedDisplay.value)
                        .font(.system(size: side * 0.105, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(speedDisplay.unit)
                        .font(.system(size: side * 0.027, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: side * 0.021, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: radius * 1.35)
                            .padding(.top, 3)
                    }
                }
                .position(x: center.x, y: center.y + radius * 0.43)

            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Скорость \(speedDisplay.value) \(speedDisplay.unit), \(phase.title)")
    }

    private var phaseColor: Color {
        switch phase {
        case .writing: return .orange
        case .reading, .finished: return .cyan
        case .failed: return .red
        default: return .secondary
        }
    }

    private func drawTrack(context: inout GraphicsContext, center: CGPoint, radius: Double) {
        var base = Path()
        base.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: .degrees(startAngle.degrees + sweep), clockwise: false)
        context.stroke(base, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 9, lineCap: .round))

        guard normalized > 0 else { return }
        var active = Path()
        active.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: .degrees(startAngle.degrees + sweep * normalized), clockwise: false)
        context.stroke(active, with: .color(phaseColor.opacity(0.85)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
    }

    private func drawTicks(context: inout GraphicsContext, center: CGPoint, radius: Double) {
        for index in 0...40 {
            let fraction = Double(index) / 40
            let angle = (startAngle.degrees + sweep * fraction) * .pi / 180
            let major = index % 5 == 0
            let outer = point(center: center, radius: radius - 18, angle: angle)
            let inner = point(center: center, radius: radius - (major ? 34 : 27), angle: angle)
            var path = Path()
            path.move(to: inner)
            path.addLine(to: outer)
            context.stroke(path, with: .color(.white.opacity(major ? 0.65 : 0.22)), lineWidth: major ? 2 : 1)

            if major {
                let labelPoint = point(center: center, radius: radius - 55, angle: angle)
                let value = maximum * fraction
                let label: String
                if maximum < 10 {
                    label = value == value.rounded()
                        ? String(format: "%.0f", value)
                        : String(format: "%.1f", value)
                } else {
                    label = value >= 1_000 ? String(format: "%.0fk", value / 1_000) : String(format: "%.0f", value)
                }
                context.draw(
                    Text(label).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.secondary),
                    at: labelPoint,
                    anchor: .center
                )
            }
        }
    }

    private func needle(center: CGPoint, radius: Double) -> some View {
        let angle = Angle.degrees(startAngle.degrees + sweep * normalized)
        return ZStack {
            Capsule()
                .fill(LinearGradient(colors: [phaseColor.opacity(0.2), phaseColor], startPoint: .leading, endPoint: .trailing))
                .frame(width: radius * 0.73, height: 4)
                .offset(x: radius * 0.31)
            Circle()
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(phaseColor.opacity(0.8), lineWidth: 3))
        }
        .rotationEffect(angle)
        .position(center)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: normalized)
    }

    private func point(center: CGPoint, radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}
