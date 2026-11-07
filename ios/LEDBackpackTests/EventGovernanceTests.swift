import XCTest
import BackpackProtocol
@testable import LEDBackpack

enum NativeEventScopeFixtures {
    static let eventID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let userID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    static let successorID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    static let reportID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    static func event(role: String? = "owner", visibility: String = "private", revision: Int = 4,
                      held: Bool = false, membership: Bool? = nil) throws -> CatalogEvent {
        let member = membership ?? (role != nil)
        let organizer = role.map { #"{"id":"\#(userID)","displayName":"Named owner","eventRole":"\#($0)"},"# } ?? ""
        let successorRole = role == "owner" ? "coorganizer" : "owner"
        return try JSONDecoder().decode(CatalogEvent.self, from: Data(#"""
        {"id":"\#(eventID)","title":"Synthetic fixed event","description":"Deliberate definition",
        "startsAtISO":"2026-11-10T15:00:12.345Z","endsAtISO":"2026-11-10T17:00:23.678Z",
        "timezone":"America/New_York","visibility":"\#(visibility)","serverTime":"2026-11-01T00:00:00Z",
        "capacity":20,"revision":\#(revision),"cancelled":false,"kind":"group-ride","status":"scheduled","rsvpStatus":null,
        "location":{"label":"Fixed venue","latitude":40,"longitude":-73,"radiusMeters":100},
        "organizers":[\#(organizer){"id":"\#(successorID)","displayName":"Named successor","eventRole":"\#(successorRole)"}],
        "access":{"role":\#(role.map { "\"\($0)\"" } ?? "null"),"invited":false,"member":\#(member),
        "canManage":\#(role != nil),"canManageRoute":\#(role == "owner"),"canRsvp":\#(!held),"canViewProgress":\#(member && !held)},
        "moderation":{"revision":\#(held ? 2 : 0),"held":\#(held)},
        "route":{"published":false,"checkpoints":[],"geometry":[]},"badges":[],
        "settings":{"exclusiveArtworkReferences":true,"eventReportsEnabled":true,"ownershipAuditEnabled":true,
        "formerOwnerRoleChoiceEnabled":true,"unlistedEventsEnabled":true,"optionalCheckpointsEnabled":true}}
        """#.utf8))
    }
    static func ownReport(expires: String = "2026-12-01T00:00:00Z") -> Data {
        Data(#"""
        {"id":"\#(reportID)","eventId":"\#(eventID)","reportedEventRevision":4,"revision":3,
        "category":"safety","details":"Typed <literal> note","resolved":false,
        "createdAtISO":"2026-11-01T00:00:00Z","expiresAtISO":"\#(expires)"}
        """#.utf8)
    }
    static func context(privateContent: Bool = true, moderation: Int = 0, held: Bool = false) -> Data {
        let definition = privateContent ? #","title":"MUST NOT COPY","description":"private stale snapshot""# :
            #","title":"Public definition","description":"Current only","startsAtISO":"2026-11-10T15:00:00Z","endsAtISO":"2026-11-10T17:00:00Z","timezone":"UTC","capacity":20,"location":{"label":"Public fixed venue","latitude":40,"longitude":-73,"radiusMeters":100},"cancelled":false,"kind":"meetup""#
        return Data(#"{"id":"\#(eventID)","revision":4,"visibility":"\#(privateContent ? "private" : "public")","contentWithheld":\#(privateContent),"moderation":{"revision":\#(moderation),"held":\#(held)}\#(definition)}"#.utf8)
    }
    static func staffReport(moderation: Int = 0, privateContent: Bool = true) throws -> NativeStaffEventReport {
        let own = String(decoding: ownReport(), as: UTF8.self)
        let context = String(decoding: context(privateContent: privateContent, moderation: moderation), as: UTF8.self)
        let json = String(own.dropLast()) + #","reporterId":null,"context":"# + context + "}"
        return try JSONDecoder().decode(NativeStaffEventReport.self, from: Data(json.utf8))
    }
}
private actor EventGovernanceFixtureTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected event fixture request.") }
        return replies.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class EventGovernanceFixtureVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class EventGovernanceTests: XCTestCase {
    private func setup(config: String, reply: Data = Data(), status: Int = 200, role: String = "admin") async throws -> (CommunityFeatureClient, EventGovernanceFixtureTransport) {
        let login = Data(#"{"user":{"id":"\#(NativeEventScopeFixtures.userID)","email":"fixture@example.invalid","displayName":"Fixture","role":"\#(role)","verified":true},"token":"synthetic-event-session","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8)
        let transport = EventGovernanceFixtureTransport([.init(status: 200, data: login), .init(status: 200, data: Data(config.utf8)), .init(status: status, data: reply)])
        let controller = CommunityController(vault: EventGovernanceFixtureVault(), factory: { _ in transport })
        controller.configure("https://catalog.example.invalid")
        try await controller.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (try CommunityFeatureClient(controller), transport)
    }
    func testAbsentNewSourceCapabilitiesFailClosed() async throws {
        let (client, _) = try await setup(config: #"{"requireEmailVerification":false,"eventsEnabled":true}"#)
        XCTAssertFalse(client.eventReportsAvailable); XCTAssertFalse(client.eventModerationAvailable)
        XCTAssertFalse(client.eventOwnershipAuditAvailable)
    }
    func testIndependentHeldQueueWithoutReportsKeyOrEventsGate() async throws {
        let (client, transport) = try await setup(config: #"{"requireEmailVerification":false,"eventsEnabled":false,"eventReportsEnabled":false,"eventModerationEnabled":true}"#,
            reply: Data(#"{"events":[],"page":1,"limit":24,"hasMore":false}"#.utf8))
        XCTAssertTrue(client.eventModerationAvailable); XCTAssertFalse(client.eventReportsAvailable)
        _ = try await client.heldEvents(page: 1)
        let history = await transport.history()
        XCTAssertEqual(history.last?.url?.path, "/api/v1/admin/event-moderation")
        XCTAssertFalse(history.contains { $0.url?.path.contains("/events/") == true })
    }
    func testExplicitModerationFalseDoesNotFallBackToReportsTrue() async throws {
        let (client, _) = try await setup(config: #"{"requireEmailVerification":false,"eventReportsEnabled":true,"eventModerationEnabled":false}"#)
        XCTAssertFalse(client.eventModerationAvailable)
    }
    func testPrivateReviewDropsInjectedFormerPublicDefinition() throws {
        let value = try JSONDecoder().decode(NativeEventReviewContext.self, from: NativeEventScopeFixtures.context())
        XCTAssertTrue(value.contentWithheld); XCTAssertNil(value.definition)
        XCTAssertEqual(value.moderation.revision, 0)
    }
    func testPublicReviewRemainsDistinctFromNormalEventAccess() throws {
        let value = try JSONDecoder().decode(NativeEventReviewContext.self, from: NativeEventScopeFixtures.context(privateContent: false))
        XCTAssertEqual(value.definition?.title, "Public definition")
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogEvent.self, from: NativeEventScopeFixtures.context(privateContent: false)))
    }
    func testWithheldVisibilityMismatchIsRejected() throws {
        let bytes = Data(String(decoding: NativeEventScopeFixtures.context(), as: UTF8.self).replacingOccurrences(of: #""contentWithheld":true"#, with: #""contentWithheld":false"#).utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeEventReviewContext.self, from: bytes))
    }
    func testBlankReportCategoryDetailsAndUncheckedConsentAreRejected() throws {
        let event = try NativeEventScopeFixtures.event()
        XCTAssertThrowsError(try NativeEventReportIntent(event: event, category: nil, details: "typed", consent: true))
        XCTAssertThrowsError(try NativeEventReportIntent(event: event, category: .safety, details: " \n", consent: true))
        XCTAssertThrowsError(try NativeEventReportIntent(event: event, category: .safety, details: "typed", consent: false))
    }
    func testReportContainsOnlyTypedScopeAndCapturedRevision() throws {
        let intent = try NativeEventReportIntent(event: NativeEventScopeFixtures.event(), category: .other, details: "  <literal>  ", consent: true)
        let text = String(decoding: intent.data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""details":"<literal>""#)); XCTAssertTrue(text.contains(#""expectedRevision":4"#))
        for forbidden in ["venue", "roster", "chat", "GPS", "gif", "Synthetic fixed event"] { XCTAssertFalse(text.contains(forbidden)) }
    }
    func testReportBoundsAccept1000Reject1001() throws {
        let event = try NativeEventScopeFixtures.event()
        _ = try NativeEventReportIntent(event: event, category: .spam, details: String(repeating: "x", count: 1000), consent: true)
        XCTAssertThrowsError(try NativeEventReportIntent(event: event, category: .spam, details: String(repeating: "x", count: 1001), consent: true))
    }
    func testFirstHoldPreservesActualModerationZeroAndLiteralNote() throws {
        let intent = try NativeEventCaseIntent(report: NativeEventScopeFixtures.staffReport(), action: .hold, note: " <typed> ")
        let text = String(decoding: intent.data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""expectedModerationRevision":0"#)); XCTAssertTrue(text.contains(#""expectedRevision":3"#))
        XCTAssertTrue(text.contains(#""expectedEventRevision":4"#)); XCTAssertTrue(text.contains(#""note":"<typed>""#))
    }
    func testStaffNoteRequiresDeliberateNonemptyBoundedInput() throws {
        let report = try NativeEventScopeFixtures.staffReport()
        XCTAssertThrowsError(try NativeEventCaseIntent(report: report, action: .resolve, note: " "))
        XCTAssertThrowsError(try NativeEventCaseIntent(report: report, action: .release, note: String(repeating: "x", count: 1001)))
    }
    func testOwnReportDecoderNeverExposesStaffContext() throws {
        let bytes = Data((String(String(decoding: NativeEventScopeFixtures.ownReport(), as: UTF8.self).dropLast()) + #","review":{"note":"SECRET STAFF NOTE"},"context":{"title":"PRIVATE"}} "#).utf8)
        let own = try JSONDecoder().decode(NativeOwnEventReport.self, from: bytes)
        XCTAssertEqual(own.details, "Typed <literal> note")
    }
    func testReportExpiryBoundary() throws {
        let report = try JSONDecoder().decode(NativeOwnEventReport.self, from: NativeEventScopeFixtures.ownReport())
        let boundary = try CatalogEventTime.parse(report.expiresAtISO)
        XCTAssertFalse(try report.expired(at: boundary.addingTimeInterval(-0.001)))
        XCTAssertTrue(try report.expired(at: boundary))
    }
    func testNullableAnonymizedAuditReferencesDecodeWithoutProfileLookup() throws {
        let data = Data(#"{"id":"\#(NativeEventScopeFixtures.reportID)","fromUserId":null,"toUserId":null,"formerOwnerRole":"none","reason":"account-erasure-succession","eventRevision":5,"occurredAtISO":"2026-11-01T00:00:00Z"}"#.utf8)
        let audit = try JSONDecoder().decode(NativeEventOwnershipAudit.self, from: data)
        XCTAssertNil(audit.fromUserId); XCTAssertNil(audit.toUserId)
    }
    func testNullableOwnershipReceiptDoesNotInventPrivateAccessOrMembership() throws {
        let receipt = try JSONDecoder().decode(NativeEventOwnershipReceipt.self, from: Data(#"{"transferred":true,"formerOwnerRole":"none","membershipRetained":false,"event":null}"#.utf8))
        try receipt.validate(eventID: XCTUnwrap(UUID(uuidString: NativeEventScopeFixtures.eventID)),
            formerAccount: XCTUnwrap(UUID(uuidString: NativeEventScopeFixtures.userID)), choice: NativeFormerOwnerRole.none)
        XCTAssertNil(receipt.event); XCTAssertFalse(receipt.membershipRetained)
    }
    func testFormerOwnerCannotRetainOwnerPrivilegesInReceipt() throws {
        let receipt = NativeEventOwnershipReceipt(transferred: true, formerOwnerRole: .none, membershipRetained: true, event: try NativeEventScopeFixtures.event())
        XCTAssertThrowsError(try receipt.validate(eventID: XCTUnwrap(UUID(uuidString: NativeEventScopeFixtures.eventID)),
            formerAccount: XCTUnwrap(UUID(uuidString: NativeEventScopeFixtures.userID)), choice: NativeFormerOwnerRole.none))
    }
    func testGlobalAdminWithoutEventOwnershipCannotChangeRoles() async throws {
        let (client, transport) = try await setup(config: #"{"requireEmailVerification":false,"eventsEnabled":true,"eventOwnershipAuditEnabled":true}"#)
        XCTAssertThrowsError(try client.checkEventOwner(NativeEventScopeFixtures.event(role: nil)))
        let history = await transport.history(); XCTAssertEqual(history.count, 2)
    }
    func testWithdrawalUsesCapturedReportRevisionWithoutEventViewAndKeepsModeration() async throws {
        let (client, transport) = try await setup(config: #"{"requireEmailVerification":false,"eventsEnabled":false,"eventReportsEnabled":true}"#,
            reply: Data(#"{"withdrawn":true,"moderationUnchanged":true}"#.utf8))
        let own = try JSONDecoder().decode(NativeOwnEventReport.self, from: NativeEventScopeFixtures.ownReport())
        try await client.withdrawEventReport(own)
        let history = await transport.history()
        XCTAssertEqual(history.count, 3); XCTAssertEqual(history.last?.httpMethod, "DELETE")
        XCTAssertEqual(history.last?.url?.path, "/api/v1/social/event-reports/\(NativeEventScopeFixtures.reportID)")
        XCTAssertTrue(String(decoding: try XCTUnwrap(history.last?.httpBody), as: UTF8.self).contains(#""expectedRevision":3"#))
    }
    func testConflictDoesNotReplayOrChangeImmutableTypedIntent() async throws {
        let (client, transport) = try await setup(config: #"{"requireEmailVerification":false,"eventReportsEnabled":true}"#,
            reply: Data(#"{"error":{"code":"event_report_changed","message":"Reload explicitly"}}"#.utf8), status: 409)
        let intent = try NativeEventCaseIntent(report: NativeEventScopeFixtures.staffReport(), action: .hold, note: "Retain this typed note")
        let bytes = intent.data
        do { _ = try await client.reviewEventReport(intent); XCTFail("Expected conflict") }
        catch { XCTAssertEqual((error as? CommunityFailure)?.status, 409) }
        XCTAssertEqual(intent.data, bytes); let history = await transport.history(); XCTAssertEqual(history.count, 3)
    }
    func testKnownHeldRSVPDeclineAcceptsNullableReceiptWithoutFetchingDetail() async throws {
        let (client, transport) = try await setup(config: #"{"requireEmailVerification":false,"eventsEnabled":true}"#,
            reply: Data(#"{"declined":true,"event":null}"#.utf8))
        try await client.declineKnownEventRSVP(XCTUnwrap(UUID(uuidString: NativeEventScopeFixtures.eventID)))
        let history = await transport.history()
        XCTAssertEqual(history.count, 3); XCTAssertEqual(history.last?.httpMethod, "POST")
        XCTAssertTrue(history.last?.url?.path.hasSuffix("/rsvp") == true)
    }
    func testIndependentReleasePinsEventAndExistingModerationRevisionsWithoutDecryption() async throws {
        let reply = Data((#"{"event":"# + String(decoding: NativeEventScopeFixtures.context(moderation: 3), as: UTF8.self) + "}").utf8)
        let (client, transport) = try await setup(config: #"{"requireEmailVerification":false,"eventReportsEnabled":false,"eventModerationEnabled":true}"#, reply: reply)
        let held = try JSONDecoder().decode(NativeEventReviewContext.self, from: NativeEventScopeFixtures.context(moderation: 2, held: true))
        let released = try await client.releaseHeldEvent(held)
        XCTAssertFalse(released.moderation.held); XCTAssertNil(released.definition)
        let history = await transport.history(), body = try XCTUnwrap(history.last?.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""expectedEventRevision":4"#)); XCTAssertTrue(text.contains(#""expectedModerationRevision":2"#))
        XCTAssertTrue(text.contains(#""action":"release""#)); XCTAssertFalse(text.contains("report"))
        XCTAssertEqual(history.last?.url?.path, "/api/v1/admin/event-moderation/\(NativeEventScopeFixtures.eventID)")
    }
    func testZeroModerationIsActualFirstHoldOnlyNotInventedExistingEnforcement() throws {
        try NativeEventModeration(revision: 0, held: false).validate()
        XCTAssertThrowsError(try NativeEventModeration(revision: 0, held: true).validate())
        XCTAssertThrowsError(try NativeEventModeration(revision: -1, held: false).validate())
    }
    func testLegacyFormerRoleOmissionPreservesOnlyServerConfirmedCoorganizerMembership() throws {
        let event = try NativeEventScopeFixtures.event(role: "coorganizer")
        let receipt = NativeEventOwnershipReceipt(transferred: true, formerOwnerRole: .coorganizer, membershipRetained: true, event: event)
        try receipt.validate(eventID: XCTUnwrap(UUID(uuidString: NativeEventScopeFixtures.eventID)),
            formerAccount: XCTUnwrap(UUID(uuidString: NativeEventScopeFixtures.userID)), choice: nil)
        XCTAssertEqual(receipt.event?.access.role, .coorganizer)
        XCTAssertFalse(receipt.event?.access.canManageRoute == true)
    }
}
