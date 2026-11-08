import XCTest
@testable import LEDBackpack

final class GPSGameEligibilityTests: XCTestCase {
    func testEventDeadlineIncludesElapsedHuntFetchTime() throws {
        let instant = ContinuousClock().now, server = Date(timeIntervalSince1970: 1000)
        let clock = try CatalogEventClock(serverTime: "1970-01-01T00:16:40Z", instant: instant)
        XCTAssertThrowsError(try LocalEventSensingLease.duration(server: server, start: server.addingTimeInterval(-10),
            end: server.addingTimeInterval(2), clock: clock, instant: instant.advanced(by: .seconds(3))))
        XCTAssertEqual(try LocalEventSensingLease.duration(server: server, start: server.addingTimeInterval(-10),
            end: server.addingTimeInterval(4), clock: clock, instant: instant.advanced(by: .seconds(3))), 1, accuracy: 0.001)
    }
    func testStaleEventReadCannotStartNewSixtySecondLease() throws {
        let instant = ContinuousClock().now, server = Date(timeIntervalSince1970: 1000)
        let clock = try CatalogEventClock(serverTime: "1970-01-01T00:16:40Z", instant: instant)
        XCTAssertThrowsError(try LocalEventSensingLease.duration(server: server, start: server,
            end: server.addingTimeInterval(100), clock: clock, instant: instant.advanced(by: .seconds(5.01))))
        XCTAssertEqual(try LocalEventSensingLease.duration(server: server, start: server,
            end: server.addingTimeInterval(100), clock: clock, instant: instant.advanced(by: .seconds(5))), 60)
    }
    func testWrongOrBackwardsEventClockFailsClosed() throws {
        let instant = ContinuousClock().now, server = Date(timeIntervalSince1970: 1000)
        let clock = try CatalogEventClock(serverTime: "1970-01-01T00:16:40Z", instant: instant)
        XCTAssertThrowsError(try LocalEventSensingLease.duration(server: server.addingTimeInterval(1), start: server,
            end: server.addingTimeInterval(100), clock: clock, instant: instant))
        XCTAssertThrowsError(try LocalEventSensingLease.duration(server: server, start: server,
            end: server.addingTimeInterval(100), clock: clock, instant: instant.advanced(by: .seconds(-1))))
    }
    private func scope(checkpoint: UUID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
        account: UUID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!) -> ForegroundLocationScope {
        .init(accountRevision: account, eventID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            eventRevision: 4, participationRevision: 3, checkpointID: checkpoint)
    }
    func testContinuousFreshFixesAreRequiredForDwellNotTwoWidelySeparatedSamples() {
        var evaluator = LocalCheckpointEvaluator()
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 0, radius: 50, now: 0), .dwelling)
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 0, radius: 50, now: 11), .dwelling)
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 0, radius: 50, now: 16), .dwelling)
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 0, radius: 50, now: 21), .eligible)
    }
    func testGPSDriftOutsideConfidenceRadiusResetsDwellWithoutExpandingTarget() {
        var evaluator = LocalCheckpointEvaluator()
        _ = evaluator.evaluate(distance: 10, accuracy: 3, age: 0, radius: 50, now: 0)
        XCTAssertEqual(evaluator.evaluate(distance: 49, accuracy: 3, age: 0, radius: 50, now: 5), .outside)
        XCTAssertEqual(evaluator.evaluate(distance: 10, accuracy: 3, age: 0, radius: 50, now: 10), .dwelling)
    }
    func testBackwardsClockAndInvalidAccuracyFailToManual() {
        var evaluator = LocalCheckpointEvaluator()
        _ = evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 50, now: 5)
        XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 50, now: 4), .manual)
        XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: 26, age: 0, radius: 50, now: 6), .manual)
    }
    func testHintIsBoundToExactAccountEventParticipationAndCheckpoint() {
        let expected = scope(), hint = LocalCheckpointHint(id: UUID(), scope: scope(), observedUptime: 100, validUntilUptime: 105)
        XCTAssertNoThrow(try hint.require(expected, uptime: 101))
        XCTAssertThrowsError(try hint.require(scope(checkpoint: UUID()), uptime: 101))
        XCTAssertThrowsError(try hint.require(scope(account: UUID()), uptime: 101))
        var changed = expected
        changed = .init(accountRevision: expected.accountRevision, eventID: expected.eventID,
            eventRevision: 5, participationRevision: expected.participationRevision, checkpointID: expected.checkpointID)
        XCTAssertThrowsError(try hint.require(changed, uptime: 101))
    }
    func testExpiredFutureOrExcessivelyLongHintCannotConfirm() {
        let expected = scope()
        let hint = LocalCheckpointHint(id: UUID(), scope: expected, observedUptime: 100, validUntilUptime: 105)
        XCTAssertThrowsError(try hint.require(expected, uptime: 105))
        XCTAssertThrowsError(try hint.require(expected, uptime: 99))
        let tooLong = LocalCheckpointHint(id: UUID(), scope: expected, observedUptime: 100, validUntilUptime: 106)
        XCTAssertThrowsError(try tooLong.require(expected, uptime: 101))
    }
    func testCooldownRemainsAfterConsumedOrLostSamplesWithoutInstantReentry() {
        var evaluator = LocalCheckpointEvaluator()
        for t in [0.0,5,10] { _ = evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 50, now: t) }
        evaluator.discardSample()
        XCTAssertEqual(evaluator.evaluate(distance: 1, accuracy: 1, age: 0, radius: 50, now: 11), .cooldown)
    }
}
