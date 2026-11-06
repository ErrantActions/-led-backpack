import Foundation
import Combine
import UIKit
import BackpackProtocol

@MainActor
final class PanelController: ObservableObject {
    let link: BluetoothLink
    @Published private(set) var identity: Identity?
    @Published private(set) var size: PanelSize?
    @Published private(set) var slots: [Slot] = []
    @Published private(set) var playback: Playback?
    @Published private(set) var busy = false
    @Published private(set) var isLive = false
    @Published private(set) var timedPlaylist = false
    @Published private(set) var monitorImage: UIImage?
    @Published private(set) var monitorGIF: Data?
    @Published private(set) var monitorCaption = "No display data yet."
    var hasDisplayOwner: Bool { isLive || timedPlaylist || batchTransferID != nil }
    var previewProvider: ((Int) throws -> Data?)?
    @Published private(set) var progress: Double?
    @Published private(set) var inventoryDeviceID: UUID?
    @Published private(set) var inventoryReadAt: Date?
    @Published private(set) var batchTransferID: UUID?
    @Published var errorMessage: String?
    @Published var password = ""
    @Published var rememberPassword = false
    @Published var legacyInit = false
    private var previous: PixelFrame?
    private var capturedPlayback: Playback?
    private var liveDeviceID: UUID?
    private var firstLiveFrame = false
    private var capturedTimedPlayback: Playback?

    init(link: BluetoothLink) {
        self.link = link
        link.onPlayback = { [weak self] value in self?.observePlayback(value) }
        link.onReady = { [weak self] in
            guard let self else { return }
            do { try await self.refresh() } catch { self.report(error) }
        }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        if hasDisplayOwner { monitorCaption = "Last known preview; update failed: \(error.localizedDescription)" }
        link.note("ERROR: \(error.localizedDescription)")
    }

    func transaction<T>(batch: UUID? = nil, _ action: () async throws -> T) async throws -> T {
        guard link.connected, !busy, !isLive, !timedPlaylist,
              batchTransferID == nil || batchTransferID == batch else {
            throw BackpackError.invalid("Connect first, finish the current transfer, or stop the live display.")
        }
        busy = true
        defer { busy = false }
        return try await action()
    }

    func beginBatch() throws -> UUID {
        guard link.connected, !busy, !hasDisplayOwner, inventoryDeviceID != nil, inventoryDeviceID == link.selectedID else {
            throw BackpackError.invalid("Connect, refresh storage and stop other operations before sending a batch.")
        }
        let token = UUID(); batchTransferID = token; return token
    }
    func endBatch(_ token: UUID) throws {
        guard batchTransferID == token else { throw BackpackError.invalid("Batch transfer ownership changed.") }
        batchTransferID = nil
    }

    func refresh() async throws {
        try await transaction {
            let device = link.selectedID
            inventoryDeviceID = nil; inventoryReadAt = nil
            identity = nil; size = nil; slots = []; playback = nil
            let reply = try await link.request(try Wire.initialize(password: password, bare: legacyInit), sensitive: true) {
                if case .identity = $0 { return true }; return false
            }
            if case .identity(let value) = reply { identity = value }
            let dimensions = try await link.request([0xC1, 3, 0x1B, 0]) {
                if case .size = $0 { return true }; return false
            }
            if case .size(let value) = dimensions { size = value }
            try await refreshSlots()
            playback = try await readPlayback()
            guard let device, link.selectedID == device else { throw BackpackError.invalid("The connected backpack changed during refresh.") }
            inventoryDeviceID = device
            updateStoredPreview()
        }
    }

    private func refreshSlots() async throws {
        let device = link.selectedID
        var known: [Int: Slot] = [:]
        for page in 0..<6 {
            var wanted = Set((page * 10)..<(page * 10 + 10))
            _ = try await link.request(try Wire.slotQuery(page: page)) { reply in
                guard case .slots(let records) = reply else { return false }
                for record in records where wanted.contains(record.id) {
                    known[record.id] = record; wanted.remove(record.id)
                }
                return wanted.isEmpty
            }
        }
        guard known.count == 60, link.connected, let device, link.selectedID == device else {
            throw BackpackError.invalid("Slot inventory is incomplete or the backpack changed.")
        }
        slots = known.values.sorted { $0.id < $1.id }
        inventoryReadAt = Date()
    }

