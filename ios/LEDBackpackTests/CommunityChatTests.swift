import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor ChatTestTransport: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected chat mock request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class ChatTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class CommunityChatTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let room = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let event = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    private let message = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
    private func reply(_ body: String) -> CommunityResponse { CommunityResponse(status: 200, data: Data(body.utf8)) }
    private func setup(_ responses: [CommunityResponse], enabled: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, ChatTestTransport) {
        let login = reply(#"{"user":{"id":"\#(account)","email":"test@example.invalid","displayName":"Test","role":"admin","verified":true},"token":"test-only-chat-token-not-real","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(enabled ?
            #"{"requireEmailVerification":false,"socialEnabled":true,"messagingEnabled":true,"groupChatsEnabled":true,"eventChatsEnabled":true,"chatMediaEnabled":true,"chatPinsEnabled":true,"liveChatEnabled":true,"chatLiveProtocol":"sse-v1"}"# :
            #"{"requireEmailVerification":false,"messagingEnabled":true}"#)
        let stub = ChatTestTransport([login, config] + responses)
        let controller = CommunityController(vault: ChatTestVault(), factory: { _ in stub })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "test-only-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), stub)
    }
    private func messageDTO(event: UUID? = nil, recipient: Bool = true) -> String {
        let fields = recipient ? #","recipientId":"\#(peer)""# : ""
        let scope = event.map { #","eventId":"\#($0)""# } ?? ""
        let retainedNow = Int64(Date().timeIntervalSince1970 * 1000)
        return #"{"id":"\#(message)","senderId":"\#(account)","text":"Hello","createdAt":\#(retainedNow)\#(fields)\#(scope)}"#
    }
    func testAbsentOptionalCapabilitiesFailClosed() async throws {
        let (_, client, stub) = try await setup([], enabled: false)
        XCTAssertFalse(client.groupsEnabled); XCTAssertFalse(client.eventChatsEnabled)
        XCTAssertFalse(client.chatMediaEnabled); XCTAssertFalse(client.chatPinsEnabled); XCTAssertFalse(client.chatLiveEnabled)
        do { _ = try await client.openEventRoom(event); XCTFail("Missing event chat flag") } catch {}
        do { _ = try client.chatHints(.room(room)); XCTFail("Missing live protocol") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testPrivateQuestionIntentHasExactContextAndNoRoomOrHistoryOverride() throws {
        let value = try ChatSendIntent(context: .direct(peer: peer, event: event), text: "Hello", attachmentID: nil, pin: nil)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: value.data) as? [String: String])
        XCTAssertEqual(fields["recipientId"], peer.uuidString.lowercased())
        XCTAssertEqual(fields["eventId"], event.uuidString.lowercased())
        XCTAssertNil(fields["roomId"]); XCTAssertNil(fields["shareHistory"])
        XCTAssertEqual(fields["clientMessageId"], value.clientMessageID.uuidString.lowercased())
    }
    func testRetryUsesIdenticalIntentBytesAndCapturedAccountHeader() async throws {
        let (_, client, stub) = try await setup([reply(#"{"message":\#(messageDTO())}"#), reply(#"{"message":\#(messageDTO())}"#)])
        let value = try ChatSendIntent(context: .direct(peer: peer, event: nil), text: "Hello", attachmentID: nil, pin: nil)
        _ = try await client.sendChat(value); _ = try await client.sendChat(value)
        let requests = await stub.history()
        XCTAssertEqual(requests[2].httpBody, requests[3].httpBody)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Catalog-Expected-Account"), account.uuidString.lowercased())
        XCTAssertEqual(requests[2].url?.path, "/api/v1/social/messages")
    }
    func testDirectStablePagingUsesBothCursorFieldsAndEventContext() async throws {
        let (_, client, stub) = try await setup([reply(#"{"messages":[\#(messageDTO(event: event))],"page":1,"limit":50,"hasMore":false,"nextBefore":null}"#)])
        _ = try await client.directHistory(peer: peer, event: event, before: DirectChatCursor(createdAt: 1700000000000, id: message))
        let requests = await stub.history()
        let values = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(values.first { $0.name == "beforeCreatedAt" }?.value, "1700000000000")
        XCTAssertEqual(values.first { $0.name == "beforeId" }?.value, message.uuidString.lowercased())
        XCTAssertEqual(values.first { $0.name == "eventId" }?.value, event.uuidString.lowercased())
    }
    func testMalformedPrivateHistoryDoesNotDefaultMissingRecipient() async throws {
        let (_, client, _) = try await setup([reply(#"{"messages":[\#(messageDTO(recipient: false))],"page":1,"limit":50,"hasMore":false,"nextBefore":null}"#)])
        do { _ = try await client.directHistory(peer: peer, event: nil, before: nil); XCTFail("Missing recipient must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("captured context")) }
    }
    func testUnsafeAndFractionalCursorCannotTrapIntegerConversionOrSend() async throws {
        let (_, client, stub) = try await setup([])
        for time in [Double.infinity, Double.nan, 1e50, -1, 1700000000000.5] {
            do { _ = try await client.directHistory(peer: peer, event: nil, before: DirectChatCursor(createdAt: time, id: message)); XCTFail("Unsafe cursor") }
            catch {}
        }
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testDifferentEventPrivateHistoryIsNeverMerged() async throws {
        let (_, client, _) = try await setup([reply(#"{"messages":[\#(messageDTO())],"page":1,"limit":50,"hasMore":false,"nextBefore":null}"#)])
        do { _ = try await client.directHistory(peer: peer, event: event, before: nil); XCTFail("Wrong event") } catch {}
    }
    func testPinOnlyIntentIsTypedNormalizedAndNotJSONTextInference() throws {
        let pin = ChatPin(label: "  Meeting place  ", latitude: 45.123456789, longitude: -120.123456789)
        let value = try ChatSendIntent(context: .room(room), text: "", attachmentID: nil, pin: pin)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: value.data) as? [String: Any])
        XCTAssertNil(body["text"]); XCTAssertNil(body["recipientId"])
        let object = try XCTUnwrap(body["pin"] as? [String: Any])
        XCTAssertEqual(object["latitude"] as? Double, 45.123457)
        XCTAssertEqual(object["label"] as? String, "Meeting place")
        let text = try ChatSendIntent(context: .room(room), text: #"{"latitude":1}"#, attachmentID: nil, pin: nil)
        let textBody = try XCTUnwrap(JSONSerialization.jsonObject(with: text.data) as? [String: Any]); XCTAssertNil(textBody["pin"])
    }
    func testPinBoundsAndTrimmedLabelBudget() throws {
        XCTAssertThrowsError(try ChatPin(label: "Place", latitude: .nan, longitude: 0).normalized())
        XCTAssertThrowsError(try ChatPin(label: "Place", latitude: 0, longitude: 181).normalized())
        XCTAssertThrowsError(try ChatPin(label: String(repeating: "x", count: 121), latitude: 0, longitude: 0).normalized())
        XCTAssertNoThrow(try ChatPin(label: String(repeating: " ", count: 150) + "Place", latitude: 90, longitude: -180).normalized())
    }
    func testSSEFragmentsAndHeartbeatContainOnlyHints() throws {
        var parser = ChatSSEParser(), values: [ChatLiveHint] = []
        for byte in Data(": heartbeat\r\n\r\ndata: {\"type\":\"ready\"}\r\n\r\ndata: {\"type\":\"messages\"}\n\n".utf8) {
            if let value = try parser.push(byte) { values.append(value) }
        }
        XCTAssertEqual(values, [.ready, .messages])
    }
    func testSSERejectsPrivatePayloadAndBoundedOversizedLines() throws {
        var parser = ChatSSEParser()
        XCTAssertThrowsError(try Data("data: {\"type\":\"messages\",\"text\":\"private\"}\n\n".utf8).forEach { _ = try parser.push($0) })
        parser = ChatSSEParser()
        XCTAssertThrowsError(try Data(repeating: 65, count: 8193).forEach { _ = try parser.push($0) })
    }
    func testForeignPrivateMediaNeverFetchesOrFallsBackPublic() async throws {
        let (_, client, stub) = try await setup([])
        let media = PrivateChatAttachment(id: message, url: URL(string: "https://foreign.example/image.gif")!,
            previewUrl: URL(string: "https://foreign.example/preview.png")!, animated: true, mimeType: "image/gif", width: 512, height: 512)
        do { _ = try await client.privateChatMedia(media, animated: true); XCTFail("Foreign media") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testAdminCannotBypassGroupOwnership() async throws {
        let (_, client, stub) = try await setup([])
        let otherOwned = NativeChatRoom(id: room, kind: "group", title: "Private", eventId: nil, ownerId: peer, revision: 7,
            archived: false, canManage: true, canSend: true, updatedAt: 1700000000000, readSequence: 0, latestSequence: 0, unread: 0)
        do { try await client.manageRoom(otherOwned, target: nil, action: "delete"); XCTFail("Admin is not group owner") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
}
