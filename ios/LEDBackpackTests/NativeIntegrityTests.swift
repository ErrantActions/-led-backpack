import XCTest
import UserNotifications
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class IntegrityTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
private final class IntegrityTestProvider: NativeAttestProvider {
    var supported = true
    var generation: (() -> Void)?
    var attestations = 0
    var assertions = 0
    func generateKey() async throws -> String { generation?(); return Data(repeating: 1, count: 32).base64EncodedString() }
    func attest(_ key: String, hash: Data) async throws -> Data { attestations += 1; return Data([1,2,3]) }
    func assert(_ key: String, hash: Data) async throws -> Data { assertions += 1; return Data([4,5,6]) }
}
private actor IntegrityTestTransport: CommunityTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        return CommunityResponse(status: 503, data: Data())
    }
    func count() -> Int { requests.count }
}

@MainActor
final class NativeIntegrityTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let key = Data(repeating: 1, count: 32).base64EncodedString()
    private let token = "synthetic-test-session-not-a-real-token"
    private let path = "/api/v1/notifications/apple-devices"
    private func fixture(message: String? = nil, hash: String? = nil) throws -> NativeIntegrityChallenge {
        let origin = "https://catalog.example", id = UUID().uuidString.lowercased()
        let nonce = NativeIntegrityBinding.base64URL(Data(repeating: 2, count: 32))
        let session = NativeIntegrityBinding.digest(Data(token.utf8))
        let scope = NativeIntegrityBinding.digest(try NativeIntegrityBinding.json([account.uuidString.lowercased(), session]))
        let body = hash ?? NativeIntegrityBinding.digest(Data())
        let exact = try XCTUnwrap(String(data: NativeIntegrityBinding.json(["led-backpack.app-integrity.v1", origin, id, nonce,
            "request", key, account.uuidString.lowercased(), session, scope, "GET", path, body]), encoding: .utf8))
        let fields: [String: Any] = ["protocol":"app-attest-v1","id":id,"nonce":nonce,"message":message ?? exact,
            "expiresAt":CatalogEventTime.wire(Date().addingTimeInterval(120)),"origin":origin,"purpose":"request","keyId":key,
            "userId":account.uuidString.lowercased(),"sessionHash":session,"scopeHash":scope,"method":"GET","path":path,
            "bodyHash":body,"lifetimeSeconds":120]
        return try JSONDecoder().decode(NativeIntegrityChallenge.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func testChallengeMustBeIndependentlyReconstructedBeforeNativeSigning() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example")
        let value = try fixture()
        let bytes = try NativeIntegrityBinding.validatedHash(value, origin: origin, account: account, token: token, key: key,
            purpose: "request", method: "GET", path: path, bodyHash: NativeIntegrityBinding.digest(Data()))
        XCTAssertEqual(bytes.count, 32)
        XCTAssertThrowsError(try NativeIntegrityBinding.validatedHash(fixture(message: "blind returned server text"),
            origin: origin, account: account, token: token, key: key, purpose: "request", method: "GET", path: path,
            bodyHash: NativeIntegrityBinding.digest(Data())))
    }
    func testQueryBodyCurrentTokenAndAccountCannotBeAliased() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example"), value = try fixture()
        for request in ["/api/v1/notifications/apple-devices?x=1", "/api/v1/notifications/apple-activity/id"] {
            XCTAssertThrowsError(try NativeIntegrityBinding.validatedHash(value, origin: origin, account: account, token: token,
                key: key, purpose: "request", method: "GET", path: request, bodyHash: NativeIntegrityBinding.digest(Data())))
        }
        XCTAssertThrowsError(try NativeIntegrityBinding.validatedHash(value, origin: origin, account: UUID(), token: token,
            key: key, purpose: "request", method: "GET", path: path, bodyHash: NativeIntegrityBinding.digest(Data())))
        XCTAssertThrowsError(try NativeIntegrityBinding.validatedHash(value, origin: origin, account: account, token: "new-session",
            key: key, purpose: "request", method: "GET", path: path, bodyHash: NativeIntegrityBinding.digest(Data())))
        XCTAssertThrowsError(try NativeIntegrityBinding.validatedHash(value, origin: origin, account: account, token: token,
            key: key, purpose: "request", method: "GET", path: path, bodyHash: NativeIntegrityBinding.digest(Data("changed".utf8))))
    }
    func testKeyAndDigestEncodingsRemainDistinctAndCanonical() throws {
        XCTAssertTrue(NativeIntegrityBinding.canonicalKey(key))
        XCTAssertFalse(NativeIntegrityBinding.canonicalKey(String(key.dropLast())))
        let digest = NativeIntegrityBinding.digest(Data())
        XCTAssertTrue(NativeIntegrityBinding.canonicalDigest(digest))
        XCTAssertFalse(NativeIntegrityBinding.canonicalDigest(digest + "="))
        XCTAssertEqual(try NativeIntegrityBinding.enrollmentHash(key),
            NativeIntegrityBinding.digest(try NativeIntegrityBinding.json(["led-backpack.app-integrity.enroll.v1", key])))
    }
    func testExactExpiryBoundaryAndWrongPurposeFailBeforeSdk() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example"), value = try fixture()
        XCTAssertThrowsError(try NativeIntegrityBinding.validatedHash(value, origin: origin, account: account, token: token,
            key: key, purpose: "request", method: "GET", path: path, bodyHash: NativeIntegrityBinding.digest(Data()),
            now: CatalogEventTime.parse(value.expiresAt)))
        XCTAssertThrowsError(try NativeIntegrityBinding.validatedHash(value, origin: origin, account: account, token: token,
            key: key, purpose: "enroll", method: "POST", path: path, bodyHash: NativeIntegrityBinding.digest(Data())))
    }
    func testOfficialPermissionStatesDoNotMapUnsupportedOrInventTokens() throws {
        XCTAssertEqual(try NativePushPermission.value(.authorized), "authorized")
        XCTAssertEqual(try NativePushPermission.value(.provisional), "provisional")
        XCTAssertEqual(try NativePushPermission.value(.denied), "denied")
        XCTAssertEqual(try NativePushPermission.value(.notDetermined), "notDetermined")
        XCTAssertThrowsError(try NativePushPermission.value(.ephemeral))
    }
    func testDeviceEndpointsAndExactLifetimeSelectorFailClosed() {
        XCTAssertTrue(NativeApplePushRoute.valid("notifications/apple-devices", method: "POST"))
        XCTAssertTrue(NativeApplePushRoute.valid("notifications/apple-activity/\(account.uuidString.lowercased())", method: "GET"))
        XCTAssertFalse(NativeApplePushRoute.valid("notifications/apple-activity/\(account)", method: "DELETE"))
        XCTAssertFalse(NativeApplePushRoute.valid("notifications/apple-devices/../auth", method: "GET"))
        XCTAssertFalse(NativeApplePushRoute.valid("notifications/apple-devices/\(account)/extra", method: "DELETE"))
        XCTAssertEqual(NativeIntegrityBinding.lifetime(method: "POST", path: "/api/v1/social/avatar"), 360)
        XCTAssertEqual(NativeIntegrityBinding.lifetime(method: "POST", path: "/api/v1/social/chat-attachments"), 120)
        XCTAssertEqual(NativeIntegrityBinding.lifetime(method: "POST", path: "/api/v1/events/\(account)/assets"), 360)
        XCTAssertEqual(NativeIntegrityBinding.lifetime(method: "POST", path: "/api/v1/notifications/apple-devices"), 120)
    }
    func testUnsupportedSdkAndScopeChangeCannotEmitBootstrapOrBusinessRequest() async throws {
        let provider = IntegrityTestProvider(), cache = IntegrityTestVault(), transport = IntegrityTestTransport()
        let origin = try CommunityOrigin.parse("https://catalog.example")
        let broker = NativeAppIntegrity(provider: provider, cache: cache)
        var request = URLRequest(url: try origin.api("notifications/apple-devices"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        provider.supported = false
        do { _ = try await broker.perform(request, origin: origin, account: account, token: token, transport: transport, maxBytes: 4096, check: {}); XCTFail("No unsupported-SDK fallback") } catch {}
        provider.supported = true
        var current = true
        provider.generation = { current = false }
        do {
            _ = try await broker.perform(request, origin: origin, account: account, token: token, transport: transport,
                maxBytes: 4096, check: { if !current { throw BackpackError.invalid("Changed account") } })
            XCTFail("Scope changed during SDK key generation")
        } catch {}
        let count = await transport.count()
        XCTAssertEqual(count, 0); XCTAssertTrue(cache.values.isEmpty)
        XCTAssertEqual(provider.assertions, 0); XCTAssertEqual(provider.attestations, 0)
    }
    func testUncertainEnrollmentAndInvalidTargetCannotReplayOrEmitRequest() async throws {
        let provider = IntegrityTestProvider(), cache = IntegrityTestVault(), transport = IntegrityTestTransport()
        let origin = try CommunityOrigin.parse("https://catalog.example")
        try cache.save(JSONEncoder().encode(NativeAppIntegrity.Key(id: key, enrolled: false, uncertain: true)),
            key: "app-attest|\(origin.url.absoluteString)|\(account.uuidString.lowercased())")
        let broker = NativeAppIntegrity(provider: provider, cache: cache)
        var request = URLRequest(url: try origin.api("notifications/apple-devices"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do { _ = try await broker.perform(request, origin: origin, account: account, token: token, transport: transport, maxBytes: 4096, check: {}); XCTFail("Uncertain key must not replay") } catch {}
        request.url = URL(string: "https://foreign.example/api/v1/notifications/apple-devices")
        do { _ = try await broker.perform(request, origin: origin, account: account, token: token, transport: transport, maxBytes: 4096, check: {}); XCTFail("Foreign origin") } catch {}
        let count = await transport.count()
        XCTAssertEqual(count, 0); XCTAssertEqual(provider.attestations, 0); XCTAssertEqual(provider.assertions, 0)
    }
}