    func refreshStoredPlayback() async throws {
        try await transaction {
            guard inventoryDeviceID == link.selectedID, inventoryDeviceID != nil else {
                throw BackpackError.invalid("Authenticate and refresh this backpack first.")
            }
            try await refreshSlots()
            playback = try await readPlayback()
            updateStoredPreview()
        }
    }

    func erasePlan() throws -> BackpackErasePlan {
        guard link.connected, let device = inventoryDeviceID, device == link.selectedID, let identity else {
            throw BackpackError.invalid("Connect and refresh the backpack first.")
        }
        return try BackpackErasePlan(deviceID: device, serial: identity.serial, records: slots)
    }

    func eraseAll(_ plan: BackpackErasePlan) async throws {
        try await transaction {
            try plan.validate(deviceID: link.selectedID, serial: identity?.serial, records: slots)
            guard inventoryDeviceID == plan.deviceID else { throw BackpackError.invalid("Refresh this backpack before erasing.") }
            var deleted = 0
            progress = 0
            playback = nil
            monitorUnavailable("Erasing stored artwork. Display state is not confirmed until the inventory is reread.")
            defer { progress = nil }
            do {
                // Use the recovered per-program delete; no unverified factory-reset opcode.
                for slot in plan.occupied {
                    try Task.checkCancellation()
                    guard link.selectedID == plan.deviceID, identity?.serial == plan.serial else {
                        throw BackpackError.invalid("The connected backpack changed.")
                    }
                    try await link.acknowledged(try Wire.deleteSlot(slot.id))
                    deleted += 1
                    progress = Double(deleted) / Double(max(1, plan.occupied.count))
                }
                try await refreshSlots()
                guard link.selectedID == plan.deviceID, identity?.serial == plan.serial else {
                    throw BackpackError.invalid("The connected backpack changed before erase verification.")
                }
                guard slots.allSatisfy({ !$0.occupied }) else { throw BackpackError.invalid("The backpack still reports occupied slots.") }
                monitorUnavailable("All 60 slots verified empty. Local and cloud GIFs are unchanged.")
                playback = nil
            } catch {
                var detail = "Erase stopped after \(deleted) acknowledged deletions. Some slots may already be erased; nothing was restored."
                if link.connected, link.selectedID == plan.deviceID {
                    do { try await refreshSlots() }
                    catch let refreshError { detail += " Inventory refresh failed: \(refreshError.localizedDescription)." }
                }
                throw BackpackError.invalid("\(detail) \(error.localizedDescription)")
            }
        }
    }

    func readPlayback() async throws -> Playback {
        let device = link.selectedID
        let reply = try await link.request([0xC1, 3, 0x36, 0]) { if case .playback = $0 { return true }; return false }
        guard case .playback(let value) = reply, link.connected, let device, link.selectedID == device else {
            throw BackpackError.invalid("Invalid playback response or backpack changed.")
        }
        return value
    }

    func brightness(_ level: Int) async throws {
        guard (0...15).contains(level) else { throw BackpackError.invalid("Brightness must be 0 through 15.") }
        try await transaction { try await link.acknowledged([0xC1, 2, 6, 2, 0, UInt8(level)]) }
    }

    func power(_ on: Bool) async throws {
        try await transaction { try await link.acknowledged([0xC1, 2, 4, 2, 0, on ? 1 : 0]) }
    }

    func rotate(_ index: Int) async throws {
        guard (0..<4).contains(index) else { throw BackpackError.invalid("Invalid rotation.") }
        try await transaction { try await link.acknowledged([0xC1, 2, 0x2F, 1, [2, 3, 0, 1][index]]) }
    }

    func configurePassword(_ newPassword: String, disable: Bool) async throws {
        _ = try Wire.initialize(password: newPassword)
        guard newPassword.utf8.count <= 254 else { throw BackpackError.invalid("New panel passwords must be at most 254 ASCII bytes.") }
        if !disable && newPassword.isEmpty { throw BackpackError.invalid("A new password cannot be empty.") }
        try await transaction {
            let body: [UInt8] = disable ? [0xC1, 2, 0x37, 1, 2]
                : [0xC1, 2, 0x37, UInt8(newPassword.utf8.count + 1), 1] + Array(newPassword.utf8)
            try await link.acknowledged(body, sensitive: true)
            password = disable ? "" : newPassword
        }
    }

