import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class RecoveryPhoneIdle: PhoneIdleTimer { var disabled = false }
@MainActor
private final class RecoveryPhoneBrightness: PhoneScreenBrightness { var value = 0.41 }
@MainActor
final class SwapRecoveryTests: XCTestCase {
    private let scope = "owner-local-no-account"
    private func gif(_ color: UInt8 = 0) -> Data {
        Data(Array("GIF89a".utf8) + [1,0,1,0,0x80,0,0,color,0,0,255,255,255,
            0x21,0xF9,4,0,1,0,0,0,0x2C,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0,0x3B])
    }
    private func repository() throws -> (SwapRecoveryRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swap-recovery-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (SwapRecoveryRepository(root: root), root)
    }
    private func snapshot(_ data: Data? = nil) -> PhoneDisplaySnapshot {
        PhoneDisplaySnapshot(data: data ?? gif(), mediaID: UUID(), elapsed: 0, wantsPlayback: false,
            motionOverride: false, keepAwake: true, brightnessEnabled: false, brightnessLevel: 0.41,
            animationsEnabled: true, dataSaving: false, crispPixels: true, pixelGrid: true)
    }
    private func prepare(_ store: SwapRecoveryRepository, data: Data? = nil) async throws -> LocalSwapOriginal {
        try await store.prepare(snapshot: snapshot(data), frame: 0, artworkRevision: UUID(), ownerScope: scope,
            target: .phone, hardwareArtwork: nil, attribution: nil)
    }
    func testAtomicOriginalIsReadableAfterRestartBeforeAnyReplacement() async throws {
        let (store, root) = try repository(), original = gif()
        let value = try await prepare(store, data: original)
        let reopened = SwapRecoveryRepository(root: root), retained = try await reopened.load()
        XCTAssertEqual(retained?.transactionID, value.transactionID)
        XCTAssertEqual(retained?.phone.data, original); XCTAssertEqual(retained?.originalFrame, 0)
        XCTAssertEqual(retained?.stage, .prepared); XCTAssertTrue(retained?.needsRecovery == true)
        XCTAssertEqual(retained?.phone.pixelGrid, true)
    }
    func testOnlyOneActiveTransactionAndCancellationNeverRemovesOriginal() async throws {
        let (store, _) = try repository()
        let first = try await prepare(store)
        do { _ = try await prepare(store, data: gif(17)); XCTFail("One active transaction") } catch {}
        let cancelled = try await store.cancelReadiness(id: first.transactionID, ownerScope: scope)
        XCTAssertEqual(cancelled.stage, .recoveryRequired); XCTAssertEqual(cancelled.phone.data, first.phone.data)
        let persisted = try await store.load(); XCTAssertEqual(persisted?.transactionID, first.transactionID)
    }
    func testWrongAccountInstallationOrTargetCannotRestoreOriginalElsewhere() async throws {
        let (store, _) = try repository(), value = try await prepare(store)
        XCTAssertThrowsError(try value.validate(installation: UUID(), ownerScope: scope, target: .phone))
        do { _ = try await store.beginRestore(id: value.transactionID, ownerScope: "different-account", target: .phone); XCTFail("Wrong account") } catch {}
        do { _ = try await store.beginRestore(id: value.transactionID, ownerScope: scope, target: .hardware); XCTFail("Wrong target") } catch {}
        let retained = try await store.load(); XCTAssertEqual(retained?.phone.data, value.phone.data)
    }
    func testTruncatedCorruptJournalIsRejectedNotResetOrOverwritten() async throws {
        let (store, root) = try repository()
        _ = try await prepare(store)
        let file = root.appendingPathComponent("active.json")
        try Data(#"{"schema":1,"payload":"broken"#.utf8).write(to: file)
        do { _ = try await store.load(); XCTFail("Truncated journal") } catch {}
        do { _ = try await prepare(store); XCTFail("Do not overwrite corrupt original") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data(#"{"schema":1,"payload":"broken"#.utf8))
    }
    func testMissingInstallationIdentityCannotAdoptExistingRecovery() async throws {
        let (store, root) = try repository()
        _ = try await prepare(store)
        try FileManager.default.removeItem(at: root.appendingPathComponent("installation.json"))
        do { _ = try await SwapRecoveryRepository(root: root).load(); XCTFail("Wrong/new installation") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active.json").path))
    }
    func testRestartDuringRestoreKeepsRecoverableCopyUntilCorrectAcknowledgment() async throws {
        let (store, root) = try repository(), original = try await prepare(store)
        _ = try await store.beginRestore(id: original.transactionID, ownerScope: scope, target: .phone)
        let reopened = SwapRecoveryRepository(root: root), pending = try await reopened.load()
        XCTAssertEqual(pending?.stage, .restoring); XCTAssertEqual(pending?.phone.data, original.phone.data)
        do { _ = try await reopened.acknowledgeRestore(id: original.transactionID, originalSHA256: "wrong", ownerScope: scope); XCTFail("Wrong acknowledgment") } catch {}
        let result = try await reopened.acknowledgeRestore(id: original.transactionID, originalSHA256: original.originalSHA256, ownerScope: scope)
        XCTAssertEqual(result.stage, .restored); XCTAssertEqual(result.phone.data, original.phone.data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("active.json").path))
        do { _ = try await prepare(reopened); XCTFail("Persisted cooldown") } catch {}
    }
    func testHardwareDescriptorOrPointerNeverEnablesPreparation() async throws {
        let (store, _) = try repository()
        do {
            _ = try await store.prepare(snapshot: snapshot(), frame: 0, artworkRevision: UUID(), ownerScope: scope,
                target: .hardware, hardwareArtwork: UUID(), attribution: nil)
            XCTFail("Hardware recovery is unsupported")
        } catch {}
        let empty = PhoneDisplaySnapshot(data: nil, mediaID: nil, elapsed: 0, wantsPlayback: false, motionOverride: false, keepAwake: false)
        do { _ = try await store.prepare(snapshot: empty, frame: 0, artworkRevision: UUID(), ownerScope: scope, target: .phone, hardwareArtwork: nil, attribution: nil); XCTFail("No original bytes") } catch {}
    }
    func testSessionAndBothPeersGameReadinessAreRequiredIndependently() async throws {
        let (store, _) = try repository(), original = try await prepare(store), session = UUID(), account = UUID(), now = Date()
        var readiness = SwapPeerReadiness(transactionID: original.transactionID, sessionID: session, accountEpoch: account,
            expiresAt: now.addingTimeInterval(60))
        func check(_ readiness: SwapPeerReadiness) throws {
            try readiness.requireApply(journal: original, installation: original.installationID, ownerScope: scope,
                session: session, account: account, incoming: gif(42), now: now)
        }
        XCTAssertThrowsError(try check(readiness))
        readiness.gameEnabled = true; readiness.ownReady = true; readiness.peerGameEnabled = true
        XCTAssertThrowsError(try check(readiness))
        readiness.peerReady = true; XCTAssertNoThrow(try check(readiness))
        try await store.validateIncomingForFuturePhoneReplacement(readiness: readiness, session: session, accountEpoch: account,
            ownerScope: scope, target: .phone, incoming: gif(42), now: now)
        readiness.cancelled = true; XCTAssertThrowsError(try check(readiness))
    }
    func testExpiredWrongSessionOrIncompleteIncomingCannotApply() async throws {
        let (store, _) = try repository(), original = try await prepare(store), session = UUID(), account = UUID(), now = Date()
        var ready = SwapPeerReadiness(transactionID: original.transactionID, sessionID: session, accountEpoch: account,
            expiresAt: now.addingTimeInterval(10))
        ready.gameEnabled = true; ready.ownReady = true; ready.peerGameEnabled = true; ready.peerReady = true
        XCTAssertThrowsError(try ready.requireApply(journal: original, installation: original.installationID, ownerScope: scope,
            session: UUID(), account: account, incoming: gif(), now: now))
        XCTAssertThrowsError(try ready.requireApply(journal: original, installation: original.installationID, ownerScope: scope,
            session: session, account: account, incoming: gif(), now: now.addingTimeInterval(10)))
        XCTAssertThrowsError(try ready.requireApply(journal: original, installation: original.installationID, ownerScope: scope,
            session: session, account: account, incoming: Data("GIF89a".utf8), now: now))
    }
    func testReceivedReceiptsDeduplicateOnlyTheirTransactionNotPrivateContent() async throws {
        let (store, _) = try repository(), data = gif(), transaction = UUID()
        let first = try await store.retainReceived(data: data, transactionID: transaction, name: "Original", attribution: nil)
        let receipt = try await store.retainReceived(data: data, transactionID: transaction, name: "Original", attribution: nil)
        XCTAssertEqual(receipt.id, first.id)
        let independent = try await store.retainReceived(data: data, transactionID: UUID(), name: "Independent", attribution: nil)
        XCTAssertNotEqual(independent.id, first.id)
        do { _ = try await store.retainReceived(data: gif(14), transactionID: transaction, name: "Conflict", attribution: nil); XCTFail("Changed local transaction") } catch {}
        let rows = try await store.received(); XCTAssertEqual(rows.count, 2)
    }
    func testReceivedCopyRetainsAttributionAndRemovalNeverDeletesRecovery() async throws {
        let (store, _) = try repository(), original = try await prepare(store)
        let attribution = Attribution(source: "Local synthetic source", author: "Fixture", license: "CC0", licenseURL: "")
        let item = try await store.retainReceived(data: gif(12), transactionID: UUID(), name: "../peer-path-is-only-a-label", attribution: attribution)
        XCTAssertEqual(item.attribution, attribution); XCTAssertFalse(item.transportVerified)
        try await store.removeReceived(item.id)
        let journal = try await store.load(), rows = try await store.received()
        XCTAssertEqual(journal?.phone.data, original.phone.data); XCTAssertTrue(rows.isEmpty)
    }
    func testFrameAndIntegrityMismatchFailBeforeRestoreAndKeepCurrentPhoneArtwork() async throws {
        let (store, _) = try repository(), original = try await prepare(store)
        var corrupt = original
        corrupt.replacementSHA256 = "arbitrary replacement label"
        // A purported incoming label grants no way to change the immutable original.
        XCTAssertEqual(corrupt.originalSHA256, original.originalSHA256)
        let phone = PhoneDisplayController(idleTimer: RecoveryPhoneIdle(), brightness: RecoveryPhoneBrightness())
        phone.setForeground(true); phone.open(); phone.setVisible(true)
        let current = gif(85); try await phone.show(current)
        let invalid = PhoneDisplaySnapshot(data: Data("corrupt".utf8), mediaID: nil, elapsed: 0, wantsPlayback: false, motionOverride: false, keepAwake: false)
        do { try await phone.restore(invalid); XCTFail("Corrupt restore") } catch {}
        XCTAssertEqual(phone.data, current)
        var animation = Data(gif().dropLast())
        animation.append(contentsOf: [0x21,0xF9,4,0,20,0,0,0,0x2C,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0,0x3B])
        var paused = snapshot(animation)
        paused = PhoneDisplaySnapshot(data: animation, mediaID: paused.mediaID, elapsed: 0.02, wantsPlayback: false, motionOverride: false, keepAwake: false)
        XCTAssertEqual(try LocalSwapOriginal.frameIndex(paused), 1)
        let (other, _) = try repository()
        do {
            _ = try await other.prepare(snapshot: paused, frame: 0, artworkRevision: UUID(), ownerScope: scope, target: .phone, hardwareArtwork: nil, attribution: nil)
            XCTFail("Frame mismatch")
        } catch {}
        let value = try await other.prepare(snapshot: paused, frame: nil, artworkRevision: UUID(), ownerScope: scope, target: .phone, hardwareArtwork: nil, attribution: nil)
        XCTAssertEqual(value.originalFrame, 1)
    }
    func testActualPhoneRestoreUsesRetainedOriginalAndAcknowledgesWithoutHardwareAccess() async throws {
        let (repository, _) = try repository()
        let store = SwapRecoveryStore(repository: repository)
        let phone = PhoneDisplayController(idleTimer: RecoveryPhoneIdle(), brightness: RecoveryPhoneBrightness())
        phone.setForeground(true); phone.open(); phone.setVisible(true)
        let original = gif(31)
        try await phone.show(original)
        phone.pixelGrid = true
        let targets = DisplayTargetSelection()
        let community = CommunityController()
        await store.prepare(phone: phone, targets: targets, community: community, attribution: nil)
        let transaction = store.journal?.transactionID
        try await phone.show(gif(62))
        await store.restore(phone: phone, targets: targets, community: community)
        XCTAssertEqual(phone.data, original); XCTAssertTrue(phone.pixelGrid)
        XCTAssertEqual(store.journal?.transactionID, transaction); XCTAssertEqual(store.journal?.stage, .restored)
        let retained = try await repository.load(); XCTAssertEqual(retained?.phone.data, original)
    }
    func testTargetSwitchCannotRestorePhoneSnapshotToHardware() async throws {
        let (repository, _) = try repository(), store = SwapRecoveryStore(repository: repository)
        let phone = PhoneDisplayController(idleTimer: RecoveryPhoneIdle(), brightness: RecoveryPhoneBrightness())
        phone.setForeground(true); phone.open(); phone.setVisible(true)
        let original = gif(31); try await phone.show(original)
        let targets = DisplayTargetSelection(), community = CommunityController()
        await store.prepare(phone: phone, targets: targets, community: community, attribution: nil)
        targets.target = .hardware
        await store.restore(phone: phone, targets: targets, community: community)
        XCTAssertEqual(phone.data, original); XCTAssertNotNil(store.failure)
        let retained = try await repository.load(); XCTAssertEqual(retained?.stage, .prepared)
    }
}
