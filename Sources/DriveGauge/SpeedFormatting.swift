import Foundation

struct SpeedDisplay {
    let value: String
    let unit: String

    static func make(_ megabytesPerSecond: Double?) -> SpeedDisplay {
        guard let speed = megabytesPerSecond else {
            return .init(value: "—", unit: "MB/s")
        }
        return .init(value: String(format: "%.1f", speed), unit: "MB/s")
    }
}
