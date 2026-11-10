import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor ChatPerformanceTransport: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected performance test request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}

@MainActor
private final class ChatPerformanceVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class CommunityChatPerformanceTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let token = String(repeating: "a", count: 43)
    private func response(_ body: String, status: Int = 200) -> CommunityResponse {
        CommunityResponse(status: status, data: Data(body.utf8))
    }
    private func setup(_ responses: [CommunityResponse], advertised: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, ChatPerformanceTransport) {
        let flags = advertised ? #","chatInboxEnabled":true,"chatHistoryValidationEnabled":true"# : ""
        let login = response(#"{"user":{"id":"\#(account)","email":"test@example.invalid","displayName":"Test","role":"user","verified":true},"token":"test-only-chat-performance-token","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = response(#"{"requireEmailVerification":false,"socialEnabled":true,"messagingEnabled":true,"groupChatsEnabled":true\#(flags)}"#)
        let transport = ChatPerformanceTransport([login, config] + responses)
        let controller = CommunityController(vault: ChatPerformanceVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "test-only-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    private func fullHistory() -> String {
        #"{"messages":[],"page":1,"limit":50,"hasMore":false,"nextBefore":null,"historyRevision":"\#(token)"}"#
    }
    private func knownRevision(_ request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "knownRevision" }?.value
    }
    func testConditionalHistorySendsOnlyMatchingLatestContextToken() async throws {
        let (_, client, transport) = try await setup([
            response(fullHistory()), response(#"{"unchanged":true,"historyRevision":"\#(token)"}"#),
            response(fullHistory())
        ])
        let initial = try await client.directHistory(peer: peer, event: nil, before: nil)
        XCTAssertNil(initial.unchanged)
        let unchanged = try await client.directHistory(peer: peer, event: nil, before: nil)
        XCTAssertEqual(unchanged.unchanged, true)
        let cursor = DirectChatCursor(createdAt: 1, id: UUID())
        _ = try await client.directHistory(peer: peer, event: nil, before: cursor)
        let requests = await transport.history()
        XCTAssertNil(knownRevision(requests[2]))
        XCTAssertEqual(knownRevision(requests[3]), token)
        XCTAssertNil(knownRevision(requests[4]))
    }
    func testOlderServerDoesNotReceiveConditionalParameterOrUnifiedInboxRequest() async throws {
        let (_, client, transport) = try await setup([response(fullHistory()), response(fullHistory())], advertised: false)
        XCTAssertFalse(client.chatInboxEnabled)
        XCTAssertFalse(client.chatHistoryValidationEnabled)
        _ = try await client.directHistory(peer: peer, event: nil, before: nil)
        _ = try await client.directHistory(peer: peer, event: nil, before: nil)
        do { _ = try await client.chatInbox(after: nil); XCTFail("Unadvertised inbox must not issue I/O") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not enabled")) }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 4)
        XCTAssertNil(knownRevision(requests[3]))
    }
    func testRevocationIsNotReplacedByCachedHistory() async throws {
        let (_, client, _) = try await setup([response(fullHistory()),
            response(#"{"error":{"code":"chat_unavailable","message":"Chat is unavailable"}}"#, status: 404)])
        _ = try await client.directHistory(peer: peer, event: nil, before: nil)
        do { _ = try await client.directHistory(peer: peer, event: nil, before: nil); XCTFail("Must reauthorize before cache reuse") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 404) }
    }
    func testUnifiedInboxConsumesOneRequestAndPreservesUnknownDirectMetadata() async throws {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let entry = #"{"id":"direct:\#(peer.uuidString.lowercased()):","kind":"direct","updatedAt":\#(timestamp),"contact":{"profile":{"id":"\#(peer)","displayName":"Peer"},"eventId":null,"lastMessageCreatedAt":\#(timestamp)},"unread":null,"snippet":null}"#
        let (_, client, transport) = try await setup([response(#"{"version":1,"limit":24,"entries":[\#(entry)],"hasMore":false,"nextAfter":null}"#)])
        let page = try await client.chatInbox(after: nil)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertNil(page.entries[0].unread)
        XCTAssertNil(page.entries[0].snippet)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.url?.path, "/api/v1/social/chat-inbox")
    }
}
