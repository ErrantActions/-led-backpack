import SwiftUI
import BackpackProtocol

@MainActor
final class NearbyDiscoveryCoordinator: ObservableObject {
    let radio = NearbyPeerRadio()
    @Published private(set) var status = "Discovery off — explicit activation required"
    @Published private(set) var contacts: [SocialPerson] = []
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    @Published private(set) var armed = false
    private var client: CommunityFeatureClient?
    private var state: NativeNearbyState?
    private var clock: CatalogEventClock?
    private var controlsRevision: Int?
    private var observations = NearbyObservedTokens()
    private var epoch = UUID()
    private var task: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var activationUncertain = false
    init() {
        radio.observedToken = { [weak self] value in
            guard let self, self.armed, self.state?.lookForFriends == true else { return }
            do { try self.observations.record(value, now: ProcessInfo.processInfo.systemUptime) }
            catch { self.failure = error.localizedDescription }
        }
        radio.interrupted = { [weak self] in self?.stop("Radio unavailable/expired — no automatic restart") }
    }
    func prepare(_ community: CommunityController) {
        guard !busy, !armed else { return }
        failure = nil
        do {
            let client = try CommunityFeatureClient(community)
            try client.checkNearby()
            try radio.prepare()
            status = "OS preparation only. Explicit Start is still required; no scan/advertisement was armed."
        } catch { failure = error.localizedDescription }
    }
    func activate(_ community: CommunityController, look: Bool, discoverable: Bool, consent: Bool, foreground: Bool) {
        guard consent, foreground, look || discoverable, radio.ready, !busy, !armed else {
            failure = "Explicit foreground consent, an independent control choice and ready Bluetooth are required."; return
        }
        let stamp = UUID(); epoch = stamp; busy = true; failure = nil
        work = Task {
            do {
                let client = try CommunityFeatureClient(community)
                try client.checkNearby()
                let profile = try await client.preferences()
                let controls: Int
                if let current = profile.locationControlsRevision, current >= 0 { controls = current }
                else {
                    guard !client.nearbyRevisionRequired, profile.socialLocationGlobalStopEnabled != true else {
                        throw BackpackError.invalid("Current service stop revision is unavailable. No advertised revision capability may silently default to zero.")
                    }
                    controls = 0 // Only the pre-stop legacy protocol has implicit zero.
                }
                let prior = try await client.ownNearby()
                try Task.checkCancellation()
                guard stamp == epoch else { return }
                self.client = client; activationUncertain = true
                // Explicit Start may take over another own login's presence; never inferred at launch.
                if client.nearbyRevisionRequired, prior.locationControlsRevision != controls { throw BackpackError.invalid("Discovery controls changed while arming; reload explicitly.") }
                let next = try await client.armNearby(expected: prior.presenceId, look: look, discoverable: discoverable,
                    expectedControlsRevision: client.nearbyRevisionRequired ? controls : nil)
                try client.checkNearby()
                guard stamp == epoch, !Task.isCancelled else {
                    if let id = next.presenceId { try await client.withdrawNearby(id) }
                    return
                }
                self.client = client; state = next; controlsRevision = controls
                activationUncertain = false
                clock = try CatalogEventClock(serverTime: next.serverTimeISO)
                observations.clear(); contacts = []
                try startRadio(next)
                armed = true; busy = false; status = "Foreground discovery armed. Signals are unauthenticated hints, not distance or proximity proof."
                poll(stamp)
            } catch {
                if stamp == epoch {
                    failure = error.localizedDescription; busy = false
                    stop("Activation unconfirmed — reload/stop explicitly; no automatic retry", preserveFailure: true)
                }
            }
        }
    }
    func stop(_ reason: String = "Discovery stopped", preserveFailure: Bool = false) {
        // Local radio/token/card clearing always precedes any service withdrawal.
        radio.stop()
        let previous = client, presence = state?.presenceId
        let uncertain = activationUncertain
        let wasWorking = armed || busy || state != nil
        epoch = UUID(); task?.cancel(); work?.cancel(); task = nil; work = nil
        let stopEpoch = epoch
        armed = false; busy = false; state = nil; clock = nil; client = nil; controlsRevision = nil
        observations.clear(); contacts = []; status = reason
        activationUncertain = false
        if !preserveFailure && wasWorking { failure = nil }
        if uncertain { failure = "Radio stopped. Activation acknowledgment was lost/cancelled; service presence is unconfirmed. Use explicit reconcile/withdraw; no retry or renewal." }
        if let previous, let presence {
            Task {
                do { try await previous.withdrawNearby(presence) }
                catch {
                    if self.epoch == stopEpoch {
                        self.failure = "Radio stopped locally, but remote presence withdrawal is unconfirmed: \(error.localizedDescription). No restart was attempted."
                    }
                }
            }
        }
    }
    func reconcileAndWithdraw(_ community: CommunityController) {
        let captured = state?.presenceId != nil
        stop("Local radio stopped before explicit service reconciliation")
        if captured { return }
        busy = true; let stamp = epoch
        work = Task {
            do {
                let scoped = try CommunityFeatureClient(community)
                let current = try await scoped.ownNearby()
                guard stamp == epoch, !Task.isCancelled else { return }
                guard current.presenceId == nil || current.ownedByCurrentSession else {
                    throw BackpackError.invalid("Another login owns this presence. Explicit Start is needed for takeover; no other-login withdrawal was inferred.")
                }
                if let id = current.presenceId { try await scoped.withdrawNearby(id) }
                guard stamp == epoch, !Task.isCancelled else { return }
                failure = nil; busy = false; status = "Current-login service presence withdrawn; local radio remains off."
            } catch { if stamp == epoch { busy = false; failure = error.localizedDescription } }
        }
    }
    private func startRadio(_ value: NativeNearbyState) throws {
        guard let clock, let raw = value.discoverable ? value.tokenExpiresAtISO : value.expiresAtISO else {
            throw BackpackError.invalid("Discovery deadline unavailable.")
        }
        let remaining = try CatalogEventTime.parse(raw).timeIntervalSince(clock.now())
        try radio.start(look: value.lookForFriends, discoverable: value.discoverable,
            token: value.advertisementToken, remaining: min(120, remaining))
    }
    private func poll(_ stamp: UUID) {
        task = Task {
            var ticks = 0
            while !Task.isCancelled && stamp == epoch && armed {
                do {
                    try await Task.sleep(for: .seconds(5))
                    guard let client, let current = state, let id = current.presenceId, let clock,
                          let end = current.expiresAtISO else { throw BackpackError.invalid("Discovery scope lost.") }
                    try client.checkNearby()
                    guard try CatalogEventTime.parse(end) > clock.now(), radio.active else {
                        stop("Presence/radio expired — explicit activation required"); return
                    }
                    if ticks % 2 == 0 {
                        let profile = try await client.preferences(), server = try await client.ownNearby()
                        guard stamp == epoch else { return }
                        let revision = client.nearbyRevisionRequired ? profile.locationControlsRevision : (profile.locationControlsRevision ?? 0)
                        guard revision == controlsRevision, server.presenceId == id,
                              server.ownedByCurrentSession, server.lookForFriends == current.lookForFriends,
                              server.discoverable == current.discoverable else {
                            stop("Control revision, login, block or presence changed — no restart"); return
                        }
                    }
                    if current.discoverable, let raw = current.tokenExpiresAtISO,
                       try CatalogEventTime.parse(raw).timeIntervalSince(clock.now()) <= 35 {
                        radio.stop(); contacts = []; observations.clear()
                        activationUncertain = true
                        let next = try await client.rotateNearby(id)
                        guard stamp == epoch, !Task.isCancelled else { if let id = next.presenceId { try await client.withdrawNearby(id) }; return }
                        guard next.expiresAtISO == current.expiresAtISO else { throw BackpackError.invalid("Rotation must not extend discovery consent.") }
                        state = next; self.clock = try CatalogEventClock(serverTime: next.serverTimeISO)
                        activationUncertain = false
                        try startRadio(next)
                    }
                    let tokens = observations.fresh(now: ProcessInfo.processInfo.systemUptime)
                    contacts = []
                    if state?.lookForFriends == true, !tokens.isEmpty, let currentID = state?.presenceId {
                        let result = try await client.resolveNearby(currentID, tokens: tokens)
                        guard stamp == epoch, !Task.isCancelled else { return }
                        contacts = result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                    }
                    ticks += 1
                } catch {
                    if stamp == epoch && !Task.isCancelled {
                        failure = error.localizedDescription; stop("Discovery access/transport failed — no automatic restart", preserveFailure: true)
                    }
                    return
                }
            }
        }
    }
    func requestFriend(_ person: SocialPerson) {
        guard armed, let client, contacts.contains(where: { $0.id == person.id }), !busy else { failure = "Resolve a current observed card before requesting friendship."; return }
        let stamp = epoch; busy = true
        work = Task {
            do {
                guard let id = state?.presenceId else { throw BackpackError.invalid("Discovery stopped.") }
                let tokens = observations.fresh(now: ProcessInfo.processInfo.systemUptime)
                guard !tokens.isEmpty else { throw BackpackError.invalid("Observed tokens are stale; no profile grant retained.") }
                let current = try await client.resolveNearby(id, tokens: tokens)
                guard stamp == epoch, !Task.isCancelled, current.contains(where: { $0.id == person.id }) else { throw BackpackError.invalid("Contact is no longer authorized by a current observed token.") }
                try await client.requestFriend(person.id)
                guard stamp == epoch, !Task.isCancelled else { return }
                status = "Explicit friend request sent. Recipient acceptance is separate; no location/game/library permission granted."
                busy = false
            } catch { if stamp == epoch { busy = false; failure = error.localizedDescription; contacts = [] } }
        }
    }
}

