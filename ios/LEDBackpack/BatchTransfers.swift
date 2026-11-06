import Foundation
import Combine
import BackpackProtocol

struct QueuedMedia: Codable, Identifiable {
    var id = UUID()
    let mediaID: UUID
}

struct BatchTransferEntry {
    let queuedID, mediaID: UUID
    let slot: Int
}

struct BatchTransferPlan: Identifiable {
    let id = UUID()
    let inventory: BackpackErasePlan
    let size: PanelSize
    let entries: [BatchTransferEntry]
    let loopWhenFinished: Bool
    init(inventory: BackpackErasePlan, size: PanelSize, entries: [BatchTransferEntry], loopWhenFinished: Bool) throws {
        guard !entries.isEmpty, entries.count <= 60,
              Set(entries.map(\.slot)).count == entries.count,
              Set(entries.map(\.queuedID)).count == entries.count,
              entries.allSatisfy({ (0..<60).contains($0.slot) }),
              [PanelSize(width: 16, height: 16), PanelSize(width: 64, height: 64), PanelSize(width: 96, height: 128)].contains(size) else {
            throw BackpackError.invalid("Choose 1 to 60 queued GIFs with distinct valid destination slots and a supported panel size.")
        }
        self.inventory = inventory; self.size = size; self.entries = entries; self.loopWhenFinished = loopWhenFinished
    }
    var overwrittenSlots: [Int] {
        entries.compactMap { entry in inventory.records.contains { $0.id == entry.slot && $0.occupied } ? entry.slot : nil }
    }
    static func freeAssignments(queue: [QueuedMedia], slots: [Slot]) -> [UUID: Int] {
        let free = slots.filter { $0.id >= 2 && !$0.occupied }.sorted { $0.id < $1.id }
        return Dictionary(uniqueKeysWithValues: zip(queue, free).map { ($0.0.id, $0.1.id) })
    }
}

@MainActor
enum BatchGIFPreparation {
    static func fit(_ data: Data, to size: PanelSize) async throws -> Data {
        try CommunityUpload.validateGIF(data)
        let bytes = [UInt8](data)
        if Wire.u16(bytes, 6) == size.width, Wire.u16(bytes, 8) == size.height { return data }
        let animation = try MediaCodec.decode(data)
        var frames: [PixelFrame] = []
        for image in animation.images {
            try Task.checkCancellation()
            frames.append(try MediaCodec.transform(image, size: size, fit: .fit, turns: 0, brightness: 1))
            await Task.yield()
        }
        return try MediaCodec.encode(frames, delays: animation.delays)
    }
}

