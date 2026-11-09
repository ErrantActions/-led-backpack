import SwiftUI
import BackpackProtocol

@MainActor
final class FriendPhoneInteractionStore: ObservableObject {
    @Published private(set) var engine: PhoneSwapGame?
    @Published private(set) var selected: NativeFriendSession?
    @Published private(set) var failure: String?
    @Published private(set) var consumed: Set<UUID> = []
    private var preparedArtworkID: UUID?
    private var preparedPreset: FriendScenePreset?
    private weak var phone: PhoneDisplayController?
    private weak var targets: DisplayTargetSelection?
    private weak var community: CommunityController?
    func bind(phone: PhoneDisplayController, targets: DisplayTargetSelection, community: CommunityController) {
        self.phone = phone; self.targets = targets; self.community = community
    }
    func prepare(_ session: NativeFriendSession, preset: FriendScenePreset, consent: Bool, attribution: Attribution?, artwork: FriendArtworkChoice? = nil) {
        do {
            guard !consumed.contains(session.id), let phone, let targets, let community, let account = community.user?.id,
                  targets.target == .phone, targets.phonePeerOwner == nil else {
                throw BackpackError.invalid("Choose a free PHONE target/current account. A stopped/backgrounded bound session requires a fresh invitation; keys are not retained or replaced.")
            }
            engine?.stop(reason: "Prepared settings replaced; no restart")
            engine = nil; selected = nil; preparedArtworkID = nil; preparedPreset = nil
            let authority = try AcceptedFriendAuthority(session: session, preset: preset, consent: consent,
                phone: phone, account: account, attribution: attribution, artwork: artwork)
            let next = PhoneSwapGame(friendAuthority: authority)
            next.bind(phone: phone, targets: targets, community: community)
            selected = session; engine = next; preparedArtworkID = artwork?.id; preparedPreset = preset
            failure = nil; next.prepareRadio()
        } catch { failure = error.localizedDescription }
    }
    func arm(_ session: NativeFriendSession, consent: Bool, attribution: Attribution?,
        artworkID: UUID? = nil, preset: FriendScenePreset? = nil) {
        guard consent, selected?.id == session.id, let engine, !engine.enabled, !engine.busy,
              artworkID == preparedArtworkID, preset == nil || preset == preparedPreset,
              engine.radio.ready, !consumed.contains(session.id), consumed.count < 32 else {
            failure = "Explicit media consent, prepared radio and fresh selected session are required. No game/discoverability fallback."; return
        }
        if engine.enable(consent: consent, attribution: attribution) { failure = nil; consumed.insert(session.id) }
    }
    func stop(_ reason: String = "Left accepted-friend scene; original retained for explicit recovery") {
        engine?.stop(reason: reason)
    }
    func stopSelected(_ id: UUID) {
        if selected?.id == id {
            engine?.stop(reason: "Selected service session stopping — local first", withdrawService: false)
        }
    }
    func accountChanged() {
        stop("Account/service changed — friend key erased, no restart")
        engine = nil; selected = nil; consumed = []; failure = nil
        preparedArtworkID = nil; preparedPreset = nil
    }
    func discardPrepared() {
        guard engine?.enabled != true, engine?.busy != true else { return }
        stop("Prepared media/settings discarded — explicit preparation required")
        engine = nil; selected = nil; preparedArtworkID = nil; preparedPreset = nil; failure = nil
    }
}

