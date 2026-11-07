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
}
