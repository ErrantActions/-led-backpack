import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class GuestTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
private final class GuestTestProvider: NativeAttestProvider {
    let supported = true
    var generations = 0
    var attestations = 0
    var assertions = 0
    var generated: (() -> Void)?
    func generateKey() async throws -> String { generations += 1; generated?(); return Data(repeating: 1, count: 32).base64EncodedString() }
    func attest(_ key: String, hash: Data) async throws -> Data { attestations += 1; return Data([1,2,3]) }
    func assert(_ key: String, hash: Data) async throws -> Data { assertions += 1; return Data([4,5,6]) }
}
private actor GuestTestTransport: CommunityTransport {
    private var requests: [URLRequest] = []
    let account: UUID
    var disabled: Bool
    init(account: UUID, disabled: Bool = false) { self.account = account; self.disabled = disabled }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        if disabled { return CommunityResponse(status: 503, data: Data()) }
        let path = request.url!.path
        var result: [String: Any] = [:]
        let fields = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        if path.hasSuffix("/sessions") {
            result = ["protocol":"app-attest-v1","token":NativeIntegrityBinding.base64URL(Data(repeating: 9, count: 32)),
                "expiresAt":CatalogEventTime.wire(Date().addingTimeInterval(86400))]
        } else if path.hasSuffix("/challenges") {
            let purpose = fields["purpose"]!, key = fields["keyId"]!, id = UUID().uuidString.lowercased()
            let token = request.value(forHTTPHeaderField: "X-Catalog-Integrity-Session") ??
                String(request.value(forHTTPHeaderField: "Authorization")!.dropFirst(7))
            let user: Any = request.value(forHTTPHeaderField: "Authorization") == nil ? NSNull() : account.uuidString.lowercased()
            let session = NativeIntegrityBinding.digest(Data(token.utf8))
            let scope = NativeIntegrityBinding.digest(try NativeIntegrityBinding.json([user, session]))
            let method = fields["method"] ?? "POST", target = fields["path"] ?? "/api/v1/app-integrity/enroll"
            let hash = try fields["bodyHash"] ?? NativeIntegrityBinding.enrollmentHash(key)
            let nonce = NativeIntegrityBinding.base64URL(Data(repeating: 3, count: 32))
            let message = try String(data: NativeIntegrityBinding.json(["led-backpack.app-integrity.v1","https://catalog.example",
                id,nonce,purpose,key,user,session,scope,method,target,hash]), encoding: .utf8)!
            result = ["protocol":"app-attest-v1","id":id,"nonce":nonce,"message":message,"expiresAt":CatalogEventTime.wire(Date().addingTimeInterval(120)),
                "lifetimeSeconds":120,"origin":"https://catalog.example","purpose":purpose,"keyId":key,"userId":user,
                "sessionHash":session,"scopeHash":scope,"method":method,"path":target,"bodyHash":hash]
        } else if path.hasSuffix("/enroll") {
            result = ["protocol":"app-attest-v1","keyId":fields["keyId"]!,"environment":"production","enforcementReady":false]
        }
        return CommunityResponse(status: 200, data: try JSONSerialization.data(withJSONObject: result))
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
final class NativeGuestIntegrityTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    func testActualAnonymousBootstrapThenLoginAndPermanentAccountScopeAdoption() async throws {
        let origin = try CommunityOrigin.parse("https://catalog.example"), provider = GuestTestProvider(), cache = GuestTestVault()
        let broker = NativeAppIntegrity(provider: provider, cache: cache), transport = GuestTestTransport(account: account)
        var login = URLRequest(url: try origin.api("auth/login"))
        login.httpMethod = "POST"; login.httpBody = Data(#"{"transport":"bearer","email":"test@example.invalid","password":"synthetic-password"}"#.utf8)
        _ = try await broker.performGuest(login, origin: origin, transport: transport, maxBytes: 4096, check: {})
        try broker.adoptGuestKey(origin: origin, account: account)
        var request = URLRequest(url: try origin.api("auth/me"))
        request.setValue("Bearer synthetic-account-session", forHTTPHeaderField: "Authorization")
        _ = try await broker.perform(request, origin: origin, account: account, token: "synthetic-account-session", transport: transport, maxBytes: 4096, check: {})
        let requests = await transport.history()
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/app-integrity/sessions")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "X-Catalog-Integrity-Session"))
        let sentLogin = try XCTUnwrap(requests.first { $0.url?.path == "/api/v1/auth/login" })
        XCTAssertEqual(sentLogin.httpBody, login.httpBody)
        XCTAssertNotNil(sentLogin.value(forHTTPHeaderField: "X-Catalog-App-Attest-Assertion"))
        XCTAssertNotNil(sentLogin.value(forHTTPHeaderField: "X-Catalog-Integrity-Session"))
        XCTAssertNil(sentLogin.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "X-Catalog-Integrity-Session"))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-account-session")
        XCTAssertEqual(provider.generations, 1); XCTAssertEqual(provider.attestations, 1); XCTAssertEqual(provider.assertions, 2)
        XCTAssertNotNil(try broker.keyID(origin: origin, account: account))
    }
    func testDisabledBootstrapCannotFabricateEnrollmentOrProtectedLogin() async throws {
        let origin = try CommunityOrigin.parse("https://catalog.example"), provider = GuestTestProvider()
        let broker = NativeAppIntegrity(provider: provider, cache: GuestTestVault()), transport = GuestTestTransport(account: account, disabled: true)
        do { _ = try await broker.performGuest(URLRequest(url: origin.api("auth/login")), origin: origin, transport: transport, maxBytes: 4096, check: {}); XCTFail("Disabled") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(provider.generations, 0); XCTAssertEqual(provider.assertions, 0)
    }
    func testGuestScopeChangeDuringSdkGenerationStopsBeforeEnrollmentOrLogin() async throws {
        let origin = try CommunityOrigin.parse("https://catalog.example"), provider = GuestTestProvider()
        let broker = NativeAppIntegrity(provider: provider, cache: GuestTestVault()), transport = GuestTestTransport(account: account)
        var current = true; provider.generated = { current = false }
        do {
            _ = try await broker.performGuest(URLRequest(url: origin.api("auth/login")), origin: origin, transport: transport, maxBytes: 4096,
                check: { if !current { throw BackpackError.invalid("Changed origin/account") } })
            XCTFail("Changed scope")
        } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 1); XCTAssertEqual(provider.attestations, 0)
    }
}