@MainActor
final class BatchTransferQueue: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Ready"
    @Published private(set) var completed: [UUID] = []
    @Published private(set) var failure: String?
    private let panel: PanelController
    private var task: Task<Void, Never>?
    private var backgrounded = false
    init(panel: PanelController) { self.panel = panel }

    func start(_ plan: BatchTransferPlan, library: LocalLibrary) throws {
        guard task == nil, !running, !backgrounded, panel.size == plan.size else {
            throw BackpackError.invalid("Finish the current batch, keep the app foreground and refresh the matching panel.")
        }
        try plan.inventory.validate(deviceID: panel.link.selectedID, serial: panel.identity?.serial, records: panel.slots)
        try checkSources(plan, library: library)
        let ownership = try panel.beginBatch()
        running = true; completed = []; failure = nil; status = "Preparing all GIFs before changing backpack storage..."
        task = Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backpack-batch-\(UUID().uuidString)", isDirectory: true)
            var prepared: [URL] = []
            var createdFolder = false
            var attemptedWrite = false
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
                createdFolder = true
                for (index, entry) in plan.entries.enumerated() {
                    try checkScope(plan)
                    guard let media = library.state.media.first(where: { $0.id == entry.mediaID }) else {
                        throw BackpackError.invalid("A queued GIF was removed before preparation.")
                    }
                    let data = try await BatchGIFPreparation.fit(library.data(media), to: plan.size)
                    try checkScope(plan)
                    let file = folder.appendingPathComponent("\(index).gif")
                    try data.write(to: file, options: [.atomic, .completeFileProtection])
                    prepared.append(file)
                }
                try checkScope(plan)
                try plan.inventory.validate(deviceID: panel.link.selectedID, serial: panel.identity?.serial, records: panel.slots)
                for (index, entry) in plan.entries.enumerated() {
                    try checkScope(plan)
                    guard library.state.transferQueue?.contains(where: { $0.id == entry.queuedID && $0.mediaID == entry.mediaID }) == true,
                          library.state.media.contains(where: { $0.id == entry.mediaID }) else {
                        throw BackpackError.invalid("The remaining queue changed. Check completed slots before retrying.")
                    }
                    guard let original = plan.inventory.records.first(where: { $0.id == entry.slot }),
                          panel.slots.first(where: { $0.id == entry.slot })?.identifier == original.identifier else {
                        throw BackpackError.invalid("A destination slot changed. Confirm a fresh overwrite plan.")
                    }
                    status = "Sending \(index + 1) / \(plan.entries.count) to slot \(entry.slot)..."
                    let data = try Data(contentsOf: prepared[index])
                    attemptedWrite = true
                    try await panel.upload(data, slot: entry.slot, overwriteApproved: true, batch: ownership)
                    completed.append(entry.queuedID)
                    try checkScope(plan)
                    guard let record = panel.slots.first(where: { $0.id == entry.slot }), record.occupied else {
                        throw BackpackError.invalid("The backpack did not confirm an occupied destination after upload.")
                    }
                    try library.rememberSlot(panel: plan.inventory.serial, slot: entry.slot,
                        identifier: record.identifier, mediaID: entry.mediaID)
                    try library.removeQueuedMedia([entry.queuedID])
                    await Task.yield()
                }
                try checkScope(plan)
                if plan.loopWhenFinished { try await panel.play(list: plan.entries.map(\.slot), batch: ownership) }
                status = plan.loopWhenFinished ? "All GIFs sent. The ordered loop runs on the backpack without the app." : "All GIFs sent."
            } catch {
                let detail = attemptedWrite
                    ? "Stopped after \(completed.count) confirmed uploads. The current slot may be partially overwritten; inspect and refresh backpack storage before retrying. No rollback or automatic retry."
                    : "Preparation stopped. No backpack slots were changed by this batch."
                status = detail
                failure = Task.isCancelled ? detail : "\(detail) \(error.localizedDescription)"
                panel.report(BackpackError.invalid(failure ?? detail))
            }
            var cleanupErrors: [String] = []
            for file in prepared {
                do { try FileManager.default.removeItem(at: file) }
                catch { cleanupErrors.append(error.localizedDescription) }
            }
            if createdFolder {
                do { try FileManager.default.removeItem(at: folder) }
                catch { cleanupErrors.append(error.localizedDescription) }
            }
            if !cleanupErrors.isEmpty {
                let detail = "Batch temporary-file cleanup failed: \(cleanupErrors.joined(separator: "; "))"
                failure = [failure, detail].compactMap { $0 }.joined(separator: " ")
                panel.report(BackpackError.invalid(detail))
            }
            do { try panel.endBatch(ownership) } catch { failure = error.localizedDescription; panel.report(error) }
            running = false; task = nil
        }
    }
    private func checkSources(_ plan: BatchTransferPlan, library: LocalLibrary) throws {
        guard plan.entries.allSatisfy({ entry in
            library.state.media.contains { $0.id == entry.mediaID } &&
                library.state.transferQueue?.contains { $0.id == entry.queuedID && $0.mediaID == entry.mediaID } == true
        }) else { throw BackpackError.invalid("Queued artwork changed. Reopen the send queue.") }
    }
    private func checkScope(_ plan: BatchTransferPlan) throws {
        try Task.checkCancellation()
        guard !backgrounded, panel.link.connected, panel.link.selectedID == plan.inventory.deviceID,
              panel.inventoryDeviceID == plan.inventory.deviceID, panel.identity?.serial == plan.inventory.serial,
              panel.size == plan.size else { throw BackpackError.invalid("Batch device or foreground state changed.") }
    }
    func stop() async {
        if task != nil { status = "Stopping batch; waiting for the current operation to end..." }
        task?.cancel(); await task?.value
    }
    func connectionLost() { task?.cancel() }
    func setBackground(_ value: Bool) { backgrounded = value; if value { task?.cancel() } }
}
