import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class StreamProofVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
private final class StreamProofProvider: NativeAttestProvider {
    let supported = true
    var assertion: (() -> Void)?
    func generateKey() async throws -> String { throw BackpackError.invalid("Expected enrolled stream key") }
    func attest(_ key: String, hash: Data) async throws -> Data { throw BackpackError.invalid("No stream attestation replay") }
    func assert(_ key: String, hash: Data) async throws -> Data { assertion?(); return Data([1,2,3]) }
}
private actor StreamProofTransport: CommunityTransport {
    let account: UUID
    private var requests: [URLRequest] = []
    init(_ account: UUID) { self.account = account }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        let key = fields["keyId"]!, method = fields["method"]!, path = fields["path"]!, hash = fields["bodyHash"]!
        let token = String(request.value(forHTTPHeaderField: "Authorization")!.dropFirst(7))
        let session = NativeIntegrityBinding.digest(Data(token.utf8))
        let scope = NativeIntegrityBinding.digest(try NativeIntegrityBinding.json([account.uuidString.lowercased(), session]))
        let id = UUID().uuidString.lowercased(), nonce = NativeIntegrityBinding.base64URL(Data(repeating: 3, count: 32))
        let message = try String(data: NativeIntegrityBinding.json(["led-backpack.app-integrity.v1","https://catalog.example",
            id,nonce,"request",key,account.uuidString.lowercased(),session,scope,method,path,hash]), encoding: .utf8)!
        let lifetime = NativeIntegrityBinding.lifetime(method: method, path: path)
        let response: [String: Any] = ["protocol":"app-attest-v1","id":id,"nonce":nonce,"message":message,
            "expiresAt":CatalogEventTime.wire(Date().addingTimeInterval(Double(lifetime))),"lifetimeSeconds":lifetime,
            "origin":"https://catalog.example","purpose":"request","keyId":key,"userId":account.uuidString.lowercased(),
            "sessionHash":session,"scopeHash":scope,"method":method,"path":path,"bodyHash":hash]
        return CommunityResponse(status: 200, data: try JSONSerialization.data(withJSONObject: response))
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
final class NativeStreamIntegrityTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let token = "synthetic-stream-session"
    private func setup() throws -> (NativeAppIntegrity, StreamProofProvider, StreamProofTransport, CommunityOrigin) {
        let origin = try CommunityOrigin.parse("https://catalog.example"), cache = StreamProofVault(), provider = StreamProofProvider()
        try cache.save(JSONEncoder().encode(NativeAppIntegrity.Key(id: Data(repeating: 1, count: 32).base64EncodedString(), enrolled: true, uncertain: false)),
            key: "app-attest|https://catalog.example|\(account.uuidString.lowercased())")
        return (NativeAppIntegrity(provider: provider, cache: cache), provider, StreamProofTransport(account), origin)
    }
    func testSseOpeningSignsExactBodylessQueryAndPreservesBearerOnlyScope() async throws {
        let (broker, _, transport, origin) = try setup()
        var request = URLRequest(url: try origin.api("social/chat-events", query: [.init(name: "peerId", value: account.uuidString.lowercased()), .init(name: "eventId", value: account.uuidString.lowercased())]))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let signed = try await broker.authorized(request, origin: origin, account: account, token: token, transport: transport, check: {}) { $0 }
        XCTAssertEqual(signed.url, request.url); XCTAssertEqual(signed.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNotNil(signed.value(forHTTPHeaderField: "X-Catalog-App-Attest-Assertion")); XCTAssertNil(signed.httpBody)
        XCTAssertNil(signed.value(forHTTPHeaderField: "X-Catalog-Integrity-Session"))
        let history = await transport.history()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: history[0].httpBody!) as? [String: String])
        XCTAssertEqual(fields["bodyHash"], NativeIntegrityBinding.digest(Data())); XCTAssertEqual(fields["method"], "GET")
        XCTAssertEqual(fields["path"], "/api/v1/social/chat-events?\(request.url!.query!)")
    }
    func testScopeChangeDuringAssertionCannotOpenHeaderOnlyStream() async throws {
        let (broker, provider, transport, origin) = try setup()
        var request = URLRequest(url: try origin.api("social/chat-events")); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var current = true, opened = false
        provider.assertion = { current = false }
        do {
            _ = try await broker.authorized(request, origin: origin, account: account, token: token, transport: transport,
                check: { if !current { throw BackpackError.invalid("Scope changed") } }, send: { value in opened = true; return value })
            XCTFail("Stale stream opened")
        } catch {}
        XCTAssertFalse(opened)
    }
    func testSignedUploadStreamIsExactlyTheImmutableSnapshotAndHash() async throws {
        let (broker, _, transport, origin) = try setup()
        let payload = Data("metadata\r\noriginal immutable ZIP multipart bytes".utf8)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("proof-stream-\(UUID().uuidString).multipart")
        try payload.write(to: source)
        addTeardownBlock { try FileManager.default.removeItem(at: source) }
        let file = try await NativeRequestFileBuilder.shared.capture(source, maxBytes: 4096)
        addTeardownBlock { try file.remove() }
        try Data("modified caller file after snapshot".utf8).write(to: source)
        var request = URLRequest(url: try origin.api("admin/imports")); request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue(String(file.byteCount), forHTTPHeaderField: "Content-Length")
        let received = try await broker.authorized(request, origin: origin, account: account, token: token, transport: transport, bodyFile: file, check: {}) { signed in
            let stream = try XCTUnwrap(signed.httpBodyStream); stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096), data = Data()
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count < 0 { throw BackpackError.invalid("Stream failed") }; if count == 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            return data
        }
        XCTAssertEqual(received, payload)
        let history = await transport.history()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: history[0].httpBody!) as? [String: String])
        XCTAssertEqual(fields["bodyHash"], NativeIntegrityBinding.digest(received))
        XCTAssertEqual(NativeIntegrityBinding.lifetime(method: "POST", path: fields["path"]!), 360)
    }
}
