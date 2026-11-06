import Foundation
import BackpackProtocol

struct PlaylistDraftEntry: Identifiable {
    let id = UUID()
    let slot: Int
    var seconds: Double
}

struct PlaylistDraft {
    var entries: [PlaylistDraftEntry]
    init() { entries = [] }
    init(_ playlist: SavedPlaylist) throws {
        guard !playlist.slots.isEmpty, playlist.slots.count <= 60,
              playlist.slots.allSatisfy({ (0..<60).contains($0) }) else {
            throw BackpackError.invalid("The saved playlist has invalid slot entries.")
        }
        if let durations = playlist.durations {
            guard durations.count == playlist.slots.count,
                  durations.allSatisfy({ $0.isFinite && (1...3600).contains($0) }) else {
                throw BackpackError.invalid("The saved playlist has invalid timing.")
            }
        }
        entries = playlist.slots.enumerated().map { index, slot in
            PlaylistDraftEntry(slot: slot, seconds: playlist.durations?[index] ?? 10)
        }
    }
    mutating func append(_ slot: Int) throws {
        try Wire.checkSlot(slot)
        guard entries.count < 60 else { throw BackpackError.invalid("A playlist supports at most 60 entries.") }
        entries.append(PlaylistDraftEntry(slot: slot, seconds: 10))
    }
    mutating func remove(_ offsets: IndexSet) throws {
        guard !offsets.isEmpty, offsets.allSatisfy({ entries.indices.contains($0) }) else {
            throw BackpackError.invalid("Select existing playlist entries.")
        }
        for index in offsets.sorted(by: >) { entries.remove(at: index) }
    }
    mutating func move(_ offsets: IndexSet, to destination: Int) throws {
        guard !offsets.isEmpty, offsets.allSatisfy({ entries.indices.contains($0) }),
              (0...entries.count).contains(destination) else { throw BackpackError.invalid("Invalid playlist reorder.") }
        let moving = offsets.sorted().map { entries[$0] }
        let target = destination - offsets.filter { $0 < destination }.count
        try remove(offsets)
        entries.insert(contentsOf: moving, at: target)
    }
}

extension SavedPlaylist {
    func validateForDevice(serial: String?, inventory: [Slot]) throws {
        guard panelSerial == nil || panelSerial == serial else {
            throw BackpackError.invalid("This playlist belongs to a different backpack.")
        }
        guard inventory.count == 60, Set(inventory.map(\.id)) == Set(0..<60),
              !slots.isEmpty, slots.count <= 60,
              slots.allSatisfy({ id in inventory.contains { $0.id == id && $0.occupied } }) else {
            throw BackpackError.invalid("Refresh storage and confirm every playlist slot still contains artwork.")
        }
    }
}
