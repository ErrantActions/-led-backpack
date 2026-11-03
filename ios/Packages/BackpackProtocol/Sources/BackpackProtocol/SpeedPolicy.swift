import Foundation

public enum SpeedPolicy {
    public static func display(metersPerSecond: Double, age: TimeInterval, mph: Bool, cap: Int?) -> Int? {
        guard metersPerSecond.isFinite, metersPerSecond >= 0, age >= -1, age <= 5 else { return nil }
        let converted = metersPerSecond * (mph ? 2.2369362921 : 3.6)
        guard converted.isFinite else { return nil }
        let value = Int(min(999, converted.rounded()))
        if let cap { return min(value, max(0, cap)) }
        return value
    }
}
