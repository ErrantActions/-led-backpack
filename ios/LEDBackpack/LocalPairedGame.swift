import SwiftUI
import CryptoKit
import BackpackProtocol

@MainActor
final class LocalPairedGame: ObservableObject {
    let radio = PhoneSwapRadio(purpose: .localPair)
    let ranging = LocalNearbyInteraction()
    let session = AutomaticPhoneSession()
    @Published private(set) var code: String?
    @Published private(set) var comparison: String?
    @Published private(set) var status = "Offline paired calm-color game off"
    @Published private(set) var failure: String?
    @Published private(set) var arming = false
    private var key: Curve25519.KeyAgreement.PrivateKey?
    private var own, peer: LocalPairCode?
    private var deadline: ContinuousClock.Instant?
    private var epoch = UUID()
    private var task: Task<Void, Never>?
    private var receiveTail: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?
    private var queued = 0
    private var observed = false
    private var link: UUID?
    private var first: PhoneSwapWire.Hello?
    private var cipher: PhoneSwapCipher?
    private var proved = false
    private var agreed = false
    private var ready = false
    private var peerReady = false
    private var acknowledged = false
    private var applied = false
    private var peerApplied = false
    private var rangeSent: Bool?
    private var peerRange = false
    private var wantsRange = false
    private var localToken: Data?
    private var gotToken = false
    private var scene: Data?
    private var preset = FriendScenePreset.aurora
    private var active = false
    init() {
        radio.observed = { [weak self] link, token in self?.saw(link, token: token) }
        radio.received = { [weak self] link, message in self?.enqueue(link, message: message) }
        radio.failed = { [weak self] error in self?.fail(BackpackError.invalid(error)) }
        radio.lost = { [weak self] link in if self?.link == link { self?.fail(BackpackError.invalid("Paired channel lost; peer result may be uncertain. Original retained.")) } }
        ranging.failed = { [weak self] error in self?.fail(BackpackError.invalid(error)) }
        ranging.changed = { [weak self] in self?.rangeChanged() }
    }
    func bind(phone: PhoneDisplayController, targets: DisplayTargetSelection) { session.bind(phone: phone, targets: targets) }
    func prepareCode() {
        do {
            guard !arming, !active, !session.hasRecovery else { throw BackpackError.invalid("Stop/restore the prior original before preparing a new local pairing; no recovery copy is deleted.") }
            stop()
            let key = Curve25519.KeyAgreement.PrivateKey()
            let own = LocalPairCode(version: 1, id: UUID(), key: PhoneSwapWire.b64(key.publicKey.rawRepresentation),
                hint: PhoneSwapWire.randomNonce(), expiresAt: CatalogEventTime.wire(Date().addingTimeInterval(120)))
            self.key = key; self.own = own; code = try own.text()
            deadline = ContinuousClock().now.advanced(by: .seconds(120)); failure = nil
            status = "Both devices exchange fresh codes, compare all four groups, then separately approve game/OS access"
        } catch { failure = error.localizedDescription }
    }
    func acceptCode(_ text: String) {
        do {
            guard !active, !arming, !session.running, let own, key != nil else { throw BackpackError.invalid("Prepare your own fresh inactive code first.") }
            let peer = try LocalPairCode.parse(text.trimmingCharacters(in: .whitespacesAndNewlines), now: Date())
            comparison = try LocalPairCode.comparison(own, peer)
            self.peer = peer; failure = nil
        } catch { failure = error.localizedDescription }
    }
    func prepareBluetooth() { do { try radio.prepare() } catch { failure = error.localizedDescription } }
    func start(consent: Bool, compared: Bool, stationary: Bool, useRange: Bool, preset: FriendScenePreset) {
        do {
            try checkPair()
            guard !active, !arming, !session.running, !session.busy, consent, compared, stationary, radio.ready, let own, let peer else {
                throw BackpackError.invalid("Both-key comparison, stationary/noncontact game consent and prepared Bluetooth are required.")
            }
            self.preset = preset; wantsRange = useRange
            let stamp = epoch
            arming = true
            task = Task {
                defer { if stamp == epoch { arming = false } }
                do {
                    let sender = own.key < peer.key
                    let worker = Task.detached {
                        let bytes = try FriendInteractionPixels.render(kind: .duet, preset: preset, sender: sender, chosen: Data(), received: nil)
                        _ = try GIFPreviewDecoder.phoneDisplay(bytes); return bytes
                    }
                    scene = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try await session.begin(id: own.id, scope: "owner-local-no-account", currentScope: { "owner-local-no-account" },
                        authorize: { try self.checkPair(); guard self.epoch == stamp else { throw CancellationError() } })
                    if useRange { localToken = try ranging.prepare(consent: true, foreground: UIApplication.shared.applicationState == .active) }
                    try checkPair(); active = true
                    try radio.start(token: own.hint, seconds: max(0, try CatalogEventTime.parse(own.expiresAt).timeIntervalSinceNow))
                    status = "Waiting for only the explicitly compared peer's observed hint/key; no server/friendship/proximity grant"
                    while active {
                        try await Task.sleep(for: .milliseconds(500)); try checkPair(); try session.check()
                        if let deadline, ContinuousClock().now >= deadline { throw BackpackError.invalid("Local pairing window expired — no renewal or replay.") }
                    }
                } catch { if stamp == epoch { fail(error) } }
            }
        } catch { fail(error) }
    }
    private func checkPair() throws {
        try Task.checkCancellation()
        guard key != nil, let own, let deadline, ContinuousClock().now < deadline,
              UIApplication.shared.applicationState == .active else { throw BackpackError.invalid("Local pair key/foreground/deadline unavailable; no automatic resume.") }
        try own.validate(now: Date())
        if let peer { try peer.validate(now: Date()) }
    }
    private func saw(_ observedLink: UUID, token: String) {
        guard active, let own, let peer, token == peer.hint else { radio.close(observedLink); return }
        observed = true
        guard own.key < peer.key, link == nil else { radio.close(observedLink); return }
        link = observedLink
        let hello = PhoneSwapWire.Hello(version: 1, sessionID: UUID(), initiatorToken: own.hint,
            responderToken: peer.hint, nonce: PhoneSwapWire.randomNonce(), response: false)
        first = hello
        let stamp = epoch
        Task {
            do { try await radio.send(.init(hello: hello, counter: nil, encrypted: nil), to: observedLink) }
            catch { if stamp == epoch { fail(error) } }
        }
    }
    private func enqueue(_ link: UUID, message: PhoneSwapWire.Outer) {
        guard active, queued < 16 else { if active { fail(BackpackError.invalid("Local paired receive queue exhausted.")) }; return }
        queued += 1
        let previous = receiveTail, stamp = epoch
        receiveTail = Task {
            await previous?.value
            defer { if stamp == epoch { queued = max(0, queued - 1) } }
            do { guard stamp == epoch else { throw CancellationError() }; try await receive(link, message) }
            catch { if stamp == epoch { fail(error) } }
        }
    }
    private func send(_ message: PhoneSwapWire.Message) async throws {
        let previous = sendTail, stamp = epoch
        let job = Task {
            await previous?.value; try checkPair()
            guard active, epoch == stamp, let link, var cipher else { throw BackpackError.invalid("Local paired encrypted channel unavailable.") }
            let frame = try cipher.seal(message); self.cipher = cipher
            try await radio.send(frame, to: link)
        }
        sendTail = Task { _ = await job.result }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    private func receive(_ incomingLink: UUID, _ outer: PhoneSwapWire.Outer) async throws {
        try checkPair()
        guard active, let own, let peer, let key else { throw CancellationError() }
        if let hello = outer.hello {
            guard hello.initiatorToken == (own.key < peer.key ? own.hint : peer.hint),
                  hello.responderToken == (own.key < peer.key ? peer.hint : own.hint) else {
                if incomingLink == link { throw BackpackError.invalid("Bound local channel attempted a different pairing transcript.") }
                radio.close(incomingLink); return
            }
            if !observed {
                for _ in 0..<30 {
                    try await Task.sleep(for: .milliseconds(100)); try checkPair()
                    if observed { break }
                }
            }
            guard observed else { throw BackpackError.invalid("A pairing QR/hello is not an actual radio observation.") }
            let a = own.key < peer.key ? own : peer, b = own.key < peer.key ? peer : own
            let second: PhoneSwapWire.Hello
            let first: PhoneSwapWire.Hello
            if hello.response {
                guard link == incomingLink, own.key < peer.key, let original = self.first, cipher == nil else { throw BackpackError.invalid("Replayed local-pair hello.") }
                first = original; second = hello
            } else {
                guard link == nil, peer.key < own.key, cipher == nil else { throw BackpackError.invalid("Unsolicited local-pair initiator.") }
                link = incomingLink; first = hello
                second = .init(version: 1, sessionID: hello.sessionID, initiatorToken: peer.hint,
                    responderToken: own.hint, nonce: PhoneSwapWire.randomNonce(), response: true)
            }
            cipher = try PhoneSwapCipher(privateKey: key, initiator: a.contact(), responder: b.contact(),
                first: first, second: second, origin: "local-manually-compared-keys",
                isInitiator: own.key < peer.key, domain: "nyan.local-pair.v1",
                binding: [try LocalPairCode.comparison(own, peer), try a.text(), try b.text()])
            if !hello.response { try await radio.send(.init(hello: second, counter: nil, encrypted: nil), to: incomingLink) }
            try await send(.init(kind: "proof", hash: cipher?.transcriptHash)); return
        }
        guard incomingLink == link, var cipher else { throw BackpackError.invalid("Local pair message has no bound channel.") }
        let message = try cipher.open(outer); self.cipher = cipher
        switch message.kind {
        case "proof":
            guard !proved, message.hash == cipher.transcriptHash else { throw BackpackError.invalid("Local key possession proof mismatch/replay.") }
            proved = true
            try await send(.init(kind: "local-intent", index: wantsRange ? 1 : 0, interaction: "stationary-calm-v1",
                preset: preset.rawValue, mediaConsent: true))
        case "local-intent":
            guard proved, !agreed, message.interaction == "stationary-calm-v1", message.preset == preset.rawValue,
                  message.index == (wantsRange ? 1 : 0), message.mediaConsent == true else { throw BackpackError.invalid("Both peers must deliberately approve the same local game/preset/ranging policy.") }
            agreed = true
            if let localToken { try await send(.init(kind: "ni-token", bytes: localToken)) }
            try await sendReady()
        case "ni-token":
            guard agreed, wantsRange, !gotToken, let bytes = message.bytes else { throw BackpackError.invalid("Unexpected/replayed paired NI token.") }
            gotToken = true; try ranging.run(peerToken: bytes)
        case "local-ready":
            guard agreed, !peerReady, message.sceneReady == true, message.hash == cipher.transcriptHash else { throw BackpackError.invalid("Invalid/replayed local ready.") }
            peerReady = true; try await send(.init(kind: "local-ready-ack", hash: cipher.transcriptHash)); try await applyIfReady()
        case "local-ready-ack":
            guard ready, !acknowledged, message.hash == cipher.transcriptHash else { throw BackpackError.invalid("Local ready acknowledgment mismatch/replay.") }
            acknowledged = true; try await applyIfReady()
        case "local-range":
            guard agreed, wantsRange else { throw BackpackError.invalid("Ranging was not independently enabled.") }
            peerRange = message.sceneReady == true
            if !peerRange && applied { throw BackpackError.invalid("Peer ranging freshness lost; stop rather than infer proximity.") }
            try await applyIfReady()
        case "local-applied":
            guard peerReady, !peerApplied else { throw BackpackError.invalid("Unexpected/replayed local scene receipt.") }
            peerApplied = true; status = applied ? "Both local scene receipts received; no verified proximity/sync/safety claim" : "Peer applied; local application still pending"
        default: throw BackpackError.invalid("Unknown local paired protocol message.")
        }
    }
    private func sendReady() async throws {
        guard agreed, !ready, scene != nil, let hash = cipher?.transcriptHash else { return }
        ready = true; try await send(.init(kind: "local-ready", hash: hash, sceneReady: true))
    }
    private func rangeChanged() {
        guard active, agreed, wantsRange, rangeSent != ranging.stableNearby else { return }
        let state = ranging.stableNearby, stamp = epoch; rangeSent = state
        Task {
            do {
                try await send(.init(kind: "local-range", sceneReady: state))
                if !state && applied { throw BackpackError.invalid("NI freshness/stability lost; local game stopped.") }
                try await applyIfReady()
            } catch { if stamp == epoch { fail(error) } }
        }
    }
    private func applyIfReady() async throws {
        guard agreed, peerReady, acknowledged, !applied, let scene else { return }
        guard !wantsRange || (ranging.stableNearby && peerRange) else { status = "Both ready; waiting for fresh coarse NI hints, not verified proximity"; return }
        applied = true
        try await session.apply(scene, title: "Locally paired complementary calm colors — no private original shared") {
            try self.checkPair()
            guard self.active, !self.wantsRange || (self.ranging.stableNearby && self.peerRange) else { throw CancellationError() }
        }
        try await send(.init(kind: "local-applied"))
        status = "Local color scene applied after both-ready; peer final outcome may be uncertain"
    }
    func stop(_ message: String = "Local pairing stopped — original retained, no automatic restart") {
        epoch = UUID(); active = false; arming = false; radio.stop(); ranging.stop()
        task?.cancel(); receiveTail?.cancel(); sendTail?.cancel(); task = nil; receiveTail = nil; sendTail = nil
        session.stop(message); key = nil; own = nil; peer = nil; code = nil; comparison = nil; deadline = nil
        cipher = nil; first = nil; link = nil; observed = false; proved = false; agreed = false
        ready = false; peerReady = false; acknowledged = false; applied = false; peerApplied = false
        rangeSent = nil; peerRange = false; localToken = nil; gotToken = false; scene = nil; queued = 0; status = message
    }
    private func fail(_ error: Error) { stop("Local paired game failed/stopped; explicit original restore remains available"); failure = error.localizedDescription }
    func restore() async { stop(); await session.restore() }
}
