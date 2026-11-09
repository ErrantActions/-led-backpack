import XCTest
import CryptoKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor private final class FriendIdle: PhoneIdleTimer { var disabled = false }
@MainActor private final class FriendBrightness: PhoneScreenBrightness { var value = 0.4 }
@MainActor
final class FriendPlaybackTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let sessionID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private func session(_ kind: FriendInteractionKind = .greeting, direction: String = "outgoing") -> NativeFriendSession {
        NativeFriendSession(id: sessionID, revision: 2, durationSeconds: 300, kind: kind, direction: direction,
            status: "active", expiresAtISO: "2026-11-06T12:05:00Z", serverTimeISO: "2026-11-06T12:00:00Z",
            peer: SocialPerson(id: peer, displayName: "Synthetic accepted friend"),
            ownedByCurrentSession: true, coordinatesIncluded: false, physicalProximityVerified: false,
            playbackStarted: false, automaticGifExchangeEnabled: false, clockSynchronizationVerified: false, historyStored: false)
    }
    private func gif() -> Data {
        Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,0,0,0,255,255,255,
            33,249,4,0,238,46,0,0,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
    }
    private func phone() -> PhoneDisplayController {
        let value = PhoneDisplayController(idleTimer: FriendIdle(), brightness: FriendBrightness())
        value.setForeground(true); value.setVisible(true); return value
    }
    private func token(_ n: UInt8) -> String { PhoneSwapWire.b64(Data(repeating: n, count: 32)) }
    private func identity() throws -> NativeFriendPeerIdentity {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        return NativeFriendPeerIdentity(sessionId: sessionID, sessionRevision: 2, identityRevision: 2,
            ownPublicKey: PhoneSwapWire.b64(key.publicKey.rawRepresentation), peerPublicKey: nil,
            ownTokenHash: NativeFriendPeerIdentity.tokenHash(token(3)), peerTokenHash: nil,
            ownTokenExpiresAtISO: "2026-11-06T12:02:00Z", peerTokenExpiresAtISO: nil,
            expiresAtISO: "2026-11-06T12:05:00Z", serverTimeISO: "2026-11-06T12:00:00Z",
            ownedByCurrentSession: true, coordinatesIncluded: false, physicalProximityVerified: false,
            playbackStarted: false, historyStored: false, advertisementToken: token(3))
    }
    private func ciphers(domain: String = "led.accepted-friend.v2", binding: [String] = ["accepted-session","revision2","identity2","greeting","aurora-soft"]) throws -> (PhoneSwapCipher, PhoneSwapCipher) {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let b = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let first = PhoneSwapContact(id: owner, displayName: "", canRequestFriendship: false, publicKey: PhoneSwapWire.b64(a.publicKey.rawRepresentation), token: token(3), tokenExpiresAtISO: "2026-11-06T12:02:00Z")
        let second = PhoneSwapContact(id: peer, displayName: "", canRequestFriendship: false, publicKey: PhoneSwapWire.b64(b.publicKey.rawRepresentation), token: token(4), tokenExpiresAtISO: "2026-11-06T12:02:00Z")
        let hello = PhoneSwapWire.Hello(version: PhoneSwapWire.version, sessionID: sessionID, initiatorToken: first.token, responderToken: second.token, nonce: token(5), response: false)
        let response = PhoneSwapWire.Hello(version: PhoneSwapWire.version, sessionID: sessionID, initiatorToken: first.token, responderToken: second.token, nonce: token(6), response: true)
        return (try PhoneSwapCipher(privateKey: a, initiator: first, responder: second, first: hello, second: response,
            origin: "https://catalog.example", isInitiator: true, domain: domain, binding: binding),
            try PhoneSwapCipher(privateKey: b, initiator: first, responder: second, first: hello, second: response,
                origin: "https://catalog.example", isInitiator: false, domain: domain, binding: binding))
    }
    private func repository() throws -> (SwapRecoveryRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("friend-scene-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (SwapRecoveryRepository(root: root), root)
    }
    private func prepared(_ store: SwapRecoveryRepository, revision: UUID) async throws -> LocalSwapOriginal {
        let snapshot = PhoneDisplaySnapshot(data: gif(), mediaID: nil, elapsed: 0, wantsPlayback: false, motionOverride: false, keepAwake: false)
        return try await store.prepareGame(snapshot: snapshot, artworkRevision: revision, ownerScope: "fixture-owner",
            attribution: nil, purpose: "friend-v1:" + sessionID.uuidString.lowercased())
    }
    func testPaletteRendererProducesBoundedRealPixelsAndCentisecondTiming() throws {
        let frames = FriendInteractionPixels.frames(kind: .palette, preset: .aurora, sender: true)
        XCTAssertEqual(frames.count, 24); XCTAssertEqual(frames[0].rgb.count, 16 * 16 * 3)
        XCTAssertNotEqual(frames[0], frames[6])
        let encoded = try FriendInteractionPixels.render(kind: .palette, preset: .aurora, sender: true, chosen: gif(), received: nil)
        let info = try GIFStructure.inspect(encoded); XCTAssertEqual(info.frames.count, 24)
        XCTAssertTrue(info.frames.allSatisfy { abs($0.previewDelay - 0.1) < 0.001 })
    }
    func testDuetRendersComplementaryRolesRatherThanIdenticalWholeScenes() {
        let left = FriendInteractionPixels.frames(kind: .duet, preset: .sunset, sender: true)
        let right = FriendInteractionPixels.frames(kind: .duet, preset: .sunset, sender: false)
        XCTAssertEqual(left.count, right.count); XCTAssertNotEqual(left, right)
        XCTAssertTrue(left.allSatisfy { $0.exactLiveColors && $0.size == PanelSize(width: 16, height: 16) })
    }
    func testGreetingKeepsExactChosenBytesIncludingLongTimingAndNoRepair() throws {
        let source = gif()
        XCTAssertEqual(try FriendInteractionPixels.render(kind: .greeting, preset: .aurora, sender: false, chosen: source, received: Data([1])), source)
        XCTAssertGreaterThan(try GIFStructure.inspect(source).frames[0].previewDelay, 10)
    }
    func testPassStripsPrivateMetadataOnlyInSeparateOutgoingCandidate() throws {
        var source = gif(); source.insert(contentsOf: [33,254,3,97,98,99,0], at: 19)
        let preserved = source
        let candidate = try FriendInteractionPixels.render(kind: .pass, preset: .aurora, sender: true, chosen: source, received: nil)
        XCTAssertEqual(source, preserved); XCTAssertEqual(candidate, gif())
        XCTAssertThrowsError(try FriendInteractionPixels.render(kind: .pass, preset: .aurora, sender: true, chosen: Data(repeating: 0, count: 131073), received: nil))
    }
    func testRecipientCannotPretendOfflineRemotePassOrExfiltrateOwnStill() throws {
        XCTAssertThrowsError(try FriendInteractionPixels.render(kind: .pass, preset: .aurora, sender: false, chosen: gif(), received: nil))
        XCTAssertEqual(try FriendInteractionPixels.render(kind: .pass, preset: .aurora, sender: false, chosen: Data([1]), received: gif()), gif())
    }
    func testAuthenticatedClockEstimateUsesMonotonicOffsetAndExplicitError() throws {
        let estimate = try FriendClockEstimate(t0: 100, t1: 120.05, t2: 120.06, t3: 100.11)
        XCTAssertEqual(estimate.offset, 20, accuracy: 0.0001)
        XCTAssertEqual(estimate.roundTrip, 0.1, accuracy: 0.0001)
        XCTAssertEqual(estimate.uncertainty, 0.1, accuracy: 0.0001)
    }
    func testClockRejectsNonfiniteNegativeAndBackwardsSamples() {
        for sample in [[Double.nan,1,2,3],[-1,1,2,3],[3,1,2,1],[1,3,2,4]] {
            XCTAssertThrowsError(try FriendClockEstimate(t0: sample[0], t1: sample[1], t2: sample[2], t3: sample[3]))
        }
    }
    func testClockRejectsExcessiveRoundTripInsteadOfClaimingVerifiedSync() {
        XCTAssertThrowsError(try FriendClockEstimate(t0: 100, t1: 120.1, t2: 120.1, t3: 101))
    }
    func testFriendPurposeCipherRoundTripProvesMatchingEphemeralKeyPossession() throws {
        var (a,b) = try ciphers()
        XCTAssertEqual(a.transcriptHash, b.transcriptHash)
        let outer = try a.seal(PhoneSwapWire.Message(kind: "friend-agreement", interaction: "greeting", preset: "aurora-soft", role: "session-sender", mediaConsent: true))
        XCTAssertEqual(try b.open(outer).kind, "friend-agreement")
        let ready = try a.seal(PhoneSwapWire.Message(kind: "ready", hash: "complete-payload", sceneReady: true))
        XCTAssertEqual(try b.open(ready).sceneReady, true)
    }
    func testGamePurposeCannotAuthenticateAcceptedFriendTraffic() throws {
        var (a,_) = try ciphers()
        var (_,game) = try ciphers(domain: "led.phone-swap.v2", binding: [])
        XCTAssertThrowsError(try game.open(a.seal(PhoneSwapWire.Message(kind: "proof"))))
        XCTAssertThrowsError(try ciphers(binding: []))
    }
    func testKindPresetRevisionAndRolesAreAuthenticatedNotSessionIDSecrets() throws {
        for different in [["other-session"],["revision3"],["identity3"],["duet"],["sunset-soft"],["wrong-role"]] {
            var (a,_) = try ciphers()
            var (_,b) = try ciphers(binding: different)
            XCTAssertThrowsError(try b.open(a.seal(PhoneSwapWire.Message(kind: "proof"))))
        }
    }
    func testEncryptedFriendMessageReplayCannotAdvanceReadiness() throws {
        var (a,b) = try ciphers()
        let message = try a.seal(PhoneSwapWire.Message(kind: "ready", hash: "fixture"))
        _ = try b.open(message); XCTAssertThrowsError(try b.open(message))
    }
    func testIdentityHashesOpaqueUTF8TokenStringNotDecodedBytes() throws {
        let value = try identity(); try value.validate(session: session())
        XCTAssertNotEqual(value.ownTokenHash, LocalSwapOriginal.digest(try PhoneSwapWire.bytes(token(3))))
        XCTAssertEqual(value.ownTokenHash, LocalSwapOriginal.digest(Data(token(3).utf8)))
    }
    func testIdentityRejectsWrongSessionRevisionLoginAndExpiredHint() throws {
        let value = try identity()
        let object: [String: Any] = ["sessionId":sessionID.uuidString,"sessionRevision":2,"identityRevision":2,"ownPublicKey":value.ownPublicKey!,
            "ownTokenHash":value.ownTokenHash!,"ownTokenExpiresAtISO":"2026-11-06T12:02:00Z","expiresAtISO":session().expiresAtISO,
            "serverTimeISO":"2026-11-06T12:00:00Z","ownedByCurrentSession":true,"coordinatesIncluded":false,
            "physicalProximityVerified":false,"playbackStarted":false,"historyStored":false]
        let changes: [(String, Any)] = [("sessionId",UUID().uuidString),("sessionRevision",3),("ownedByCurrentSession",false),("ownTokenExpiresAtISO","2026-11-06T11:59:00Z"),("historyStored",true)]
        for (field, invalid) in changes {
            var wrong = object; wrong[field] = invalid
            let decoded = try JSONDecoder().decode(NativeFriendPeerIdentity.self, from: JSONSerialization.data(withJSONObject: wrong))
            XCTAssertThrowsError(try decoded.validate(session: session()))
        }
    }
    func testControlAcceptanceDoesNotReplaceBilateralMediaPresetRoleConsent() async throws {
        let display = phone(); try await display.show(gif())
        XCTAssertThrowsError(try AcceptedFriendAuthority(session: session(), preset: .aurora, consent: false, phone: display, account: owner, attribution: nil))
        let intent = try AcceptedFriendAuthority(session: session(), preset: .aurora, consent: true, phone: display, account: owner, attribution: nil)
        let peerIntent = PhoneSwapWire.Message(kind: "friend-agreement", interaction: "greeting", preset: "aurora-soft", role: "session-recipient", mediaConsent: true)
        XCTAssertNoThrow(try intent.checkAgreement(peerIntent))
        var wrong = peerIntent; wrong.mediaConsent = false; XCTAssertThrowsError(try intent.checkAgreement(wrong))
        wrong = peerIntent; wrong.role = "session-sender"; XCTAssertThrowsError(try intent.checkAgreement(wrong))
        wrong = peerIntent; wrong.preset = "unknown"; XCTAssertThrowsError(try intent.checkAgreement(wrong))
        intent.eraseKey(); XCTAssertThrowsError(try intent.key())
    }
    func testFriendOriginalSurvivesRestartWithPurposeAssociation() async throws {
        let (store,root) = try repository(), revision = UUID()
        let original = try await prepared(store, revision: revision)
        let reopened = try await SwapRecoveryRepository(root: root).load()
        XCTAssertEqual(reopened?.phone.data, original.phone.data); XCTAssertEqual(reopened?.peerPurpose, "friend-v1:" + sessionID.uuidString.lowercased())
    }
    func testFriendStageRequiresBothExplicitConsentsAndBothReadyNotGameFlags() async throws {
        let (store,_) = try repository(), revision = UUID(), now = Date()
        _ = try await prepared(store, revision: revision)
        for (own,peer,ready) in [(false,true,true),(true,false,true),(true,true,false)] {
            do {
                _ = try await store.stageAcceptedFriendScene(sessionID: sessionID, ownConsent: own, peerConsent: peer, bothReady: ready,
                    ownerScope: "fixture-owner", expectedRevision: revision, nextRevision: UUID(), scene: gif(), expiresAt: now.addingTimeInterval(60), now: now)
                XCTFail("No consent/readiness inference")
            } catch {}
        }
        let retained = try await store.load(); XCTAssertEqual(retained?.stage, .prepared)
    }
    func testWrongFriendSessionAccountOrNewManualSelectionCannotStage() async throws {
        let (store,_) = try repository(), revision = UUID(), now = Date()
        _ = try await prepared(store, revision: revision)
        for (id,scope,expected) in [(UUID(),"fixture-owner",revision),(sessionID,"foreign-owner",revision),(sessionID,"fixture-owner",UUID())] {
            do {
                _ = try await store.stageAcceptedFriendScene(sessionID: id, ownConsent: true, peerConsent: true, bothReady: true,
                    ownerScope: scope, expectedRevision: expected, nextRevision: UUID(), scene: gif(), expiresAt: now.addingTimeInterval(60), now: now)
                XCTFail("Wrong binding")
            } catch {}
        }
    }
    func testRepeatedFriendSceneStagingRetainsInitialExactOriginal() async throws {
        let (store,_) = try repository(), revision = UUID(), next = UUID(), now = Date()
        let original = try await prepared(store, revision: revision)
        _ = try await store.stageAcceptedFriendScene(sessionID: sessionID, ownConsent: true, peerConsent: true, bothReady: true,
            ownerScope: "fixture-owner", expectedRevision: revision, nextRevision: next, scene: AcceptedFriendAuthority.controlMarker, expiresAt: now.addingTimeInterval(120), now: now)
        let repeated = try await store.stageAcceptedFriendScene(sessionID: sessionID, ownConsent: true, peerConsent: true, bothReady: true,
            ownerScope: "fixture-owner", expectedRevision: next, nextRevision: UUID(), scene: gif(), expiresAt: now.addingTimeInterval(120), now: now.addingTimeInterval(61))
        XCTAssertEqual(repeated.transactionID, original.transactionID); XCTAssertEqual(repeated.phone.data, original.phone.data)
    }
    func testCancelPreventsSceneAndRetainsOnlyRecoveryCopy() async throws {
        let (store,root) = try repository(), revision = UUID(), now = Date()
        let original = try await prepared(store, revision: revision)
        _ = try await store.cancelReadiness(id: original.transactionID, ownerScope: "fixture-owner")
        do {
            _ = try await store.stageAcceptedFriendScene(sessionID: sessionID, ownConsent: true, peerConsent: true, bothReady: true,
                ownerScope: "fixture-owner", expectedRevision: revision, nextRevision: UUID(), scene: gif(), expiresAt: now.addingTimeInterval(60), now: now)
            XCTFail("Cancelled")
        } catch {}
        let retained = try await SwapRecoveryRepository(root: root).load(); XCTAssertEqual(retained?.phone.data, gif())
    }
    func testActualPhoneHandoffRespectsMotionDataSavingAndSourceBytes() async throws {
        let display = phone(); try await display.show(gif())
        display.setDataSaving(true)
        try await display.applyValidatedGameGIF(gif(), expectedRevision: display.artworkRevision, nextRevision: UUID(),
            explicitlyArmedPlayback: true, handoffSender: true)
        XCTAssertFalse(display.isPlaying); XCTAssertNil(display.peerHandoff); XCTAssertEqual(display.data, gif())
        let left = PhonePeerHandoff(startUptime: 100, sender: true), right = PhonePeerHandoff(startUptime: 100, sender: false)
        for time in [100.0,101.99,102,103.99,104] { XCTAssertNotEqual(left.visible(at: time), right.visible(at: time)) }
        XCTAssertFalse(left.visible(at: 99))
    }
    func testPhoneControllerLeaseExcludesGameFriendAndHardwareTargets() throws {
        let targets = DisplayTargetSelection(), first = UUID(), other = UUID()
        targets.target = .phone; try targets.acquirePhone(first)
        XCTAssertThrowsError(try targets.acquirePhone(other))
        targets.releasePhone(other); XCTAssertEqual(targets.phonePeerOwner, first)
        targets.releasePhone(first); try targets.acquirePhone(other)
        targets.releasePhone(other); targets.target = .hardware
        XCTAssertThrowsError(try targets.acquirePhone(first))
    }
    func testLateContextAndNewSelectionRejectScheduledPhoneReplacement() async throws {
        let display = phone(); try await display.show(gif())
        let old = display.artworkRevision
        try await display.show(AcceptedFriendAuthority.controlMarker)
        do { try await display.applyValidatedGameGIF(gif(), expectedRevision: old, nextRevision: UUID()); XCTFail("Newer selection") } catch {}
        do {
            try await display.applyValidatedGameGIF(gif(), expectedRevision: display.artworkRevision, nextRevision: UUID(),
                validateContext: { throw CancellationError() })
            XCTFail("Late context")
        } catch {}
        XCTAssertEqual(display.data, AcceptedFriendAuthority.controlMarker)
    }
    func testFriendMarkersCreateNoReceivedCopiesOrNotFriendsMetCards() async throws {
        let (recovery,root) = try repository(), revision = UUID(), now = Date()
        _ = try await prepared(recovery, revision: revision)
        let local = PhoneSwapLocalStore(root: root, recovery: recovery)
        let next = UUID()
        _ = try await local.stageFriendScene(scene: gif(), receivedGIF: nil, exchangeID: UUID(),
            credit: PhoneSwapWire.Credit(nil).attribution(), sessionID: sessionID, ownConsent: true, peerConsent: true,
            bothReady: true, scope: "fixture-owner", expectedRevision: revision, nextRevision: next,
            expiresAt: now.addingTimeInterval(60), now: now)
        let received = try await recovery.received(), cards = try await local.cards(scope: "fixture-owner")
        XCTAssertTrue(received.isEmpty); XCTAssertTrue(cards.isEmpty)
        _ = try await local.stageFriendScene(scene: gif(), receivedGIF: gif(), exchangeID: UUID(),
            credit: PhoneSwapWire.Credit(nil).attribution(), sessionID: sessionID, ownConsent: true, peerConsent: true,
            bothReady: true, scope: "fixture-owner", expectedRevision: next, nextRevision: UUID(),
            expiresAt: now.addingTimeInterval(120), now: now.addingTimeInterval(61))
        let actualPass = try await recovery.received(), stillNoCards = try await local.cards(scope: "fixture-owner")
        XCTAssertEqual(actualPass.count, 1); XCTAssertEqual(actualPass.first?.data, gif()); XCTAssertTrue(stillNoCards.isEmpty)
    }
}
