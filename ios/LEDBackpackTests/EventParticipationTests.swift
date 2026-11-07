import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor ParticipationTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    var lateChange: (@MainActor @Sendable () -> Void)?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func setLateChange(_ work: @escaping @MainActor @Sendable () -> Void) { lateChange = work }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected participation fixture request.") }
        let result = responses.removeFirst()
        if request.url?.path.hasSuffix("/progress") == true { await lateChange?() }
        return result
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class ParticipationVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class EventParticipationTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let id = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let start = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    private let finish = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
    private func eventJSON(role: String? = "owner", revision: Int = 3, participation: Int = 2,
        going: Bool = true, member: Bool = true, review: Bool = false) -> String {
        let roleValue = role.map { #""\#($0)""# } ?? "null", rsvp = going ? #""going""# : "null"
        let organizer = role.map { #"{"id":"\#(owner)","displayName":"Owner","eventRole":"\#($0)"}"# } ?? ""
        return #"{"id":"\#(id)","title":"Synthetic route","description":"","startsAtISO":"2026-11-06T10:00:00.000Z","endsAtISO":"2026-11-06T14:00:00.000Z","serverTime":"2026-11-06T12:00:00.000Z","timezone":"UTC","visibility":"private","capacity":20,"revision":\#(revision),"participationRevision":\#(participation),"requiresReconfirmation":\#(review),"cancelled":false,"status":"in-progress","rsvpStatus":\#(rsvp),"location":{"label":"Fixed","latitude":40,"longitude":-73,"radiusMeters":100},"organizers":[\#(organizer)],"access":{"role":\#(roleValue),"invited":false,"member":\#(member),"canManage":\#(role != nil),"canManageRoute":\#(role == "owner"),"canRsvp":true,"canViewProgress":\#(member)},"settings":{"sharedProgressExpiryEnabled":true,"sharedProgressRetentionSeconds":86400,"expiringInvitationsEnabled":true},"route":{"published":true,"geometry":[],"checkpoints":[{"id":"\#(start)","title":"Start","kind":"start","latitude":40,"longitude":-73,"radiusMeters":100,"order":0,"optional":false},{"id":"\#(finish)","title":"Finish","kind":"finish","latitude":40,"longitude":-73,"radiusMeters":100,"order":1,"optional":false}]},"badges":[]}"#
    }
    private func event(role: String? = "owner", revision: Int = 3, participation: Int = 2,
        going: Bool = true, member: Bool = true, review: Bool = false) throws -> CatalogEvent {
        try JSONDecoder().decode(CatalogEvent.self, from: Data(eventJSON(role: role, revision: revision,
            participation: participation, going: going, member: member, review: review).utf8))
    }
    private func reply(_ raw: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(raw.utf8)) }
    private func setup(_ responses: [CommunityResponse], enabled: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, ParticipationTransport) {
        let login = reply(#"{"user":{"id":"\#(owner)","email":"test@example.invalid","displayName":"Owner","role":"admin","verified":true},"token":"synthetic-participation-session","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(enabled ?
            #"{"requireEmailVerification":false,"eventsEnabled":true,"eventProgressExpiryEnabled":true,"expiringEventInvitationsEnabled":true}"# :
            #"{"requireEmailVerification":false,"eventsEnabled":true}"#)
        let transport = ParticipationTransport([login, config] + responses)
        let controller = CommunityController(vault: ParticipationVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    private func roster(role: String = "owner", revision: Int = 3) -> String {
        #"{"participants":[{"user":{"id":"\#(peer)","displayName":"Named friend"},"invited":true,"invitationExpiresAtISO":null,"rsvpStatus":"going","eventRole":null,"requiresReconfirmation":true}],"page":1,"limit":24,"total":1,"eventRevision":\#(revision),"organizerRole":"\#(role)","serverTime":"2026-11-06T12:00:00.000Z"}"#
    }
    func testRosterUsesExactBoundedCurrentParticipantEndpointAndLegacyFields() async throws {
        let (_, client, transport) = try await setup([reply(roster())])
        let result = try await client.participantRoster(event(), page: 1)
        XCTAssertEqual(result.participants[0].invitationDeadline, .legacy)
        XCTAssertTrue(result.participants[0].requiresReconfirmation)
        let requests = await transport.history(), request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.url?.path, "/api/v1/events/\(id.uuidString.lowercased())/participants")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [.init(name: "page", value: "1"), .init(name: "limit", value: "24")])
        XCTAssertEqual(requests.count, 3)
    }
    func testGlobalAdminCannotReadRosterWithoutEventOrganizerRole() async throws {
        let (_, client, transport) = try await setup([])
        do { _ = try await client.participantRoster(event(role: nil), page: 1); XCTFail("No global-admin bypass") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 2)
    }
    func testRosterRevisionAndOwnerRoleCannotBeSilentlyRebased() throws {
        let value = try JSONDecoder().decode(NativeEventRoster.self, from: Data(roster(revision: 4).utf8))
        XCTAssertThrowsError(try value.validate(event: event(), requestedPage: 1, deadlinesEnabled: true))
        XCTAssertThrowsError(try JSONDecoder().decode(NativeEventRoster.self, from: Data(roster(role: "coorganizer").utf8)).validate(event: event(), requestedPage: 1, deadlinesEnabled: true))
    }
    func testProgressConsentResetsOnRevisionMembershipAndReviewChanges() throws {
        var choice = EventProgressChoice()
        choice.update(try event()); choice.checkpointID = start; choice.share = true
        choice.update(try event())
        XCTAssertTrue(choice.share)
        choice.update(try event(revision: 4)); XCTAssertFalse(choice.share); XCTAssertNil(choice.checkpointID)
        choice.checkpointID = finish; choice.share = true
        choice.update(try event(revision: 4, member: false)); XCTAssertFalse(choice.share); XCTAssertNil(choice.checkpointID)
        choice.share = true; choice.update(try event(review: true)); XCTAssertFalse(choice.share)
        choice.clear(); XCTAssertNil(choice.context)
    }
    func testClaimPayloadKeepsLocalOnlySeparateWithoutCoordinatesOrBadgeCollection() throws {
        for share in [false, true] {
            let intent = try EventProgressIntent(event: event(), checkpointID: start, share: share)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
            XCTAssertEqual(Set(fields.keys), ["checkpointId", "share"])
            XCTAssertEqual(fields["share"] as? Bool, share)
            XCTAssertEqual(fields["checkpointId"] as? String, start.uuidString.lowercased())
        }
        XCTAssertThrowsError(try EventProgressIntent(event: event(going: false), checkpointID: start, share: true))
        XCTAssertThrowsError(try EventProgressIntent(event: event(review: true), checkpointID: start, share: true))
    }
    func testChangedContextCannotReplayClaimAndMissingCapabilityCannotReadBoard() async throws {
        let (_, client, transport) = try await setup([reply(#"{"event":\#(eventJSON(revision: 4))}"#)])
        let intent = try EventProgressIntent(event: event(), checkpointID: start, share: true)
        do { _ = try await client.claimCheckpoint(intent); XCTFail("Changed revision") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
        let (_, disabled, other) = try await setup([], enabled: false)
        do { _ = try await disabled.currentSharedProgress(event()); XCTFail("Missing retention capability") } catch {}
        let disabledRequests = await other.history(); XCTAssertEqual(disabledRequests.count, 2)
    }
    func testOwnWithdrawalAfterAccessLossDoesNotReadEventOrSendARequestBody() async throws {
        let (_, client, transport) = try await setup([reply(#"{"cleared":true}"#)], enabled: false)
        try await client.withdrawOwnProgress(eventID: id)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].httpMethod, "DELETE")
        XCTAssertNil(requests[2].httpBody)
        XCTAssertEqual(requests[2].url?.path, "/api/v1/events/\(id.uuidString.lowercased())/progress")
    }
    func testSharedClaimReturnsActualRetentionWhileLocalOnlyDoesNotPublishCheckpoint() async throws {
        let current = eventJSON(), end = "2026-11-06T14:00:00.000Z"
        for share in [true, false] {
            let extra = share ? #","checkpointId":"\#(start)","expiresAtISO":"2026-11-07T14:00:00.000Z""# : ""
            let response = #"{"localOnly":\#(!share),"shared":\#(share),"selfReported":true,"serverTime":"2026-11-06T12:00:00.000Z","startsAtISO":"2026-11-06T10:00:00.000Z","endsAtISO":"\#(end)","participationRevision":2,"requiresReconfirmation":false\#(extra)}"#
            let (_, client, transport) = try await setup([reply(#"{"event":\#(current)}"#), reply(response)])
            let result = try await client.claimCheckpoint(EventProgressIntent(event: event(), checkpointID: start, share: share))
            XCTAssertEqual(result.shared, share)
            XCTAssertEqual(result.expiresAtISO != nil, share)
            let requests = await transport.history(); XCTAssertEqual(requests.count, 4)
        }
    }
    func testOptionalAvatarDecorationDoesNotRequireAnotherProfileRead() throws {
        let base = #"{"user":{"id":"\#(peer)","displayName":"Peer"},"checkpointId":"\#(start)","started":true,"finished":false,"selfReported":true,"expiresAtISO":"2026-11-07T14:00:00.000Z"}"#
        let plain = try JSONDecoder().decode(EventSharedProgressDeadline.self, from: Data(base.utf8))
        XCTAssertNil(plain.user.avatarUrl); XCTAssertNil(plain.user.avatarMasked)
        let decorated = base.replacingOccurrences(of: #""displayName":"Peer""#,
            with: #""displayName":"Peer","avatarMasked":true,"avatarAnimated":false"#)
        let row = try JSONDecoder().decode(EventSharedProgressDeadline.self, from: Data(decorated.utf8))
        XCTAssertEqual(row.user.avatarMasked, true)
    }
    func testOptionalCheckpointFlagSurvivesNativeRouteRoundTrip() throws {
        let value = #"{"id":"\#(start)","title":"Optional stop","kind":"checkpoint","latitude":40,"longitude":-73,"radiusMeters":100,"order":1,"optional":true}"#
        let checkpoint = try JSONDecoder().decode(EventRouteCheckpoint.self, from: Data(value.utf8))
        XCTAssertEqual(checkpoint.optional, true)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as? [String: Any])
        XCTAssertEqual(encoded["optional"] as? Bool, true)
    }
    func testParticipantRemovalRequiresOwnerAndSendsNoInventedRevisionBody() async throws {
        let (_, client, transport) = try await setup([reply(#"{"event":\#(eventJSON())}"#), reply(#"{"removed":true}"#)])
        try await client.rosterAction(event(), target: peer, action: .removeParticipant)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 4); XCTAssertNil(requests[3].httpBody)
        let (_, coorganizer, other) = try await setup([reply(#"{"event":\#(eventJSON(role: "coorganizer"))}"#)])
        do { try await coorganizer.rosterAction(event(role: "coorganizer"), target: peer, action: .removeParticipant); XCTFail("Owner required") } catch {}
        let coRequests = await other.history(); XCTAssertEqual(coRequests.count, 3)
    }
    func testLateAccountSwitchDiscardsBoardWithoutClaimOrReplay() async throws {
        let (controller, client, transport) = try await setup([reply(#"{"progress":[],"retentionSecondsAfterEventEnd":86400,"serverTime":"2026-11-06T12:00:00.000Z","endsAtISO":"2026-11-06T14:00:00.000Z"}"#)])
        await transport.setLateChange { controller.configure("https://different.example") }
        do { _ = try await client.currentSharedProgress(event()); XCTFail("Stale account response") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
}
