import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor AwardTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    var lateChange: (@MainActor @Sendable () -> Void)?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func setLateChange(_ work: @escaping @MainActor @Sendable () -> Void) { lateChange = work }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected private-award fixture request.") }
        let result = responses.removeFirst()
        if request.url?.path.contains("/my-awards") == true { await lateChange?() }
        return result
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class AwardVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class EventAwardTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let id = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let awardID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let checkpoint = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    private func reply(_ raw: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(raw.utf8)) }
    private func preference(_ enabled: Bool = true) -> CommunityResponse {
        reply(#"{"profile":{"id":"\#(owner)","displayName":"Owner"},"discoverable":false,"allowRequests":true,"messagingEnabled":false,"encryption":"server-managed","accountAwardsEnabled":\#(enabled)}"#)
    }
    private func eventJSON(enabled: Bool = true, revision: Int = 3, review: Bool = false) -> String {
        #"{"id":"\#(id)","title":"Synthetic event","description":"","startsAtISO":"2026-11-06T10:00:00.000Z","endsAtISO":"2026-11-06T14:00:00.000Z","serverTime":"2026-11-06T12:00:00.000Z","timezone":"UTC","visibility":"private","capacity":20,"revision":\#(revision),"participationRevision":2,"requiresReconfirmation":\#(review),"cancelled":false,"status":"in-progress","rsvpStatus":"going","organizers":[],"access":{"role":null,"invited":false,"member":true,"canManage":false,"canManageRoute":false,"canRsvp":true,"canViewProgress":true},"location":{"label":"Fixed","latitude":40,"longitude":-73,"radiusMeters":100},"settings":{"accountAwardsEnabled":\#(enabled)},"route":{"published":true,"geometry":[],"checkpoints":[{"id":"\#(checkpoint)","title":"Start","kind":"start","latitude":40,"longitude":-73,"radiusMeters":100,"order":0,"optional":false},{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","title":"Finish","kind":"finish","latitude":40.001,"longitude":-73,"radiusMeters":100,"order":1,"optional":false}]},"badges":[]}"#
    }
    private func event(enabled: Bool = true, revision: Int = 3, review: Bool = false) throws -> CatalogEvent {
        try JSONDecoder().decode(CatalogEvent.self, from: Data(eventJSON(enabled: enabled, revision: revision, review: review).utf8))
    }
    private func badgeJSON(requested: Bool = false, visible: Bool = false, allowed: Bool = true) -> String {
        let revision = allowed ? "2" : "null"
        return #"{"id":"\#(awardID)","eventId":"\#(id)","kind":"participation","title":"Joined synthetic event","description":"An explicit choice, not attendance.","eventVersion":2,"selfReported":true,"certified":false,"sharingRequested":\#(requested),"profileVisible":\#(visible),"canShowProfile":\#(allowed),"currentParticipationRevision":\#(revision)}"#
    }
    private func badge(requested: Bool = false, visible: Bool = false, allowed: Bool = true) throws -> NativeOwnedEventBadge {
        try JSONDecoder().decode(NativeOwnedEventBadge.self, from: Data(badgeJSON(requested: requested, visible: visible, allowed: allowed).utf8))
    }
    private func setup(_ responses: [CommunityResponse]) async throws -> (CommunityController, CommunityFeatureClient, AwardTransport) {
        let login = reply(#"{"user":{"id":"\#(owner)","email":"test@example.invalid","displayName":"Owner","role":"admin","verified":true},"token":"synthetic-private-award-session","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(#"{"requireEmailVerification":false,"socialEnabled":true,"eventsEnabled":true}"#)
        let transport = AwardTransport([login, config] + responses)
        let controller = CommunityController(vault: AwardVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    func testCollectionRequiresSeparateConsentAndNeverIncludesProgressGpsOrProfileChoice() throws {
        XCTAssertThrowsError(try EventBadgeCollectionIntent(event: event(), checkpointID: nil, consent: false))
        let intent = try EventBadgeCollectionIntent(event: event(), checkpointID: checkpoint, consent: true)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["collect","expectedParticipationRevision","checkpointId"])
        XCTAssertEqual(fields["collect"] as? Bool, true); XCTAssertEqual(fields["expectedParticipationRevision"] as? Int, 2)
        XCTAssertEqual(fields["checkpointId"] as? String, checkpoint.uuidString.lowercased())
        XCTAssertNil(fields["share"]); XCTAssertNil(fields["profileVisible"]); XCTAssertNil(fields["latitude"])
    }
    func testBothCapabilitiesFailClosedIncludingGlobalAdmin() async throws {
        XCTAssertThrowsError(try EventBadgeCollectionIntent(event: event(enabled: false), checkpointID: nil, consent: true))
        let (_, client, transport) = try await setup([preference(false)])
        do { _ = try await client.ownEventBadges(page: 1); XCTFail("Missing social/me capability") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/v1/events/my-awards" })
    }
    func testOwnerPagingIsBoundedAndUsesActualLimitTwentyFour() async throws {
        let (_, client, transport) = try await setup([preference(), reply(#"{"awards":[\#(badgeJSON())],"page":2,"limit":24,"hasMore":false}"#)])
        let result = try await client.ownEventBadges(page: 2)
        XCTAssertEqual(result.awards.count, 1)
        do { _ = try await client.ownEventBadges(page: 1001); XCTFail("Page bound") } catch {}
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(URLComponents(url: requests[3].url!, resolvingAgainstBaseURL: false)?.queryItems,
            [.init(name: "page", value: "2"), .init(name: "limit", value: "24")])
    }
    func testPrivateDefaultAndRequestedVersusVisibleRemainDistinct() throws {
        let privateRecord = try badge()
        XCTAssertFalse(privateRecord.sharingRequested); XCTAssertFalse(privateRecord.profileVisible)
        let withheld = try badge(requested: true, visible: false, allowed: false)
        try withheld.validate()
        XCTAssertTrue(withheld.sharingRequested); XCTAssertFalse(withheld.canShowProfile); XCTAssertNil(withheld.currentParticipationRevision)
        XCTAssertThrowsError(try EventBadgeProfileIntent(award: withheld, visible: true, consent: true))
    }
    func testProfileShowingRequiresDisplayedRevisionAndAdditionalConsent() throws {
        let current = try badge()
        XCTAssertThrowsError(try EventBadgeProfileIntent(award: current, visible: true, consent: false))
        let intent = try EventBadgeProfileIntent(award: current, visible: true, consent: true)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
        XCTAssertEqual(fields["profileVisible"] as? Bool, true)
        XCTAssertEqual(fields["expectedParticipationRevision"] as? Int, 2)
    }
    func testHideAndDeleteAfterEventAccessLossDoNotReadEvent() async throws {
        let unavailable = try badge(requested: true, visible: false, allowed: false)
        let (_, client, transport) = try await setup([
            preference(), reply(#"{"award":\#(badgeJSON(allowed: false))}"#),
            preference(), reply(#"{"removed":true}"#)
        ])
        let intent = try EventBadgeProfileIntent(award: unavailable, visible: false, consent: false)
        _ = try await client.setBadgeProfileChoice(intent)
        try await client.deleteOwnEventBadge(unavailable)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 6)
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/v1/events/\(id.uuidString.lowercased())" })
        let hidden = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Bool])
        XCTAssertEqual(hidden, ["profileVisible":false])
        XCTAssertEqual(requests[5].httpMethod, "DELETE"); XCTAssertNil(requests[5].httpBody)
    }
    func testCollectionRechecksCurrentEventAndReturnsPrivateUncertifiedReceipt() async throws {
        let (_, client, transport) = try await setup([preference(), reply(#"{"event":\#(eventJSON())}"#),
            reply(#"{"collected":1,"private":true,"selfReported":true,"certified":false}"#)])
        let result = try await client.collectEventBadges(EventBadgeCollectionIntent(event: event(), checkpointID: nil, consent: true))
        XCTAssertEqual(result.collected, 1); XCTAssertTrue(result.private); XCTAssertFalse(result.certified)
        let requests = await transport.history(); XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[4].url?.path, "/api/v1/events/\(id.uuidString.lowercased())/awards")
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/progress") == true })
    }
    func testReviewOrRevisionChangeResetsCollectionConsentAndCannotReplay() async throws {
        var choice = EventBadgeCollectionChoice()
        choice.update(try event()); choice.checkpointID = checkpoint; choice.consent = true
        choice.update(try event(revision: 4)); XCTAssertFalse(choice.consent); XCTAssertNil(choice.checkpointID)
        XCTAssertThrowsError(try EventBadgeCollectionIntent(event: event(review: true), checkpointID: nil, consent: true))
        let (_, client, transport) = try await setup([preference(), reply(#"{"event":\#(eventJSON(revision: 4))}"#)])
        do { _ = try await client.collectEventBadges(EventBadgeCollectionIntent(event: event(), checkpointID: nil, consent: true)); XCTFail("Changed context") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 4)
    }
    func testProfileConflictAndLimitsAreExplicitWithoutSilentRebaseOrRetry() async throws {
        let intent = try EventBadgeProfileIntent(award: badge(), visible: true, consent: true)
        for code in ["event_award_visibility","event_award_profile_limit"] {
            let (_, client, transport) = try await setup([preference(), reply(#"{"error":{"code":"\#(code)","message":"Review current records"}}"#, status: 409)])
            do { _ = try await client.setBadgeProfileChoice(intent); XCTFail("Expected conflict/limit") }
            catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 409) }
            let requests = await transport.history(); XCTAssertEqual(requests.count, 4); XCTAssertEqual(requests[3].httpBody, intent.data)
        }
    }
    func testLateAccountSwitchDiscardsOwnedList() async throws {
        let (controller, client, transport) = try await setup([preference(), reply(#"{"awards":[],"page":1,"limit":24,"hasMore":false}"#)])
        await transport.setLateChange { controller.configure("https://different.example") }
        do { _ = try await client.ownEventBadges(page: 1); XCTFail("Late account result") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 4)
    }
    func testProfileDecorationIsMinimalOptionalAndNeverAPlaceOrAttendanceGrant() throws {
        let raw = #"{"id":"\#(awardID)","kind":"participation","title":"Chosen event title","selfReported":true,"certified":false}"#
        let minimal = try JSONDecoder().decode(NativeProfileEventBadge.self, from: Data(raw.utf8))
        try minimal.validate()
        let old = try JSONDecoder().decode(SocialPerson.self, from: Data(#"{"id":"\#(owner)","displayName":"Owner"}"#.utf8))
        XCTAssertNil(old.eventBadges)
        let invalid = raw.replacingOccurrences(of: #""certified":false"#, with: #""certified":true"#)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeProfileEventBadge.self, from: Data(invalid.utf8)).validate())
    }
    func testFiveHundredPrivateRecordLimitDoesNotTriggerProgressOrAutomaticRetry() async throws {
        let (_, client, transport) = try await setup([preference(), reply(#"{"event":\#(eventJSON())}"#),
            reply(#"{"error":{"code":"event_award_limit","message":"Limit: 500 saved badges"}}"#, status: 409)])
        do { _ = try await client.collectEventBadges(EventBadgeCollectionIntent(event: event(), checkpointID: nil, consent: true)); XCTFail("Explicit storage limit") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.code, "event_award_limit") }
        let requests = await transport.history(); XCTAssertEqual(requests.count, 5)
    }
}
