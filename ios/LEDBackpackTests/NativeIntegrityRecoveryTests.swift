import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class RecoveryTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
private final class RecoveryUnsupportedSDK: NativeAttestProvider {
    let supported = false
    func generateKey() async throws -> String { throw BackpackError.invalid("Recovery must not call SDK") }
    func attest(_ key: String, hash: Data) async throws -> Data { throw BackpackError.invalid("Recovery must not call SDK") }
    func assert(_ key: String, hash: Data) async throws -> Data { throw BackpackError.invalid("Recovery must not call SDK") }
}
private actor RecoveryTestTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected recovery mock request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
final class NativeIntegrityRecoveryTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let key = Data(repeating: 251, count: 32).base64EncodedString()
    private func setup(_ response: CommunityResponse) async throws -> (CommunityController, NativeAppIntegrity, RecoveryTestTransport) {
        let vault = RecoveryTestVault(), cache = RecoveryTestVault()
        let broker = NativeAppIntegrity(provider: RecoveryUnsupportedSDK(), cache: cache)
        try cache.save(JSONEncoder().encode(NativeAppIntegrity.Key(id: key, enrolled: true, uncertain: false)),
            key: "app-attest|https://catalog.example|\(account.uuidString.lowercased())")
        let login = CommunityResponse(status: 200, data: Data(#"{"user":{"id":"\#(account)","email":"test@example.invalid","displayName":"Test","role":"admin","verified":true},"token":"synthetic-recovery-token","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
        let config = CommunityResponse(status: 200, data: Data(#"{"requireEmailVerification":false,"appIntegrityProtocol":"app-attest-v1","appIntegrityEnforcementEnabled":true,"appIntegrityEnforcementReady":false}"#.utf8))
        let stub = RecoveryTestTransport([login, config, response])
        let controller = CommunityController(vault: vault, integrity: broker, factory: { _ in stub })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, broker, stub)
    }
    func testCanonicalStandardBase64PathEncodesSlashPlusAndPadding() throws {
        let url = try NativeIntegrityKeyRoute.url(origin: CommunityOrigin.parse("https://catalog.example"), key: key)
        let path = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        XCTAssertTrue(path.contains("%2F")); XCTAssertTrue(path.contains("%2B")); XCTAssertTrue(path.hasSuffix("%3D"))
        XCTAssertNil(url.query)
        XCTAssertThrowsError(try NativeIntegrityKeyRoute.url(origin: CommunityOrigin.parse("https://catalog.example"), key: String(key.dropLast())))
    }
    func testFreshPrimaryControlDoesNotRequireSdkOrProofFallback() async throws {
        let response = CommunityResponse(status: 200, data: Data(#"{"keys":[{"keyId":"\#(key)","createdAt":"2026-11-01T00:00:00Z"}]}"#.utf8))
        let (controller, _, stub) = try await setup(response)
        let result = try await controller.integrityKeys(); XCTAssertEqual(result.map(\.keyId), [key])
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 3); XCTAssertEqual(requests[2].url?.path, "/api/v1/app-integrity/keys")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-recovery-token")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "X-Catalog-Integrity-Session"))
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "X-Catalog-App-Attest-Assertion"))
    }
    func testCapturedRevocationClearsOnlyMatchingLocalKeyWithoutAccountRevisionChange() async throws {
        let response = CommunityResponse(status: 200, data: Data(#"{"keyId":"\#(key)","revoked":true}"#.utf8))
        let (controller, broker, stub) = try await setup(response)
        let accountEpoch = controller.accountRevision, integrityEpoch = controller.nativeIntegrityRevision
        try await controller.revokeIntegrityKey(NativeIntegrityOwnedKey(keyId: key, createdAt: "2026-11-01T00:00:00Z"))
        XCTAssertEqual(controller.accountRevision, accountEpoch); XCTAssertNotEqual(controller.nativeIntegrityRevision, integrityEpoch)
        XCTAssertNil(try broker.keyID(origin: CommunityOrigin.parse("https://catalog.example"), account: account))
        let requests = await stub.history()
        XCTAssertEqual(requests[2].httpBody, Data(#"{"confirmation":"REVOKE"}"#.utf8)); XCTAssertEqual(requests[2].httpMethod, "DELETE")
    }
    func testStalePrimaryAuthenticationCannotPretendRevocationSucceeded() async throws {
        let (controller, broker, _) = try await setup(CommunityResponse(status: 401, data: Data()))
        do { try await controller.revokeIntegrityKey(NativeIntegrityOwnedKey(keyId: key, createdAt: "2026-11-01T00:00:00Z")); XCTFail("Fresh auth required") }
        catch let error as CommunityFailure { XCTAssertEqual(error.status, 401) }
        XCTAssertEqual(try broker.keyID(origin: CommunityOrigin.parse("https://catalog.example"), account: account), key)
    }
    func testWrongReceiptCannotClearCapturedKey() async throws {
        let other = Data(repeating: 2, count: 32).base64EncodedString()
        let (controller, broker, _) = try await setup(CommunityResponse(status: 200, data: Data(#"{"keyId":"\#(other)","revoked":true}"#.utf8)))
        do { try await controller.revokeIntegrityKey(NativeIntegrityOwnedKey(keyId: key, createdAt: "2026-11-01T00:00:00Z")); XCTFail("Wrong key") } catch {}
        XCTAssertEqual(try broker.keyID(origin: CommunityOrigin.parse("https://catalog.example"), account: account), key)
    }
}
