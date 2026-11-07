import SwiftUI
import BackpackProtocol

@MainActor
final class SwapRecoveryStore: ObservableObject {
    @Published private(set) var journal: LocalSwapOriginal?
    @Published private(set) var received: [ReceivedSwapArtwork] = []
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var notice: String?
    private var repository: SwapRecoveryRepository?
    private var operation = UUID()
    init(repository: SwapRecoveryRepository? = nil) { self.repository = repository }
    private func storage() throws -> SwapRecoveryRepository {
        if let repository { return repository }
        guard let value = SwapRecoveryRepository.shared else {
            throw BackpackError.invalid("Owned swap recovery directory unavailable; replacement is prohibited.")
        }
        repository = value; return value
    }
    static func ownerScope(_ community: CommunityController) -> String {
        guard let id = community.user?.id, let origin = community.origin, community.signedIn else { return "owner-local-no-account" }
        return origin.url.absoluteString + "|" + id.uuidString.lowercased()
    }
    func invalidate() { operation = UUID(); busy = false; received = []; journal = nil; failure = nil; notice = nil }
    func load() async {
        guard !busy else { return }
        let stamp = operation
        busy = true; defer { if stamp == operation { busy = false } }
        do {
            let original = try await storage().load()
            try Task.checkCancellation(); guard stamp == operation else { return }
            journal = original
            let collection = try await storage().received()
            try Task.checkCancellation(); guard stamp == operation else { return }
            received = collection; failure = nil
        } catch { if stamp == operation && !Task.isCancelled { failure = error.localizedDescription } }
    }
    func prepare(phone: PhoneDisplayController, targets: DisplayTargetSelection,
        community: CommunityController, attribution: Attribution?) async {
        guard !busy else { return }
        let stamp = operation, scope = Self.ownerScope(community), account = community.accountRevision
        let original = phone.snapshot(), revision = phone.artworkRevision
        let frame = phone.preview == nil ? nil : Optional(phone.position(atElapsed: original.elapsed).index)
        let target = targets.target, hardware = targets.hardwareArtworkID
        busy = true; failure = nil
        defer { if stamp == operation { busy = false } }
        do {
            guard targets.phonePeerOwner == nil else { throw BackpackError.invalid("Stop the active peer controller before manually preparing recovery.") }
            let value = try await storage().prepare(snapshot: original, frame: frame, artworkRevision: revision,
                ownerScope: scope, target: target, hardwareArtwork: hardware, attribution: attribution)
            guard stamp == operation, community.accountRevision == account, targets.target == target,
                  phone.artworkRevision == revision else {
                throw BackpackError.invalid("Original saved, but display/account context changed. Recovery remains available; no readiness or replacement is authorized.")
            }
            journal = value
            notice = "Original bytes and playback saved durably. Recovery preparation did not swap or enable the separate game."
        } catch { if stamp == operation { failure = error.localizedDescription } }
    }
    func cancelReadiness(community: CommunityController) async {
        guard !busy, let journal else { return }
        let stamp = operation
        busy = true; defer { if stamp == operation { busy = false } }
        do {
            let value = try await storage().cancelReadiness(id: journal.transactionID, ownerScope: Self.ownerScope(community))
            guard stamp == operation else { return }
            self.journal = value; notice = "Future readiness cancelled. Original recovery bytes remain; explicit restore is still available."
        } catch { if stamp == operation { failure = error.localizedDescription } }
    }
    func restore(phone: PhoneDisplayController, targets: DisplayTargetSelection,
        community: CommunityController) async {
        guard !busy, let journal else { failure = "Load a known recovery journal first."; return }
        let stamp = operation, scope = Self.ownerScope(community), account = community.accountRevision
        busy = true; failure = nil
        defer { if stamp == operation { busy = false } }
        do {
            guard targets.target == .phone else { throw BackpackError.invalid("Explicitly select the phone target before restoring. No hardware commands will be sent.") }
            let lease = UUID()
            try targets.acquirePhone(lease)
            defer { targets.releasePhone(lease) }
            let retained = try await storage().beginRestore(id: journal.transactionID, ownerScope: scope, target: .phone)
            try Task.checkCancellation()
            guard stamp == operation, community.accountRevision == account, targets.target == .phone else { throw CancellationError() }
            try await phone.restore(retained.phone)
            let restored = phone.snapshot()
            guard stamp == operation, community.accountRevision == account, targets.target == .phone,
                  restored.data == retained.phone.data, restored.mediaID == retained.phone.mediaID,
                  phone.position().index == retained.originalFrame,
                  restored.wantsPlayback == retained.phone.wantsPlayback else {
                throw BackpackError.invalid("Phone restoration was not acknowledged in the current target/account context. Original copy remains retained.")
            }
            let acknowledged = try await storage().acknowledgeRestore(id: retained.transactionID,
                originalSHA256: LocalSwapOriginal.digest(restored.data ?? Data()), ownerScope: scope)
            guard stamp == operation, community.accountRevision == account else { return }
            self.journal = acknowledged; phone.open()
            notice = "Original phone artwork/playhead restored and acknowledged. Durable recovery bytes remain; no hardware restore was attempted."
        } catch { if stamp == operation && !(error is CancellationError) { failure = error.localizedDescription } }
    }
    func importReceived(_ url: URL) async {
        guard !busy else { return }
        let stamp = operation; busy = true; failure = nil
        defer { if stamp == operation { busy = false } }
        do {
            let reader = Task.detached { try PhoneDisplayFileReader.read(url) }
            let data = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            try Task.checkCancellation()
            guard stamp == operation else { return }
            _ = try await storage().retainReceived(data: data, transactionID: UUID(),
                name: url.deletingPathExtension().lastPathComponent, attribution: nil)
            let values = try await storage().received()
            guard stamp == operation else { return }
            received = values
            notice = "File staged locally in Received swaps. This was a manual import, not a peer transfer or encounter."
        } catch { if stamp == operation && !Task.isCancelled { failure = error.localizedDescription } }
    }
    func remove(_ item: ReceivedSwapArtwork) async {
        guard !busy else { return }
        let stamp = operation; busy = true
        defer { if stamp == operation { busy = false } }
        do {
            try await storage().removeReceived(item.id)
            guard stamp == operation else { return }
            received.removeAll { $0.id == item.id }; notice = "Received local copy removed; recovery original unchanged."
        } catch { if stamp == operation { failure = error.localizedDescription } }
    }
    func report(_ error: Error) { if !(error is CancellationError) { failure = error.localizedDescription } }
}