    func play(slot: Int) async throws {
        try await transaction {
            guard inventoryDeviceID == link.selectedID, inventoryDeviceID != nil,
                  slots.contains(where: { $0.id == slot && $0.occupied }) else {
                throw BackpackError.invalid("Refresh storage and choose an occupied slot on this backpack.")
            }
            try await link.acknowledged(try Wire.playSingle(slot))
            playback = try await readPlayback()
            updateStoredPreview()
        }
    }

    func refreshPlaybackStatus() async throws {
        try await transaction {
            playback = try await readPlayback()
            updateStoredPreview()
        }
    }

    func play(list: [Int], batch: UUID? = nil) async throws {
        guard !list.isEmpty, list.count <= 60, list.allSatisfy({ (0..<60).contains($0) }) else {
            throw BackpackError.invalid("Choose 1 to 60 valid slots.")
        }
        try await transaction(batch: batch) {
            guard inventoryDeviceID == link.selectedID, inventoryDeviceID != nil, slots.count == 60,
                  list.allSatisfy({ id in slots.contains { $0.id == id && $0.occupied } }) else {
                throw BackpackError.invalid("Refresh this backpack and choose only occupied slots.")
            }
            try await link.acknowledged(try Wire.play(Playback(mode: 2, index: 255, ids: list.map(UInt8.init))))
            playback = try await readPlayback()
            updateStoredPreview()
        }
    }

    func delete(slot: Int) async throws {
        try Wire.checkSlot(slot)
        try await transaction {
            guard slots.count == 60, inventoryDeviceID != nil, inventoryDeviceID == link.selectedID else {
                throw BackpackError.invalid("Refresh this backpack's storage before deleting.")
            }
            try await link.acknowledged(try Wire.deleteSlot(slot))
            playback = nil
            monitorUnavailable("Slot \(slot) deletion acknowledged. Refreshing inventory; playback will be reread.")
            try await refreshSlots()
        }
    }

    func upload(_ data: Data, slot: Int, overwriteApproved: Bool, playSeconds: Int? = nil, batch: UUID? = nil) async throws {
        try await transaction(batch: batch) {
            guard let size, slots.count == 60, inventoryDeviceID != nil, inventoryDeviceID == link.selectedID,
                  let selected = slots.first(where: { $0.id == slot }) else {
                throw BackpackError.invalid("Refresh panel dimensions and storage first.")
            }
            guard !selected.occupied || overwriteApproved else {
                throw BackpackError.invalid("Overwriting occupied artwork requires confirmation.")
            }
            let messages = try Wire.upload(Array(data), slot: slot, size: size, playSeconds: playSeconds)
            progress = 0
            defer { progress = nil }
            for (index, body) in messages.enumerated() {
                try Task.checkCancellation()
                try await link.acknowledged(body)
                progress = Double(index + 1) / Double(messages.count)
            }
            try await link.acknowledged(try Wire.playSingle(slot))
            try await refreshSlots()
            playback = try await readPlayback()
            monitorImage = nil; monitorGIF = data
            monitorCaption = "Uploaded GIF preview. Device playback phase may differ."
        }
    }

    func beginLive() async throws {
        try await transaction {
            guard let size, let device = link.selectedID, inventoryDeviceID == device else {
                throw BackpackError.invalid("Read this panel's dimensions and storage first.")
            }
            let captured = try await readPlayback()
            _ = try Wire.play(captured)
            try await link.acknowledged([0xC1, 2, 0x30, 1, 0x90])
            guard link.connected, link.selectedID == device else {
                throw BackpackError.invalid("Live display startup lost its device; physical playback state is unconfirmed.")
            }
            capturedPlayback = captured
            liveDeviceID = device
            previous = .black(size)
            firstLiveFrame = true
            link.resetLiveErrors()
            isLive = true
        }
    }

