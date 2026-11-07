import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor FriendQRTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    var late: (@MainActor @Sendable () -> Void)?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func setLate(_ action: @escaping @MainActor @Sendable () -> Void) { late = action }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected friend-QR fixture request.") }
        let value = responses.removeFirst()
        if request.url?.path.hasSuffix("/preview") == true { await late?() }
        return value
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class FriendQRVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class FriendInviteQRTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private var token: String { Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    private func reply(_ raw: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(raw.utf8)) }
    private func preview(id: UUID? = nil, canRedeem: Bool = true, expiry: Double = 1_800_000) -> String {
        #"{"profile":{"id":"\#(id ?? peer)","displayName":"Minimal inviter"},"serverTime":1000000,"expiresAt":\#(expiry),"canRedeem":\#(canRedeem)}"#
    }
    private func setup(_ responses: [CommunityResponse]) async throws -> (CommunityController, CommunityFeatureClient, FriendQRTransport) {
        let login = reply(#"{"user":{"id":"\#(owner)","email":"test@example.invalid","displayName":"Owner","role":"user","verified":true},"token":"synthetic-friend-qr-account","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = reply(#"{"requireEmailVerification":false,"socialEnabled":true}"#)
        let transport = FriendQRTransport([login, config] + responses)
        let controller = CommunityController(vault: FriendQRVault(), factory: { _ in transport })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }
    func testConfiguredFragmentLinkRoundTripDoesNotPutTokenInQueryOrPath() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example")
        let url = try FriendInviteLink.link(token: token, origin: origin)
        XCTAssertEqual(url.path, "/social"); XCTAssertNil(url.query); XCTAssertNil(url.user)
        XCTAssertEqual(url.fragment, "invite=" + token)
        XCTAssertEqual(try FriendInviteLink.token(url.absoluteString, origin: origin), token)
        XCTAssertEqual(try FriendInviteLink.token(token, origin: origin), token)
    }
    func testForeignUserinfoPortPathQueryAndEncodedAliasesAreRejected() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example")
        for raw in [
            "https://foreign.example/social#invite=\(token)",
            "https://catalog.example@foreign.example/social#invite=\(token)",
            "https://user@catalog.example/social#invite=\(token)",
            "https://catalog.example:444/social#invite=\(token)",
            "https://catalog.example/social/?invite=\(token)",
            "https://catalog.example/social?token=secret#invite=\(token)",
            "https://catalog.example/%73ocial#invite=\(token)",
            "https://catalog.example/social#invite=\(token)&other=1",
            "https://catalog.example/social#invite=%41\(token.dropFirst())",
            "https://catalog.example\\social#invite=\(token)"
        ] { XCTAssertThrowsError(try FriendInviteLink.token(raw, origin: origin)) }
    }
    func testWrongPurposeKeyQrAndArbitraryTextCannotBecomeFriendToken() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example")
        for raw in ["not a token", "private-key-material", "https://catalog.example/adopt#invite=\(token)", token + "="] {
            XCTAssertThrowsError(try FriendInviteLink.token(raw, origin: origin))
        }
    }
    func testOwnUnavailableAndExpiredMinimalInviterPreviewFailsClosed() throws {
        for raw in [preview(id: owner), preview(canRedeem: false), preview(expiry: 1_000_000)] {
            XCTAssertThrowsError(try JSONDecoder().decode(NativeFriendInvitePreview.self, from: Data(raw.utf8)).validate(account: owner))
        }
    }
    func testPreviewIsAuthenticatedButDoesNotRedeemRequestOrFetchAvatar() async throws {
        let (_, client, transport) = try await setup([reply(preview())])
        let value = try await client.previewFriendInvite(token)
        XCTAssertEqual(value.profile.id, peer)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2].url?.path, "/api/v1/social/invites/preview")
        XCTAssertNil(requests[2].url?.query)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: String])
        XCTAssertEqual(body, ["token":token])
    }
    func testDeliberateRequestRepreviewsExactInviterBeforeConsumingInvite() async throws {
        let requestID = UUID()
        let result = #"{"request":{"id":"\#(requestID)","senderId":"\#(owner)","recipientId":"\#(peer)","status":"pending","createdAt":1000000,"updatedAt":1000000}}"#
        let (_, client, transport) = try await setup([reply(preview()), reply(result)])
        try await client.requestFromPreview(token: token, inviter: peer)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].url?.path, "/api/v1/social/invites/preview")
        XCTAssertEqual(requests[3].url?.path, "/api/v1/social/invites/redeem")
    }
    func testRevokedInviteCannotIssueRequestOrSilentRetry() async throws {
        let (_, client, transport) = try await setup([reply(#"{"error":{"code":"social_invite_unavailable","message":"Expired or revoked"}}"#, status: 404)])
        do { try await client.requestFromPreview(token: token, inviter: peer); XCTFail("Revoked") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
    func testLateAccountSwitchDiscardsInviterPreview() async throws {
        let (controller, client, transport) = try await setup([reply(preview())])
        await transport.setLate { controller.configure("https://different.example") }
        do { _ = try await client.previewFriendInvite(token); XCTFail("Late result") } catch {}
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
    }
    func testReceivedFragmentCaptureIsVolatileAndExplicitlyClearable() throws {
        var state = FriendInvitePreviewState()
        let value = try JSONDecoder().decode(NativeFriendInvitePreview.self, from: Data(preview().utf8))
        let epoch = UUID()
        try state.capture(token: token, preview: value, account: owner, epoch: epoch)
        XCTAssertEqual(state.token, token); XCTAssertEqual(state.inviter, peer); XCTAssertEqual(state.accountEpoch, epoch)
        state.clear(); XCTAssertNil(state.token); XCTAssertNil(state.inviter); XCTAssertNil(state.accountEpoch)
    }
    func testCameraPolicyRequiresExplicitForegroundPermissionAndUsageTextWithoutCameraInitialization() throws {
        var camera = FriendCameraPolicy()
        XCTAssertFalse(camera.armed)
        XCTAssertThrowsError(try camera.arm(explicitScan: false, foreground: true, usageDescription: "Scan friend QR", authorized: true))
        XCTAssertThrowsError(try camera.arm(explicitScan: true, foreground: false, usageDescription: "Scan friend QR", authorized: true))
        XCTAssertThrowsError(try camera.arm(explicitScan: true, foreground: true, usageDescription: nil, authorized: true))
        XCTAssertThrowsError(try camera.arm(explicitScan: true, foreground: true, usageDescription: "Scan friend QR", authorized: false))
        try camera.arm(explicitScan: true, foreground: true, usageDescription: "Scan friend QR", authorized: true)
        XCTAssertTrue(camera.armed); camera.stop(); XCTAssertFalse(camera.armed)
    }
    func testCreateUsesServerClockAndRevocationIsOwnerBound() async throws {
        let id = UUID()
        let created = #"{"invite":{"id":"\#(id)","token":"\#(token)","expiresAt":1900000},"serverTime":1000000}"#
        let (_, client, transport) = try await setup([reply(created), reply(#"{"removed":true}"#)])
        let value = try await client.createFriendQRInvite()
        XCTAssertEqual(value.invite.expiresAt - value.serverTime, 900000)
        try await client.revokeInvite(value.invite.id)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 4); XCTAssertEqual(requests[3].httpMethod, "DELETE")
    }
    func testChangedInviterCannotConsumePreviewForAnotherPerson() async throws {
        let (_, client, transport) = try await setup([reply(preview(id: UUID()))])
        do { try await client.requestFromPreview(token: token, inviter: peer); XCTFail("Changed inviter") } catch {}
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/redeem") == true })
    }
}