@MainActor
struct SwapRecoveryView: View {
    @EnvironmentObject private var store: SwapRecoveryStore
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @EnvironmentObject private var targets: DisplayTargetSelection
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.scenePhase) private var phase
    @State private var restoreConfirmation = false
    @State private var preparing = false
    @State private var importing = false
    @State private var selected: ReceivedSwapArtwork?
    @State private var removing: ReceivedSwapArtwork?
    @State private var task: Task<Void, Never>?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Recovery first").font(.title2.bold())
                Label("Recovery tool — no exchange started here", systemImage: "lock.shield")
                Text("No game is enabled. No peer transfer, discovery-triggered replacement, slot write or hardware restoration exists in this screen. A saved original is prerequisite, not evidence that a swap happened.").font(.caption)
                Text("Target: \(targets.target.rawValue). Hardware automatic replacement is blocked: a slot/hash/unknown or sentinel descriptor is not recoverable original bytes/state.").font(.caption).foregroundStyle(.orange)
                if let failure = store.failure { Text(failure).foregroundStyle(.orange) }
                if let notice = store.notice { Text(notice).font(.caption) }
                if store.busy { ProgressView() }
                Button("Inspect retained recovery / received originals") { task = Task { await store.load() } }.disabled(store.busy)
                if let journal = store.journal {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved transaction: \(journal.transactionID.uuidString.lowercased())").font(.caption.monospaced())
                        Text("Stage: \(journal.stage.rawValue) · original frame \(journal.originalFrame + 1)")
                        Text("Exact original bytes: \(journal.phone.data?.count ?? 0); playhead \(journal.phone.elapsed, specifier: "%.2f")s. No encounter/location history.").font(.caption)
                        if journal.needsRecovery { Label("Original recovery copy retained", systemImage: "arrow.uturn.backward") }
                        if journal.needsRecovery {
                            Button("Cancel future readiness / retain recovery") { task = Task { await store.cancelReadiness(community: community) } }.disabled(store.busy)
                        }
                        Button("Restore my original phone artwork") { restoreConfirmation = true }
                            .disabled(store.busy || targets.target != .phone)
                        Text("Restore explicitly replaces the current phone choice, even if you selected newer artwork. Check the target. An account/installation mismatch fails closed; no automatic recovery on login, disconnect or target change.").font(.caption)
                    }.padding(16).glassPanel()
                }
                Button("Prepare durable copy of my current phone original") { preparing = true }
                    .disabled(store.busy || targets.target != .phone || !phone.hasArtwork || phone.loading)
                Text("One active transaction. Original remains retained through errors/restarts/cancellation and until an acknowledged restore. A new prepared original may replace only an acknowledged record after its cooldown; no automatic replay.").font(.caption)
                Text("Received swaps — separate local collection").font(.headline)
                Button("Manually import a received file (not peer transfer)") { importing = true }.disabled(store.busy)
                Text("Local staging/preview/save/remove only, never automatic cloud/publication/friendship. Original timing/bytes and supplied attribution stay intact. No arbitrary peer filenames/paths are followed.").font(.caption)
                ForEach(store.received) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        ReceivedSwapPixels(data: item.data, play: false)
                            .frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 16))
                        Text(item.name).font(.headline)
                        Text(item.transportVerified ? "Authenticated peer-protocol receipt — not proximity/attendance proof" : "Manually staged — no verified peer transfer").font(.caption)
                        if let attribution = item.attribution { Text("\(attribution.author) · \(attribution.source) · \(attribution.license)").font(.caption) }
                        Button("Inspect full local preview") { selected = item }
                        Button("Save independent copy to phone library") {
                            task = Task {
                                do { _ = try await originals.saveReceivedCopy(item.data, name: item.name, attribution: item.attribution) }
                                catch { store.report(error) }
                            }
                        }.disabled(originals.busy || store.busy)
                        Button("Remove received local copy", role: .destructive) { removing = item }
                    }.padding(16).glassPanel()
                }
            }.padding(20)
        }.modernScene().navigationTitle("Swap recovery")
        .task { await store.load() }
        .onChange(of: community.accountRevision) { _, _ in cancelContext() }
        .onChange(of: targets.target) { _, _ in cancelContext() }
        .onChange(of: phase) { _, state in if state != .active { cancelContext() } }
        .onDisappear { task?.cancel(); phone.cancelPendingSelection(); store.invalidate() }
        .confirmationDialog("Save my exact original before future replacement?", isPresented: $preparing) {
            Button("Prepare recovery only — no exchange") {
                let attribution = originals.items.first(where: { $0.id == phone.mediaID })?.attribution ??
                    library.state.media.first(where: { $0.id == phone.mediaID })?.attribution
                task = Task { await store.prepare(phone: phone, targets: targets, community: community, attribution: attribution) }
            }
        }
        .confirmationDialog("Restore saved original onto the PHONE target?", isPresented: $restoreConfirmation) {
            Button("Restore my original phone artwork") { task = Task { await store.restore(phone: phone, targets: targets, community: community) } }
        } message: { Text("Current phone artwork will be replaced only after validating the known original. Original journal is not deleted. Hardware artwork/playback stays unchanged.") }
        .confirmationDialog("Remove received local copy?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let removing { Button("Remove received copy", role: .destructive) { task = Task { await store.remove(removing); self.removing = nil } } }
        }
        .sheet(item: $selected) { item in ReceivedSwapPreview(item: item) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gif, .png, .jpeg, .webP]) { result in
            task?.cancel()
            task = Task {
                do { let url = try result.get(); await store.importReceived(url) }
                catch { store.report(error) }
            }
        }
    }
    private func cancelContext() {
        task?.cancel(); phone.cancelPendingSelection(); store.invalidate()
        restoreConfirmation = false; preparing = false; selected = nil; removing = nil
    }
}

