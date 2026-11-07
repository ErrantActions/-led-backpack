import XCTest
import MapKit
@testable import LEDBackpack

@MainActor
final class EventRoadRouteTests: XCTestCase {
    func testCheckpointProjectionSnapsToRouteAndReportsDistanceAlongIt() throws {
        let a = EventCoordinate(latitude: 0, longitude: 0), b = EventCoordinate(latitude: 0, longitude: 0.01)
        let projection = try EventRoadGeometry.nearest(.init(latitude: 0.0001, longitude: 0.005), to: [a,b])
        XCTAssertEqual(projection.point.latitude, 0, accuracy: 0.000001)
        XCTAssertEqual(projection.point.longitude, 0.005, accuracy: 0.000001)
        XCTAssertGreaterThan(projection.distance, 10); XCTAssertLessThan(projection.distance, 20)
        XCTAssertGreaterThan(projection.along, 500); XCTAssertLessThan(projection.along, 600)
    }
    func testProjectionClampsToEndInsteadOfExtendingRoadLine() throws {
        let line = [EventCoordinate(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.01)]
        let projection = try EventRoadGeometry.nearest(.init(latitude: 0, longitude: 0.02), to: line)
        XCTAssertEqual(projection.point.longitude, 0.01, accuracy: 0.000001)
    }
    func testInvalidAndMissingRoadGeometryRejectsCheckpointDrop() {
        XCTAssertThrowsError(try EventRoadGeometry.nearest(.init(latitude: .nan, longitude: 0), to: []))
        XCTAssertThrowsError(try EventRoadGeometry.nearest(.init(latitude: 0, longitude: 0), to: [.init(latitude: 0, longitude: 0)]))
    }
    func testStraightRoadSimplifiesWithinBoundWithoutChangingEndpoints() throws {
        let points = (0..<1000).map { EventCoordinate(latitude: 0, longitude: Double($0) / 10000) }
        let saved = try EventRoadGeometry.bounded(points)
        XCTAssertEqual(saved, [points[0],points[points.count - 1]])
    }
    func testImportantRoadCornerIsRetainedRatherThanCutAcross() throws {
        let points = [EventCoordinate(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.01), .init(latitude: 0.01, longitude: 0.01)]
        XCTAssertEqual(try EventRoadGeometry.bounded(points), points)
    }
    func testComplexRoadExceedingServiceGeometryLimitFailsWithoutTruncation() {
        let points = (0..<401).map { EventCoordinate(latitude: $0.isMultiple(of: 2) ? 0 : 0.005, longitude: Double($0) / 1000) }
        XCTAssertThrowsError(try EventRoadGeometry.bounded(points))
    }
    func testClosedLoopKeepsRouteCornersAndSameStartEnd() throws {
        let points = [EventCoordinate(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.01),
            .init(latitude: 0.01, longitude: 0.01), .init(latitude: 0.01, longitude: 0), .init(latitude: 0, longitude: 0)]
        let saved = try EventRoadGeometry.bounded(points)
        XCTAssertEqual(saved.first, saved.last); XCTAssertEqual(saved.count, points.count)
    }
    func testColdRoadPlannerCancelDoesNotMakeDirectionsRequest() {
        let route = EventRoadRouteStore()
        route.cancel(); route.clear()
        XCTAssertFalse(route.busy); XCTAssertNil(route.result); XCTAssertTrue(route.waypoints.isEmpty)
    }
}