    func paintLive(_ frame: PixelFrame) async throws {
        guard isLive, !busy, let previous else { throw BackpackError.invalid("Live session is not ready.") }
        busy = true
        defer { busy = false }
        for body in try MediaCodec.delta(from: previous, to: frame, forceFullFrame: firstLiveFrame) {
            try await link.live(body)
        }
        let resolved = frame.resolvedLive()
        self.previous = resolved
        firstLiveFrame = false
        monitorImage = try resolved.image(); monitorGIF = nil
        monitorCaption = "Last live frame sent. Not a camera or device pixel readback."
    }

    func endLive() async throws {
        guard isLive else { return }
        isLive = false; previous = nil; firstLiveFrame = false
        monitorUnavailable("Restoring stored playback...")
        guard let captured = capturedPlayback else { throw BackpackError.invalid("No playback snapshot to restore.") }
        capturedPlayback = nil
        let device = liveDeviceID; liveDeviceID = nil
        guard link.connected, let device, link.selectedID == device else {
            throw BackpackError.invalid("Connection changed; playback restoration is not confirmed. Reconnect and choose a program.")
        }
        busy = true
        defer { busy = false }
        var errors: [String] = []
        do { try await link.acknowledged([0xC1, 2, 0x30, 1, 0x65]) }
        catch { errors.append(error.localizedDescription) }
        do {
            guard link.connected, link.selectedID == device else { throw BackpackError.invalid("Backpack changed before playback restoration.") }
            try await link.acknowledged(try Wire.play(captured))
            let actual = try await readPlayback()
            guard actual.mode == captured.mode, actual.ids == captured.ids else {
                throw BackpackError.invalid("Restored mode/program list differs.")
            }
            playback = actual
        } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty { throw BackpackError.invalid("Restoration not confirmed: " + errors.joined(separator: " ")) }
    }

    func beginTimedPlaylist() async throws {
        try await transaction {
            let captured = try await readPlayback()
            _ = try Wire.play(captured)
            capturedTimedPlayback = captured; timedPlaylist = true
        }
    }

    func timedPlaylistStep(_ slot: Int) async throws {
        guard timedPlaylist, !busy else { throw BackpackError.invalid("Timed playlist is not ready.") }
        busy = true; defer { busy = false }
        try await link.acknowledged(try Wire.playSingle(slot))
        playback = try await readPlayback()
    }

    func endTimedPlaylist() async throws {
        guard timedPlaylist else { return }
        timedPlaylist = false
        guard let captured = capturedTimedPlayback else { throw BackpackError.invalid("No playlist restoration snapshot.") }
        capturedTimedPlayback = nil
        guard link.connected else {
            monitorUnavailable("Disconnected. Stored playback is not readable.")
            throw BackpackError.invalid("Timed playlist disconnected; restoration not confirmed.")
        }
        busy = true; defer { busy = false }
        try await link.acknowledged(try Wire.play(captured))
        let actual = try await readPlayback()
        guard actual.mode == captured.mode, actual.ids == captured.ids else {
            throw BackpackError.invalid("Playlist restoration differs from the original mode/program list.")
        }
        playback = actual
    }

    func abandonLivePreview(_ reason: String) {
        isLive = false; previous = nil; capturedPlayback = nil; liveDeviceID = nil; firstLiveFrame = false
        monitorUnavailable(reason)
    }

    func monitorUnavailable(_ message: String) {
        monitorImage = nil; monitorGIF = nil; monitorCaption = message
    }

    private func observePlayback(_ value: Playback) {
        playback = value
        updateStoredPreview()
    }

    func updateStoredPreview() {
        guard !isLive else { return }
        guard let slot = BackpackPlaybackStatus.reportedSlot(playback) else {
            monitorUnavailable(BackpackPlaybackStatus.caption(playback))
            return
        }
        do {
            if let bytes = try previewProvider?(slot) {
                monitorImage = nil; monitorGIF = bytes
                monitorCaption = "Cached GIF matched to reported slot \(slot). Animation phase is not a screen readback."
            } else { monitorUnavailable("Backpack reports slot \(slot). No matching local GIF is cached; its identifier is readable, not its pixels.") }
        } catch { monitorUnavailable(error.localizedDescription); report(error) }
    }
}
