import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor AppleTransport: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ values: [CommunityResponse]) { responses = values }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected Apple contract request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}

@MainActor
private final class AppleVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class AppleSignInTests: XCTestCase {
    private let root = "https://catalog.example"
    private let nonce = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq"
    private let challengeID = UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef")!
    private func expiry(_ seconds: TimeInterval = 300) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(seconds))
    }
    private func response(_ text: String, status: Int = 200) -> CommunityResponse {
        CommunityResponse(status: status, data: Data(text.utf8))
    }
    private var config: CommunityResponse {
        response(#"{"requireEmailVerification":true,"appleSignInEnabled":true,"accountDeletionRetainsSharedGifs":false}"#)
    }
    private var challengeResponse: CommunityResponse {
        response("""
        {"challengeId":"\(challengeID.uuidString.lowercased())","rawNonce":"\(nonce)","expiresAt":"\(expiry())"}
        """)
    }
    private func login(appleOnly: Bool) -> CommunityResponse {
        response("""
        {"user":{"id":"223609c9-cc77-4818-8951-0c55acdaab4e","email":"relay@privaterelay.appleid.com","displayName":"Rider","role":"user","verified":true,
        "authMethods":{"apple":\(appleOnly),"password":\(!appleOnly),"appleOnly":\(appleOnly)}},
        "token":"test-only-native-apple-session-not-real","expiresAt":"2099-01-01T00:00:00.000Z"}
        """)
    }
    private func client(_ transport: AppleTransport, vault: AppleVault? = nil) -> CommunityController {
        let service = CommunityController(vault: vault ?? AppleVault(), factory: { _ in transport })
        service.configure(root)
        return service
    }
    private func proof(_ attempt: AppleAuthAttempt) throws -> AppleAuthProof {
        try AppleAuthProof(challenge: attempt.challenge, identityToken: Data("test.identity.token".utf8),
            authorizationCode: Data("test-authorization-code".utf8))
    }

    func testNonceIsHashedOnceAsUTF8NotBase64Decoded() throws {
        let challenge = AppleAuthChallenge(challengeId: challengeID, rawNonce: nonce, expiresAt: expiry())
        try challenge.validate()
        XCTAssertEqual(challenge.hashedNonce, "769e8d95aa246a02d94d48c42fb7183e531c85c41d5b3456ddb90011712d8bd7")
        XCTAssertThrowsError(try AppleAuthChallenge(challengeId: challengeID, rawNonce: "bad", expiresAt: expiry()).validate())
        XCTAssertThrowsError(try AppleAuthChallenge(challengeId: challengeID, rawNonce: nonce, expiresAt: expiry(-1)).validate())
        XCTAssertThrowsError(try AppleAuthChallenge(challengeId: challengeID, rawNonce: nonce, expiresAt: expiry(1000)).validate())
        XCTAssertFalse(AppleAuthChallenge.validExpiry("not a timestamp"))
    }

    func testAppleDisabledDoesNotRequestChallengeOrCredentials() async throws {
        let transport = AppleTransport([response(#"{"requireEmailVerification":true,"appleSignInEnabled":false,"accountDeletionRetainsSharedGifs":false}"#)])
        let service = client(transport)
        do { _ = try await service.beginAppleAuth(.login); XCTFail("Disabled service must not start Apple auth") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not enabled")) }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/config")
        XCTAssertNil(requests.first?.httpBody)
    }

    func testAppleLoginUsesServerChallengeRawNonceAndRevocableBearerSession() async throws {
        let vault = AppleVault()
        let transport = AppleTransport([config, challengeResponse, login(appleOnly: true)])
        let service = client(transport, vault: vault)
        let attempt = try await service.beginAppleAuth(.login)
        try await service.finishAppleAuth(attempt, proof: proof(attempt), password: nil, confirmation: nil)
        XCTAssertTrue(service.signedIn)
        XCTAssertEqual(service.user?.authMethods?.appleOnly, true)
        let requests = await transport.history()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/config", "/api/v1/auth/apple/challenges", "/api/v1/auth/apple/login"])
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: String])
        XCTAssertEqual(object["rawNonce"], nonce)
        XCTAssertEqual(object["challengeId"], challengeID.uuidString.lowercased())
        XCTAssertEqual(object["identityToken"], "test.identity.token")
        XCTAssertNil(object["user"])
        XCTAssertEqual(vault.values.count, 1)
    }

    func testAppleEmailCollisionDoesNotSilentlyCreateOrLinkAccount() async throws {
        let transport = AppleTransport([config, challengeResponse,
            response(#"{"error":{"code":"account_link_required","message":"Sign in to your existing account and link Apple explicitly."}}"#, status: 409)])
        let service = client(transport)
        let attempt = try await service.beginAppleAuth(.login)
        do {
            try await service.finishAppleAuth(attempt, proof: proof(attempt), password: nil, confirmation: nil)
            XCTFail("Existing email must not silently merge")
        } catch let error as CommunityFailure { XCTAssertEqual(error.code, "account_link_required") }
        XCTAssertFalse(service.signedIn)
    }

    func testProofCannotBeAppliedAfterServerOrSessionChanges() async throws {
        let transport = AppleTransport([config, challengeResponse])
        let service = client(transport)
        let attempt = try await service.beginAppleAuth(.login)
        service.configure("https://other.example")
        do {
            try await service.finishAppleAuth(attempt, proof: proof(attempt), password: nil, confirmation: nil)
            XCTFail("Old Apple proof must not cross servers")
        } catch { XCTAssertTrue(error.localizedDescription.contains("different attempt")) }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
    }

    func testAppleOnlyDeletionUsesFreshProofNotAPasswordAndClearsCredentials() async throws {
        let vault = AppleVault()
        let receiptID = "9bdc44d9-a300-46aa-8062-c120d6d87ddd"
        let receipt = response("""
        {"deletion":{"id":"\(receiptID)","status":"completed","statusUrl":"\(root)/api/v1/account-deletions/\(receiptID)",
        "requestedAt":"\(expiry(-1))","completedAt":"\(expiry(-1))","error":null,"retainedSharedGifs":0}}
        """)
        let transport = AppleTransport([config, challengeResponse, login(appleOnly: true), config, challengeResponse,
            response("{\"deletionToken\":\"test-only-apple-deletion-proof\",\"expiresAt\":\"\(expiry())\"}"), receipt])
        let service = client(transport, vault: vault)
        let loginAttempt = try await service.beginAppleAuth(.login)
        try await service.finishAppleAuth(loginAttempt, proof: proof(loginAttempt), password: nil, confirmation: nil)
        let attempt = try await service.beginAppleAuth(.delete)
        try await service.finishAppleAuth(attempt, proof: proof(attempt), password: nil, confirmation: "DELETE")
        XCTAssertFalse(service.signedIn)
        XCTAssertEqual(service.deletion?.status, .completed)
        XCTAssertEqual(service.deletion?.retainedSharedGifs, 0)
        let requests = await transport.history()
        XCTAssertEqual(requests[5].url?.path, "/api/v1/auth/apple/deletion-proof")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[6].httpBody)) as? [String: String])
        XCTAssertEqual(body["appleDeletionToken"], "test-only-apple-deletion-proof")
        XCTAssertEqual(body["confirmation"], "DELETE")
        XCTAssertNil(body["password"])
        XCTAssertNotNil(requests[6].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(vault.values.keys.contains { $0.hasPrefix("session|") })
    }

    func testRevocationFailureLeavesExistingAccountAndCredentialsIntact() async throws {
        let vault = AppleVault()
        let transport = AppleTransport([config, challengeResponse, login(appleOnly: true), config, challengeResponse,
            response(#"{"error":{"code":"apple_revocation_failed","message":"Apple revocation failed. Try again later."}}"#, status: 503)])
        let service = client(transport, vault: vault)
        let loginAttempt = try await service.beginAppleAuth(.login)
        try await service.finishAppleAuth(loginAttempt, proof: proof(loginAttempt), password: nil, confirmation: nil)
        let attempt = try await service.beginAppleAuth(.delete)
        do {
            try await service.finishAppleAuth(attempt, proof: proof(attempt), password: nil, confirmation: "DELETE")
            XCTFail("Revocation failure must block deletion")
        } catch let error as CommunityFailure { XCTAssertEqual(error.status, 503) }
        XCTAssertTrue(service.signedIn)
        XCTAssertNil(service.deletion)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 6)
        XCTAssertFalse(requests.contains { $0.httpMethod == "DELETE" })
    }

    func testMissingIdentityOrAuthorizationCodeIsExplicitlyRejected() throws {
        let challenge = AppleAuthChallenge(challengeId: challengeID, rawNonce: nonce, expiresAt: expiry())
        XCTAssertThrowsError(try AppleAuthProof(challenge: challenge, identityToken: nil, authorizationCode: Data("code".utf8)))
        XCTAssertThrowsError(try AppleAuthProof(challenge: challenge, identityToken: Data("token".utf8), authorizationCode: nil))
    }

    func testAppleLinkRequiresCurrentPasswordAndUsesExplicitAuthenticatedEndpoint() async throws {
        let dualUser = """
        {"user":{"id":"223609c9-cc77-4818-8951-0c55acdaab4e","email":"example@example.org","displayName":"Rider","role":"user","verified":true,
        "authMethods":{"apple":true,"password":true,"appleOnly":false}}}
        """
        let transport = AppleTransport([login(appleOnly: false), config, challengeResponse, response(dualUser)])
        let service = client(transport)
        try await service.signIn(email: "example@example.org", password: "fixture email password")
        let attempt = try await service.beginAppleAuth(.link)
        do {
            try await service.finishAppleAuth(attempt, proof: proof(attempt), password: nil, confirmation: nil)
            XCTFail("Linking must require password reauthentication")
        } catch { XCTAssertTrue(error.localizedDescription.contains("existing account password")) }
        try await service.finishAppleAuth(attempt, proof: proof(attempt), password: "fixture email password", confirmation: nil)
        XCTAssertEqual(service.user?.authMethods?.apple, true)
        XCTAssertEqual(service.user?.authMethods?.password, true)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[3].url?.path, "/api/v1/auth/apple/link")
        XCTAssertNotNil(requests[3].value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[3].httpBody)) as? [String: String])
        XCTAssertEqual(body["password"], "fixture email password")
        XCTAssertEqual(body["rawNonce"], nonce)
    }
}