@MainActor
struct FriendPlaybackView: View {
    let selected: NativeFriendSession
    @EnvironmentObject private var interactions: FriendPhoneInteractionStore
    @EnvironmentObject private var game: PhoneSwapGame
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var targets: DisplayTargetSelection
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @Environment(\.scenePhase) private var phase
    @State private var preset = FriendScenePreset.aurora
    @State private var consent = false
    @StateObject private var media = FriendArtworkSelection()
    @State private var choosing = false
    @State private var selectionTask: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(selected.kind.rawValue) with \(selected.peer.displayName)").font(.title2.bold())
                Text("PHONE target only • \(selected.direction == "outgoing" ? "session sender / left scene" : "session recipient / right scene") • ends \(selected.expiresAtISO)").font(.caption)
                FeatureDetails("Peer verification") {
                    Text("Both friends must arm this session and verify their keys. Radio hints do not prove proximity.")
                }
                Picker("Supported matching preset", selection: $preset) { ForEach(FriendScenePreset.allCases) { Text($0.rawValue).tag($0) } }
                    .disabled(interactions.engine?.enabled == true || interactions.engine?.busy == true || interactions.consumed.contains(selected.id))
                if selectsArtwork {
                    if let choice = media.choice {
                        Text("Interaction artwork: \(choice.name) — \(choice.data.count) bytes").font(.caption)
                    } else { Text("Select interaction artwork separately. Your current phone artwork remains the recovery original.").font(.caption) }
                    Button("Choose GIF") { media.pause(); choosing = true }.disabled(!canEdit)
                    FeatureDetails("Use what's playing") {
                        Button("Use my displayed GIF") { useDisplayedArtwork() }.disabled(!canEdit || !phone.hasArtwork)
                    }
                } else if selected.kind == .palette || selected.kind == .duet {
                    Button("Prepare isolated LOCAL preset preview — paused") {
                        selectionTask?.cancel()
                        let context = selectionContext()
                        selectionTask = Task { await media.previewPreset(kind: selected.kind, preset: preset, sender: selected.direction == "outgoing", context: context) }
                    }.disabled(!canEdit)
                } else { Text("Recipient's current artwork is recovery only and is never sent. Remote GIF preview is unavailable until validated transfer.").font(.caption) }
                FriendArtworkPreview(selection: media)
                FeatureDetails("How this scene works") {
                    Text("Greeting stays local. Palette and duet use generated colors. Pass sends only the sender's chosen GIF (up to128KiB). Your original is retained.")
                }
                Toggle("I explicitly arm this kind/preset and its media-sharing/display intent", isOn: $consent)
                    .disabled(interactions.consumed.contains(selected.id) || media.reading)
                Text("Both friends must opt in here. Pass shares your chosen GIF—even private artwork—and the recipient can keep it. Incoming content may be explicit.").font(.caption).foregroundStyle(.orange)
                Button("Prepare this friend's Bluetooth (explicit OS permission)") {
                    media.pause()
                    interactions.prepare(selected, preset: preset, consent: consent, attribution: credit, artwork: media.choice)
                }.disabled(!consent || !canEdit || (selectsArtwork && media.choice == nil) || !phone.hasArtwork)
                if let failure = interactions.failure { Text(failure).foregroundStyle(.orange) }
                if interactions.selected?.id == selected.id, let engine = interactions.engine {
                    FriendArmButton(engine: engine, radio: engine.radio, consent: consent,
                        blocked: media.reading || interactions.consumed.contains(selected.id) || targets.target != .phone || !phone.hasArtwork || phone.loading) {
                            media.pause()
                            interactions.arm(selected, consent: consent, attribution: credit, artworkID: media.choice?.id, preset: preset)
                        }
                    FriendPlaybackStatus(engine: engine)
                    Button("Leave / stop local first", role: .destructive) { consent = false; interactions.stop() }
                    Button("Leave and restore my initial original") { consent = false; Task { await engine.restoreOriginal() } }
                }
                NavigationLink("Recovery first / Received swaps — explicit Save/remove") { SwapRecoveryView() }
                FeatureDetails("Timing & recovery") {
                    Text("Both apps verify readiness before replacing artwork. Timing is best-effort, not certified synchronization or proximity.")
                    Text("Stopping, expiry or leaving the foreground stops locally; no automatic restart. Your original remains available for explicit Restore.")
                    Text("Phone only. Stay stationary; no chase or traffic play. Motion and data-saving settings still apply.")
                }
            }.padding(20)
        }.modernScene().navigationTitle("Friend phone scene")
        .sheet(isPresented: $choosing) {
            FriendArtworkPicker(selection: media, requiresOutgoingGIF: selected.kind == .pass, context: selectionContext())
        }
        .onChange(of: media.choice?.id) { _, _ in consent = false; interactions.discardPrepared() }
        .onChange(of: consent) { _, value in if !value && !interactions.consumed.contains(selected.id) { interactions.discardPrepared() } }
        .onChange(of: preset) { _, _ in consent = false; media.cancelPending(); interactions.discardPrepared() }
        .onChange(of: phase) { _, value in if value != .active { selectionTask?.cancel(); media.cancelPending(); consent = false; interactions.stop("Background — no resume; recovery retained") } }
        .onChange(of: community.accountRevision) { _, _ in selectionTask?.cancel(); media.clear(); choosing = false; consent = false; interactions.accountChanged() }
        .onChange(of: community.origin) { _, _ in selectionTask?.cancel(); media.clear(); choosing = false; consent = false; interactions.accountChanged() }
        .onChange(of: targets.target) { _, value in if value != .phone { selectionTask?.cancel(); media.cancelPending(); consent = false; interactions.stop("Hardware friend scenes unsupported") } }
        .onDisappear { selectionTask?.cancel(); media.cancelPending(); if !phone.presented { consent = false; interactions.stop() } }
    }
    private var selectsArtwork: Bool { selected.kind == .greeting || (selected.kind == .pass && selected.direction == "outgoing") }
    private var canEdit: Bool { !media.reading && interactions.engine?.enabled != true && interactions.engine?.busy != true && !interactions.consumed.contains(selected.id) }
    private func selectionContext() -> @MainActor () throws -> Void {
        let account = community.accountRevision, origin = community.origin
        return {
            guard community.accountRevision == account, community.origin == origin, phase == .active,
                  targets.target == .phone, !interactions.consumed.contains(selected.id) else { throw CancellationError() }
        }
    }
    private func useDisplayedArtwork() {
        guard let data = phone.data else { return }
        selectionTask?.cancel()
        let context = selectionContext(), attribution = credit
        selectionTask = Task {
            _ = await media.select(name: "Explicit copy of current phone artwork", attribution: attribution,
                requiresOutgoingGIF: selected.kind == .pass, read: { data }, context: context)
        }
    }
    private var credit: Attribution? {
        originals.items.first(where: { $0.id == phone.mediaID })?.attribution ??
            library.state.media.first(where: { $0.id == phone.mediaID })?.attribution ??
            interactions.engine?.ownedPhoneAttribution ?? game.ownedPhoneAttribution
    }
}
@MainActor
private struct FriendArmButton: View {
    @ObservedObject var engine: PhoneSwapGame
    @ObservedObject var radio: PhoneSwapRadio
    let consent, blocked: Bool
    let action: @MainActor () -> Void
    var body: some View {
        Button("Arm selected friend scene / open phone canvas", action: action)
            .disabled(!consent || blocked || !radio.ready || engine.enabled || engine.busy)
    }
}
@MainActor
private struct FriendPlaybackStatus: View {
    @ObservedObject var engine: PhoneSwapGame
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(engine.status)
            FriendRadioReadiness(radio: engine.radio)
            if engine.busy { ProgressView("Preparing durable original / current friend binding") }
            if let error = engine.failure { Text(error).foregroundStyle(.orange) }
        }
    }
}
@MainActor
private struct FriendRadioReadiness: View {
    @ObservedObject var radio: PhoneSwapRadio
    var body: some View { Text("Accepted-friend radio: \(radio.ready ? "OS ready, consent still separate" : "not ready") — \(radio.status)").font(.caption) }
}
@MainActor
struct FriendPhoneCanvasControls: View {
    @ObservedObject var engine: PhoneSwapGame
    var body: some View {
        if engine.enabled || engine.busy {
            VStack(spacing: 8) {
                Text(engine.status).font(.caption)
                Button("Leave friend interaction / retain original", role: .destructive) { engine.stop(reason: "Explicit phone-canvas leave — original retained") }
                Button("Leave / restore my original") { Task { await engine.restoreOriginal() } }
            }
        } else if let failure = engine.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
    }
}
