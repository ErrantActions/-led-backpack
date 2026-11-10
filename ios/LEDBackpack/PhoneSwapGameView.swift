import SwiftUI

@MainActor
struct PhoneSwapGameView: View {
    @EnvironmentObject private var game: PhoneSwapGame
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var targets: DisplayTargetSelection
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var originals: PhoneArtworkLibrary
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var consent = false
    @State private var cardAction: CardAction?
    @State private var peerReport: PeerIncidentSelection?
    @State private var reportSelectionFailure: String?
    @State private var removing: ReceivedSwapArtwork?
    private struct CardAction { let card: LocalMetFriend; let action: String }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GIF swap").font(.title2.bold())
                        StatusPill(title: game.busy ? "Preparing" : game.enabled ? "Game on" : "Game off", symbol: "arrow.triangle.2.circlepath")
                    }
                    Spacer()
                    Text("\(game.received.count)").font(.largeTitle.bold()).foregroundStyle(Aurora.mint)
                }
                if let failure = game.failure { Text(failure).foregroundStyle(.orange) }
                if let reportSelectionFailure { Text(reportSelectionFailure).foregroundStyle(.orange) }
                if let peer = game.reportablePeer, community.config?.peerIncidentReportsEnabled == true {
                    Button("Report this game peer") { selectReport(peer) }
                }
                if game.busy { ProgressView("Preparing GIF swap") }
                Text(game.status).font(.caption).foregroundStyle(.secondary)
                if !game.enabled && !game.busy {
                    NavigationLink { PhoneDisplayLibraryView() } label: { FeatureRowLabel(title: "Choose a GIF", symbol: "photo") }
                    if phone.hasArtwork {
                        Button("Open player") {
                            targets.target = .phone; phone.open()
                        }
                    }
                }
                setup
                if game.enabled || game.busy {
                    Button("Stop swaps", role: .destructive) { game.stop(); consent = false; Task { await game.loadMet() } }
                        .buttonStyle(.bordered)
                }
                Button("Restore my original GIF") { consent = false; Task { await game.restoreOriginal() } }
                FeatureDetails("Connection & recovery") {
                    GameRadioIndicator(radio: game.radio)
                    Text("Both players opt in. Only the playing GIF is sent (up to 128 KiB). Swaps have a 60-second cooldown and do not repeat the same peer on rearm.")
                    Text("Your first original stays saved across swaps. A newer manual choice is not overwritten. Disconnects can leave the peer's outcome uncertain.")
                    Text("Phone only. Bluetooth is a nearby hint, not reliable meters or anti-relay proof. No GPS/encounter history is uploaded.")
                    Button("Withdraw this login's game") { consent = false; Task { await game.reconcileAndStop() } }
                    NavigationLink("Received & recovery tools") { SwapRecoveryView() }
                }
                foundUsers
            }.padding(20)
        }.modernScene().navigationTitle("Phone GIF swap game")
        .sheet(item: $peerReport) { selection in PeerIncidentComposeView(selection: selection) }
        .task(id: community.accountRevision) { await game.loadMet() }
        .onChange(of: phase) { _, state in if state != .active { game.stop(reason: "Background stopped game; restore original explicitly"); consent = false } }
        .onChange(of: community.accountRevision) { _, _ in game.stop(reason: "Account changed"); consent = false; cardAction = nil; peerReport = nil; removing = nil }
        .onChange(of: community.user?.role) { _, _ in peerReport = nil; reportSelectionFailure = nil }
        .onChange(of: targets.target) { _, target in if target != .phone { game.stop(reason: "Target changed — hardware swap unsupported"); consent = false } }
        .onDisappear {
            if !phone.presented { game.stop(reason: "Game page closed"); consent = false }
        }
        .confirmationDialog("Apply this explicit contact action?", isPresented: Binding(get: { cardAction != nil }, set: { if !$0 { cardAction = nil } })) {
            if let value = cardAction {
                Button(value.action == "request" ? "Send friend request" : value.action == "block" ? "Block this account" : "Dismiss local card",
                    role: value.action == "block" ? .destructive : nil) {
                        Task { await game.contactAction(value.card, action: value.action); cardAction = nil }
                    }
            }
        } message: { Text("This changes only the selected contact. It does not grant location or game permission.") }
        .confirmationDialog("Remove this received GIF and its Found Users card?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let item = removing {
                Button("Remove received GIF/card", role: .destructive) {
                    Task { await game.removeFound(item); removing = nil }
                }
            }
        } message: { Text("The first recovery original, current phone display and independently saved copies remain unchanged. Blocking is separate.") }
    }
    @ViewBuilder private var setup: some View {
        if community.config?.gifSwapPresenceEnabled == true && community.signedIn {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nearby players can keep your playing GIF—even private artwork—and see your name. Incoming GIFs may be explicit. Both players opt in; no friendship or encounter popup.")
                    .font(.caption).foregroundStyle(.orange)
                Text("Start replaces any game you enabled on another login.").font(.caption)
                Toggle("Allow automatic GIF sharing & display", isOn: $consent).disabled(game.enabled || game.busy)
                if !game.radio.ready {
                    Button("Enable Bluetooth") { game.prepareRadio() }.disabled(game.enabled || game.busy)
                        .accessibilityLabel("Prepare GAME Bluetooth (explicit)")
                }
                if !game.enabled && !game.busy {
                Button("Start swaps · 5 minutes") {
                    let credit = originals.items.first(where: { $0.id == phone.mediaID })?.attribution ??
                        library.state.media.first(where: { $0.id == phone.mediaID })?.attribution
                    game.enable(consent: consent, attribution: credit)
                }.buttonStyle(AuroraPrimaryButton())
                    .disabled(!consent || !game.radio.ready || game.enabled || game.busy || targets.target != .phone ||
                        !phone.isPlaying || !phone.viewerAutomaticPlaybackAllowed)
                    .accessibilityLabel("Enable 5-minute phone-only game")
                if !phone.isPlaying { Text("Play an animated GIF before starting.").font(.caption).foregroundStyle(.secondary) }
                if !phone.viewerAutomaticPlaybackAllowed { Text("Enable automatic phone playback in viewer settings first.").font(.caption) }
                if targets.target != .phone { Text("Choose the phone target before starting.").font(.caption).foregroundStyle(.orange) }
                }
            }.padding(16).glassPanel(radius: 20)
        } else if community.config?.gifSwapPresenceEnabled == true {
            Text("Sign in to swap GIFs. No friendship required.").font(.subheadline)
        } else {
            Text("GIF swaps are unavailable on this service.").font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var foundUsers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Found Users").font(.headline)
            Button("Reload Found Users") { Task { await game.loadMet() } }
            if game.received.isEmpty {
                ContentUnavailableView("No swaps yet", systemImage: "person.2",
                    description: Text("Confirmed swaps and their senders appear here."))
                    .accessibilityIdentifier("found-users-empty")
            }
            ForEach(game.received) { item in
                if let card = item.sender { foundRow(item, card: card) }
            }
        }
    }
    private func foundRow(_ item: ReceivedSwapArtwork, card: LocalMetFriend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ReceivedSwapPixels(data: item.data,
                play: phase == .active && !reducedMotion && phone.animationsEnabled && !phone.dataSaving).frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(card.displayName).font(.headline)
            if let credit = item.attribution { Text("\(credit.author) · \(credit.license)").font(.caption) }
            Button("Save GIF") { Task { await game.saveFound(item, to: originals) } }
                .disabled(originals.busy)
            if card.canRequestFriendship {
                Button("Send friend request") { cardAction = CardAction(card: card, action: "request") }
            }
            Menu("More") {
                Button("Remove GIF & card", role: .destructive) { removing = item }
                Button("Block", role: .destructive) { cardAction = CardAction(card: card, action: "block") }
                if community.config?.peerIncidentReportsEnabled == true {
                    Button("Report") { selectReport(card) }
                }
            }
        }.padding(16).glassPanel()
    }
    private func selectReport(_ peer: LocalMetFriend) {
        do {
            let selected = try PeerIncidentSelection(peer: peer, community: community)
            peerReport = selected
            game.stop(reason: "Game stopped locally for a deliberately selected incident explanation")
        } catch { reportSelectionFailure = error.localizedDescription }
    }
}
@MainActor
private struct GameRadioIndicator: View {
    @ObservedObject var radio: PhoneSwapRadio
    var body: some View { Text(radio.status).font(.caption).foregroundStyle(.secondary) }
}