@MainActor
private struct ReceivedSwapPreview: View {
    let item: ReceivedSwapArtwork
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var play = false
    var body: some View {
        NavigationStack {
            VStack {
                if play && phase == .active {
                    ReceivedSwapPixels(data: item.data, play: true, fullSize: true).scaledToFit()
                } else {
                    ReceivedSwapPixels(data: item.data, play: false, fullSize: true).scaledToFit()
                }
                Text(item.name)
                Button(play ? "Pause preview" : "Play local preview") { play.toggle() }
                Text("Preview only; current phone/hardware artwork and recovery original are unchanged.").font(.caption)
            }.padding().background(.black).foregroundStyle(.white)
                .toolbar { Button("Done") { dismiss() } }
                .onChange(of: phase) { _, phase in if phase != .active { play = false } }
                .onChange(of: reduced) { _, reduced in if reduced { play = false } }
        }
    }
}

@MainActor
private struct ReceivedSwapPixels: View {
    let data: Data
    let play: Bool
    var fullSize = false
    @State private var decoded: GIFPreview?
    @State private var failure: String?
    @State private var start = Date()
    var body: some View {
        Group {
            if let decoded {
                TimelineView(.animation(paused: !play)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(start))
                    let finished = decoded.cycles.map { elapsed >= decoded.duration * Double($0) } ?? false
                    let index = !play ? 0 : finished ? decoded.frames.count - 1 : decoded.frameIndex(at: elapsed)
                    Image(uiImage: decoded.frames[index]).interpolation(.none).resizable().scaledToFit()
                }
            } else if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            else { ProgressView() }
        }.background(.black)
        .task {
            do {
                let worker = Task.detached {
                    if fullSize { return try GIFPreviewDecoder.phoneDisplay(data) }
                    return try GIFPreviewDecoder.thumbnail(data)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); decoded = result; start = Date()
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onDisappear { decoded = nil }
    }
}
