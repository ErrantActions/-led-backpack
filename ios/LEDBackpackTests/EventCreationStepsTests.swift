import XCTest
@testable import LEDBackpack

final class EventCreationStepsTests: XCTestCase {
    private var input: CatalogEventInput {
        CatalogEventInput(title: "Meetup", description: "", startsAtISO: "2026-11-11T00:00:00Z",
            endsAtISO: "2026-11-11T01:00:00Z", timezone: "America/Chicago", visibility: "private",
            capacity: 50, location: .init(label: "Fixed place", latitude: 0, longitude: 0, radiusMeters: 100))
    }
    private func issue(_ value: CatalogEventInput? = nil, start: Bool = true, end: Bool = true,
        confirmed: Bool = true, existingVisibility: String? = nil) -> String? {
        EventCreationReadiness.issue(input: value ?? input, startChosen: start, endChosen: end,
            venueConfirmed: confirmed, existingVisibility: existingVisibility)
    }
    func testEssentialsCanBeReviewedWithoutDescriptionRoutesOrActivities() {
        XCTAssertNil(issue())
    }
    func testSuggestionsStillRequireBothDeliberateTimeChoices() {
        XCTAssertNotNil(issue(start: false)); XCTAssertNotNil(issue(end: false))
    }
    func testBlankOrOversizeUTF16TitleCannotBeReviewed() {
        var value = input; value.title = "  "
        XCTAssertNotNil(issue(value))
        value.title = String(repeating: "\u{1F600}", count: 81)
        XCTAssertNotNil(issue(value))
    }
    func testVenueMustExistBeValidAndBeExplicitlyConfirmed() {
        XCTAssertNotNil(EventCreationReadiness.issue(input: nil, startChosen: true, endChosen: true, venueConfirmed: true))
        XCTAssertNotNil(issue(confirmed: false))
        var value = input; value.location.latitude = 91
        XCTAssertNotNil(issue(value))
    }
    func testInvalidTimezoneAndNonincreasingScheduleCannotBeReviewed() {
        var value = input; value.timezone = "invalid-zone"
        XCTAssertNotNil(issue(value))
        value = input; value.endsAtISO = value.startsAtISO
        XCTAssertNotNil(issue(value))
    }
    func testNewLinkReadableEventRequiresSeparateConsent() {
        var value = input; value.visibility = "unlisted"
        XCTAssertNotNil(issue(value))
        value.unlistedLinkConsent = true
        XCTAssertNil(issue(value))
    }
    func testExistingUnlistedVisibilityDoesNotInventAFreshConsentGrant() {
        var value = input; value.visibility = "unlisted"
        XCTAssertNil(issue(value, existingVisibility: "unlisted"))
        XCTAssertNil(value.unlistedLinkConsent)
    }
    func testScheduleUsesEventTimezoneInsteadOfRawUTCOrPhoneTimezone() throws {
        let value = try EventScheduleSummary(startsAtISO: input.startsAtISO, endsAtISO: input.endsAtISO,
            timezone: input.timezone, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(value.day, "10"); XCTAssertEqual(value.month, "Nov")
        XCTAssertTrue(value.date.contains("2026")); XCTAssertTrue(value.time.contains("CST"))
        XCTAssertTrue(value.time.contains("6:00")); XCTAssertTrue(value.time.contains("7:00"))
    }
    func testOvernightScheduleShowsEndDateAndDSTChangeShowsBothOffsets() throws {
        let overnight = try EventScheduleSummary(startsAtISO: "2026-11-11T05:00:00Z",
            endsAtISO: "2026-11-11T08:00:00Z", timezone: "America/Chicago", locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(overnight.day, "10"); XCTAssertTrue(overnight.time.contains("11"))
        let dst = try EventScheduleSummary(startsAtISO: "2026-11-01T06:30:00Z",
            endsAtISO: "2026-11-01T07:30:00Z", timezone: "America/Chicago", locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(dst.time.contains("CDT")); XCTAssertTrue(dst.time.contains("CST"))
    }
    func testInvalidScheduleNeverBecomesASuccessShapedDateLabel() {
        XCTAssertThrowsError(try EventScheduleSummary(startsAtISO: input.startsAtISO, endsAtISO: input.endsAtISO, timezone: "invalid"))
        XCTAssertThrowsError(try EventScheduleSummary(startsAtISO: "invalid", endsAtISO: input.endsAtISO, timezone: "UTC"))
        XCTAssertThrowsError(try EventScheduleSummary(startsAtISO: input.endsAtISO, endsAtISO: input.startsAtISO, timezone: "UTC"))
    }
#if DEBUG
    @MainActor
    func testEventPreviewFixtureSupportsAuthorizedBrowseDetailsAndEmptyGallery() async throws {
        let controller = LibraryPreviewFixture.community(social: true, events: true)
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "ui@example.invalid", password: "fixture-password")
        try await controller.loadConfig()
        let client = try CommunityFeatureClient(controller)
        let page = try await client.events(.accessible, offset: 0)
        let first = try XCTUnwrap(page.events.first)
        let event = try await client.event(first.id)
        XCTAssertEqual(event.title, "Glow in the park")
        XCTAssertEqual(event.access.role, .owner)
        XCTAssertNil(event.rsvpStatus)
        let own = try await client.events(.mine, offset: 0)
        XCTAssertEqual(own.events.map(\.id), [event.id])
        let invites = try await client.events(.invitations, offset: 0)
        XCTAssertTrue(invites.events.isEmpty)
        let next = try await client.events(.accessible, offset: 50)
        XCTAssertEqual(next.offset, 50); XCTAssertTrue(next.events.isEmpty)
        let images = try await client.eventImages(event.id)
        XCTAssertTrue(images.assets.isEmpty); XCTAssertNil(images.coverAssetId)
    }
#endif
}
