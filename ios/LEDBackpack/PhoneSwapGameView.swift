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
                if !game.enabled && !game.busy {
                    NavigationLink("Choose a local phone GIF") { PhoneDisplayLibraryView() }
                    if phone.hasArtwork {
                        Button("Open phone player — Play, then choose Automatic GIF swap from its menu") {
                            targets.target = .phone; phone.open()
                        }
                    }
                }
                if community.config?.gifSwapPresenceEnabled == true {
                    Toggle("Enable automatic sharing/display risk for this foreground game", isOn: $consent).disabled(game.enabled || game.busy)
                    Text("Both players opt in beforehand. Nearby Bluetooth exchanges are automatic, without encounter popups or friendship requirements, and share the CURRENTLY PLAYING phone GIF, including a received GIF now playing. Private-library artwork can be copied by other players. Unexpected mature/offensive artwork is possible. The game shares a minimal consented name/card and safe author/license credit, not email, private profile or library access. Private URLs/comments are removed from an outgoing copy, never your original.").font(.caption).foregroundStyle(.orange)
                    Text("Choose a GIF <=128 KiB; still formats remain valid for normal phone playback but are not secretly converted for the game. Both apps must independently enable this game and acknowledge complete validated artwork/readiness. Service access is required at handshake and again before apply; offline fails closed.").font(.caption)
                    Text("Explicit Enable replaces any prior own game presence, including another login's game. It does not take over friend discovery or enable friend requests.").font(.caption)
                    Button("Prepare GAME Bluetooth (explicit)") { game.prepareRadio() }.disabled(game.enabled || game.busy)
                    Button("Enable 5-minute phone-only game") {
                        let credit = originals.items.first(where: { $0.id == phone.mediaID })?.attribution ??
                            library.state.media.first(where: { $0.id == phone.mediaID })?.attribution
                        game.enable(consent: consent, attribution: credit)
                    }.disabled(!consent || game.enabled || game.busy || targets.target != .phone || !phone.isPlaying || !phone.viewerAutomaticPlaybackAllowed)
                    if !phone.isPlaying { Text("Play a phone GIF first. A paused, finished or merely selected GIF is not an outgoing game source.").font(.caption) }
                    if !phone.viewerAutomaticPlaybackAllowed {
                        Text("Saved viewer settings disable automatic phone playback. Change that setting explicitly before arming; the game does not override it.").font(.caption)
                    }
                } else { Text("Game service capability is unavailable. Friend discoverability is NOT a fallback.") }
                Button("Stop game / retain recovery", role: .destructive) { game.stop(); consent = false; Task { await game.loadMet() } }
                Button("Stop and restore initial phone original") { consent = false; Task { await game.restoreOriginal() } }
                Button("Reconcile / withdraw current-login game") { consent = false; Task { await game.reconcileAndStop() } }
                NavigationLink("Recovery first / Received swaps") { SwapRecoveryView() }
                Text("The initial original is durable across successive swaps; received GIFs remain separate. A newer manual phone selection cancels ownership and is never automatically restored over. ATT success alone is not validation; peer outcome can be uncertain after disconnect.").font(.caption)
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
        } message: { Text("Normal current service permissions are authoritative. No automatic friendship, location permission, public directory or media/profile access.") }
        .confirmationDialog("Remove this received GIF and its Found Users card?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let item = removing {
                Button("Remove received GIF/card", role: .destructive) {
                    Task { await game.removeFound(item); removing = nil }
                }
            }
        } message: { Text("The first recovery original, current phone display and independently saved copies remain unchanged. Blocking is separate.") }
    }
    private var foundUsers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Found Users").font(.headline)
            Text("Only confirmed bilateral swaps appear here: the received GIF is paired with its authenticated sender. No encounter times, GPS, distances or automatic friendship. Stop/rearm does not reset the 60-second cooldown or same-peer suppression.").font(.caption)
            Button("Reload Found Users") { Task { await game.loadMet() } }
            if game.received.isEmpty { Text("No confirmed swaps for this account yet. Partial exchanges are not Found success.").font(.caption) }
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
            Text("Verified game sender, not an automatic friend or proximity/profile grant.").font(.caption)
            if let credit = item.attribution { Text("\(credit.author) · \(credit.license)").font(.caption) }
            Button("Save GIF permanently to phone library") { Task { await game.saveFound(item, to: originals) } }
                .disabled(originals.busy)
            if card.canRequestFriendship {
                Button("Send friend request") { cardAction = CardAction(card: card, action: "request") }
            } else { Text("This player has not enabled friend requests.").font(.caption) }
            Button("Remove received GIF/card", role: .destructive) { removing = item }
            Button("Review block", role: .destructive) { cardAction = CardAction(card: card, action: "block") }
            if community.config?.peerIncidentReportsEnabled == true {
                Button("Report an incident about this sender") { selectReport(card) }
            }
            Text("Reporting sends only your deliberate explanation, not this GIF, a location or an encounter log. Block and removal are separate.").font(.caption).foregroundStyle(.secondary)
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
