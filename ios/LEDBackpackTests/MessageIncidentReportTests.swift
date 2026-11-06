import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor IncidentTestTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected incident mock request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class IncidentTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class MessageIncidentReportTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let id = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private func message(sender: UUID? = nil) throws -> NativeChatMessage {
        try JSONDecoder().decode(NativeChatMessage.self, from: Data(#"{"id":"\#(id)","senderId":"\#(sender ?? peer)","text":"PRIVATE ORIGINAL MUST NOT AUTO-COPY","createdAt":1700000000000,"pin":{"label":"PRIVATE PLACE","latitude":40,"longitude":-73}}"#.utf8))
    }
    private func report(staff: Bool = false, revision: Int = 1, resolved: Bool = false, details: String = "My deliberately typed explanation") -> String {
        let extra = staff ? #","reporterId":"\#(owner)","subjectId":"\#(peer)""# : ""
        return #"{"id":"\#(id)","kind":"direct","messageId":"\#(id)","category":"other","details":"\#(details)","revision":\#(revision),"resolved":\#(resolved),"createdAtISO":"2026-11-01T00:00:00Z"\#(extra)}"#
    }
    private func setup(_ responses: [CommunityResponse], enabled: Bool = true, admin: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, IncidentTestTransport) {
        let role = admin ? "admin" : "user"
        let login = CommunityResponse(status: 200, data: Data(#"{"user":{"id":"\#(owner)","email":"test@example.invalid","displayName":"Test","role":"\#(role)","verified":true},"token":"synthetic-incident-session","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
        let config = CommunityResponse(status: 200, data: Data(#"{"requireEmailVerification":false,"messagingEnabled":true,"chatReportsEnabled":\#(enabled)}"#.utf8))
        let stub = IncidentTestTransport([login, config] + responses)
        let controller = CommunityController(vault: IncidentTestVault(), factory: { _ in stub })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), stub)
    }
    func testConsentIsRequiredAndPayloadIncludesOnlyDeliberateExplanation() throws {
        let selected = try message()
        let details = "<script>alert('literal')</script>"
        let value = try MessageIncidentIntent(message: selected, context: .direct(peer: peer, event: id), account: owner, category: .other, details: details, consent: true)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: value.data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["kind","messageId","category","details","consent"])
        XCTAssertEqual(fields["details"] as? String, details)
        XCTAssertFalse(String(decoding: value.data, as: UTF8.self).contains("PRIVATE ORIGINAL"))
        XCTAssertNil(fields["pin"]); XCTAssertNil(fields["eventId"]); XCTAssertNil(fields["attachment"])
        XCTAssertThrowsError(try MessageIncidentIntent(message: selected, context: .room(id), account: owner, category: .other, details: "Explanation", consent: false))
        XCTAssertThrowsError(try MessageIncidentIntent(message: selected, context: .room(id), account: owner, category: .other, details: String(repeating: "x", count: 1001), consent: true))
    }
    func testOwnAndForeignDirectMessagesCannotBeReportedEvenAsAdmin() throws {
        XCTAssertThrowsError(try MessageIncidentIntent(message: message(sender: owner), context: .room(id), account: owner, category: .spam, details: "Explanation", consent: true))
        XCTAssertThrowsError(try MessageIncidentIntent(message: message(), context: .direct(peer: id, event: nil), account: owner, category: .spam, details: "Explanation", consent: true))
    }
    func testMissingCapabilityCannotSubmitOrFetchPrivateReports() async throws {
        let (_, client, stub) = try await setup([], enabled: false)
        let value = try MessageIncidentIntent(message: message(), context: .direct(peer: peer, event: nil), account: owner, category: .other, details: "Explanation", consent: true)
        do { _ = try await client.submitMessageIncident(value); XCTFail("Missing capability") } catch {}
        do { _ = try await client.ownedMessageIncidents(page: 1, state: "all"); XCTFail("Missing capability") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testIdenticalRetriesBindSameEnteredBytesAndNeverOverwriteConflict() async throws {
        let response = CommunityResponse(status: 200, data: Data(#"{"report":\#(report())}"#.utf8))
        let conflict = CommunityResponse(status: 409, data: Data(#"{"error":{"code":"chat_report_exists","message":"Review original report"}}"#.utf8))
        let (_, client, stub) = try await setup([response, response, conflict])
        let value = try MessageIncidentIntent(message: message(), context: .direct(peer: peer, event: nil), account: owner, category: .other, details: "My deliberately typed explanation", consent: true)
        _ = try await client.submitMessageIncident(value); _ = try await client.submitMessageIncident(value)
        do { _ = try await client.submitMessageIncident(value); XCTFail("Conflict retained") }
        catch let error as CommunityFailure { XCTAssertEqual(error.status, 409) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 5); XCTAssertEqual(requests[2].httpBody, value.data); XCTAssertEqual(requests[3].httpBody, value.data)
        XCTAssertEqual(requests[4].httpBody, value.data)
    }
    func testOwnerWithdrawalUsesCapturedReviewedRevisionWithoutChatReadOrEvidenceFetch() async throws {
        let (_, client, stub) = try await setup([CommunityResponse(status: 200, data: Data(#"{"removed":true}"#.utf8))])
        let value = try JSONDecoder().decode(NativeMessageIncident.self, from: Data(report(revision: 2).utf8))
        try await client.withdrawMessageIncident(value)
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].httpMethod, "DELETE")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Int])
        XCTAssertEqual(fields, ["expectedRevision":2])
        XCTAssertThrowsError(try JSONDecoder().decode(NativeMessageIncident.self, from: Data(report(staff: true).utf8)).validate(staff: false))
    }
    func testRestrictedModeratorReviewCapturesRevisionAndDoesNotUnlockMessage() async throws {
        let response = CommunityResponse(status: 200, data: Data(#"{"report":\#(report(staff: true, revision: 2, resolved: true))}"#.utf8))
        let (controller, _, stub) = try await setup([response])
        let client = try CommunityAdminClient(controller)
        let initial = try JSONDecoder().decode(NativeMessageIncident.self, from: Data(report(staff: true).utf8))
        _ = try await client.reviewMessageIncident(initial, resolved: true)
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].url?.path, "/api/v1/admin/message-reports/\(id.uuidString.lowercased())")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertEqual(fields["expectedRevision"] as? Int, 1); XCTAssertEqual(fields["resolved"] as? Bool, true)
        let (ordinary, _, _) = try await setup([], admin: false)
        XCTAssertThrowsError(try CommunityAdminClient(ordinary))
    }
}
