import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor LibrarySyncTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected library synchronization request.") }
        let reply = replies.removeFirst()
        guard reply.data.count <= maxBytes else { throw BackpackError.invalid("Library response exceeds its budget.") }
        return reply
    }
    func history() -> [URLRequest] { requests }
}

@MainActor
private final class LibrarySyncAccount: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}

@MainActor
final class LibrarySyncPerformanceTests: XCTestCase {
    private let origin = "https://catalog.example"
    private let account = "11111111-1111-4111-8111-111111111111"
    private let key = "22222222-2222-4222-8222-222222222222"
    private let item = "33333333-3333-4333-8333-333333333333"
    private func response(_ object: [String: Any]) throws -> CommunityResponse {
        CommunityResponse(status: 200, data: try JSONSerialization.data(withJSONObject: object))
    }
    private func state(revision: Int = 3, generation: Int = 7, enabled: Bool = true) -> CloudVaultState {
        CloudVaultState(protocolVersion: 1, accountId: account, origin: origin, enabled: enabled, deleting: !enabled,
            mode: .managed, generation: generation, revision: revision, keyId: key, migrationId: nil,
            recovery: nil, passkeys: [], controlPublicKey: nil, userHeldEnrollmentAvailable: false,
            deviceAdoptionAvailable: false, itemLimit: 100, maxPlaintextBytes: 5_000_000,
            legacyMigrationPending: false, legacyMigrationError: nil, legacyItemCount: 0)
    }
    private func conditional(_ state: CloudVaultState, unchanged: Bool) throws -> CommunityResponse {
        try response(["cloud": JSONSerialization.jsonObject(with: CloudVaultWire.json(state)), "unchanged": unchanged])
    }
    func testAuthenticatedUnchangedValidationUsesOneSmallRequestAndCapturesFullContext() async throws {
        let transport = LibrarySyncTransport([try conditional(state(), unchanged: true)])
        let scope = CloudVaultScope(origin: try CommunityOrigin.parse(origin), accountID: try XCTUnwrap(UUID(uuidString: account)), revision: UUID())
        let client = CloudVaultClient(scope: scope, send: { request, limit in try await transport.send(request, maxBytes: limit) })
        let (current, unchanged) = try await client.changes(since: state())
        XCTAssertTrue(unchanged); XCTAssertEqual(current.revision, 3)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/cloud/changes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Cloud-Protocol"), "1")
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }),
            ["generation": "7", "revision": "3", "keyId": key, "mode": "server-managed"])
        XCTAssertNil(request.httpBody)
    }
    func testFalseUnchangedClaimCannotReuseStaleSnapshotButResetStateIsAccepted() async throws {
        let transport = LibrarySyncTransport([
            try conditional(state(revision: 4), unchanged: true),
            try conditional(state(revision: 4, generation: 8, enabled: false), unchanged: false)])
        let scope = CloudVaultScope(origin: try CommunityOrigin.parse(origin), accountID: try XCTUnwrap(UUID(uuidString: account)), revision: UUID())
        let client = CloudVaultClient(scope: scope, send: { request, limit in try await transport.send(request, maxBytes: limit) })
        do {
            _ = try await client.changes(since: state())
            XCTFail("An unchanged claim cannot cross a revision boundary.")
        } catch {}
        let (reset, unchanged) = try await client.changes(since: state())
        XCTAssertFalse(unchanged); XCTAssertEqual(reset.generation, 8); XCTAssertTrue(reset.deleting)
    }
    func testLegacyWarmManifestAvoidsPagesKeepsThumbnailRevisionAndReconcilesRemoval() async throws {
        let revision = String(repeating: "a", count: 64)
        let owned: [String: Any] = [
            "id": item, "title": "Synthetic artwork", "category": "memes", "tags": [],
            "attribution": "Example", "displayAttribution": "Example", "license": "CC0-1.0",
            "pageUrl": "\(origin)/items/\(item)", "gifUrl": "\(origin)/media/\(item)/original.gif",
            "previewUrl": "\(origin)/media/\(item)/preview.png", "width": 16, "height": 16,
            "frameCount": 2, "byteSize": 1000, "variants": [], "likeCount": 0,
            "uploader": ["id": account, "displayName": "Example"], "visibility": "private",
            "status": "pending", "moderationReason": "", "aiState": "disabled", "contentRevision": revision, "syncRevision": revision]
        func delta(_ items: [[String: Any]], removed: [String] = [], order: [String], snapshot: String) throws -> CommunityResponse {
            try response(["accountId": account, "snapshot": snapshot, "items": items, "removed": removed,
                "order": order, "page": 1, "limit": 100, "total": order.count, "nextPage": NSNull()])
        }
        let transport = LibrarySyncTransport([
            try response(["user": ["id": account, "email": "example@example.org", "displayName": "Example", "role": "user", "verified": true],
                "token": "synthetic-library-session", "expiresAt": "2099-01-01T00:00:00.000Z"]),
            try response(["requireEmailVerification": false, "libraryDeltaSyncEnabled": true]),
            try delta([owned], order: [item], snapshot: "first"),
            try delta([], order: [item], snapshot: "first"),
            try delta([], removed: [item], order: [], snapshot: "second")])
        let community = CommunityController(vault: LibrarySyncAccount(), factory: { _ in transport })
        community.configure(origin)
        try await community.signIn(email: "example@example.org", password: "example test password")
        try await community.loadConfig()
        let library = CloudLibraryStore()
        await library.refresh(community)
        XCTAssertNil(library.failure)
        let initial = try XCTUnwrap(library.items.first)
        let thumbnail = library.thumbnailKey(initial)
        await library.refresh(community)
        XCTAssertNil(library.failure)
        XCTAssertEqual(library.thumbnailKey(try XCTUnwrap(library.items.first)), thumbnail)
        await library.refresh(community)
        XCTAssertNil(library.failure); XCTAssertTrue(library.items.isEmpty)
        let changes = await transport.history().filter { $0.url?.path == "/api/v1/me/items/changes" }
        XCTAssertEqual(changes.count, 3)
        let warm = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(changes[1].httpBody)) as? [String: Any])
        let baseline = try XCTUnwrap(warm["baseline"] as? [[String: String]])
        XCTAssertEqual(baseline, [["id": item, "revision": revision]])
    }
}
