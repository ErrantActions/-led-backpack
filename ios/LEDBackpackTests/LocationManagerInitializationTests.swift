import XCTest
@testable import LEDBackpack

@MainActor
final class LocationManagerInitializationTests: XCTestCase {
    func testLiveSensorsColdConstructionDoesNotInitializeLocationOrInventAuthorization() {
        let sensors = LiveSensors()
        XCTAssertFalse(sensors.hasInitializedLocationManager)
        XCTAssertNil(sensors.authorization)
        XCTAssertFalse(sensors.locationRunning)
    }

    func testLiveSensorsRepeatedStopDoesNotInitializeLocation() {
        let sensors = LiveSensors()
        sensors.stop()
        sensors.stop()
        XCTAssertFalse(sensors.hasInitializedLocationManager)
        XCTAssertNil(sensors.authorization)
    }

    func testCheckpointColdConstructionAndStopRemainLocationFree() {
        let location = ForegroundCheckpointLocation()
        XCTAssertFalse(location.hasInitializedLocationManager)
        location.stop("Global stop while offline")
        location.stop("Background before activation")
        XCTAssertFalse(location.hasInitializedLocationManager)
        XCTAssertFalse(location.sensing)
        XCTAssertEqual(location.eligibility, .manual)
    }

    func testCheckpointPermissionRequestWithoutConsentDoesNotInitializeLocation() {
        let location = ForegroundCheckpointLocation()
        location.requestWhenInUse(consent: false)
        XCTAssertFalse(location.hasInitializedLocationManager)
        XCTAssertFalse(location.sensing)
        XCTAssertEqual(location.status, "Local consent required")
    }
}
