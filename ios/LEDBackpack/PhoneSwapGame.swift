import SwiftUI
import CryptoKit
import BackpackProtocol

@MainActor
final class PhoneSwapGame: ObservableObject {
    let radio: PhoneSwapRadio
    private let friendAuthority: AcceptedFriendAuthority?
    private let ownerLease = UUID()
    var isAcceptedFriendInteraction: Bool { friendAuthority != nil }
    var ownedPhoneAttribution: Attribution? {
        guard phone?.artworkRevision == ownedRevision, community?.accountRevision == accountEpoch else { return nil }
        return currentCredit
    }
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Phone swap game off"
    @Published private(set) var failure: String?
    @Published private(set) var met: [LocalMetFriend] = []
    @Published private(set) var received: [ReceivedSwapArtwork] = []
    @Published private(set) var reportablePeer: LocalMetFriend?
    private weak var phone: PhoneDisplayController?
    private weak var targets: DisplayTargetSelection?
    private weak var community: CommunityController?
    private var client: CommunityFeatureClient?
    private var storage: PhoneSwapLocalStore?
    private var key: Curve25519.KeyAgreement.PrivateKey?
    private var presence: PhoneSwapPresence?
    private var clock: CatalogEventClock?
    private var original: LocalSwapOriginal?
    private var ownedRevision: UUID?
    private var currentCredit: Attribution?
    private var scope = ""
    private var epoch = UUID()
    private var accountEpoch = UUID()
    private var observed: [String: (card: PhoneSwapContact, seen: Date, firstUptime: Double, lastUptime: Double, count: Int)] = [:]
    private var throttle = PhoneSwapThrottle()
    private var retiredSessions: Set<UUID> = []
    private var gamePlaybackPolicy: UUID?
    private var polling: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var receiveTail: Task<Void, Never>?
    private var queuedFrames = 0
    private var exchange: Exchange?
    private var armingUncertain = false
    private final class Exchange {
        let link: UUID
        let id: UUID
        let peer: PhoneSwapContact
        let isInitiator: Bool
        let first: PhoneSwapWire.Hello
        var second: PhoneSwapWire.Hello?
        var cipher: PhoneSwapCipher?
        var sendTail: Task<Void, Never>?
        var transfer: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        var proved = false
        var offerSent = false
        var offerCompleted = false
        var incoming: PhoneSwapIncoming?
        var validated: Data?
        var preparedFriendScene: Data?
        var ownReadySent = false
        var ownReadyAcknowledged = false
        var peerReady = false
        var applying = false
        var applied = false
        var appliedSent = false
        var peerApplied = false
        var peerAppliedHash: String?
        var confirming = false
        var friendAgreed = false
        var clockPing: Double?
        var clockPong: [Double]?
        var estimate: FriendClockEstimate?
        var schedule: Double?
        var schedulePeer: Double?
        var scheduleAcknowledged = false
        var scheduling = false
        let outgoing: Data
        let credit: PhoneSwapWire.Credit
        let outgoingHash: String
        init(link: UUID, peer: PhoneSwapContact, initiator: Bool, first: PhoneSwapWire.Hello,
            outgoing: Data, credit: PhoneSwapWire.Credit) {
            self.link = link; id = first.sessionID; self.peer = peer; isInitiator = initiator; self.first = first
            self.outgoing = outgoing; self.credit = credit; outgoingHash = LocalSwapOriginal.digest(outgoing)
        }
    }
    init(friendAuthority: AcceptedFriendAuthority? = nil) {
        self.friendAuthority = friendAuthority
        radio = PhoneSwapRadio(purpose: friendAuthority == nil ? .game : .acceptedFriend)
        radio.observed = { [weak self] link, token in self?.saw(link: link, token: token) }
        radio.received = { [weak self] link, outer in
            guard let self, self.enabled else { return }
            guard self.queuedFrames < 32 else { self.fail(BackpackError.invalid("Game application receive backpressure exceeded; original retained.")); return }
            self.queuedFrames += 1
            let previous = self.receiveTail, stamp = self.epoch
            self.receiveTail = Task {
                await previous?.value
                guard stamp == self.epoch else { return }
                defer { if stamp == self.epoch { self.queuedFrames = max(0, self.queuedFrames - 1) } }
                do { try await self.receive(outer, link: link) }
                catch { if stamp == self.epoch { self.fail(error) } }
            }
        }
        radio.lost = { [weak self] link in
            if self?.exchange?.link == link && self?.enabled == true { self?.fail(BackpackError.invalid("Peer disconnected. Application outcome may be uncertain; original retained.")) }
        }
        radio.failed = { [weak self] reason in self?.fail(BackpackError.invalid(reason)) }
    }
    func bind(phone: PhoneDisplayController, targets: DisplayTargetSelection, community: CommunityController) {
        self.phone = phone; self.targets = targets; self.community = community
    }
    private func localStore() throws -> PhoneSwapLocalStore {
        if let storage { return storage }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw BackpackError.invalid("Local recovery storage is unavailable.") }
        guard let recovery = SwapRecoveryRepository.shared else { throw BackpackError.invalid("Shared durable original repository unavailable; game cannot arm.") }
        let value = PhoneSwapLocalStore(root: base, recovery: recovery); storage = value; return value
    }
    func prepareRadio() {
        do {
            guard let community, community.signedIn else {
                throw BackpackError.invalid("Sign in before preparing authenticated peer-game Bluetooth. Friendship is not required for the GIF game.")
            }
            guard capability(community) else { throw BackpackError.invalid("Current purpose-specific peer service unavailable; game/discovery cannot substitute for accepted-friend identity.") }
            try radio.prepare()
        } catch { failure = error.localizedDescription }
    }
    @discardableResult
    func enable(consent: Bool, attribution: Attribution?) -> Bool {
        guard !enabled, !busy, consent, radio.ready, let phone, let targets, let community,
              UIApplication.shared.applicationState == .active,
              targets.target == .phone, let bytes = phone.data, !phone.loading else { failure = "Choose a phone original, explicitly consent and prepare ready foreground peer Bluetooth."; return false }
        if let friendAuthority, friendAuthority.initialRevision != phone.artworkRevision || friendAuthority.ownerAccount != community.user?.id {
            failure = "The phone original/account changed. Prepare a new intent rather than overwrite a newer selection."; return false
        }
        let playing: PhoneGamePlayingSource?
        do {
            if friendAuthority == nil && !phone.viewerAutomaticPlaybackAllowed {
                throw BackpackError.invalid("Saved viewer settings disable automatic phone playback. Enable it explicitly before arming the GIF game.")
            }
            playing = friendAuthority == nil ? try phone.capturePlayingGameGIF() : nil
            try targets.acquirePhone(ownerLease)
        } catch { failure = error.localizedDescription; return false }
        let outgoingAttribution = ownedPhoneAttribution ?? attribution
        let stamp = UUID(); epoch = stamp; accountEpoch = community.accountRevision
        let initial = phone.snapshot(), revision = phone.artworkRevision
        ownedRevision = revision; scope = SwapRecoveryStore.ownerScope(community)
        gamePlaybackPolicy = playing?.playbackPolicyRevision
        failure = nil; busy = true
        operation = Task {
            do {
                let localOnly = friendAuthority != nil && !(friendAuthority?.selected.kind == .pass && friendAuthority?.mainSender == true)
                let chosen = friendAuthority?.chosenArtwork ?? bytes
                let friendMode = friendAuthority != nil
                let worker = Task.detached {
                    if friendMode { _ = try GIFPreviewDecoder.phoneDisplay(bytes) }
                    if localOnly { _ = try GIFPreviewDecoder.phoneDisplay(chosen); return chosen }
                    return try PrivateOutgoingGIF.inspectAlreadySanitized(PrivateOutgoingGIF.make(chosen))
                }
                _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try playing?.requireCurrent(phone)
                if friendAuthority == nil { _ = try PhoneSwapWire.Credit(outgoingAttribution) }
                let client = try CommunityFeatureClient(community)
                let state: PhoneSwapPresence
                if let friendAuthority { state = try await friendAuthority.current(client) }
                else { state = try await client.gamePresence() }
                try checkContext(stamp, requireCanvas: false)
                let generated = try friendAuthority?.key() ?? Curve25519.KeyAgreement.PrivateKey()
                let publicKey = PhoneSwapWire.b64(generated.publicKey.rawRepresentation)
                let purpose = friendAuthority.map { "friend-v1:" + $0.selected.id.uuidString.lowercased() } ?? "game-v1"
                let recovery = try await localStore().original(snapshot: initial, artworkRevision: revision, scope: scope, attribution: outgoingAttribution, purpose: purpose)
                try checkContext(stamp, requireCanvas: false)
                original = recovery
                armingUncertain = true; self.client = client
                let armed: PhoneSwapPresence
                if let friendAuthority { armed = try await friendAuthority.prepare(client, publicKey: publicKey) }
                else { armed = try await client.enableGame(expected: state.presenceId, controls: state.locationControlsRevision, key: publicKey) }
                do { try checkContext(stamp, requireCanvas: false) }
                catch {
                    if let friendAuthority { try await client.stopFriendSession(friendAuthority.selected) }
                    else if let id = armed.presenceId { try await client.stopGame(id) }
                    throw error
                }
                armingUncertain = false
                key = generated; presence = armed; clock = try CatalogEventClock(serverTime: armed.serverTimeISO)
                guard let clock else { throw BackpackError.invalid("Current game service clock is unavailable.") }
                try throttle.resume(journal: recovery, now: clock.now(), uptime: ProcessInfo.processInfo.systemUptime)
                currentCredit = outgoingAttribution; enabled = true; busy = false
                phone.open()
                for _ in 0..<60 {
                    try checkContext(stamp, requireCanvas: false)
                    if phone.canApplyAutomaticPhoneArtwork { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try checkContext(stamp)
                try startRadio()
                status = friendAuthority == nil ? "Game enabled: automatic phone GIF sharing/display within this foreground window. No proximity proof." :
                    "Accepted-friend media intent armed. Waiting for the intended authenticated hint and matching preset/role; no proximity/timing proof."
                poll(stamp)
            } catch { if stamp == epoch { fail(error) } }
        }
        return true
    }
    private func checkContext(_ stamp: UUID, requireCanvas: Bool = true) throws {
        try Task.checkCancellation()
        guard stamp == epoch, let phone, let targets, let community, community.accountRevision == accountEpoch,
              capability(community), targets.target == .phone, targets.phonePeerOwner == ownerLease,
              UIApplication.shared.applicationState == .active,
              phone.artworkRevision == ownedRevision, (!requireCanvas || phone.canApplyAutomaticPhoneArtwork) else {
            throw BackpackError.invalid("Game account/target/foreground/manual selection changed; no automatic replay.")
        }
        try client?.check(.social)
        if let friendAuthority {
            guard phone.playbackPolicyRevision == friendAuthority.phonePolicy else { throw BackpackError.invalid("Phone play/motion/data-saving policy changed; friend interaction needs fresh explicit arming.") }
        } else {
            guard phone.playbackPolicyRevision == gamePlaybackPolicy,
                  exchange?.applied == true || (phone.isPlaying && !phone.position().finished) else {
                throw BackpackError.invalid("Play/pause/motion policy changed or the outgoing GIF stopped playing; game stopped without sharing stale artwork.")
            }
        }
        if enabled, let presence, let clock {
            guard let end = presence.expiresAtISO, let tokenEnd = presence.tokenExpiresAtISO,
                  try CatalogEventTime.parse(end) > clock.now(), try CatalogEventTime.parse(tokenEnd) > clock.now() else {
                throw BackpackError.invalid("Game consent/token deadline elapsed before application.")
            }
            if let peer = exchange?.peer, try CatalogEventTime.parse(peer.tokenExpiresAtISO) <= clock.now() {
                throw BackpackError.invalid("Peer token expired during validation/scheduling; no phone replacement.")
            }
        }
    }
    private func capability(_ community: CommunityController) -> Bool {
        friendAuthority == nil ? community.config?.gifSwapPresenceEnabled == true :
            community.config?.friendSessionPeerIdentityEnabled == true && community.config?.friendSessionsAvailable == true
    }
    private func startRadio() throws {
        guard let presence, let token = presence.advertisementToken, let end = presence.tokenExpiresAtISO, let clock else { throw BackpackError.invalid("Game token/deadline is unavailable.") }
        try radio.start(token: token, seconds: CatalogEventTime.parse(end).timeIntervalSince(clock.now()))
    }
    private func selfCard() throws -> PhoneSwapContact {
        guard let client, let presence, let token = presence.advertisementToken, let key = presence.publicKey,
              let end = presence.tokenExpiresAtISO else { throw BackpackError.invalid("Local game card unavailable.") }
        return PhoneSwapContact(id: client.accountID, displayName: "", canRequestFriendship: false, publicKey: key, token: token, tokenExpiresAtISO: end)
    }
    private func fresh(_ peer: PhoneSwapContact) async throws {
        guard let client, let presence, let id = presence.presenceId, let clock else { throw BackpackError.invalid("Game presence disappeared.") }
        let own: PhoneSwapPresence
        if let friendAuthority { own = try await friendAuthority.current(client) }
        else { own = try await client.gamePresence() }
        guard own.enabled, own.ownedByCurrentSession, own.presenceId == id, own.publicKey == presence.publicKey,
              own.locationControlsRevision == presence.locationControlsRevision else { throw BackpackError.invalid("Game permission/login/Stop all binding changed.") }
        guard let end = own.expiresAtISO, try CatalogEventTime.parse(end) > clock.now(),
              let seen = observed[peer.token] else {
            throw BackpackError.invalid("Game hint was not actually observed or has expired.")
        }
        let age = friendAuthority == nil ? Date().timeIntervalSince(seen.seen) : ProcessInfo.processInfo.systemUptime - seen.lastUptime
        guard age >= 0, age < 120 else { throw BackpackError.invalid("Observed peer hint is no longer fresh.") }
        let contacts: [PhoneSwapContact]
        if let friendAuthority { contacts = try await friendAuthority.resolve(peer.token, client: client).map { [$0] } ?? [] }
        else { contacts = try await client.resolveGame(id, observed: [peer.token]) }
        guard contacts.contains(peer), try CatalogEventTime.parse(peer.tokenExpiresAtISO) > clock.now() else {
            throw BackpackError.invalid("Current service no longer binds this observed peer token/key/card.")
        }
    }
    private func candidate() async throws -> (Data, PhoneSwapWire.Credit) {
        if let friendAuthority {
            let source = friendAuthority.chosenArtwork, credit = friendAuthority.chosenAttribution
            let transfersMedia = friendAuthority.selected.kind == .pass && friendAuthority.mainSender
            let worker = Task.detached {
                if transfersMedia {
                    return (try PrivateOutgoingGIF.inspectAlreadySanitized(PrivateOutgoingGIF.make(source)), try PhoneSwapWire.Credit(credit))
                }
                return (AcceptedFriendAuthority.controlMarker, try PhoneSwapWire.Credit(nil))
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
        guard let phone else { throw BackpackError.invalid("No current phone player.") }
        let source = try phone.capturePlayingGameGIF(), credit = currentCredit
        let worker = Task.detached { try PrivateOutgoingGIF.inspectAlreadySanitized(PrivateOutgoingGIF.make(source.data)) }
        let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try source.requireCurrent(phone)
        return (value, try PhoneSwapWire.Credit(credit))
    }
    private func saw(link: UUID, token: String) {
        guard enabled, let client, let id = presence?.presenceId, NearbyTokenPolicy.valid(token) else { radio.close(link); return }
        let stamp = epoch
        Task {
            do {
                try checkContext(stamp)
                let cards: [PhoneSwapContact]
                if let friendAuthority { cards = try await friendAuthority.resolve(token, client: client).map { [$0] } ?? [] }
                else { cards = try await client.resolveGame(id, observed: [token]) }
                try checkContext(stamp)
                guard let peer = cards.first(where: { $0.token == token }), observed.count < 32 || observed[token] != nil else { radio.close(link); return }
                let uptime = ProcessInfo.processInfo.systemUptime
                if let previous = observed[token], previous.card == peer {
                    observed[token] = (peer, Date(), previous.firstUptime, uptime, min(100, previous.count + 1))
                } else { observed[token] = (peer, Date(), uptime, uptime, 1) }
                guard stableObservation(token) else { radio.close(link); status = "Intended friend's hint read once; awaiting another stable foreground observation (not proximity proof)."; return }
                let own = try selfCard()
                guard own.publicKey < peer.publicKey, exchange == nil,
                      throttle.permits(peer.id, uptime: ProcessInfo.processInfo.systemUptime),
                      retiredSessions.count < 32 else { radio.close(link); return }
                let (outgoing, credit) = try await candidate()
                try checkContext(stamp)
                guard exchange == nil else { radio.close(link); return }
                let nonce = PhoneSwapWire.randomNonce()
                let hello = PhoneSwapWire.Hello(version: 1, sessionID: UUID(), initiatorToken: own.token,
                    responderToken: peer.token, nonce: nonce, response: false)
                let active = Exchange(link: link, peer: peer, initiator: true, first: hello, outgoing: outgoing, credit: credit)
                exchange = active; startDeadline(active)
                try await radio.send(PhoneSwapWire.Outer(hello: hello, counter: nil, encrypted: nil), to: link)
            } catch { if stamp == epoch { fail(error) } }
        }
    }
    private func stableObservation(_ token: String) -> Bool {
        guard friendAuthority != nil else { return true }
        guard let value = observed[token] else { return false }
        return value.count >= 2 && ProcessInfo.processInfo.systemUptime - value.firstUptime >= 2
    }
    private func startDeadline(_ active: Exchange) {
        active.timeout = Task { [weak self, weak active] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            if let active, self?.exchange === active { self?.fail(BackpackError.invalid("Bounded exchange timeout. No exactly-once/peer-application success is inferred.")) }
        }
    }
    private func send(_ message: PhoneSwapWire.Message, on active: Exchange) async throws {
        let previous = active.sendTail, stamp = epoch
        let job = Task {
            await previous?.value
            try checkContext(stamp)
            guard exchange === active, var cipher = active.cipher else { throw BackpackError.invalid("Game cipher/session changed.") }
            let value = try cipher.seal(message); active.cipher = cipher
            try await radio.send(value, to: active.link)
        }
        active.sendTail = Task { _ = await job.result }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    private func receive(_ outer: PhoneSwapWire.Outer, link: UUID) async throws {
        let stamp = epoch; try checkContext(stamp)
        if let hello = outer.hello { try await handshake(hello, link: link, stamp: stamp); return }
        guard let active = exchange, active.link == link, var cipher = active.cipher else { throw BackpackError.invalid("Unbound encrypted game message.") }
        let message = try cipher.open(outer); active.cipher = cipher
        switch message.kind {
        case "proof":
            guard !active.proved, message.hash == cipher.transcriptHash else { throw BackpackError.invalid("Duplicate/mismatched peer possession proof.") }
            active.proved = true
            reportablePeer = LocalMetFriend(id: active.peer.id, displayName: active.peer.displayName, canRequestFriendship: active.peer.canRequestFriendship)
            if active.isInitiator { try await send(PhoneSwapWire.Message(kind: "proof", hash: cipher.transcriptHash), on: active) }
            if let friendAuthority { try await send(friendAuthority.agreement(), on: active) }
            else { beginOffer(active) }
        case "friend-agreement":
            guard let friendAuthority, active.proved, !active.friendAgreed else { throw BackpackError.invalid("Unexpected/replayed accepted-friend media intent.") }
            try friendAuthority.checkAgreement(message)
            active.friendAgreed = true; beginOffer(active)
        case "friend-clock-ping":
            guard friendAuthority != nil, active.friendAgreed, !active.isInitiator, active.clockPing == nil,
                  active.peerReady, active.ownReadyAcknowledged, let ticks = message.ticks, ticks.count == 1,
                  ticks[0].isFinite, ticks[0] >= 0 else { throw BackpackError.invalid("Unexpected/replayed authenticated clock ping.") }
            active.clockPing = ticks[0]
            let t1 = ProcessInfo.processInfo.systemUptime, t2 = ProcessInfo.processInfo.systemUptime
            active.clockPong = [ticks[0],t1,t2]
            try await send(PhoneSwapWire.Message(kind: "friend-clock-pong", ticks: [ticks[0],t1,t2]), on: active)
        case "friend-clock-pong":
            guard friendAuthority != nil, active.friendAgreed, active.isInitiator, active.schedule == nil,
                  let ping = active.clockPing, let ticks = message.ticks, ticks.count == 3, ticks[0] == ping else { throw BackpackError.invalid("Unexpected/replayed clock response.") }
            let t3 = ProcessInfo.processInfo.systemUptime
            let estimate = try FriendClockEstimate(t0: ping, t1: ticks[1], t2: ticks[2], t3: t3)
            let start = t3 + 4
            active.estimate = estimate; active.schedule = start; active.schedulePeer = start + estimate.offset
            try await send(PhoneSwapWire.Message(kind: "friend-schedule", ticks: [ping,t3,start,start + estimate.offset]), on: active)
        case "friend-schedule":
            guard friendAuthority != nil, active.friendAgreed, !active.isInitiator, active.schedule == nil,
                  let pong = active.clockPong, let ticks = message.ticks, ticks.count == 4, ticks[0] == pong[0] else { throw BackpackError.invalid("Unexpected/replayed friend schedule.") }
            let estimate = try FriendClockEstimate(t0: ticks[0], t1: pong[1], t2: pong[2], t3: ticks[1])
            let remaining = ticks[3] - ProcessInfo.processInfo.systemUptime
            guard ticks.allSatisfy(\.isFinite), abs(ticks[3] - ticks[2] - estimate.offset) < 0.001,
                  (1...5).contains(remaining), ticks[2] >= ticks[1] + 3 else { throw BackpackError.invalid("Shared start/clock translation is stale or inconsistent.") }
            active.estimate = estimate; active.schedule = ticks[3]; active.schedulePeer = ticks[2]
            try await send(PhoneSwapWire.Message(kind: "friend-schedule-ack", ticks: [ticks[2],ticks[3]]), on: active)
            active.scheduleAcknowledged = true
            try await applyIfReady(active, stamp: stamp)
        case "friend-schedule-ack":
            guard friendAuthority != nil, active.isInitiator, !active.scheduleAcknowledged,
                  let own = active.schedule, let peer = active.schedulePeer, message.ticks == [own,peer] else { throw BackpackError.invalid("Friend schedule acknowledgment mismatch/replay.") }
            active.scheduleAcknowledged = true
            try await applyIfReady(active, stamp: stamp)
        case "offer":
            guard active.proved, active.incoming == nil, friendAuthority == nil || active.friendAgreed else { throw BackpackError.invalid("Duplicate/unproved/unconsented GIF offer.") }
            active.incoming = try PhoneSwapIncoming(message)
        case "chunk":
            guard active.proved, active.validated == nil, active.incoming != nil else { throw BackpackError.invalid("Unexpected GIF chunk.") }
            try active.incoming?.append(message)
        case "end":
            guard active.validated == nil, let incoming = active.incoming, message.hash == incoming.hash else { throw BackpackError.invalid("Unexpected/incomplete GIF end.") }
            let worker = Task.detached { try incoming.complete() }
            let bytes = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try friendAuthority?.validatePayloadIntent(bytes)
            if let friendAuthority {
                let kind = friendAuthority.selected.kind, preset = friendAuthority.preset
                let sender = friendAuthority.mainSender, chosen = friendAuthority.chosenArtwork
                let renderer = Task.detached {
                    let scene = try FriendInteractionPixels.render(kind: kind, preset: preset, sender: sender, chosen: chosen, received: bytes)
                    _ = try GIFPreviewDecoder.phoneDisplay(scene)
                    return scene
                }
                let scene = try await withTaskCancellationHandler { try await renderer.value } onCancel: { renderer.cancel() }
                try checkContext(stamp)
                guard exchange === active else { throw CancellationError() }
                active.preparedFriendScene = scene
            }
            try await fresh(active.peer); try checkContext(stamp)
            guard exchange === active else { throw CancellationError() }
            active.validated = bytes; active.ownReadySent = true
            try await send(PhoneSwapWire.Message(kind: "ready", hash: incoming.hash,
                sceneReady: friendAuthority == nil ? nil : active.preparedFriendScene != nil), on: active)
        case "ready":
            guard active.proved, active.offerCompleted, !active.peerReady, message.hash == active.outgoingHash,
                  friendAuthority == nil || message.sceneReady == true else {
                throw BackpackError.invalid("Peer ready did not acknowledge the complete outgoing GIF.")
            }
            active.peerReady = true
            try await send(PhoneSwapWire.Message(kind: "ready-ack", hash: active.outgoingHash), on: active)
            try await applyIfReady(active, stamp: stamp)
        case "ready-ack":
            guard active.ownReadySent, !active.ownReadyAcknowledged, message.hash == active.incoming?.hash else { throw BackpackError.invalid("Local payload-ready acknowledgment mismatch.") }
            active.ownReadyAcknowledged = true
            try await applyIfReady(active, stamp: stamp)
        case "applied":
            guard active.peerReady, message.hash == active.outgoingHash else { throw BackpackError.invalid("Unexpected peer applied receipt.") }
            if active.peerApplied { return }
            active.peerApplied = true; active.peerAppliedHash = message.hash
            try await finishIfConfirmed(active, stamp: stamp)
        default: throw BackpackError.invalid("Unknown game application message; stop and retain recovery.")
        }
    }
    private func handshake(_ hello: PhoneSwapWire.Hello, link: UUID, stamp: UUID) async throws {
        guard hello.version == 1, NearbyTokenPolicy.valid(hello.nonce), !retiredSessions.contains(hello.sessionID),
              let key, let client else { throw BackpackError.invalid("Unsupported/replayed game hello.") }
        let own = try selfCard()
        if hello.response {
            guard let active = exchange, active.link == link, active.isInitiator, active.second == nil,
                  hello.sessionID == active.id else { throw BackpackError.invalid("Unsolicited game response.") }
            try await fresh(active.peer); try checkContext(stamp)
            active.second = hello
            active.cipher = try PhoneSwapCipher(privateKey: key, initiator: own, responder: active.peer,
                first: active.first, second: hello, origin: client.origin.url.absoluteString, isInitiator: true,
                domain: friendAuthority == nil ? "nyan.phone-swap.v1" : "nyan.accepted-friend.v1",
                binding: try friendAuthority?.binding() ?? [])
        } else {
            guard exchange == nil, hello.responderToken == own.token else { radio.close(link); return }
            // Both sides must independently have read the other GAME token. A hello is not an observation.
            if observed[hello.initiatorToken] == nil { try await Task.sleep(for: .seconds(2)); try checkContext(stamp) }
            guard stableObservation(hello.initiatorToken), let peer = observed[hello.initiatorToken]?.card, peer.publicKey < own.publicKey,
                  throttle.permits(peer.id, uptime: ProcessInfo.processInfo.systemUptime),
                  retiredSessions.count < 32, exchange == nil else { radio.close(link); return }
            try await fresh(peer); try checkContext(stamp)
            let (outgoing, credit) = try await candidate(); try checkContext(stamp)
            let second = PhoneSwapWire.Hello(version: 1, sessionID: hello.sessionID, initiatorToken: peer.token,
                responderToken: own.token, nonce: PhoneSwapWire.randomNonce(), response: true)
            let active = Exchange(link: link, peer: peer, initiator: false, first: hello, outgoing: outgoing, credit: credit)
            active.second = second
            active.cipher = try PhoneSwapCipher(privateKey: key, initiator: peer, responder: own,
                first: hello, second: second, origin: client.origin.url.absoluteString, isInitiator: false,
                domain: friendAuthority == nil ? "nyan.phone-swap.v1" : "nyan.accepted-friend.v1",
                binding: try friendAuthority?.binding() ?? [])
            exchange = active; startDeadline(active)
            try await radio.send(PhoneSwapWire.Outer(hello: second, counter: nil, encrypted: nil), to: link)
            if let hash = active.cipher?.transcriptHash { try await send(PhoneSwapWire.Message(kind: "proof", hash: hash), on: active) }
        }
    }
    private func beginOffer(_ active: Exchange) {
        guard !active.offerSent else { return }; active.offerSent = true
        let stamp = epoch
        active.transfer = Task {
            do {
                try await send(PhoneSwapWire.Message(kind: "offer", hash: active.outgoingHash, length: active.outgoing.count, credit: active.credit), on: active)
                for offset in stride(from: 0, to: active.outgoing.count, by: PhoneSwapWire.chunkBytes) {
                    try checkContext(stamp)
                    let bytes = Data(active.outgoing[offset..<min(active.outgoing.count, offset + PhoneSwapWire.chunkBytes)])
                    try await send(PhoneSwapWire.Message(kind: "chunk", index: offset, bytes: bytes), on: active)
                }
                active.offerCompleted = true
                try await send(PhoneSwapWire.Message(kind: "end", hash: active.outgoingHash), on: active)
            } catch { if stamp == epoch { fail(error) } }
        }
    }
    private func applyIfReady(_ active: Exchange, stamp: UUID) async throws {
        guard active.ownReadyAcknowledged, active.peerReady, !active.applying, !active.applied,
              let bytes = active.validated, let original, let phone, let expected = ownedRevision else { return }
        if friendAuthority != nil && !active.scheduleAcknowledged {
            if active.isInitiator && !active.scheduling {
                active.scheduling = true
                let now = ProcessInfo.processInfo.systemUptime; active.clockPing = now
                try await send(PhoneSwapWire.Message(kind: "friend-clock-ping", ticks: [now]), on: active)
            }
            return
        }
        active.applying = true
        try await fresh(active.peer); try checkContext(stamp)
        guard exchange === active else { throw CancellationError() }
        let next = UUID()
        if let friendAuthority {
            guard active.friendAgreed, let schedule = active.schedule, let estimate = active.estimate,
                  let serviceClock = clock, let incoming = active.incoming, let scene = active.preparedFriendScene else { throw BackpackError.invalid("Accepted intent/clock/actual rendered scene readiness incomplete.") }
            let kind = friendAuthority.selected.kind
            let sender = friendAuthority.mainSender
            try checkContext(stamp)
            let credit = try incoming.credit.attribution()
            let staged = try await localStore().stageFriendScene(scene: scene,
                receivedGIF: kind == .pass && !sender ? bytes : nil, exchangeID: active.id, credit: credit,
                sessionID: friendAuthority.selected.id, ownConsent: enabled, peerConsent: active.friendAgreed,
                bothReady: active.peerReady && active.ownReadyAcknowledged, scope: scope, expectedRevision: expected,
                nextRevision: next, expiresAt: CatalogEventTime.parse(active.peer.tokenExpiresAtISO), now: serviceClock.now())
            try await fresh(active.peer); try checkContext(stamp)
            self.original = staged
            try await phone.applyValidatedGameGIF(scene, expectedRevision: expected, nextRevision: next,
                startAtUptime: schedule, explicitlyArmedPlayback: true, handoffSender: kind == .pass ? sender : nil,
                validateContext: {
                    try self.checkContext(stamp)
                    guard self.exchange === active, active.friendAgreed, active.scheduleAcknowledged else { throw BackpackError.invalid("Accepted friend scene was cancelled during decode/schedule; original retained.") }
                })
            ownedRevision = next; currentCredit = kind == .pass && !sender ? credit : friendAuthority.chosenAttribution
            active.applied = true
            try throttle.applied(active.peer.id, uptime: ProcessInfo.processInfo.systemUptime)
            retiredSessions.insert(active.id)
            status = "\(kind.rawValue) phone scene started, best-effort clock RTT \(Int(estimate.roundTrip * 1000))ms ±\(Int(estimate.uncertainty * 1000))ms. Relay possible; peer final receipt pending."
            try await send(PhoneSwapWire.Message(kind: "applied", hash: incoming.hash), on: active)
            active.appliedSent = true; try await finishIfConfirmed(active, stamp: stamp); return
        }
        var readiness = SwapPeerReadiness(transactionID: original.transactionID, sessionID: active.id, accountEpoch: accountEpoch,
            expiresAt: try CatalogEventTime.parse(active.peer.tokenExpiresAtISO))
        readiness.gameEnabled = enabled; readiness.ownReady = active.ownReadyAcknowledged
        readiness.peerGameEnabled = true; readiness.peerReady = active.peerReady
        guard let incoming = active.incoming else { throw BackpackError.invalid("Validated incoming transfer disappeared; do not apply.") }
        let credit = try incoming.credit.attribution()
        guard let clock else { throw BackpackError.invalid("Current game service clock disappeared; no replacement.") }
        let staged = try await localStore().receivedAndStage(bytes, exchangeID: active.id, credit: credit, peer: active.peer,
            readiness: readiness, scope: scope, expectedRevision: expected, nextRevision: next, now: clock.now())
        try checkContext(stamp)
        self.original = staged
        try await fresh(active.peer); try checkContext(stamp)
        try await phone.applyValidatedGameGIF(bytes, expectedRevision: expected, nextRevision: next, reauthorize: {
            try await self.fresh(active.peer)
        }, validateContext: {
            try self.checkContext(stamp)
            guard self.exchange === active else { throw BackpackError.invalid("Game exchange was cancelled during decode; initial original retained.") }
        })
        ownedRevision = next; currentCredit = credit; active.applied = true
        try throttle.applied(active.peer.id, uptime: ProcessInfo.processInfo.systemUptime)
        retiredSessions.insert(active.id)
        status = "Phone GIF applied after bilateral validation/ready acknowledgments. Peer final application receipt is still pending; original retained."
        try await send(PhoneSwapWire.Message(kind: "applied", hash: active.incoming?.hash), on: active)
        active.appliedSent = true
        try await finishIfConfirmed(active, stamp: stamp)
    }
    private func finishIfConfirmed(_ active: Exchange, stamp: UUID) async throws {
        guard active.applied, active.appliedSent, active.peerApplied, !active.confirming, exchange === active else { return }
        active.confirming = true
        if friendAuthority == nil {
            guard let bytes = active.validated, let incoming = active.incoming, let peerAppliedHash = active.peerAppliedHash else {
                throw BackpackError.invalid("Both receipts arrived but the matching received GIF is unavailable; no Found success.")
            }
            try await fresh(active.peer); try checkContext(stamp)
            guard exchange === active else { throw CancellationError() }
            let receipt = PhoneSwapApplicationReceipt(exchangeID: active.id, peerID: active.peer.id,
                outgoingHash: active.outgoingHash, incomingHash: incoming.hash, peerAppliedHash: peerAppliedHash,
                proved: active.proved, ownReadyAcknowledged: active.ownReadyAcknowledged, peerReady: active.peerReady,
                ownApplied: active.applied, ownAppliedSent: active.appliedSent)
            _ = try await localStore().confirmReceived(bytes, credit: incoming.credit.attribution(),
                peer: active.peer, receipt: receipt, scope: scope)
            try checkContext(stamp)
            guard exchange === active else { throw CancellationError() }
            try await reloadFound()
            try checkContext(stamp)
        }
        active.timeout?.cancel(); active.transfer?.cancel(); active.sendTail?.cancel()
        exchange = nil; radio.close(active.link)
        status = friendAuthority == nil ? "Swap confirmed: received GIF and verified sender paired in Found Users. Initial original retained; 60-second cooldown and same-peer suppression survive stop/rearm." :
            "Both scene receipts received; best-effort timing only. Initial original retained, no same-encounter retrigger. Leave/restore explicitly; hardware/ranging/offline pairing unsupported."
    }
    private func poll(_ stamp: UUID) {
        polling = Task {
            while enabled && !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10)); try checkContext(stamp)
                    guard let client, let presence, let id = presence.presenceId, let clock,
                          let end = presence.expiresAtISO else { throw BackpackError.invalid("Game binding lost.") }
                    guard try CatalogEventTime.parse(end) > clock.now() else { stop(reason: "Game consent expired; explicit recovery retained"); return }
                    let current: PhoneSwapPresence
                    if let friendAuthority { current = try await friendAuthority.current(client) }
                    else { current = try await client.gamePresence() }
                    try checkContext(stamp)
                    guard current.enabled, current.ownedByCurrentSession, current.presenceId == id,
                          current.publicKey == presence.publicKey, current.locationControlsRevision == presence.locationControlsRevision else {
                        throw BackpackError.invalid("Game stopped/revoked/account controls changed.")
                    }
                    if friendAuthority == nil, let tokenEnd = presence.tokenExpiresAtISO, try CatalogEventTime.parse(tokenEnd).timeIntervalSince(clock.now()) <= 35 {
                        guard exchange == nil else { throw BackpackError.invalid("Game token is expiring during exchange; stop safely rather than change the transcript.") }
                        radio.stop()
                        armingUncertain = true
                        let next = try await client.rotateGame(id); try checkContext(stamp)
                        guard next.expiresAtISO == presence.expiresAtISO, next.publicKey == presence.publicKey,
                              next.locationControlsRevision == presence.locationControlsRevision else { throw BackpackError.invalid("Game rotation changed key, stop revision or consent end.") }
                        self.presence = next; self.clock = try CatalogEventClock(serverTime: next.serverTimeISO)
                        observed = [:]; armingUncertain = false; try startRadio()
                    }
                } catch { if stamp == epoch && !Task.isCancelled { fail(error) }; return }
            }
        }
    }
    func stop(reason: String = "Game stopped; original available in Recovery first", withdrawService: Bool = true) {
        radio.stop() // Before any remote revocation or restoration.
        if friendAuthority != nil, targets?.phonePeerOwner == ownerLease, phone?.artworkRevision == ownedRevision { phone?.stopPeerPlayback() }
        targets?.releasePhone(ownerLease)
        let prior = client, id = presence?.presenceId, uncertain = armingUncertain
        epoch = UUID(); enabled = false; busy = false
        let stopEpoch = epoch
        polling?.cancel(); operation?.cancel(); receiveTail?.cancel()
        exchange?.timeout?.cancel(); exchange?.transfer?.cancel(); exchange?.sendTail?.cancel()
        exchange?.cipher = nil
        exchange = nil; key = nil; presence = nil; client = nil; clock = nil; observed = [:]
        friendAuthority?.eraseKey()
        status = reason; armingUncertain = false; queuedFrames = 0; met = []; received = []; reportablePeer = nil
        if uncertain { failure = friendAuthority == nil ?
            "Radio stopped; game activation/rotation acknowledgment is uncertain. Explicitly reconcile/withdraw service game; no restart or exactly-once claim." :
            "Friend radio/key stopped; identity activation acknowledgment is uncertain. Stop/reload the accepted service session; no replay, renewal or exactly-once claim." }
        if withdrawService, let prior, id != nil || friendAuthority != nil {
            Task {
                do {
                    if let friendAuthority { try await prior.stopFriendSession(friendAuthority.selected) }
                    else if let id { try await prior.stopGame(id) }
                }
                catch { if self.epoch == stopEpoch { self.failure = "Local exchange stopped; remote purpose/session withdrawal unconfirmed: \(error.localizedDescription)." } }
            }
        }
    }
    private func fail(_ error: Error) {
        failure = error.localizedDescription
        if friendAuthority == nil, targets?.phonePeerOwner == ownerLease, phone?.artworkRevision == ownedRevision { phone?.pause() }
        stop(reason: original == nil ? "Stopped before durable preparation; display unchanged, no replacement authorized." :
            "Exchange failed/stopped. Initial original and any validated received copies retained; use explicit Restore. Peer outcome may be uncertain.")
    }
    func restoreOriginal() async {
        stop()
        guard let phone, let targets, let community, let original, targets.target == .phone,
              phone.artworkRevision == ownedRevision, SwapRecoveryStore.ownerScope(community) == original.ownerScope else {
            failure = "A newer manual selection/target/account must not be overwritten. Use the separately confirmed Recovery first action."; return
        }
        do {
            let restoreLease = UUID()
            try targets.acquirePhone(restoreLease)
            defer { targets.releasePhone(restoreLease) }
            let account = community.accountRevision
            let value = try await localStore().originalForRestore(original.transactionID, scope: original.ownerScope)
            guard community.accountRevision == account, phone.artworkRevision == ownedRevision, targets.target == .phone,
                  SwapRecoveryStore.ownerScope(community) == value.ownerScope else { throw BackpackError.invalid("Restore context changed.") }
            try await phone.restore(value.phone)
            guard community.accountRevision == account, targets.target == .phone else { throw BackpackError.invalid("Account/target changed during restore; original remains retained.") }
            guard phone.data == value.phone.data else { throw BackpackError.invalid("Restored bytes were not acknowledged; original retained.") }
            try await localStore().acknowledge(value.transactionID, hash: value.originalSHA256, scope: value.ownerScope)
            guard community.accountRevision == account, targets.target == .phone else { return }
            phone.open(); failure = nil; status = "Initial phone original restored. Durable copy retained; game remains off."
        } catch { failure = error.localizedDescription }
    }
    func reconcileAndStop() async {
        stop()
        guard let community else { return }
        let stamp = epoch, account = community.accountRevision
        do {
            let scoped = try CommunityFeatureClient(community)
            let current = try await scoped.gamePresence()
            guard !current.enabled || current.ownedByCurrentSession else { throw BackpackError.invalid("Another login owns this game; no automatic takeover or withdrawal.") }
            if let id = current.presenceId { try await scoped.stopGame(id) }
            guard stamp == epoch, account == community.accountRevision else { return }
            failure = nil; status = "Current-login game service withdrawn; radio off. Original recovery remains available."
        } catch { if stamp == epoch && account == community.accountRevision { failure = error.localizedDescription } }
    }
    func loadMet() async {
        do { try await reloadFound() }
        catch { failure = error.localizedDescription }
    }
    private func reloadFound() async throws {
        guard let community else { return }; let scope = SwapRecoveryStore.ownerScope(community), account = community.accountRevision
        let found = try await localStore().found(scope: scope)
        guard account == community.accountRevision else { throw CancellationError() }
        received = found
        met = found.compactMap(\.sender).reduce(into: [LocalMetFriend]()) { cards, card in
            if !cards.contains(where: { $0.id == card.id }) { cards.append(card) }
        }
    }
    func saveFound(_ item: ReceivedSwapArtwork, to library: PhoneArtworkLibrary) async {
        guard let community else { failure = "Current Found Users account is unavailable."; return }
        let owner = SwapRecoveryStore.ownerScope(community), account = community.accountRevision
        do {
            let values = try await localStore().found(scope: owner)
            guard account == community.accountRevision,
                  let current = values.first(where: { $0.id == item.id }),
                  current.sha256 == item.sha256, current.sender == item.sender else {
                throw BackpackError.invalid("The selected GIF/sender or account changed; no permanent copy was saved.")
            }
            _ = try await library.saveReceivedCopy(current.data, name: current.name, attribution: current.attribution)
            guard account == community.accountRevision else { return }
            status = "Independent local GIF copy saved with attribution; no automatic friendship or publication."
        } catch { failure = error.localizedDescription }
    }
    func removeFound(_ item: ReceivedSwapArtwork) async {
        guard let community else { failure = "Current Found Users account is unavailable."; return }
        let owner = SwapRecoveryStore.ownerScope(community), account = community.accountRevision
        do {
            try await localStore().removeFound(item, scope: owner)
            guard account == community.accountRevision else { return }
            try await reloadFound()
            status = "Received GIF/sender record removed; first original and separately saved copies unchanged."
        } catch { failure = error.localizedDescription }
    }
    func contactAction(_ card: LocalMetFriend, action: String) async {
        guard let community else { return }
        let owner = SwapRecoveryStore.ownerScope(community)
        do {
            guard ["dismiss", "request", "block"].contains(action) else { throw BackpackError.invalid("Unknown contact action.") }
            if action == "dismiss" { try await localStore().dismiss(card.id, scope: owner) }
            else {
                let current = try CommunityFeatureClient(community)
                let found = try await localStore().found(scope: owner)
                try current.check(.social)
                guard found.contains(where: { $0.sender == card }) else {
                    throw BackpackError.invalid("Select a current confirmed Found Users card before requesting friendship or blocking.")
                }
                if action == "block" { stop(reason: "Contact block requested"); try await current.block(card.id); try await localStore().dismiss(card.id, scope: owner) }
                else {
                    guard card.canRequestFriendship else { throw BackpackError.invalid("This game participant did not permit friend requests. Game consent does not change it.") }
                    try await current.requestFriend(card.id)
                    status = "Explicit request processed; normal friendship/recipient authorization remains authoritative."
                }
            }
            await loadMet()
        } catch { failure = error.localizedDescription }
    }
}
