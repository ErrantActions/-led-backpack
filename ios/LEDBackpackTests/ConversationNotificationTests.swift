import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor MuteTestTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    var lateChange: (@MainActor @Sendable () -> Void)?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func setLateChange(_ action: @escaping @MainActor @Sendable () -> Void) { lateChange = action }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected mute mock request.") }
        let result = responses.removeFirst()
        if request.url?.path == "/api/v1/notifications/chat-preferences" { await lateChange?() }
        return result
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class MuteTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class ConversationNotificationTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let event = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private func reply(_ json: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(json.utf8)) }
    private func setup(_ responses: [CommunityResponse], enabled: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, MuteTestTransport) {
        let login = reply(#"{"user":{"id":"\#(account)","email":"test@example.invalid","displayName":"Test","role":"admin","verified":true},"token":"synthetic-mute-session","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(#"{"requireEmailVerification":false,"messagingEnabled":true,"chatNotificationPreferencesEnabled":\#(enabled)}"#)
        let stub = MuteTestTransport([login, config] + responses)
        let controller = CommunityController(vault: MuteTestVault(), factory: { _ in stub })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), stub)
    }
    func testMissingCapabilityCannotReadOrWriteEvenAsAdmin() async throws {
        let (_, client, stub) = try await setup([], enabled: false)
        XCTAssertFalse(client.chatNotificationPreferencesEnabled)
        let intent = try ChatMuteIntent(context: .room(event), preference: ChatNotificationPreference(revision: 0, muted: false), muted: true)
        do { _ = try await client.chatNotificationPreference(.room(event)); XCTFail("Absent capability") } catch {}
        do { _ = try await client.saveChatNotificationPreference(intent); XCTFail("Absent capability") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testDirectOrganizerQuestionsAndRoomsHaveIndependentExactContexts() throws {
        let initial = ChatNotificationPreference(revision: 0, muted: false)
        let contexts: [ChatConversation] = [.direct(peer: peer, event: nil), .direct(peer: peer, event: event), .room(event)]
        let fields = try contexts.map { context -> [String: Any] in
            let value = try ChatMuteIntent(context: context, preference: initial, muted: true)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: value.data) as? [String: Any])
        }
        XCTAssertEqual(fields[0]["context"] as? [String: String], ["peerId":peer.uuidString.lowercased()])
        XCTAssertEqual(fields[1]["context"] as? [String: String], ["peerId":peer.uuidString.lowercased(),"eventId":event.uuidString.lowercased()])
        XCTAssertEqual(fields[2]["context"] as? [String: String], ["roomId":event.uuidString.lowercased()])
        XCTAssertEqual(fields[0]["expectedRevision"] as? Int, 0); XCTAssertNil(fields[0]["deleteMessages"])
    }
    func testOwnerReadUsesOnlyCapturedContextAndRevisionZeroIsUnmuted() async throws {
        let (_, client, stub) = try await setup([reply(#"{"revision":0,"muted":false}"#)])
        let value = try await client.chatNotificationPreference(.direct(peer: peer, event: event))
        XCTAssertEqual(value.revision, 0); XCTAssertFalse(value.muted)
        let requests = await stub.history()
        let request = try XCTUnwrap(requests.last)
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, ChatConversation.direct(peer: peer, event: event).query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Expected-Account"), account.uuidString.lowercased())
    }
    func testPatchCapturesExactRevisionContextAndAckWithoutChangingMessages() async throws {
        let (_, client, stub) = try await setup([reply(#"{"revision":8,"muted":true}"#)])
        let intent = try ChatMuteIntent(context: .room(event), preference: ChatNotificationPreference(revision: 7, muted: false), muted: true)
        let result = try await client.saveChatNotificationPreference(intent)
        XCTAssertTrue(result.muted); XCTAssertEqual(result.revision, 8)
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].httpMethod, "PATCH")
        XCTAssertEqual(requests[2].httpBody, intent.data); XCTAssertNil(requests[2].url?.query)
    }
    func testConflictRetainsImmutableIntentAndCannotSilentlyRetryOrRebase() async throws {
        let (_, client, stub) = try await setup([reply(#"{"error":{"code":"chat_preferences_changed","message":"Reload current settings"}}"#, status: 409)])
        let intent = try ChatMuteIntent(context: .direct(peer: peer, event: event), preference: ChatNotificationPreference(revision: 4, muted: false), muted: true)
        let original = intent.data
        do { _ = try await client.saveChatNotificationPreference(intent); XCTFail("Conflict") }
        catch let error as CommunityFailure { XCTAssertEqual(error.status, 409) }
        XCTAssertEqual(intent.data, original); XCTAssertEqual(intent.expectedRevision, 4)
        let requests = await stub.history(); XCTAssertEqual(requests.count, 3)
    }
    func testLateAccountOriginChangeCannotApplyOwnerMuteResult() async throws {
        let (controller, client, stub) = try await setup([reply(#"{"revision":1,"muted":true}"#)])
        await stub.setLateChange { controller.configure("https://different.example") }
        do { _ = try await client.chatNotificationPreference(.room(event)); XCTFail("Late scope change") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 3)
    }
}