@MainActor
struct NearbyDiscoveryView: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var discovery: NearbyDiscoveryCoordinator
    @Environment(\.scenePhase) private var phase
    @State private var look = false
    @State private var discoverable = false
    @State private var consent = false
    @State private var requesting: SocialPerson?
    @State private var cardClient: CommunityFeatureClient?
    var body: some View {
        Form {
            Text("Add friends — foreground hints only").font(.headline)
            Text("Independent controls default off. BLE hints can be relayed/copied; they do not prove identity, distance or physical proximity. No location/RSSI, device identifiers, names or encounter history are advertised or uploaded.").font(.caption)
            if community.config?.nearbyDiscoveryEnabled == true {
                Toggle("Look for friends", isOn: $look)
                Toggle("Let nearby people find me", isOn: $discoverable)
                Toggle("I consent to one foreground 5-minute discovery session", isOn: $consent)
                Text("Start explicitly takes over any existing discovery session on this account. Token rotation is limited to this foreground consent window and never extends it.").font(.caption)
                Button("Prepare Bluetooth permission / OS state") { discovery.prepare(community) }
                Button("Start my selected discovery controls") { discovery.activate(community, look: look, discoverable: discoverable, consent: consent, foreground: phase == .active) }
                    .disabled(discovery.armed || discovery.busy || !consent || (!look && !discoverable))
            } else { Text("Nearby discovery is unavailable on this service. Use the existing manual invitation flow.") }
            Text(discovery.status).font(.caption)
            NearbyRadioStatus(radio: discovery.radio)
            if let error = discovery.failure { Text(error).foregroundStyle(.orange) }
            if discovery.busy { ProgressView() }
            Button("Stop scanning / advertising and withdraw presence", role: .destructive) {
                discovery.stop(); consent = false; requesting = nil
            }
            Button("Explicitly reconcile / withdraw current-login presence") {
                consent = false; requesting = nil; discovery.reconcileAndWithdraw(community)
            }.disabled(discovery.busy)
            ForEach(discovery.contacts) { contact in
                HStack {
                    if let cardClient { CommunityProfileAvatar(person: contact, client: cardClient).frame(width: 44, height: 44) }
                    Text(contact.displayName)
                    Button("Request friendship") { requesting = contact }.disabled(discovery.busy)
                }
            }
            Text("Cards are minimal, currently authorized results of actually read tokens, alphabetically ordered—not a public directory or a distance list. Mature/avatar viewing rules still apply.").font(.caption)
            NavigationLink("Manual invite / existing friend-request controls") { CommunitySocialView() }
            NavigationLink("My friend QR / Scan / Manual invite") { FriendInviteQRView() }
            Text("Manual invitation fallback remains available. No automatic friendship, per-friend permission, ranging, game, synchronized playback or GIF swap is enabled.").font(.caption)
        }.modernScene().navigationTitle("Look for friends")
        .task(id: community.accountRevision) {
            do { cardClient = try CommunityFeatureClient(community) }
            catch { cardClient = nil; discovery.stop("Account unavailable; cards cleared") }
        }

        .onChange(of: look) { _, _ in discovery.stop("Control choice changed"); consent = false }
        .onChange(of: discoverable) { _, _ in discovery.stop("Control choice changed"); consent = false }
        .onChange(of: consent) { _, value in if !value { discovery.stop("Consent withdrawn") } }
        .onChange(of: phase) { _, value in if value != .active { discovery.stop("Background — no restart"); consent = false; requesting = nil } }
        .onChange(of: community.accountRevision) { _, _ in discovery.stop("Account changed"); consent = false; requesting = nil; cardClient = nil }
        .onDisappear { discovery.stop("Discovery page closed"); consent = false; requesting = nil; cardClient = nil }
        .confirmationDialog("Send an explicit friend request?", isPresented: Binding(get: { requesting != nil }, set: { if !$0 { requesting = nil } })) {
            if let person = requesting { Button("Request \(person.displayName)") { discovery.requestFriend(person); requesting = nil } }
        } message: { Text("Current observed token authorization is rechecked. This does not accept a friendship or grant location, game, swaps or library access.") }
    }
}

@MainActor
private struct NearbyRadioStatus: View {
    @ObservedObject var radio: NearbyPeerRadio
    var body: some View {
        VStack(alignment: .leading) {
            Text(radio.status).font(.caption)
            Text(radio.active ? "Local radio work armed (foreground only)" : "Local scanning / advertising OFF").font(.caption2)
        }
    }
}
