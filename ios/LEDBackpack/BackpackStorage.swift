import Foundation
import BackpackProtocol

struct BackpackErasePlan: Identifiable {
    let id = UUID()
    let deviceID: UUID
    let serial: String
    let records: [Slot]
    var occupied: [Slot] { records.filter(\.occupied) }

    init(deviceID: UUID, serial: String, records: [Slot]) throws {
        guard !serial.isEmpty, records.count == 60, Set(records.map(\.id)) == Set(0..<60) else {
            throw BackpackError.invalid("Read the complete backpack inventory before changing storage.")
        }
        self.deviceID = deviceID; self.serial = serial; self.records = records
    }

    func validate(deviceID: UUID?, serial: String?, records: [Slot]) throws {
        guard deviceID == self.deviceID, serial == self.serial,
              records.sorted(by: { $0.id < $1.id }) == self.records.sorted(by: { $0.id < $1.id }) else {
            throw BackpackError.invalid("The backpack or its slot contents changed. Refresh and confirm again.")
        }
    }
}

enum BackpackPlaybackStatus {
    static func reportedSlot(_ playback: Playback?) -> Int? {
        guard let playback, [0, 1].contains(playback.mode), playback.index < 60 else { return nil }
        return Int(playback.index)
    }
    static func caption(_ playback: Playback?) -> String {
        guard let playback else { return "Playback has not been read." }
        if let slot = reportedSlot(playback) { return "Backpack reports slot \(slot)." }
        if playback.mode == 2 {
            let ids = playback.ids.filter { $0 < 60 }
            return "Backpack loop: \(ids.map(String.init).joined(separator: ", ")). Current frame/slot phase is not reported."
        }
        return "Reported playback mode \(playback.mode), index \(playback.index)."
    }
}
