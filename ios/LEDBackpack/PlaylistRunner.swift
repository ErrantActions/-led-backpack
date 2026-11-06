import Foundation
import Combine
import BackpackProtocol

@MainActor
final class PlaylistRunner: ObservableObject {
    let panel: PanelController
    @Published private(set) var running = false
    @Published private(set) var status = "Stopped"
    private var task: Task<Void, Never>?
    init(panel: PanelController) { self.panel = panel }

    func start(_ playlist: SavedPlaylist, repeatPlaylist: Bool) async throws {
        try playlist.validateForDevice(serial: panel.identity?.serial, inventory: panel.slots)
        guard panel.inventoryDeviceID == panel.link.selectedID, panel.inventoryDeviceID != nil else {
            throw BackpackError.invalid("Authenticate and refresh this backpack first.")
        }
        guard task == nil, !playlist.slots.isEmpty, playlist.slots.count <= 60,
              playlist.slots.allSatisfy({ (0..<60).contains($0) }) else {
            throw BackpackError.invalid("Choose 1 to 60 valid slots and stop the current timed sequence.")
        }
        let durations = playlist.durations ?? Array(repeating: 10, count: playlist.slots.count)
        guard durations.count == playlist.slots.count,
              durations.allSatisfy({ $0.isFinite && (1...3600).contains($0) }) else {
            throw BackpackError.invalid("Each playlist item needs a duration in 1...3600 seconds.")
        }
        try await panel.beginTimedPlaylist()
        running = true
        task = Task {
            do {
                repeat {
                    for (index, slot) in playlist.slots.enumerated() {
                        try Task.checkCancellation()
                        let started = Date()
                        try await panel.timedPlaylistStep(slot)
                        status = "Slot \(slot) / \(Int(durations[index]))s"
                        try await Task.sleep(for: .seconds(max(0.1, durations[index] - Date().timeIntervalSince(started))))
                    }
                } while repeatPlaylist && !Task.isCancelled
            } catch {
                if !Task.isCancelled { panel.report(error) }
            }
            do { try await panel.endTimedPlaylist() } catch { panel.report(error) }
            running = false; task = nil; status = "Stopped"
        }
    }

    func stop() async { task?.cancel(); await task?.value }
    func connectionLost() { task?.cancel() }
}
