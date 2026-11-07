import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor DeadlineTestTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    var lateChange: (@MainActor @Sendable () -> Void)?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func setLateChange(_ action: @escaping @MainActor @Sendable () -> Void) { lateChange = action }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected deadline fixture request.") }
        let response = responses.removeFirst()
        if request.url?.path.hasSuffix("/invitations") == true { await lateChange?() }
        return response
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class DeadlineTestVault: CommunityVault {
    var data: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { data[key] }
    func save(_ value: Data, key: String) throws { data[key] = value }
    func remove(_ key: String) throws { data[key] = nil }
}
@MainActor
final class EventDeadlinePolicyTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let eventID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let now = "2026-11-06T12:00:00.000Z"
    private let end = "2026-11-08T12:00:00.000Z"
    private func event(deadline: String = #""2026-11-07T12:00:00.000Z""#, invited: Bool = true,
        role: Bool = true, going: Bool = false, settings: Bool = true) throws -> CatalogEvent {
        let inviteField = deadline == "missing" ? "" : #","invitationExpiresAtISO":\#(deadline)"#
        let settingsField = settings ? #","settings":{"expiringInvitationsEnabled":true,"sharedProgressExpiryEnabled":true,"sharedProgressRetentionSeconds":86400}"# : ""
        let roleValue = role ? #""owner""# : "null", rsvp = going ? #""going""# : "null"
        let organizer = role ? #"{"id":"\#(owner)","displayName":"Owner","eventRole":"owner"}"# : ""
        let raw = #"{"id":"\#(eventID)","title":"Synthetic event","description":"No private fixture content","startsAtISO":"2026-11-08T10:00:00.000Z","endsAtISO":"\#(end)","timezone":"UTC","visibility":"private","capacity":20,"revision":3,"cancelled":false,"serverTime":"\#(now)","status":"scheduled","rsvpStatus":\#(rsvp),"organizers":[\#(organizer)],"access":{"role":\#(roleValue),"invited":\#(invited),"member":true,"canManage":\#(role),"canManageRoute":\#(role),"canRsvp":true,"canViewProgress":true\#(inviteField)}\#(settingsField)}"#
        return try JSONDecoder().decode(CatalogEvent.self, from: Data(raw.utf8))
    }
    private func response(_ raw: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(raw.utf8)) }
    private func setup(_ replies: [CommunityResponse], enabled: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, DeadlineTestTransport) {
        let login = response(#"{"user":{"id":"\#(owner)","email":"test@example.invalid","displayName":"Owner","role":"admin","verified":true},"token":"synthetic-deadline-session","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = response(enabled ?
            #"{"requireEmailVerification":false,"eventsEnabled":true,"notificationsEnabled":true,"expiringEventInvitationsEnabled":true,"eventProgressExpiryEnabled":true}"# :
            #"{"requireEmailVerification":false,"eventsEnabled":true,"notificationsEnabled":true}"#)
        let transport = DeadlineTestTransport([login, config] + replies)
        let controller = CommunityController(vault: DeadlineTestVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    func testMissingNullAndActualInvitationDeadlineRemainDistinct() throws {
        XCTAssertEqual(try event(deadline: "missing").access.invitationDeadline, .unspecified)
        XCTAssertEqual(try event(deadline: "null").access.invitationDeadline, .legacy)
        XCTAssertEqual(try event().access.invitationDeadline, .expires("2026-11-07T12:00:00.000Z"))
        let null = try JSONDecoder().decode(EventInvitationReceipt.self, from: Data(#"{"invited":true,"automaticRsvp":false,"expiresAtISO":null}"#.utf8))
        XCTAssertEqual(null.deadline, .legacy)
    }
    func testExplicitUtcDeadlineHasStrictFutureAndInclusiveThirtyDayBoundary() throws {
        let server = try CatalogEventTime.parse(now)
        XCTAssertThrowsError(try EventDeadlinePolicy.explicitInvitation(now, serverNow: server))
        let boundary = CatalogEventTime.wire(server.addingTimeInterval(30 * 86400))
        XCTAssertNoThrow(try EventDeadlinePolicy.explicitInvitation(boundary, serverNow: server))
        XCTAssertThrowsError(try EventDeadlinePolicy.explicitInvitation(CatalogEventTime.wire(server.addingTimeInterval(30 * 86400 + 0.001)), serverNow: server))
        XCTAssertThrowsError(try EventDeadlinePolicy.explicitInvitation("2026-11-07T12:00:00+00:00", serverNow: server))
    }
    func testOmittedExpiryNeverInventsSevenDaysOrRenewsActiveLegacyGrant() async throws {
        let (_, client, transport) = try await setup([response(#"{"invited":true,"automaticRsvp":false,"expiresAtISO":null}"#)])
        let receipt = try await client.invite(event(), target: peer, expiresAtISO: nil)
        XCTAssertEqual(receipt.deadline, .legacy)
        let requests = await transport.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String])
        XCTAssertEqual(body, ["userId":peer.uuidString.lowercased()])
        XCTAssertEqual(requests.count, 3)
    }
    func testServerReceiptKeepsActualDefaultRatherThanComputingLocalSevenDays() async throws {
        let expiry = "2026-11-13T12:00:00.500Z"
        let (_, client, _) = try await setup([response(#"{"invited":true,"automaticRsvp":false,"expiresAtISO":"\#(expiry)"}"#)])
        let receipt = try await client.invite(event(), target: peer, expiresAtISO: nil)
        XCTAssertEqual(receipt.deadline, .expires(expiry))
    }
    func testExplicitDeadlineRequiresBothCapabilitiesBeforeAnyWrite() async throws {
        let (_, client, transport) = try await setup([], enabled: false)
        XCTAssertFalse(client.invitationDeadlinesEnabled(try event()))
        do { _ = try await client.invite(event(), target: peer, expiresAtISO: "2026-11-07T12:00:00.000Z"); XCTFail("Missing config gate") } catch {}
        let (_, enabled, other) = try await setup([])
        XCTAssertFalse(enabled.invitationDeadlinesEnabled(try event(settings: false)))
        do { _ = try await enabled.invite(event(settings: false), target: peer, expiresAtISO: "2026-11-07T12:00:00.000Z"); XCTFail("Missing event gate") } catch {}
        let first = await transport.history(), second = await other.history()
        XCTAssertEqual(first.count, 2); XCTAssertEqual(second.count, 2)
    }
    func testExpiryDoesNotRemoveIndependentGoingOrOrganizerAccess() throws {
        let expired = #""2026-11-06T12:00:00.000Z""#, server = try CatalogEventTime.parse(now)
        XCTAssertTrue(try EventDeadlinePolicy.invitationOnlyExpired(event(deadline: expired, role: false), serverNow: server))
        XCTAssertFalse(try EventDeadlinePolicy.invitationOnlyExpired(event(deadline: expired, role: false, going: true), serverNow: server))
        XCTAssertFalse(try EventDeadlinePolicy.invitationOnlyExpired(event(deadline: expired, role: true), serverNow: server))
        XCTAssertFalse(try EventDeadlinePolicy.invitationOnlyExpired(event(deadline: "null", role: false), serverNow: server))
    }
    func testOpaqueGrantSuffixNeverBecomesEventRevisionAndStaleNoticeCannotUsePublicAccess() async throws {
        let noticeID = UUID(), suffix = "340282366920938463463374607431768211455"
        let raw = #"{"id":"\#(noticeID)","type":"event-invite","referenceId":"\#(eventID):\#(suffix)","createdAtISO":"\#(now)","readAtISO":null}"#
        let notice = try JSONDecoder().decode(NativeActivityNotice.self, from: Data(raw.utf8))
        XCTAssertEqual(try notice.reference(), eventID)
        let (_, client, transport) = try await setup([response(#"{"notifications":[],"unread":0,"total":0,"page":1,"limit":24}"#)])
        do { _ = try await client.verifyEventNotice(notice, page: 1); XCTFail("A current event read cannot substitute for the exact grant notice") } catch {}
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests.last?.url?.path, "/api/v1/notifications")
    }
    func testExplicitExpiryIsCapturedAndLateAccountSwitchDiscardsReceipt() async throws {
        let expiry = "2026-11-07T12:00:00.000Z"
        let (controller, client, transport) = try await setup([response(#"{"invited":true,"automaticRsvp":false,"expiresAtISO":"\#(expiry)"}"#)])
        await transport.setLateChange { controller.configure("https://different.example") }
        do { _ = try await client.invite(event(), target: peer, expiresAtISO: expiry); XCTFail("Late account/origin result") } catch {}
        let requests = await transport.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String])
        XCTAssertEqual(body["expiresAtISO"], expiry); XCTAssertEqual(requests.count, 3)
    }
    func testConflictCannotRenewOrAutomaticallyResendCapturedInvitation() async throws {
        let (_, client, transport) = try await setup([response(#"{"error":{"code":"event_review_required","message":"Review current event"}}"#, status: 409)])
        let current = try event(), intent = try EventInvitationIntent(event: current, recipient: peer, expiresAtISO: nil, serverNow: CatalogEventTime.parse(now))
        do { _ = try await client.invite(current, target: peer, expiresAtISO: nil); XCTFail("Conflict") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 409) }
        let requests = await transport.history()
        XCTAssertEqual(requests[2].httpBody, intent.data); XCTAssertEqual(requests.count, 3)
    }
    func testSharedProgressDeadlineIsRetentionNotArrivalAndNeverExtendsLocally() throws {
        let expiry = "2026-11-09T12:00:00.000Z"
        let raw = #"{"progress":[{"user":{"id":"\#(peer)","displayName":"Peer"},"checkpointId":"\#(eventID)","started":true,"finished":false,"selfReported":true,"expiresAtISO":"\#(expiry)"}],"retentionSecondsAfterEventEnd":86400,"serverTime":"\#(now)","endsAtISO":"\#(end)"}"#
        let board = try JSONDecoder().decode(EventSharedProgressBoard.self, from: Data(raw.utf8))
        XCTAssertEqual(try board.currentEntries(expiryEnabled: true, at: CatalogEventTime.parse(now)).count, 1)
        XCTAssertTrue(try board.currentEntries(expiryEnabled: true, at: CatalogEventTime.parse(expiry)).isEmpty)
        XCTAssertThrowsError(try board.currentEntries(expiryEnabled: false, at: CatalogEventTime.parse(now)))
        let row = board.progress[0]
        XCTAssertTrue(try row.retained(at: CatalogEventTime.parse(now), eventEnd: "2026-11-10T12:00:00.000Z", expiryEnabled: true))
        XCTAssertEqual(row.expiresAtISO, expiry)
        XCTAssertThrowsError(try row.retained(at: CatalogEventTime.parse(now), eventEnd: "2026-11-07T12:00:00.000Z", expiryEnabled: true))
        let local = try JSONDecoder().decode(EventSharedProgressReceipt.self, from: Data(#"{"localOnly":true,"shared":false,"selfReported":true}"#.utf8))
        XCTAssertNil(try local.retentionDeadline(eventEnd: end, expiryEnabled: true))
    }
    func testRosterLegacyExpiryCanCoexistWithIndependentGoingMembership() throws {
        let raw = #"{"user":{"id":"\#(peer)","displayName":"Peer"},"eventRole":null,"invited":true,"rsvpStatus":"going","invitationExpiresAtISO":null}"#
        let participant = try JSONDecoder().decode(EventParticipantDeadline.self, from: Data(raw.utf8))
        XCTAssertEqual(participant.invitationDeadline, .legacy); XCTAssertEqual(participant.rsvpStatus, .going)
    }
    func testExactCurrentGrantNoticeIsCheckedWithoutInterpretingSuffix() async throws {
        let noticeID = UUID(), reference = "\(eventID):999999999999999999999999999999999999999"
        let raw = #"{"id":"\#(noticeID)","type":"event-invite","referenceId":"\#(reference)","createdAtISO":"\#(now)","readAtISO":null}"#
        let notice = try JSONDecoder().decode(NativeActivityNotice.self, from: Data(raw.utf8))
        let page = #"{"notifications":[\#(raw)],"unread":1,"total":1,"page":1,"limit":24}"#
        let (_, client, transport) = try await setup([response(page)])
        let event = try await client.verifyEventNotice(notice, page: 1)
        XCTAssertEqual(event, eventID)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/v1/events/\(eventID)" })
    }
    func testEnabledRetentionRequiresActualDeadlineAndDoesNotGuessFromEventEnd() throws {
        let raw = #"{"user":{"id":"\#(peer)","displayName":"Peer"},"checkpointId":"\#(eventID)","started":true,"finished":false,"selfReported":true}"#
        let row = try JSONDecoder().decode(EventSharedProgressDeadline.self, from: Data(raw.utf8))
        XCTAssertThrowsError(try row.retained(at: CatalogEventTime.parse(now), eventEnd: end, expiryEnabled: true))
        let shared = try JSONDecoder().decode(EventSharedProgressReceipt.self, from: Data(#"{"localOnly":false,"shared":true,"selfReported":true}"#.utf8))
        XCTAssertThrowsError(try shared.retentionDeadline(eventEnd: end, expiryEnabled: true))
    }
    func testEnabledDeadlineReceiptCannotClaimAutomaticAttendanceOrDifferentExpiry() async throws {
        let expected = "2026-11-07T12:00:00.000Z"
        for reply in [
            #"{"invited":true,"automaticRsvp":true,"expiresAtISO":"2026-11-07T12:00:00.000Z"}"#,
            #"{"invited":true,"automaticRsvp":false,"expiresAtISO":"2026-11-08T12:00:00.000Z"}"#
        ] {
            let (_, client, transport) = try await setup([response(reply)])
            do { _ = try await client.invite(event(), target: peer, expiresAtISO: expected); XCTFail("Unconfirmed explicit grant") } catch {}
            let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
        }
    }
}
