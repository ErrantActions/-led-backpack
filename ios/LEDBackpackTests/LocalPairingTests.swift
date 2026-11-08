import XCTest
import CryptoKit
@testable import LEDBackpack

@MainActor
final class LocalPairingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1794000000)
    private func code(_ n: UInt8) throws -> (LocalPairCode, Curve25519.KeyAgreement.PrivateKey) {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: n, count: 32))
        return (.init(version: 1, id: n == 1 ? UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")! : UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            key: PhoneSwapWire.b64(key.publicKey.rawRepresentation), hint: PhoneSwapWire.b64(Data(repeating: n + 4, count: 32)),
            expiresAt: CatalogEventTime.wire(now.addingTimeInterval(120))), key)
    }
    private func ciphers(domain: String = "nyan.local-pair.v1") throws -> (PhoneSwapCipher, PhoneSwapCipher) {
        let (a,ka) = try code(1), (b,kb) = try code(2)
        let first = PhoneSwapWire.Hello(version: 1, sessionID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!, initiatorToken: a.hint, responderToken: b.hint,
            nonce: PhoneSwapWire.b64(Data(repeating: 8, count: 32)), response: false)
        let second = PhoneSwapWire.Hello(version: 1, sessionID: first.sessionID, initiatorToken: a.hint, responderToken: b.hint,
            nonce: PhoneSwapWire.b64(Data(repeating: 9, count: 32)), response: true)
        let binding = [try LocalPairCode.comparison(a,b), try a.text(), try b.text()]
        return (try .init(privateKey: ka, initiator: a.contact(), responder: b.contact(), first: first, second: second,
            origin: "local-manually-compared-keys", isInitiator: true, domain: domain, binding: binding),
            try .init(privateKey: kb, initiator: a.contact(), responder: b.contact(), first: first, second: second,
                origin: "local-manually-compared-keys", isInitiator: false, domain: domain, binding: binding))
    }
    func testCanonicalCodeRoundtripKeepsEphemeralBindingsOnly() throws {
        let (value,_) = try code(1)
        XCTAssertEqual(try LocalPairCode.parse(value.text(), now: now), value)
    }
    func testForeignUrlsOversizeAndAlternateEncodingAreRejected() throws {
        XCTAssertThrowsError(try LocalPairCode.parse("https://foreign.example/pair", now: now))
        XCTAssertThrowsError(try LocalPairCode.parse(String(repeating: "x", count: 1201), now: now))
        let (value,_) = try code(1)
        XCTAssertThrowsError(try LocalPairCode.parse(value.text() + "=", now: now))
    }
    func testExpiredFutureAndUnsupportedVersionCannotArmPair() throws {
        let (value,_) = try code(1)
        XCTAssertThrowsError(try value.validate(now: now.addingTimeInterval(121)))
        let future = LocalPairCode(version: 1, id: value.id, key: value.key, hint: value.hint, expiresAt: CatalogEventTime.wire(now.addingTimeInterval(1000)))
        XCTAssertThrowsError(try future.validate(now: now))
        let wrong = LocalPairCode(version: 2, id: value.id, key: value.key, hint: value.hint, expiresAt: value.expiresAt)
        XCTAssertThrowsError(try wrong.validate(now: now))
    }
    func testOwnCodeCannotBeAcceptedAsTheOtherDevice() throws {
        let (value,_) = try code(1)
        XCTAssertThrowsError(try LocalPairCode.comparison(value,value))
    }
    func testComparisonIsSymmetricAndBoundToBothKeysAndHints() throws {
        let (a,_) = try code(1), (b,_) = try code(2)
        XCTAssertEqual(try LocalPairCode.comparison(a,b), try LocalPairCode.comparison(b,a))
        let changed = LocalPairCode(version: 1, id: b.id, key: b.key, hint: PhoneSwapWire.b64(Data(repeating: 9, count: 32)), expiresAt: b.expiresAt)
        XCTAssertNotEqual(try LocalPairCode.comparison(a,b), try LocalPairCode.comparison(a,changed))
    }
    func testComparedKeyCipherAuthenticatesCurrentLocalGameMessages() throws {
        var (a,b) = try ciphers()
        let message = try a.seal(.init(kind: "local-ready", hash: a.transcriptHash, sceneReady: true))
        XCTAssertEqual(try b.open(message).kind, "local-ready")
    }
    func testOnlinePurposeCannotDecryptOfflineLocalPairCipher() throws {
        var (a,_) = try ciphers()
        var (_,b) = try ciphers(domain: "nyan.phone-swap.v1")
        XCTAssertThrowsError(try b.open(a.seal(.init(kind: "proof"))))
    }
    func testLocalCipherReplayFailsBeforeAnotherReadyApplication() throws {
        var (a,b) = try ciphers()
        let message = try a.seal(.init(kind: "local-ready", sceneReady: true))
        _ = try b.open(message); XCTAssertThrowsError(try b.open(message))
    }
    func testPairCodeContainsNoPrivateKeyAccountLocationOrArtworkFields() throws {
        let (value,key) = try code(1)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: PhoneSwapWire.encoder().encode(value)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["version","id","key","hint","expiresAt"])
        XCTAssertNotEqual(value.key, PhoneSwapWire.b64(key.rawRepresentation))
    }
    func testRangeStabilityNeedsFreshBoundedStableSamplesAndResetsOnLoss() {
        var gate = LocalRangeStability()
        XCTAssertFalse(gate.observe(distance: 1, uptime: 1))
        XCTAssertTrue(gate.observe(distance: 1.1, uptime: 2.1))
        XCTAssertFalse(gate.observe(distance: 2, uptime: 2.2))
        XCTAssertFalse(gate.observe(distance: 2, uptime: 5))
        XCTAssertFalse(gate.observe(distance: .nan, uptime: 6))
        XCTAssertFalse(gate.observe(distance: nil, uptime: 7))
    }
    func testFreshRangeGateExpiresEvenBeforeTimerCallbackRuns() {
        var gate = LocalRangeStability()
        XCTAssertFalse(gate.observe(distance: 1, uptime: 1))
        XCTAssertFalse(gate.fresh(uptime: 1))
        XCTAssertTrue(gate.observe(distance: 1.1, uptime: 2.1))
        XCTAssertTrue(gate.fresh(uptime: 4.099))
        XCTAssertFalse(gate.fresh(uptime: 4.1))
        XCTAssertFalse(gate.fresh(uptime: 2))
    }
    func testRangeResetOrUnstableMeasurementRevokesFreshGate() {
        var gate = LocalRangeStability()
        _ = gate.observe(distance: 1, uptime: 1)
        _ = gate.observe(distance: 1.1, uptime: 2.1)
        XCTAssertTrue(gate.fresh(uptime: 2.1))
        _ = gate.observe(distance: 2, uptime: 2.2)
        XCTAssertFalse(gate.fresh(uptime: 2.2))
        gate.reset()
        XCTAssertFalse(gate.fresh(uptime: 2.3))
    }
    func testNegativeRangeClockCannotEstablishStability() {
        var gate = LocalRangeStability()
        XCTAssertFalse(gate.observe(distance: 1, uptime: -1))
        XCTAssertFalse(gate.fresh(uptime: 0))
    }
    func testQueuedRangeClaimRequiresFreshSampleAtTransmissionTime() throws {
        var gate = LocalRangeStability()
        _ = gate.observe(distance: 1, uptime: 1)
        _ = gate.observe(distance: 1, uptime: 2)
        XCTAssertNoThrow(try gate.requireFresh(uptime: 3.999))
        XCTAssertThrowsError(try gate.requireFresh(uptime: 4))
        XCTAssertThrowsError(try gate.requireFresh(uptime: 5))
    }
    func testPeerReceiptDuringLocalPreparationCannotConfirmBothApplications() {
        var state = LocalPairApplicationState()
        state.applying = true; state.peerApplied = true
        XCTAssertFalse(state.canApply); XCTAssertFalse(state.confirmed)
        state.localApplied = true
        XCTAssertFalse(state.confirmed)
        state.localReceiptSent = true
        XCTAssertFalse(state.confirmed)
        state.applying = false
        XCTAssertTrue(state.confirmed)
    }
    func testLocalApplicationWithoutPeerReceiptRemainsUnconfirmedAndResetClearsState() {
        var state = LocalPairApplicationState()
        state.localApplied = true; state.localReceiptSent = true
        XCTAssertFalse(state.canApply); XCTAssertFalse(state.confirmed)
        state.peerApplied = true
        XCTAssertTrue(state.confirmed)
        state = .init()
        XCTAssertTrue(state.canApply); XCTAssertFalse(state.confirmed)
    }
    func testNIColdStopAndUnconsentedPrepareNeverInitializeSession() {
        let ni = LocalNearbyInteraction()
        XCTAssertFalse(ni.initialized); ni.stop(); XCTAssertFalse(ni.initialized)
        XCTAssertFalse(ni.hasFreshStableHint(uptime: 0))
        XCTAssertThrowsError(try ni.requireFreshStableHint(uptime: 0))
        XCTAssertThrowsError(try ni.prepare(consent: false, foreground: false))
        XCTAssertFalse(ni.initialized)
    }
    func testColdPairedGameAndStopDoNotInitializeRadioOrNI() {
        let game = LocalPairedGame()
        XCTAssertFalse(game.radio.ready); XCTAssertFalse(game.ranging.initialized)
        game.stop()
        XCTAssertNil(game.code); XCTAssertNil(game.comparison); XCTAssertFalse(game.ranging.initialized)
        XCTAssertFalse(game.session.running)
    }
}
