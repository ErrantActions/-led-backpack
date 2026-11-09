import Foundation
import BackpackProtocol

struct BluetoothScanIntent {
    private var requestedAt: TimeInterval?
    var pending: Bool { requestedAt != nil }
    mutating func request(now: TimeInterval) throws {
        guard now.isFinite, now >= 0 else { throw BackpackError.invalid("Bluetooth request clock is invalid.") }
        requestedAt = now
    }
    mutating func consume(now: TimeInterval, foreground: Bool) throws -> Bool {
        guard let requestedAt else { return false }
        guard now.isFinite, now >= requestedAt, now - requestedAt < 30 else {
            cancel()
            throw BackpackError.invalid("Bluetooth preparation expired. Choose Scan again.")
        }
        guard foreground else { return false }
        cancel()
        return true
    }
    mutating func cancel() { requestedAt = nil }
}
