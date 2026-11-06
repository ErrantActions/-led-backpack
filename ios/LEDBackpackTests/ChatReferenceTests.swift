import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor ReferenceTestTransport: CommunityTransport {
    var replies: [CommunityResponse]
    var requests: [URLRequest] = []
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected reference mock request.") }
        return replies.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class ReferenceTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class ChatReferenceTests: XCTestCase {
    private let id = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private func event(status: String = "upcoming", timezone: String = "America/New_York") throws -> SharedChatEvent {
        try JSONDecoder().decode(SharedChatEvent.self, from: Data(#"{"id":"\#(id)","title":"Synthetic private event","visibility":"private","status":"\#(status)","revision":4,"participationRevision":7,"startsAtISO":"2026-11-10T15:00:00Z","endsAtISO":"2026-11-10T17:00:00Z","timezone":"\#(timezone)","location":{"label":"Fixed synthetic venue","latitude":40,"longitude":-73,"radiusMeters":100}}"#.utf8))
    }
    private func setup(enabled: Bool, replies: [CommunityResponse] = []) async throws -> (CommunityFeatureClient, ReferenceTestTransport) {
        let login = CommunityResponse(status: 200, data: Data(#"{"user":{"id":"\#(id)","email":"test@example.invalid","displayName":"Test","role":"admin","verified":true},"token":"synthetic-reference-token","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
        let config = CommunityResponse(status: 200, data: Data(#"{"requireEmailVerification":false,"messagingEnabled":true,"chatReferencesEnabled":\#(enabled)}"#.utf8))
        let stub = ReferenceTestTransport([login, config] + replies)
        let controller = CommunityController(vault: ReferenceTestVault(), factory: { _ in stub })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (try CommunityFeatureClient(controller), stub)
    }
    func testReferenceOnlyIntentBindsExactDisplayedEventRevisionsWithoutGrantFields() async throws {
        let reference = try ChatReferenceSelection(event: event())
        let intent = try ChatSendIntent(context: .direct(peer: peer, event: nil), text: "", attachmentID: nil, pin: nil, reference: reference)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
        let ref = try XCTUnwrap(fields["reference"] as? [String: Any])
        XCTAssertEqual(ref["id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(ref["expectedRevision"] as? Int, 4); XCTAssertEqual(ref["expectedParticipationRevision"] as? Int, 7)
        XCTAssertNil(fields["slot"]); XCTAssertNil(fields["invite"]); XCTAssertNil(fields["rsvp"]); XCTAssertNil(fields["latitude"])
        let response = CommunityResponse(status: 200, data: Data(#"{"message":{"id":"\#(id)","senderId":"\#(id)","text":"","createdAt":1700000000000,"reference":{"kind":"event","available":false}}}"#.utf8))
        let (client, stub) = try await setup(enabled: true, replies: [response, response])
        _ = try await client.sendChat(intent); _ = try await client.sendChat(intent)
        let requests = await stub.history()
        XCTAssertEqual(requests[2].httpBody, intent.data); XCTAssertEqual(requests[3].httpBody, intent.data)
        XCTAssertThrowsError(try ChatReferenceSelection(event: event(status: "ended")))
    }
    func testCommunitySelectionCannotBecomePrivateCloudOrExclusiveReference() throws {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatReferenceSelection(gif: id))) as? [String: String]
        XCTAssertEqual(value, ["kind":"communityGif", "id":id.uuidString.lowercased()])
    }
    func testUnavailableHydrationNeverKeepsPrivateMetadataOrFallbackURLs() throws {
        let value = try JSONDecoder().decode(HydratedChatReference.self, from: Data(#"{"kind":"event","available":false,"title":"PRIVATE TITLE","coverUrl":"https://foreign.example/private"}"#.utf8))
        XCTAssertNil(value.event); XCTAssertNil(value.gif); XCTAssertFalse(value.fingerprint.contains("PRIVATE"))
    }
    func testEventDatesUseVerifiedTimezoneAndRejectInvalidZone() throws {
        let dates = try event().dates(locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(dates.hasSuffix("(America/New_York)"))
        XCTAssertTrue(dates.contains("10:00")); XCTAssertTrue(dates.contains("12:00"))
        XCTAssertThrowsError(try event(timezone: "Invalid/Zone").dates())
    }
    func testPickerAndSentMediaHaveDistinctExactScopeAndNoTokenOrForeignFallback() throws {
        let context = ChatConversation.direct(peer: peer, event: nil)
        let path = "/api/v1/social/chat-references/catalog/\(id.uuidString.lowercased())/preview.png?peerId=\(peer.uuidString.lowercased())"
        let result = try ChatReferenceMedia.path(path, context: context)
        XCTAssertEqual(result.1, context.query)
        XCTAssertThrowsError(try ChatReferenceMedia.path(path, context: .room(id)))
        XCTAssertThrowsError(try ChatReferenceMedia.path(path + "&token=secret", context: context))
        XCTAssertThrowsError(try ChatReferenceMedia.path("https://foreign.example" + path, context: context))
        XCTAssertThrowsError(try ChatReferenceMedia.path("/api/v1/cloud/items/\(id)", context: nil))
        XCTAssertThrowsError(try ChatReferenceMedia.path("/api/v1/social/chat-references/\(id)/original.gif?peerId=\(peer)", context: context))
    }
    func testMissingCapabilityCannotSendReferenceEvenAsAdmin() async throws {
        let (client, stub) = try await setup(enabled: false)
        let intent = try ChatSendIntent(context: .room(id), text: "", attachmentID: nil, pin: nil, reference: ChatReferenceSelection(gif: id))
        do { _ = try await client.sendChat(intent); XCTFail("Missing reference capability") } catch {}
        do { _ = try await client.referenceEvents(.room(id), page: 1); XCTFail("Missing picker capability") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testScopedPickerUsesCapturedConversationAndRejectsOversizedPage() async throws {
        let reply = CommunityResponse(status: 200, data: Data(#"{"items":[],"page":2,"hasMore":false}"#.utf8))
        let (client, stub) = try await setup(enabled: true, replies: [reply])
        _ = try await client.referenceGIFs(.direct(peer: peer, event: id), page: 2, search: "Test")
        do { _ = try await client.referenceGIFs(.room(id), page: 1001, search: ""); XCTFail("Invalid bounded page") } catch {}
        let requests = await stub.history(), last = try XCTUnwrap(requests.last)
        let query = try XCTUnwrap(URLComponents(url: last.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(.init(name: "peerId", value: peer.uuidString.lowercased())))
        XCTAssertTrue(query.contains(.init(name: "eventId", value: id.uuidString.lowercased())))
        XCTAssertFalse(query.contains { $0.name == "token" }); XCTAssertEqual(requests.count, 3)
    }
    func testPickerEnforcesActualTwentyFourRowOutputBound() async throws {
        let item = #"{"kind":"communityGif","available":false}"#
        let valid = CommunityResponse(status: 200, data: Data(#"{"items":[\#(Array(repeating:item,count:24).joined(separator:","))],"page":1,"hasMore":true}"#.utf8))
        let invalid = CommunityResponse(status: 200, data: Data(#"{"items":[\#(Array(repeating:item,count:25).joined(separator:","))],"page":2,"hasMore":false}"#.utf8))
        let (client, _) = try await setup(enabled: true, replies: [valid, invalid])
        let result = try await client.referenceGIFs(.room(id), page: 1, search: "")
        XCTAssertEqual(result.items.count, 24)
        do { _ = try await client.referenceGIFs(.room(id), page: 2, search: ""); XCTFail("25-row response must fail") } catch {}
    }
}
