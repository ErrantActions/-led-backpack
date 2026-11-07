import SwiftUI
import BackpackProtocol

enum BackpackSendSource {
    case catalog(CommunityItem)
    case local(SavedMedia)
    case vault(CloudVaultItem)
    case legacyCloud(CommunityCloudItem)
    var id: String {
        switch self {
        case .catalog(let item): return "catalog:" + item.id.uuidString.lowercased()
        case .local(let item): return "local:" + item.id.uuidString.lowercased()
        case .vault(let item): return "vault:\(item.accountId):\(item.generation):\(item.id):\(item.version)"
        case .legacyCloud(let item): return "legacy-cloud:" + item.id.uuidString.lowercased()
        }
    }
    var title: String {
        switch self {
        case .catalog: return "Selected community GIF"
        case .local(let item): return item.name
        case .vault, .legacyCloud: return "Selected private cloud GIF"
        }
    }
}
struct BackpackSendRequest: Identifiable {
    let id = UUID()
    let sources: [BackpackSendSource]
    var usesVault: Bool { sources.contains { if case .vault = $0 { return true }; return false } }
}
@MainActor
final class BackpackDirectSendStore: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var sending = false
    @Published private(set) var completed = 0
    @Published private(set) var status = "Prepare selected GIFs, then Send & Play"
    @Published private(set) var failure: String?
    @Published private(set) var plan: BackpackDirectSendPlan?
    @Published private(set) var preview: GIFPreview?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var playbackConfirmed = false
    private var payloads: [Data] = []
    private var preparedOptions: BackpackSendOptions?
    private var durations: [Int] = []
    private var task: Task<Void, Never>?
    private var epoch = UUID()
    private var capturedAccount: UUID?
    private var capturedPolicy: UUID?
    private var preparedSources: [BackpackSendSource] = []
    func invalidate() {
        guard !sending else { return }
        epoch = UUID(); task?.cancel(); task = nil; busy = false
        payloads = []; preparedSources = []; durations = []; preparedOptions = nil; plan = nil; preview = nil; warnings = []; failure = nil; playbackConfirmed = false
    }
    func stop() {
        epoch = UUID(); task?.cancel(); task = nil; busy = false; sending = false
        payloads = []; preparedSources = []; durations = []; capturedAccount = nil; capturedPolicy = nil
        preview = nil; plan = nil; preparedOptions = nil
        status = "Stopped after\(completed) uploaded GIF(s). Inspect backpack storage/playback before retrying; no automatic resend or rollback."
    }
    func prepare(_ request: BackpackSendRequest, options: BackpackSendOptions,
        community: CommunityController, panel: PanelController, library: LocalLibrary, vault: CloudVaultStore) {
        guard !sending else { return }
        invalidate()
        do { try options.validate() } catch { failure = error.localizedDescription; return }
        let stamp = epoch, account = community.accountRevision, policy = community.avatarPolicyRevision
        busy = true
        task = Task {
            defer { if epoch == stamp { busy = false } }
            do {
                guard !request.sources.isEmpty, request.sources.count <= 20, Set(request.sources.map(\.id)).count == request.sources.count,
                      panel.link.connected, !panel.hasDisplayOwner else { throw BackpackError.invalid("Connect the backpack and stop its other display controller before preparing1–20selected GIFs.") }
                try await panel.refreshStoredPlayback()
                guard let size = panel.size else { throw BackpackError.invalid("Panel dimensions unavailable. Refresh the Backpack tab.") }
                let proposed = try BackpackDirectSendPlan(inventory: panel.erasePlan(), size: size, count: request.sources.count)
                var prepared: [Data] = [], displayTimes: [Int] = [], cost = 0, notes: [String] = []
                for source in request.sources {
                    try context(stamp, account: account, policy: policy, community: community)
                    let original: Data
                    switch source {
                    case .catalog(let item):
                        guard let file = item.recordedFiles.first(where: \.original) else { throw BackpackError.invalid("Selected original GIF descriptor is unavailable.") }
                        original = try await community.downloadCatalogFile(itemID: item.id, file: file).data
                    case .local(let item):
                        let url = try library.phoneOriginalURL(item)
                        let worker = Task.detached { try PhoneDisplayFileReader.read(url) }
                        original = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    case .vault(let item):
                        original = try await vault.downloadForBackpack(item).data
                    case .legacyCloud(let item):
                        original = try await community.downloadLegacyBackpackGIF(item)
                    }
                    let worker = Task.detached { try options.timing.applying(to: original) }
                    let timed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    let fittedSource = try await BatchGIFPreparation.fit(timed, to: size)
                    let repeatWorker = Task.detached {
                        try GIFTimingAdjustment.repeatingCopy(fittedSource, totalLoops: options.limit == .loops ? options.totalLoops : nil)
                    }
                    let fitted = try await withTaskCancellationHandler { try await repeatWorker.value } onCancel: { repeatWorker.cancel() }
                    try context(stamp, account: account, policy: policy, community: community)
                    cost += fitted.count
                    guard cost <= 50_000_000 else { throw BackpackError.invalid("Prepared send copies exceed50MB; select fewer GIFs.") }
                    let info = try GIFStructure.inspect(fitted)
                    if info.frames.count == 1 { notes.append("GIF\(prepared.count + 1) contains one frame. Timing controls cannot make still artwork animate.") }
                    let cycle = try GIFTimingAdjustment.cycleSeconds(fitted)
                    let duration = try options.duration(for: fitted)
                    if cycle > Double(duration) {
                        notes.append("GIF\(prepared.count + 1) takes\(String(format: "%.2f", cycle))s for one animation cycle, longer than its\(duration)s time on screen.")
                    }
                    if options.limit == .loops { notes.append("GIF\(prepared.count + 1): \(options.totalLoops) total loops encoded in the send copy; derived device time\(duration)s (rounded to whole seconds). The backpack has no verified loop counter and may differ.") }
                    if info.frames.contains(where: { $0.delayCentiseconds == 0 || $0.delayCentiseconds == nil }) {
                        notes.append("GIF\(prepared.count + 1) has zero/missing frame delays. Device timing may differ; use Set all frame delays to choose explicit timing.")
                    }
                    if info.frames.contains(where: { ($0.delayCentiseconds ?? 0) > 6553 }) {
                        notes.append("GIF\(prepared.count + 1) has a frame pause over65.53s. Recovered firmware delay handling can differ; inspect the prepared timing and explicitly approve.")
                    }
                    prepared.append(fitted); displayTimes.append(duration)
                }
                try context(stamp, account: account, policy: policy, community: community)
                try proposed.inventory.validate(deviceID: panel.link.selectedID, serial: panel.identity?.serial, records: panel.slots)
                let first = prepared[0]
                let previewWorker = Task.detached { try GIFPreviewDecoder.thumbnail(first) }
                let image = try await withTaskCancellationHandler { try await previewWorker.value } onCancel: { previewWorker.cancel() }
                try context(stamp, account: account, policy: policy, community: community)
                payloads = prepared; preparedSources = request.sources; durations = displayTimes; plan = proposed; preview = image; warnings = notes
                preparedOptions = options; capturedAccount = account; capturedPolicy = policy
                status = "Ready: \(prepared.count)GIF(s), auto-fit to\(size.width)×\(size.height), empty slots\(proposed.slots.map(String.init).joined(separator: ", ")). Sources unchanged."
            } catch { if epoch == stamp && !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    private func context(_ stamp: UUID, account: UUID, policy: UUID, community: CommunityController) throws {
        try Task.checkCancellation()
        guard epoch == stamp, community.accountRevision == account, community.avatarPolicyRevision == policy,
              !community.avatarPolicyChanging, UIApplication.shared.applicationState == .active else { throw CancellationError() }
    }
    func send(options: BackpackSendOptions, confirmed: Bool, community: CommunityController, panel: PanelController, vault: CloudVaultStore) {
        guard !busy, !sending, !playbackConfirmed, confirmed, let plan, preparedOptions == options, payloads.count == plan.slots.count,
              durations.count == payloads.count,
              preparedSources.count == payloads.count,
              let account = capturedAccount, let policy = capturedPolicy else { failure = "Prepare current settings and explicitly confirm Send & Play first."; return }
        let stamp = epoch, bytes = payloads, displayTimes = durations, sources = preparedSources
        busy = true; sending = true; failure = nil; completed = 0; playbackConfirmed = false
        task = Task {
            var ownership: UUID?
            var attempted = false
            defer {
                if let ownership {
                    do { try panel.endBatch(ownership) }
                    catch { panel.report(error); if epoch == stamp { failure = error.localizedDescription } }
                }
                if epoch == stamp { busy = false; sending = false }
            }
            do {
                try context(stamp, account: account, policy: policy, community: community)
                try plan.inventory.validate(deviceID: panel.link.selectedID, serial: panel.identity?.serial, records: panel.slots)
                let token = try panel.beginBatch(); ownership = token
                try await panel.transaction(batch: token) {
                    for index in bytes.indices {
                        try context(stamp, account: account, policy: policy, community: community)
                        switch sources[index] {
                        case .vault(let item): try await vault.authorizeForBackpack(item)
                        case .legacyCloud(let item): try await community.authorizeLegacyBackpackGIF(item)
                        case .catalog, .local: break
                        }
                        try context(stamp, account: account, policy: policy, community: community)
                        guard panel.link.selectedID == plan.inventory.deviceID, panel.identity?.serial == plan.inventory.serial,
                              panel.size == plan.size else { throw BackpackError.invalid("The connected backpack changed before sending.") }
                        let slot = plan.slots[index]
                        let prior = try await readSlot(slot, panel: panel)
                        try context(stamp, account: account, policy: policy, community: community)
                        guard !prior.occupied, prior == plan.inventory.records.first(where: { $0.id == slot }) else {
                            throw BackpackError.invalid("The automatic empty slot changed. No overwrite authorized; refresh and prepare again.")
                        }
                        status = "Sending GIF\(index + 1)/\(bytes.count) to empty slot\(slot)"
                        let messages = try Wire.upload(Array(bytes[index]), slot: slot, size: plan.size, playSeconds: displayTimes[index])
                        for message in messages {
                            try context(stamp, account: account, policy: policy, community: community)
                            attempted = true; try await panel.link.acknowledged(message)
                        }
                        let stored = try await readSlot(slot, panel: panel)
                        try context(stamp, account: account, policy: policy, community: community)
                        guard stored.occupied else { throw BackpackError.invalid("Upload acknowledged but destination is not reported occupied. Do not resend automatically.") }
                        completed += 1
                    }
                    try context(stamp, account: account, policy: policy, community: community)
                    for source in sources {
                        switch source {
                        case .vault(let item): try await vault.authorizeForBackpack(item)
                        case .legacyCloud(let item): try await community.authorizeLegacyBackpackGIF(item)
                        case .catalog, .local: break
                        }
                    }
                    try context(stamp, account: account, policy: policy, community: community)
                    // Use the ordered-loop path for one GIF too; slot selection alone is not an animation receipt.
                    try await panel.link.acknowledged(try Wire.play(Playback(mode: 2, index: 255, ids: plan.slots.map(UInt8.init))))
                    let playback = try await panel.readPlayback()
                    try context(stamp, account: account, policy: policy, community: community)
                    guard plan.verifies(playback) else { throw BackpackError.invalid("GIFs uploaded, but requested loop playback was not confirmed. Inspect status; no success-shaped fallback/resend.") }
                    playbackConfirmed = true
                    status = "Uploaded\(completed)GIF(s). Backpack confirms their playback loop; speed\(String(format: "%.2f", options.timing.speed))×, program times\(displayTimes.map(String.init).joined(separator: ", "))s. Physical frames/loop counts remain unverified."
                }
                try panel.endBatch(token); ownership = nil
                try await panel.refreshStoredPlayback()
            } catch {
                if epoch == stamp {
                    failure = "\(error.localizedDescription) \(completed) uploads confirmed.\(attempted ? " The current slot may have been changed; inspect before retrying." : " No slots written.")"
                }
            }
        }
    }
    private func readSlot(_ slot: Int, panel: PanelController) async throws -> Slot {
        var result: Slot?
        _ = try await panel.link.request(try Wire.slotQuery(page: slot / 10)) { reply in
            guard case .slots(let records) = reply, let record = records.first(where: { $0.id == slot }) else { return false }
            result = record; return true
        }
        guard let result else { throw BackpackError.invalid("Destination-slot status unavailable.") }
        return result
    }
}
