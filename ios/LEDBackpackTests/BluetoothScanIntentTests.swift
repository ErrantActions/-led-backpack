import XCTest
@testable import LEDBackpack

final class BluetoothScanIntentTests: XCTestCase {
    func testOpeningOrReturningToTheAppDoesNotCreateAnIntent() throws {
        var intent = BluetoothScanIntent()
        XCTAssertFalse(intent.pending)
        XCTAssertFalse(try intent.consume(now: 100, foreground: true))
    }
    func testExplicitIntentWaitsForForegroundThenIsConsumedOnlyOnce() throws {
        var intent = BluetoothScanIntent()
        try intent.request(now: 100)
        XCTAssertFalse(try intent.consume(now: 110, foreground: false))
        XCTAssertTrue(intent.pending)
        XCTAssertTrue(try intent.consume(now: 115, foreground: true))
        XCTAssertFalse(try intent.consume(now: 116, foreground: true))
    }
    func testExactThirtySecondBoundaryAndBackwardClockRevokeTheIntent() throws {
        for time in [99, 130, .infinity, .nan] {
            var intent = BluetoothScanIntent()
            try intent.request(now: 100)
            XCTAssertThrowsError(try intent.consume(now: time, foreground: true))
            XCTAssertFalse(intent.pending)
            XCTAssertFalse(try intent.consume(now: 101, foreground: true))
        }
    }
    func testImmediatelyBeforeDeadlineIsAllowedButCancelNeverRestarts() throws {
        var intent = BluetoothScanIntent()
        try intent.request(now: 100)
        XCTAssertTrue(try intent.consume(now: 129.999, foreground: true))
        try intent.request(now: 200)
        intent.cancel()
        XCTAssertFalse(try intent.consume(now: 201, foreground: true))
    }
}
