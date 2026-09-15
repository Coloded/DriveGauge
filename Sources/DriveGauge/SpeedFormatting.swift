import Foundation

struct SpeedDisplay {
    let value: String
    let unit: String

    static func make(_ megabytesPerSecond: Double?) -> SpeedDisplay {
        guard let speed = megabytesPerSecond else {
            return .init(value: "—", unit: "MB/s")
        }
        guard speed > 0, speed < 1 else {
            return .init(value: String(format: "%.1f", speed), unit: "MB/s")
        }

        let kilobytes = speed * 1_000
        let value = kilobytes >= 100
            ? String(format: "%.0f", kilobytes)
            : String(format: "%.1f", kilobytes)
        return .init(value: value, unit: "КБ/с")
    }
}
