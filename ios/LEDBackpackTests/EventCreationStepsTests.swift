import XCTest
@testable import LEDBackpack

final class EventCreationStepsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1794000000)
    private func advances(_ step: EventCreationStep, title: String = "Meetup", startChosen: Bool = true,
        endChosen: Bool = true, endOffset: Double = 3600, zone: String = "UTC",
        venue: CatalogEventLocation? = nil, confirmed: Bool = false) -> Bool {
        step.canAdvance(title: title, startChosen: startChosen, endChosen: endChosen,
            start: start, end: start.addingTimeInterval(endOffset), zone: zone, venue: venue, venueConfirmed: confirmed)
    }
    func testWizardHasExactlyFourOrderedNamedSteps() {
        XCTAssertEqual(EventCreationStep.allCases.map(\.title), ["Basics","Time","Venue","Review"])
    }
    func testBasicsRequiresNonblankBoundedTitle() {
        XCTAssertFalse(advances(.basics, title: "  ")); XCTAssertFalse(advances(.basics, title: String(repeating: "x", count: 161)))
        XCTAssertTrue(advances(.basics))
    }
    func testTimeRequiresBothDeliberateChoicesAndValidIncreasingSchedule() {
        XCTAssertFalse(advances(.time, startChosen: false)); XCTAssertFalse(advances(.time, endChosen: false))
        XCTAssertFalse(advances(.time, endOffset: 0)); XCTAssertFalse(advances(.time, zone: "invalid-zone"))
        XCTAssertTrue(advances(.time))
    }
    func testVenueRequiresExplicitReviewedValidCoordinates() {
        let venue = CatalogEventLocation(label: "Fixed place", latitude: 0, longitude: 0, radiusMeters: 100)
        XCTAssertFalse(advances(.venue)); XCTAssertFalse(advances(.venue, venue: venue))
        XCTAssertTrue(advances(.venue, venue: venue, confirmed: true))
        let invalid = CatalogEventLocation(label: "", latitude: 91, longitude: 0, radiusMeters: 100)
        XCTAssertFalse(advances(.venue, venue: invalid, confirmed: true))
    }
    func testFinalStepNeverAdvancesOrAutomaticallySaves() {
        XCTAssertFalse(advances(.review))
    }
}
