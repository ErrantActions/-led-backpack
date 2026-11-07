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
    @State private var consent = false
    @State private var cardAction: CardAction?
    @State private var peerReport: PeerIncidentSelection?
    @State private var reportSelectionFailure: String?
    private struct CardAction { let card: LocalMetFriend; let action: String }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Automatic phone GIF swap").font(.title2.bold())
                Text("Separate GAME consent — discovery, friendship and OS permission do not enable this. Phone target only. No verified proximity/anti-relay guarantee or hardware swap.").font(.caption)
                Text(game.status)
                if let failure = game.failure { Text(failure).foregroundStyle(.orange) }
                if let reportSelectionFailure { Text(reportSelectionFailure).foregroundStyle(.orange) }
                if let peer = game.reportablePeer, community.config?.peerIncidentReportsEnabled == true {
                    Button("Deliberately explain an incident with the selected game peer") { selectReport(peer) }
                }
                GameRadioIndicator(radio: game.radio)
                if game.busy { ProgressView() }
                if community.config?.gifSwapPresenceEnabled == true {
                    Toggle("Enable automatic sharing/display risk for this foreground game", isOn: $consent).disabled(game.enabled || game.busy)
                    Text("This consent covers automatic exchanges without encounter popups: the currently chosen GIF can be shared even if it came from a private library. Other players may retain copies and send unexpected mature/offensive artwork. Minimal account name/card is shared by the game service. Author/license credit is included if safe; private URL/comment metadata is removed from a separate outgoing copy, never your original.").font(.caption).foregroundStyle(.orange)
                    Text("Choose a GIF <=128 KiB; still formats remain valid for normal phone playback but are not secretly converted for the game. Both apps must independently enable this game and acknowledge complete validated artwork/readiness. Service access is required at handshake and again before apply; offline fails closed.").font(.caption)
                    Text("Explicit Enable replaces any prior own game presence, including another login's game. It does not take over friend discovery or enable friend requests.").font(.caption)
                    Button("Prepare GAME Bluetooth (explicit)") { game.prepareRadio() }.disabled(game.enabled || game.busy)
                    Button("Enable 5-minute phone-only game") {
                        let credit = originals.items.first(where: { $0.id == phone.mediaID })?.attribution ??
                            library.state.media.first(where: { $0.id == phone.mediaID })?.attribution
                        game.enable(consent: consent, attribution: credit)
                    }.disabled(!consent || game.enabled || game.busy || targets.target != .phone || !phone.hasArtwork)
                } else { Text("Game service capability is unavailable. Friend discoverability is NOT a fallback.") }
                Button("Stop game / retain recovery", role: .destructive) { game.stop(); consent = false; Task { await game.loadMet() } }
                Button("Stop and restore initial phone original") { consent = false; Task { await game.restoreOriginal() } }
                Button("Reconcile / withdraw current-login game") { consent = false; Task { await game.reconcileAndStop() } }
                NavigationLink("Recovery first / Received swaps") { SwapRecoveryView() }
                Text("The initial original is durable across successive swaps; received GIFs remain separate. A newer manual phone selection cancels ownership and is never automatically restored over. ATT success alone is not validation; peer outcome can be uncertain after disconnect.").font(.caption)
                Text("Met friends — local minimal cards").font(.headline)
                Button("Reload local cards") { Task { await game.loadMet() } }
                ForEach(game.met) { card in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(card.displayName.prefix(1))).frame(width: 40, height: 40).background(.quaternary, in: Circle())
                            Text(card.displayName).font(.headline)
                        }
                        Text("Not friends yet — this is a game card, not a relationship/proximity/profile grant.").font(.caption)
                        if card.canRequestFriendship {
                            Button("Review explicit friend request") { cardAction = CardAction(card: card, action: "request") }
                        } else { Text("Friend requests unavailable for this participant; playing did not change their preferences.").font(.caption) }
                        Button("Dismiss this local card") { cardAction = CardAction(card: card, action: "dismiss") }
                        Button("Review block", role: .destructive) { cardAction = CardAction(card: card, action: "block") }
                        if community.config?.peerIncidentReportsEnabled == true {
                            Button("Deliberately explain a private incident about this selected peer") { selectReport(card) }
                        }
                        Text("Any submitted claim remains unverified. Only a deliberate explanation is sent; no GIF/hash/evidence copy or target-profile grant. Local stop, block and remove remain separate.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).glassPanel()
                }
            }.padding(20)
        }.modernScene().navigationTitle("Phone GIF swap game")
        .sheet(item: $peerReport) { selection in PeerIncidentComposeView(selection: selection) }
        .task(id: community.accountRevision) { await game.loadMet() }
        .onChange(of: phase) { _, state in if state != .active { game.stop(reason: "Background stopped game; restore original explicitly"); consent = false } }
        .onChange(of: community.accountRevision) { _, _ in game.stop(reason: "Account changed"); consent = false; cardAction = nil; peerReport = nil }
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
        } message: { Text("Normal current service permissions are authoritative. No automatic friendship, location permission, public directory or media/profile access.") }
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
