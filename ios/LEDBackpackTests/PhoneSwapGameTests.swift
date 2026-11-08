import XCTest
import CryptoKit
import BackpackProtocol
@testable import LEDBackpack

private actor SwapGameTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    var late: (@MainActor @Sendable () -> Void)?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func setLate(_ action: @escaping @MainActor @Sendable () -> Void) { late = action }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected game fixture request.") }
        let response = responses.removeFirst()
        if request.url?.path.hasPrefix("/api/v1/social/swap-presence") == true { await late?() }
        return response
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class SwapGameVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
private final class GameIdleFixture: PhoneIdleTimer { var disabled = false }
@MainActor
private final class GameBrightnessFixture: PhoneScreenBrightness { var value = 0.4 }
@MainActor
final class PhoneSwapGameTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let presence = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private func key(_ n: UInt8) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: n, count: 32))
    }
    private func token(_ n: UInt8) -> String { PhoneSwapWire.b64(Data(repeating: n, count: 32)) }
    private func card(_ id: UUID, _ key: Curve25519.KeyAgreement.PrivateKey, _ n: UInt8) -> PhoneSwapContact {
        PhoneSwapContact(id: id, displayName: "Synthetic player", canRequestFriendship: false,
            publicKey: PhoneSwapWire.b64(key.publicKey.rawRepresentation), token: token(n), tokenExpiresAtISO: "2026-11-06T12:02:00Z")
    }
    private func ciphers(origin: String = "https://catalog.example") throws -> (PhoneSwapCipher, PhoneSwapCipher) {
        let first = try key(1), second = try key(2)
        let initiator = card(owner, first, 3), responder = card(peer, second, 4)
        let hello = PhoneSwapWire.Hello(version: 1, sessionID: presence, initiatorToken: initiator.token,
            responderToken: responder.token, nonce: token(5), response: false)
        let response = PhoneSwapWire.Hello(version: 1, sessionID: presence, initiatorToken: initiator.token,
            responderToken: responder.token, nonce: token(6), response: true)
        return (try PhoneSwapCipher(privateKey: first, initiator: initiator, responder: responder,
            first: hello, second: response, origin: origin, isInitiator: true),
            try PhoneSwapCipher(privateKey: second, initiator: initiator, responder: responder,
                first: hello, second: response, origin: origin, isInitiator: false))
    }
    private func gif() -> Data {
        Data(Array("GIF89a".utf8) + [1,0,1,0,0x80,0,0,0,0,0,255,255,255,
            0x21,0xF9,4,0,0xEE,0x2E,0,0,0x2C,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0,0x3B])
    }
    private func playingGIF(_ color: UInt8 = 0) -> Data {
        var bytes = Array(gif())
        bytes.removeLast()
        bytes.append(contentsOf: Array(gif()).dropFirst(19).dropLast())
        bytes.append(0x3B); bytes[13] = color
        return Data(bytes)
    }
    private func localRepository() throws -> SwapRecoveryRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return SwapRecoveryRepository(root: root)
    }
    private func receipt(_ data: Data, exchange: UUID = UUID(), sender: UUID? = nil,
        peerHash: String? = nil, sent: Bool = true) -> PhoneSwapApplicationReceipt {
        let outgoing = LocalSwapOriginal.digest(playingGIF(1))
        return PhoneSwapApplicationReceipt(exchangeID: exchange, peerID: sender ?? peer,
            outgoingHash: outgoing, incomingHash: LocalSwapOriginal.digest(data), peerAppliedHash: peerHash ?? outgoing,
            proved: true, ownReadyAcknowledged: true, peerReady: true, ownApplied: true, ownAppliedSent: sent)
    }
    private func minimalCard(_ id: UUID? = nil) -> LocalMetFriend {
        LocalMetFriend(id: id ?? peer, displayName: "Consented player", canRequestFriendship: false)
    }
    private func stage(_ repository: SwapRecoveryRepository, incoming: Data, exchange: UUID,
        sender: UUID? = nil) async throws -> LocalSwapOriginal {
        let revision = UUID(), account = UUID(), now = Date()
        let original = try await repository.prepareGame(
            snapshot: PhoneDisplaySnapshot(data: playingGIF(1), mediaID: nil, elapsed: 0, wantsPlayback: true,
                motionOverride: false, keepAwake: false), artworkRevision: revision, ownerScope: "fixture", attribution: nil)
        var ready = SwapPeerReadiness(transactionID: original.transactionID, sessionID: exchange, accountEpoch: account,
            expiresAt: now.addingTimeInterval(300))
        ready.gameEnabled = true; ready.ownReady = true; ready.peerGameEnabled = true; ready.peerReady = true
        _ = try await repository.stageGameReplacement(readiness: ready, session: exchange, accountEpoch: account,
            ownerScope: "fixture", expectedRevision: revision, nextRevision: UUID(), incoming: incoming,
            now: now, peerID: sender ?? peer)
        return original
    }
    private func reply(_ raw: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(raw.utf8)) }
    private func state() throws -> String {
        let publicKey = PhoneSwapWire.b64(try key(1).publicKey.rawRepresentation)
        return #"{"presenceId":"\#(presence)","enabled":true,"ownedByCurrentSession":true,"publicKey":"\#(publicKey)","expiresAtISO":"2026-11-06T12:05:00Z","tokenExpiresAtISO":"2026-11-06T12:02:00Z","locationControlsRevision":8,"serverTimeISO":"2026-11-06T12:00:00Z","gpsUsed":false,"encounterHistoryStored":false,"physicalProximityVerified":false,"backgroundDiscoveryVerified":false,"advertisementToken":"\#(token(3))"}"#
    }
    private func setup(_ responses: [CommunityResponse], game: Bool = true, nearbyRevision: Bool = false) async throws -> (CommunityController, CommunityFeatureClient, SwapGameTransport) {
        let login = reply(#"{"user":{"id":"\#(owner)","email":"test@example.invalid","displayName":"Owner","role":"admin","verified":true},"token":"synthetic-game-bearer","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(#"{"requireEmailVerification":false,"socialEnabled":true,"gifSwapPresenceEnabled":\#(game),"nearbyDiscoveryEnabled":true,"nearbyDiscoveryControlRevisionEnabled":\#(nearbyRevision)}"#)
        let transport = SwapGameTransport([login, config] + responses)
        let controller = CommunityController(vault: SwapGameVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    func testPurposeSeparatedGameConsentRequiresActualCapabilityAndNoFriendFlags() async throws {
        let (_, client, transport) = try await setup([], game: false)
        do { _ = try await client.gamePresence(); XCTFail("No discovery fallback") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 2)
    }
    func testRegisteredPublicKeyAndCurrentStopRevisionAreTheOnlyGameIdentityClaim() async throws {
        let (_, client, transport) = try await setup([reply(state())])
        _ = try await client.enableGame(expected: nil, controls: 8, key: PhoneSwapWire.b64(key(1).publicKey.rawRepresentation))
        let requests = await transport.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["expectedPresenceId","expectedControlsRevision","publicKey","consent","durationSeconds"])
        XCTAssertTrue(body["expectedPresenceId"] is NSNull)
        XCTAssertEqual(body["expectedControlsRevision"] as? Int, 8)
        XCTAssertNil(body["privateKey"]); XCTAssertNil(body["coordinates"])
    }
    func testAdvertisedNearbyStopRevisionCannotBeOmittedOrSilentlyZeroed() async throws {
        let (_, client, transport) = try await setup([], nearbyRevision: true)
        do { _ = try await client.armNearby(expected: nil, look: true, discoverable: false); XCTFail("Missing capture") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 2)
    }
    func testDirectionalTranscriptKeysRoundTripAuthenticatedApplicationMessages() throws {
        var (initiator, responder) = try ciphers()
        XCTAssertEqual(initiator.transcriptHash, responder.transcriptHash)
        let first = try initiator.seal(PhoneSwapWire.Message(kind: "proof", hash: initiator.transcriptHash))
        XCTAssertEqual(try responder.open(first).kind, "proof")
        let second = try responder.seal(PhoneSwapWire.Message(kind: "ready", hash: "synthetic"))
        XCTAssertEqual(try initiator.open(second).kind, "ready")
    }
    func testReplayedOrTamperedCiphertextFailsWithoutAdvancingToReady() throws {
        var (a, b) = try ciphers()
        let original = try a.seal(PhoneSwapWire.Message(kind: "proof", hash: a.transcriptHash))
        _ = try b.open(original)
        XCTAssertThrowsError(try b.open(original))
        let next = try a.seal(PhoneSwapWire.Message(kind: "ready", hash: "test"))
        var corrupt = try XCTUnwrap(next.encrypted); corrupt[corrupt.startIndex] ^= 1
        let value = PhoneSwapWire.Outer(hello: nil, counter: next.counter, encrypted: corrupt)
        XCTAssertThrowsError(try b.open(value))
    }
    func testCrossOriginOrReflectedDirectionCannotAuthenticatePeerPossession() throws {
        var (a, _) = try ciphers()
        var (_, foreign) = try ciphers(origin: "https://different.example")
        let frame = try a.seal(PhoneSwapWire.Message(kind: "proof", hash: a.transcriptHash))
        XCTAssertThrowsError(try foreign.open(frame))
        XCTAssertThrowsError(try a.open(frame))
    }
    func testWrongRegisteredKeyTokenOrRoleCannotBuildTranscript() throws {
        let first = try key(1), second = try key(2)
        let a = card(owner, first, 3), b = card(peer, second, 4)
        let hello = PhoneSwapWire.Hello(version: 1, sessionID: presence, initiatorToken: token(3), responderToken: token(4), nonce: token(5), response: false)
        let wrong = PhoneSwapWire.Hello(version: 1, sessionID: presence, initiatorToken: token(8), responderToken: token(4), nonce: token(6), response: true)
        XCTAssertThrowsError(try PhoneSwapCipher(privateKey: first, initiator: a, responder: b, first: hello, second: wrong, origin: "https://catalog.example", isInitiator: true))
    }
    func testEveryFrameSplitAndOversizeHeaderAreBoundedWithoutRadioInitialization() throws {
        let hello = PhoneSwapWire.Hello(version: 1, sessionID: presence, initiatorToken: token(3), responderToken: token(4), nonce: token(5), response: false)
        let bytes = try PhoneSwapWire.packet(PhoneSwapWire.Outer(hello: hello, counter: nil, encrypted: nil))
        for split in 1..<bytes.count {
            var parser = PhoneSwapFrameDecoder()
            XCTAssertTrue(try parser.push(Data(bytes.prefix(split))).isEmpty)
            XCTAssertEqual(try parser.push(Data(bytes.dropFirst(split))).first?.hello?.sessionID, presence)
        }
        var parser = PhoneSwapFrameDecoder()
        XCTAssertThrowsError(try parser.push(Data([0xFF,0xFF,0xFF,0x7F])))
    }
    func testSanitizationStripsCommentAndUnknownAppMetadataButNotOriginalPixelsOrTiming() throws {
        let original = gif()
        var decorated = [UInt8](original)
        decorated.insert(contentsOf: [0x21,0xFE,6] + Array("SECRET".utf8) + [0], at: 19)
        let source = Data(decorated), clean = try PrivateOutgoingGIF.make(source)
        XCTAssertEqual(clean, original)
        XCTAssertEqual(try GIFStructure.inspect(clean).frames[0].delayCentiseconds, 12014)
        XCTAssertTrue(String(decoding: source, as: UTF8.self).contains("SECRET"))
        XCTAssertFalse(String(decoding: clean, as: UTF8.self).contains("SECRET"))
    }
    func testStillOversizeAndIncomingMetadataAreRejectedWithoutRewritingOriginal() throws {
        XCTAssertThrowsError(try PrivateOutgoingGIF.make(Data("PNG".utf8)))
        XCTAssertThrowsError(try PrivateOutgoingGIF.make(Data(repeating: 0, count: PhoneSwapWire.maximumGIF + 1)))
        var decorated = [UInt8](gif())
        decorated.insert(contentsOf: [0x21,0xFE,1,65,0], at: 19)
        XCTAssertThrowsError(try PrivateOutgoingGIF.inspectAlreadySanitized(Data(decorated)))
    }
    func testCompleteBytesHashAndChunkOrderAreRequiredBeforeValidationReady() throws {
        let bytes = gif(), credit = try PhoneSwapWire.Credit(nil)
        var incoming = try PhoneSwapIncoming(PhoneSwapWire.Message(kind: "offer", hash: LocalSwapOriginal.digest(bytes), length: bytes.count, credit: credit))
        XCTAssertThrowsError(try incoming.complete())
        XCTAssertThrowsError(try incoming.append(PhoneSwapWire.Message(kind: "chunk", index: 1, bytes: bytes)))
        try incoming.append(PhoneSwapWire.Message(kind: "chunk", index: 0, bytes: bytes))
        XCTAssertEqual(try incoming.complete(), bytes)
        XCTAssertThrowsError(try incoming.append(PhoneSwapWire.Message(kind: "chunk", index: 0, bytes: bytes)))
    }
    func testPrivateUrlsCredentialsAndContactLikeCreditsCannotEscapeAsAttribution() throws {
        for secret in ["https://private.example/item?token=secret", "person@example.invalid", "Bearer credential"] {
            XCTAssertThrowsError(try PhoneSwapWire.Credit(Attribution(source: "unused", author: secret, license: "CC0", licenseURL: "")))
        }
        let credit = try PhoneSwapWire.Credit(Attribution(source: "private source URL intentionally omitted", author: "Artist", license: "CC0", licenseURL: "https://private.example"))
        let minimal = try credit.attribution()
        XCTAssertEqual(minimal.author, "Artist"); XCTAssertEqual(minimal.licenseURL, "")
    }
    func testLateAccountSwitchDiscardsCurrentGameProofRatherThanApplyingArtwork() async throws {
        let (controller, client, transport) = try await setup([reply(state())])
        await transport.setLate { controller.configure("https://different.example") }
        do { _ = try await client.gamePresence(); XCTFail("Late game binding") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
    func testAutomaticPhoneReplacementRetainsPoliciesAndRejectsNewerManualSelection() async throws {
        let phone = PhoneDisplayController(idleTimer: GameIdleFixture(), brightness: GameBrightnessFixture())
        phone.setForeground(true); phone.open(); phone.setVisible(true)
        let bytes = gif(); try await phone.show(bytes)
        phone.setDataSaving(true)
        let first = phone.artworkRevision, next = UUID()
        try await phone.applyValidatedGameGIF(bytes, expectedRevision: first, nextRevision: next)
        XCTAssertEqual(phone.artworkRevision, next); XCTAssertTrue(phone.dataSaving)
        XCTAssertFalse(phone.isPlaying); XCTAssertFalse(phone.brightnessEnabled)
        do { try await phone.applyValidatedGameGIF(bytes, expectedRevision: first, nextRevision: UUID()); XCTFail("Newer selection") } catch {}
    }
    func testInitialDurableOriginalSurvivesConsecutiveGameReplacements() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = SwapRecoveryRepository(root: root), firstRevision = UUID(), session = UUID(), account = UUID(), now = Date()
        let snapshot = PhoneDisplaySnapshot(data: gif(), mediaID: nil, elapsed: 0, wantsPlayback: false, motionOverride: false, keepAwake: false)
        let original = try await repository.prepareGame(snapshot: snapshot, artworkRevision: firstRevision, ownerScope: "fixture", attribution: nil)
        var ready = SwapPeerReadiness(transactionID: original.transactionID, sessionID: session, accountEpoch: account, expiresAt: now.addingTimeInterval(300))
        ready.gameEnabled = true; ready.ownReady = true; ready.peerGameEnabled = true; ready.peerReady = true
        let secondRevision = UUID()
        _ = try await repository.stageGameReplacement(readiness: ready, session: session, accountEpoch: account,
            ownerScope: "fixture", expectedRevision: firstRevision, nextRevision: secondRevision, incoming: gif(), now: now)
        let final = try await repository.stageGameReplacement(readiness: ready, session: session, accountEpoch: account,
            ownerScope: "fixture", expectedRevision: secondRevision, nextRevision: UUID(), incoming: gif(), now: now.addingTimeInterval(61))
        XCTAssertEqual(final.originalSHA256, original.originalSHA256); XCTAssertEqual(final.phone.data, snapshot.data)
        XCTAssertEqual(final.transactionID, original.transactionID)
    }
    func testBilateralReadyCancelExpiryAndHardwareTargetDoNotGrantApply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = SwapRecoveryRepository(root: root), account = UUID(), session = UUID(), now = Date()
        let original = try await repository.prepareGame(snapshot: PhoneDisplaySnapshot(data: gif(), mediaID: nil, elapsed: 0, wantsPlayback: false, motionOverride: false, keepAwake: false),
            artworkRevision: UUID(), ownerScope: "fixture", attribution: nil)
        var gate = SwapPeerReadiness(transactionID: original.transactionID, sessionID: session, accountEpoch: account, expiresAt: now)
        gate.gameEnabled = true; gate.ownReady = true; gate.peerGameEnabled = true
        XCTAssertThrowsError(try gate.requireApply(journal: original, installation: original.installationID, ownerScope: "fixture", session: session, account: account, incoming: gif(), now: now))
        var cancelled = SwapPeerReadiness(transactionID: original.transactionID, sessionID: session, accountEpoch: account, expiresAt: now.addingTimeInterval(60))
        cancelled.gameEnabled = true; cancelled.ownReady = true; cancelled.peerGameEnabled = true
        cancelled.peerReady = true; cancelled.cancelled = true
        XCTAssertThrowsError(try cancelled.requireApply(journal: original, installation: original.installationID, ownerScope: "fixture", session: session, account: account, incoming: gif(), now: now))
        do { try await repository.validateIncomingForFuturePhoneReplacement(readiness: gate, session: session, accountEpoch: account, ownerScope: "fixture", target: .hardware, incoming: gif(), now: now); XCTFail("No hardware apply") } catch {}
    }
    func testMetFriendsPersistsOnlyMinimalLocalCardAndDoesNotGlobalDeduplicateArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-met-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = PhoneSwapLocalStore(root: root), contact = card(peer, try key(2), 4)
        try await store.retainCard(contact, scope: "fixture")
        let cards = try await store.cards(scope: "fixture")
        XCTAssertEqual(cards.count, 1); XCTAssertFalse(cards[0].canRequestFriendship)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("MetFriends"), includingPropertiesForKeys: nil)
        let content = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertFalse(content.contains(contact.token)); XCTAssertFalse(content.contains(contact.publicKey))
        XCTAssertFalse(content.contains("time")); XCTAssertFalse(content.contains("location"))
        let other = try await store.cards(scope: "different"); XCTAssertTrue(other.isEmpty)
    }
    func testDisablingFriendRequestsDoesNotPreventGameCardResolution() async throws {
        let publicKey = PhoneSwapWire.b64(try key(2).publicKey.rawRepresentation)
        let result = #"{"contacts":[{"id":"\#(peer)","displayName":"Player","canRequestFriendship":false,"publicKey":"\#(publicKey)","token":"\#(token(4))","tokenExpiresAtISO":"2026-11-06T12:02:00Z"}],"distanceOrdering":false,"friendshipCreated":false,"physicalProximityVerified":false,"gpsUsed":false,"encounterHistoryStored":false}"#
        let (_, client, transport) = try await setup([reply(result)])
        let cards = try await client.resolveGame(presence, observed: [token(4)])
        XCTAssertFalse(try XCTUnwrap(cards.first).canRequestFriendship)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].url?.path, "/api/v1/social/swap-presence/resolve")
    }
    func testPlayingCaptureRejectsPausedStillAndChangedPlaybackPolicy() async throws {
        let phone = PhoneDisplayController(idleTimer: GameIdleFixture(), brightness: GameBrightnessFixture())
        phone.setForeground(true); phone.open(); phone.setVisible(true)
        try await phone.show(playingGIF())
        XCTAssertThrowsError(try phone.capturePlayingGameGIF())
        phone.play()
        let captured = try phone.capturePlayingGameGIF()
        XCTAssertEqual(captured.data, phone.data)
        phone.pause(); phone.play()
        XCTAssertThrowsError(try captured.requireCurrent(phone))
        let current = try phone.capturePlayingGameGIF()
        phone.setDataSaving(true)
        XCTAssertThrowsError(try current.requireCurrent(phone))
        try await phone.show(gif()); phone.setDataSaving(false); phone.play()
        XCTAssertThrowsError(try phone.capturePlayingGameGIF())
    }
    func testPlayingCaptureRejectsNewManualArtworkAndBackground() async throws {
        let phone = PhoneDisplayController(idleTimer: GameIdleFixture(), brightness: GameBrightnessFixture())
        phone.setForeground(true); phone.open(); phone.setVisible(true)
        try await phone.show(playingGIF(1)); phone.play()
        let source = try phone.capturePlayingGameGIF()
        try await phone.show(playingGIF(2)); phone.play()
        XCTAssertThrowsError(try source.requireCurrent(phone))
        let next = try phone.capturePlayingGameGIF()
        phone.setForeground(false)
        XCTAssertThrowsError(try next.requireCurrent(phone))
    }
    func testNextOutgoingIsReceivedPlayingGIFNotFirstRecoveryOriginal() async throws {
        let repository = try localRepository()
        let phone = PhoneDisplayController(idleTimer: GameIdleFixture(), brightness: GameBrightnessFixture())
        phone.setForeground(true); phone.open(); phone.setVisible(true)
        let first = playingGIF(1), incoming = playingGIF(2)
        try await phone.show(first); phone.play()
        let revision = phone.artworkRevision, next = UUID(), account = UUID(), session = UUID(), now = Date()
        let original = try await repository.prepareGame(snapshot: phone.snapshot(), artworkRevision: revision,
            ownerScope: "fixture", attribution: nil)
        var ready = SwapPeerReadiness(transactionID: original.transactionID, sessionID: session, accountEpoch: account,
            expiresAt: now.addingTimeInterval(300))
        ready.gameEnabled = true; ready.ownReady = true; ready.peerGameEnabled = true; ready.peerReady = true
        _ = try await repository.stageGameReplacement(readiness: ready, session: session, accountEpoch: account,
            ownerScope: "fixture", expectedRevision: revision, nextRevision: next, incoming: incoming, now: now, peerID: peer)
        try await phone.applyValidatedGameGIF(incoming, expectedRevision: revision, nextRevision: next)
        XCTAssertEqual(try phone.capturePlayingGameGIF().data, incoming)
        let resumed = try await repository.prepareGame(snapshot: phone.snapshot(), artworkRevision: next,
            ownerScope: "fixture", attribution: nil)
        XCTAssertEqual(resumed.phone.data, first)
        XCTAssertEqual(resumed.gamePeerIDs, [peer])
        XCTAssertEqual(resumed.transactionID, original.transactionID)
        let wrong = PhoneDisplaySnapshot(data: first, mediaID: nil, elapsed: 0, wantsPlayback: true,
            motionOverride: false, keepAwake: false)
        do {
            _ = try await repository.prepareGame(snapshot: wrong, artworkRevision: next, ownerScope: "fixture", attribution: nil)
            XCTFail("Matching revision must not adopt unrelated bytes")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    func testCooldownSurvivesRearmClockJumpAndNewController() async throws {
        let repository = try localRepository(), now = Date(), other = UUID()
        var journal = try await repository.prepareGame(
            snapshot: PhoneDisplaySnapshot(data: playingGIF(), mediaID: nil, elapsed: 0, wantsPlayback: true,
                motionOverride: false, keepAwake: false), artworkRevision: UUID(), ownerScope: "fixture", attribution: nil)
        var throttle = PhoneSwapThrottle()
        try throttle.resume(journal: journal, now: now, uptime: 100)
        try throttle.applied(peer, uptime: 100)
        journal.gamePeerIDs = [peer]; journal.cooldownUntil = now.addingTimeInterval(60)
        try throttle.resume(journal: journal, now: now.addingTimeInterval(20), uptime: 120)
        XCTAssertFalse(throttle.permits(other, uptime: 159.999))
        XCTAssertTrue(throttle.permits(other, uptime: 160))
        XCTAssertFalse(throttle.permits(peer, uptime: 1000))
        try throttle.resume(journal: journal, now: now.addingTimeInterval(1000), uptime: 121)
        XCTAssertFalse(throttle.permits(other, uptime: 121))
        var restarted = PhoneSwapThrottle()
        try restarted.resume(journal: journal, now: now.addingTimeInterval(20), uptime: 1)
        XCTAssertFalse(restarted.permits(other, uptime: 40.999))
        XCTAssertTrue(restarted.permits(other, uptime: 41))
        XCTAssertFalse(restarted.permits(peer, uptime: 1000))
        XCTAssertFalse(restarted.permits(other, uptime: .nan))
    }
    func testSamePeerCannotStageAgainAfterCooldownOrRearm() async throws {
        let repository = try localRepository(), revision = UUID(), next = UUID(), session = UUID(), account = UUID(), now = Date()
        let snapshot = PhoneDisplaySnapshot(data: playingGIF(1), mediaID: nil, elapsed: 0, wantsPlayback: true,
            motionOverride: false, keepAwake: false)
        let original = try await repository.prepareGame(snapshot: snapshot, artworkRevision: revision, ownerScope: "fixture", attribution: nil)
        var ready = SwapPeerReadiness(transactionID: original.transactionID, sessionID: session, accountEpoch: account,
            expiresAt: now.addingTimeInterval(300))
        ready.gameEnabled = true; ready.ownReady = true; ready.peerGameEnabled = true; ready.peerReady = true
        _ = try await repository.stageGameReplacement(readiness: ready, session: session, accountEpoch: account,
            ownerScope: "fixture", expectedRevision: revision, nextRevision: next, incoming: playingGIF(2), now: now, peerID: peer)
        do {
            _ = try await repository.stageGameReplacement(readiness: ready, session: session, accountEpoch: account,
                ownerScope: "fixture", expectedRevision: next, nextRevision: UUID(), incoming: playingGIF(3),
                now: now.addingTimeInterval(61), peerID: peer)
            XCTFail("Same-peer suppression must outlive cooldown")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let retained = try await repository.load()
        XCTAssertEqual(retained?.gamePeerIDs, [peer])
        XCTAssertEqual(retained?.phone.data, snapshot.data)
    }
    func testPartialAndWrongHashReceiptsDoNotCreateFoundUsers() async throws {
        let repository = try localRepository(), data = playingGIF(2), card = minimalCard()
        for proof in [receipt(data, sent: false), receipt(data, peerHash: LocalSwapOriginal.digest(data))] {
            do {
                _ = try await repository.retainConfirmedGame(data: data, attribution: nil, sender: card,
                    receipt: proof, ownerScope: "fixture")
                XCTFail("Partial or mismatched bilateral receipt")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        let values = try await repository.received()
        XCTAssertTrue(values.isEmpty)
    }
    func testConfirmedGIFAndMinimalSenderAreAtomicScopedAndDuplicateSafe() async throws {
        let repository = try localRepository(), data = playingGIF(2), card = minimalCard(), proof = receipt(playingGIF(2))
        _ = try await stage(repository, incoming: data, exchange: proof.exchangeID)
        let credit = Attribution(source: "Peer GIF", author: "Artist", license: "CC0", licenseURL: "")
        let first = try await repository.retainConfirmedGame(data: data, attribution: credit, sender: card,
            receipt: proof, ownerScope: "fixture")
        let second = try await repository.retainConfirmedGame(data: data, attribution: credit, sender: card,
            receipt: proof, ownerScope: "fixture")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.data, data); XCTAssertEqual(first.sender, card); XCTAssertEqual(first.attribution, credit)
        XCTAssertTrue(first.isFoundUser(ownerScope: "fixture"))
        XCTAssertFalse(first.isFoundUser(ownerScope: "other"))
        let values = try await repository.received()
        XCTAssertEqual(values.count, 1)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(first), encoding: .utf8))
        for forbidden in ["publicKey", "token", "email", "location", "distance", "timestamp"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }
    func testConflictingDuplicateSenderOrPayloadCannotChangeConfirmedPair() async throws {
        let repository = try localRepository(), data = playingGIF(2), exchange = UUID(), other = UUID()
        _ = try await stage(repository, incoming: data, exchange: exchange)
        let first = try await repository.retainConfirmedGame(data: data, attribution: nil, sender: minimalCard(),
            receipt: receipt(data, exchange: exchange), ownerScope: "fixture")
        do {
            _ = try await repository.retainConfirmedGame(data: playingGIF(3), attribution: nil, sender: minimalCard(),
                receipt: receipt(playingGIF(3), exchange: exchange), ownerScope: "fixture")
            XCTFail("Conflicting duplicate GIF")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        do {
            _ = try await repository.retainConfirmedGame(data: data, attribution: nil, sender: minimalCard(other),
                receipt: receipt(data, exchange: exchange, sender: other), ownerScope: "fixture")
            XCTFail("Conflicting duplicate verified sender")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let values = try await repository.received()
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values.first?.id, first.id)
        XCTAssertEqual(values.first?.sender, first.sender); XCTAssertEqual(values.first?.data, data)
    }
    func testLegacyUnconfirmedReceivedArtworkCannotBecomeFoundRetrospectively() async throws {
        let repository = try localRepository(), data = playingGIF(2), exchange = UUID()
        let old = try await repository.retainReceived(data: data, transactionID: exchange,
            name: "Legacy validated copy", attribution: nil, verifiedGame: true)
        XCTAssertFalse(old.isFoundUser(ownerScope: "fixture"))
        do {
            _ = try await repository.retainConfirmedGame(data: data, attribution: nil, sender: minimalCard(),
                receipt: receipt(data, exchange: exchange), ownerScope: "fixture")
            XCTFail("Legacy unconfirmed outcome must not synthesize a Found record")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    func testCancelledCompletionDoesNotPersistFoundSuccess() async throws {
        let repository = try localRepository(), data = playingGIF(2), proof = receipt(playingGIF(2)), card = minimalCard()
        _ = try await stage(repository, incoming: data, exchange: proof.exchangeID)
        let task = Task {
            try await repository.retainConfirmedGame(data: data, attribution: nil, sender: card,
                receipt: proof, ownerScope: "fixture")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled completion") }
        catch { XCTAssertTrue(error is CancellationError) }
        let values = try await repository.received()
        XCTAssertTrue(values.isEmpty)
    }
    func testRemovingConfirmedReceivedCopyPreservesFirstOriginal() async throws {
        let repository = try localRepository(), bytes = playingGIF(1), proof = receipt(playingGIF(2))
        let first = try await stage(repository, incoming: playingGIF(2), exchange: proof.exchangeID)
        let item = try await repository.retainConfirmedGame(data: playingGIF(2), attribution: nil, sender: minimalCard(),
            receipt: proof, ownerScope: "fixture")
        try await repository.removeReceived(item.id)
        let retained = try await repository.load()
        XCTAssertEqual(retained?.transactionID, first.transactionID); XCTAssertEqual(retained?.phone.data, bytes)
        let received = try await repository.received()
        XCTAssertTrue(received.isEmpty)
    }
    func testReceiptsWithoutMatchingDurableStagingCannotCreateFoundUsers() async throws {
        let repository = try localRepository(), data = playingGIF(2)
        do {
            _ = try await repository.retainConfirmedGame(data: data, attribution: nil, sender: minimalCard(),
                receipt: receipt(data), ownerScope: "fixture")
            XCTFail("Receipt flags cannot substitute for actual staged recovery/game identity")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let values = try await repository.received()
        XCTAssertTrue(values.isEmpty)
    }
    func testFoundProjectionAndRemovalRespectAccountAndPreserveOriginal() async throws {
        let repository = try localRepository(), data = playingGIF(2), proof = receipt(playingGIF(2))
        let original = try await stage(repository, incoming: data, exchange: proof.exchangeID)
        let item = try await repository.retainConfirmedGame(data: data, attribution: nil, sender: minimalCard(),
            receipt: proof, ownerScope: "fixture")
        let store = PhoneSwapLocalStore(root: FileManager.default.temporaryDirectory, recovery: repository)
        let own = try await store.found(scope: "fixture"), other = try await store.found(scope: "other")
        XCTAssertEqual(own.count, 1); XCTAssertTrue(other.isEmpty)
        do { try await store.removeFound(item, scope: "other"); XCTFail("Cross-account removal") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        try await store.removeFound(item, scope: "fixture")
        let retained = try await repository.load()
        XCTAssertEqual(retained?.phone.data, original.phone.data)
        let remaining = try await store.found(scope: "fixture")
        XCTAssertTrue(remaining.isEmpty)
    }
}
