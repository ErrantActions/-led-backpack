import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor private final class AutomaticIdle: PhoneIdleTimer { var disabled = false }
@MainActor private final class AutomaticBrightness: PhoneScreenBrightness { var value = 0.4 }
@MainActor
final class AutomaticPhoneSessionTests: XCTestCase {
    private func gif(_ color: UInt8 = 0) -> Data {
        Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,color,0,0,255,255,255,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
    }
    private func setup() async throws -> (AutomaticPhoneSession, PhoneDisplayController, DisplayTargetSelection, SwapRecoveryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-phone-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = SwapRecoveryRepository(root: root), phone = PhoneDisplayController(idleTimer: AutomaticIdle(), brightness: AutomaticBrightness())
        phone.setForeground(true); phone.setVisible(true); try await phone.show(gif(1))
        let targets = DisplayTargetSelection(), session = AutomaticPhoneSession(repository: repository)
        session.bind(phone: phone, targets: targets)
        return (session, phone, targets, repository)
    }
    func testSessionCapturesRealOriginalBeforeAnyReplacement() async throws {
        let (session, phone, _, repository) = try await setup(), original = phone.data
        try await session.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {})
        let saved = try await repository.load()
        XCTAssertTrue(session.running); XCTAssertEqual(saved?.phone.data, original)
        XCTAssertEqual(saved?.stage, .prepared); XCTAssertTrue(saved?.peerPurpose?.hasPrefix("phone-session-v1:") == true)
    }
    func testRepeatedAppliedScenesRetainInitialOriginalAndFreshAuthorization() async throws {
        let (session, phone, _, repository) = try await setup()
        try await session.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {})
        var authorizations = 0
        try await session.apply(gif(2), title: "First") { authorizations += 1 }
        try await session.apply(gif(3), title: "Second") { authorizations += 1 }
        let saved = try await repository.load()
        XCTAssertEqual(authorizations, 4); XCTAssertEqual(phone.data, gif(3))
        XCTAssertEqual(saved?.phone.data, gif(1))
    }
    func testLateAuthorizationFailureAfterDecodeDoesNotApplyBytes() async throws {
        let (session, phone, _, repository) = try await setup()
        try await session.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {})
        var count = 0
        do {
            try await session.apply(gif(2), title: "Forbidden") {
                count += 1; if count == 2 { throw CancellationError() }
            }
            XCTFail("Post-decode authorization is mandatory")
        } catch {}
        XCTAssertEqual(count, 2); XCTAssertEqual(phone.data, gif(1))
        let retained = try await repository.load(); XCTAssertEqual(retained?.phone.data, gif(1))
    }
    func testNewManualSelectionCannotBeReplacedByOlderAutomaticOwner() async throws {
        let (session, phone, _, _) = try await setup()
        try await session.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {})
        try await phone.show(gif(3))
        do { try await session.apply(gif(2), title: "Stale", verify: {}); XCTFail("New manual selection") } catch {}
        XCTAssertEqual(phone.data, gif(3))
    }
    func testPhoneLeaseExcludesSecondControllerWithoutReplacingJournal() async throws {
        let (first, phone, targets, repository) = try await setup()
        try await first.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {})
        let original = try await repository.load()
        let second = AutomaticPhoneSession(repository: repository); second.bind(phone: phone, targets: targets)
        do { try await second.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {}); XCTFail("One owner") } catch {}
        let retained = try await repository.load(); XCTAssertEqual(original?.transactionID, retained?.transactionID)
    }
    func testRestoreAcknowledgesExactInitialBytesWithoutDeletingRecoveryCopy() async throws {
        let (session, phone, _, repository) = try await setup()
        try await session.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {})
        try await session.apply(gif(2), title: "Replacement", verify: {})
        await session.restore()
        let saved = try await repository.load()
        XCTAssertEqual(phone.data, gif(1)); XCTAssertEqual(saved?.stage, .restored)
        XCTAssertEqual(saved?.phone.data, gif(1)); XCTAssertFalse(session.hasRecovery)
    }
    func testChangedOwnerScopeCannotRestoreAnotherAccountsSnapshot() async throws {
        let (session, phone, _, _) = try await setup()
        var current = "first"
        try await session.begin(id: UUID(), scope: current, currentScope: { current }, authorize: {})
        try await session.apply(gif(2), title: "Replacement", verify: {})
        current = "different"
        await session.restore()
        XCTAssertEqual(phone.data, gif(2)); XCTAssertNotNil(session.failure)
    }
    func testHardwareTargetNeverCreatesAutomaticPhoneJournal() async throws {
        let (session, _, targets, repository) = try await setup()
        targets.target = .hardware
        do { try await session.begin(id: UUID(), scope: "fixture-owner", currentScope: { "fixture-owner" }, authorize: {}); XCTFail("PHONE only") } catch {}
        let saved = try await repository.load(); XCTAssertNil(saved); XCTAssertFalse(session.running)
    }
}
