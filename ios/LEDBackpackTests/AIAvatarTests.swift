import XCTest
import Combine
import BackpackProtocol
@testable import LEDBackpack

private actor AIAvatarTransport: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected avatar fixture request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class AIAvatarVault: CommunityVault {
    var data: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { data[key] }
    func save(_ value: Data, key: String) throws { data[key] = value }
    func remove(_ key: String) throws { data[key] = nil }
}
@MainActor
final class AIAvatarTests: XCTestCase {
    private let account = UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef")!
    private let version = UUID(uuidString: "12345678-1234-4567-89ab-123456789abc")!
    private func response(_ json: String, status: Int = 200) -> CommunityResponse {
        CommunityResponse(status: status, data: Data(json.utf8))
    }
    private func user(mature: Bool) -> String {
        #"{"id":"\#(account)","email":"test@example.invalid","displayName":"Owner","role":"admin","verified":true,"allowMature":\#(mature)}"#
    }
    private var login: CommunityResponse {
        response(#"{"user":\#(user(mature: false)),"token":"test-only-avatar-session-not-real","expiresAt":"2099-01-01T00:00:00Z"}"#)
    }
    private func config(automatic: Bool = true) -> CommunityResponse {
        response(automatic ? #"{"requireEmailVerification":false,"avatarsEnabled":true,"avatarUploadsEnabled":true,"avatarApprovalMode":"ai"}"# :
            #"{"requireEmailVerification":false,"avatarsEnabled":true}"#)
    }
    private func owned(version: UUID? = nil, masked: Bool = false, uploads: Bool = true) -> CommunityResponse {
        let version = version ?? self.version
        let base = "/api/v1/social/avatars/\(account.uuidString.lowercased())/\(version.uuidString.lowercased())"
        let urls = masked ? #""avatarUrl":null,"avatarPreviewUrl":null,"avatarMature":true,"avatarMasked":true"# :
            #""avatarUrl":"\#(base)/image.gif","avatarPreviewUrl":"\#(base)/preview.png""#
        return response("""
        {"approvalMode":"ai","uploadsEnabled":\(uploads),"avatar":{"userId":"\(account)","version":"\(version)",
        "status":"\(masked ? "approved" : "pending")","createdAt":1700000000000,\(urls),"avatarAnimated":false,
        "approvalMode":"ai","aiState":"\(masked ? "done" : "failed")","aiError":"\(masked ? "" : "Provider unavailable")"}}
        """)
    }
    private func client(_ stub: AIAvatarTransport) async throws -> (CommunityController, CommunityFeatureClient) {
        let community = CommunityController(vault: AIAvatarVault(), factory: { _ in stub })
        community.configure("https://catalog.example")
        try await community.signIn(email: "test@example.invalid", password: "example test password")
        try await community.loadConfig()
        return (community, try CommunityFeatureClient(community))
    }
    func testMissingNewCapabilitiesNeverAssumeAutomaticUploadsOrManualFallback() async throws {
        let stub = AIAvatarTransport([login, config(automatic: false)])
        let (_, client) = try await client(stub)
        XCTAssertFalse(client.automaticAvatarUploads)
        do { try await client.uploadAvatar(Data(), publicConsent: true); XCTFail("Missing capabilities must block uploads") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not enabled")) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 2)
    }
    func testOwnerAvailabilityFalseBlocksUploadBeforeMultipartPost() async throws {
        let stub = AIAvatarTransport([login, config(), owned(uploads: false)])
        let (_, client) = try await client(stub)
        do { try await client.uploadAvatar(Data(), publicConsent: true, expectedVersion: version); XCTFail("Owner gate must be checked") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/v1/social/avatar" && $0.httpMethod == "POST" })
    }
    func testRetryBindsExactFailedVersionAndNoApprovalOverride() async throws {
        let stub = AIAvatarTransport([login, config(), owned(), response(#"{"queued":true}"#)])
        let (_, client) = try await client(stub)
        try await client.retryAvatar(expectedVersion: version)
        let requests = await stub.history()
        XCTAssertEqual(requests[3].url?.path, "/api/v1/social/avatar/retry")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[3].httpBody)) as? [String: String])
        XCTAssertEqual(body, ["expectedVersion": version.uuidString.lowercased()])
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        XCTAssertFalse(requests.contains { $0.url?.path.hasPrefix("/api/v1/admin/avatars") == true })
    }
    func testRetryDoesNotRebaseOntoAReplacedAvatar() async throws {
        let stub = AIAvatarTransport([login, config(), owned(version: UUID())])
        let (_, client) = try await client(stub)
        do { try await client.retryAvatar(expectedVersion: version); XCTFail("Replaced version must not be retried") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no version is rebased")) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 3)
    }
    func testMatureMaskedOwnedAvatarIsValidWithoutURLsEvenForAdminOwner() async throws {
        let stub = AIAvatarTransport([login, config(), owned(masked: true)])
        let (community, client) = try await client(stub)
        XCTAssertEqual(community.user?.role, "admin")
        let state = try await client.ownedAvatar()
        XCTAssertEqual(state.avatar?.status, "approved")
        XCTAssertEqual(state.avatar?.avatarMasked, true)
        XCTAssertNil(state.avatar?.avatarUrl)
        XCTAssertNil(state.avatar?.avatarPreviewUrl)
    }
    func testMaturePreferenceUpdatesAreScopedAndInvalidateAvatarEpoch() async throws {
        let stub = AIAvatarTransport([login, config(), response(#"{"user":\#(user(mature: true))}"#)])
        let (community, client) = try await client(stub)
        let epoch = community.avatarPolicyRevision
        var changes: [Bool] = []
        let observation = community.$avatarPolicyChanging.sink { changes.append($0) }
        try await client.setMaturePreference(true)
        observation.cancel()
        XCTAssertEqual(community.user?.allowMature, true)
        XCTAssertNotEqual(epoch, community.avatarPolicyRevision)
        XCTAssertEqual(changes, [false, true, false])
        let requests = await stub.history()
        XCTAssertEqual(requests[2].url?.path, "/api/v1/auth/me/preferences")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Bool])
        XCTAssertEqual(body, ["allowMature": true])
    }
}
