import XCTest
@testable import LEDBackpack

final class ScopedActionConfirmationTests: XCTestCase {
    private struct Scope: Equatable {
        var target = UUID()
        var account = UUID()
        var revision = 1
        var action = "delete"
        var authorized = true
    }

    func testDefaultOffAndToggleNeverPerformsFinalAction() {
        var approval = ScopedActionConfirmation<Scope>()
        let scope = Scope()
        XCTAssertFalse(approval.isConfirmed(for: scope))
        XCTAssertFalse(approval.consume(for: scope))
        approval.setConfirmed(true, for: scope)
        XCTAssertTrue(approval.isConfirmed(for: scope))
        // Only the explicit final action consumes the approval.
        XCTAssertTrue(approval.consume(for: scope))
        XCTAssertFalse(approval.isConfirmed(for: scope))
        XCTAssertFalse(approval.consume(for: scope))
    }

    func testEveryCapturedScopeChangeRejectsSubmission() {
        let original = Scope()
        var changes: [Scope] = []
        var changed = original; changed.target = UUID(); changes.append(changed)
        changed = original; changed.account = UUID(); changes.append(changed)
        changed = original; changed.revision += 1; changes.append(changed)
        changed = original; changed.action = "quarantine"; changes.append(changed)
        changed = original; changed.authorized = false; changes.append(changed)
        for scope in changes {
            var approval = ScopedActionConfirmation<Scope>()
            approval.setConfirmed(true, for: original)
            XCTAssertFalse(approval.isConfirmed(for: scope))
            XCTAssertFalse(approval.consume(for: scope))
            XCTAssertFalse(approval.isConfirmed(for: original))
        }
    }

    func testTurningOffLeavingAndRetryRequireNewApproval() {
        let scope = Scope()
        var approval = ScopedActionConfirmation<Scope>()
        approval.setConfirmed(true, for: scope)
        approval.setConfirmed(false, for: scope)
        XCTAssertFalse(approval.consume(for: scope))
        approval.setConfirmed(true, for: scope)
        approval.reset()
        XCTAssertFalse(approval.isConfirmed(for: scope))
        approval.setConfirmed(true, for: scope)
        XCTAssertTrue(approval.consume(for: scope))
        // Even a failed request cannot reuse the consumed permission.
        XCTAssertFalse(approval.consume(for: scope))
        approval.setConfirmed(true, for: scope)
        XCTAssertTrue(approval.consume(for: scope))
    }
}
