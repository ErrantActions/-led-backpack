import XCTest
import Combine
import BackpackProtocol
@testable import LEDBackpack

private actor AdminTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var requests: [URLRequest] = []
    private var uploaded: Data?
    private var pending: CheckedContinuation<CommunityResponse, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var waiting = false
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: 1024)
                guard count >= 0 else { throw BackpackError.invalid("Test stream read failed.") }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 100_000 else { throw BackpackError.invalid("Unexpected test archive size.") }
            }
            uploaded = bytes
        }
        if !replies.isEmpty { return replies.removeFirst() }
        waiting = true; started?.resume(); started = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForPending() async {
        if waiting { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ response: CommunityResponse) { pending?.resume(returning: response); pending = nil }
    func history() -> [URLRequest] { requests }
    func uploadBytes() -> Data? { uploaded }
}

@MainActor
private final class AdminVault: CommunityVault {
    private var data: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { data[key] }
    func save(_ value: Data, key: String) throws { data[key] = value }
    func remove(_ key: String) throws { data[key] = nil }
}

@MainActor
final class CommunityAdminTests: XCTestCase {
    private let owner = UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef")!
    private let target = UUID(uuidString: "12345678-1234-4567-89ab-123456789abc")!
    private func response(_ json: String, status: Int = 200) -> CommunityResponse {
        CommunityResponse(status: status, data: Data(json.utf8))
    }
    private func login(role: String = "admin") -> CommunityResponse {
        response("""
        {"user":{"id":"\(owner)","email":"admin@example.invalid","displayName":"Test admin","role":"\(role)","verified":true},
        "token":"test-only-admin-session-not-real","expiresAt":"2099-01-01T00:00:00Z"}
        """)
    }
    private func community(_ transport: AdminTransport) -> CommunityController {
        let value = CommunityController(vault: AdminVault(), factory: { _ in transport })
        value.configure("https://catalog.example")
        return value
    }
    private func signedIn(_ transport: AdminTransport) async throws -> CommunityController {
        let value = community(transport)
        try await value.signIn(email: "admin@example.invalid", password: "example test password")
        return value
    }
    private func account(id: UUID? = nil, role: String = "user", disabled: Bool = false,
        verified: Bool = true) -> AdminAccount {
        AdminAccount(id: id ?? target, email: "rider@example.invalid", displayName: "Rider", role: role,
            verified: verified, allowMature: false, trustedReporter: false, disabled: disabled,
            createdAt: "2026-01-01T00:00:00Z", itemCount: 1)
    }
    private var stats: String {
        """
        {"generatedAt":"2026-01-01T00:00:00Z","accounts":{"total":3,"admins":1,"enabled":3,"emailVerified":2},
        "items":{"total":8,"active":7,"private":2,"shared":5,"approvedShared":3,"pendingShared":1,"rejectedShared":1,"deleted":1,"retainedShared":0},
        "storage":{"usedBytes":1234,"limitBytes":2147483648},"reports":{"open":1,"resolved":0},"likes":5,
        "activeSessions":2,"reviews":{"queued":1,"failed":0}}
        """
    }
    private func item(visibility: String = "shared", status: String = "pending") -> String {
        """
        {"id":"\(target)","title":"Test artwork","category":"memes","tags":[],"displayAttribution":"","license":"unspecified",
        "licenseUrl":null,"sourceUrl":null,"pageUrl":"https://catalog.example/items/\(target)",
        "gifUrl":"https://catalog.example/media/test.gif","previewUrl":"https://catalog.example/media/test-preview.gif",
        "width":16,"height":16,"frameCount":1,"byteSize":100,"uploader":{"id":null,"displayName":"Deleted account"},
        "likeCount":0,"variants":[],"visibility":"\(visibility)","status":"\(status)","moderationReason":"",
        "aiState":"disabled","aiError":null,"aiReview":null,"requiresAdminReview":true,"heldByReports":false}
        """
    }
    private var job: String {
        """
        {"id":"\(target)","filename":"package.zip","status":"queued","createdAt":"2026-01-01T00:00:00Z",
        "updatedAt":"2026-01-01T00:00:00Z","error":null,"total":0,"processed":0,"imported":0,"duplicates":0,
        "skipped":0,"failed":0,"results":[]}
        """
    }

    func testGuestsOrdinaryUsersAndLegacyModeratorsCannotCreateAdminClient() async throws {
        let guest = community(AdminTransport([]))
        XCTAssertFalse(guest.isAdmin)
        XCTAssertThrowsError(try CommunityAdminClient(guest))
        for role in ["user", "moderator"] {
            let transport = AdminTransport([login(role: role)])
            let user = try await signedIn(transport)
            XCTAssertFalse(user.isAdmin)
            XCTAssertThrowsError(try CommunityAdminClient(user))
            let requests = await transport.history()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testAdminReadsUsePinnedBearerAndEncodedPaginatedSearch() async throws {
        let transport = AdminTransport([login(), response(stats),
            response(#"{"users":[],"page":2,"limit":24,"total":24}"#)])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        let snapshot = try await client.statistics()
        XCTAssertEqual(snapshot.storage.limitBytes, 2_147_483_648)
        let result = try await client.accounts(page: 2, query: "name+&@example.invalid", role: "moderator")
        XCTAssertEqual(result.page, 2)
        let requests = await transport.history()
        XCTAssertEqual(requests[1].url?.path, "/api/v1/admin/stats")
        let search = try XCTUnwrap(requests[2].url)
        XCTAssertEqual(search.host, "catalog.example")
        let parameters = try XCTUnwrap(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(parameters.first { $0.name == "q" }?.value, "name+&@example.invalid")
        XCTAssertEqual(parameters.first { $0.name == "limit" }?.value, "24")
        XCTAssertEqual(parameters.first { $0.name == "role" }?.value, "moderator")
        XCTAssertNotNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Cookie"))
    }

    func testAccountMutationsProtectSelfAdminsAndPromotionEligibility() async throws {
        let transport = AdminTransport([login()])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        for value in [account(id: owner), account(role: "admin"), account(disabled: true), account(verified: false)] {
            do { try await client.update(value, action: .promote); XCTFail("Protected or ineligible promotion must fail") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 1)
    }

    func testAccountChangesSendOnlySelectedFieldsAndCanonicalIDs() async throws {
        let transport = AdminTransport([login()] + Array(repeating: response(#"{"message":"Updated"}"#), count: 5))
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        for action in AdminAccountAction.allCases { try await client.update(account(), action: action) }
        let requests = await transport.history()
        let expected = ["role", "disabled", "disabled", "trustedReporter", "trustedReporter"]
        for (index, request) in requests.dropFirst().enumerated() {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/admin/users/\(target.uuidString.lowercased())/role")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Client"), "1")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), Set([expected[index]]))
        }
    }

    func testModerationRequiresActualSafetyReviewAndRejectionReason() throws {
        func change(_ status: AdminItemStatus, reason: String = "", reviewed: Bool = false) -> AdminModeration {
            AdminModeration(status: status, reason: reason, title: "Test", category: "memes", tags: [],
                audience: reviewed ? "general" : nil, safetyReviewed: reviewed ? true : nil)
        }
        XCTAssertThrowsError(try change(.approved).validate())
        XCTAssertThrowsError(try change(.rejected, reason: " \n ").validate())
        XCTAssertNoThrow(try change(.approved, reviewed: true).validate())
        XCTAssertNoThrow(try change(.rejected, reason: "Unsafe").validate())
        XCTAssertNoThrow(try change(.pending).validate())
        XCTAssertThrowsError(try JSONDecoder().decode(AdminItem.self, from: Data(item(visibility: "private").utf8)))
    }

    func testModerationQueueNeverRequestsPrivateItemsAndPreservesSingleFrames() async throws {
        let transport = AdminTransport([login(), response("{\"items\":[\(item())],\"page\":1,\"limit\":24,\"total\":1}"),
            response("{\"item\":\(item(status: "approved"))}")])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        let page = try await client.items(page: 1, status: .pending)
        XCTAssertEqual(page.items.first?.item.frameCount, 1)
        try await client.moderate(target, change: AdminModeration(status: .approved, reason: "", title: "Test",
            category: "memes", tags: [], audience: "general", safetyReviewed: true))
        let requests = await transport.history()
        let url = try XCTUnwrap(requests[1].url)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "visibility" }?.value, "shared")
        XCTAssertEqual(requests[2].httpMethod, "PATCH")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(body["safetyReviewed"] as? Bool, true)
        XCTAssertEqual(body["audience"] as? String, "general")
    }

    func testReportsUseUnixMillisecondsAndResolveIndependentlyOfModeration() async throws {
        let report = """
        {"id":"\(target)","itemId":"\(target)","reporterId":"\(owner)","reason":"Review this GIF",
        "status":"open","createdAt":1700000000000}
        """
        let transport = AdminTransport([login(), response("{\"reports\":[\(report)],\"page\":1,\"limit\":24,\"total\":1}"),
            response(#"{"message":"Resolved"}"#)])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        let page = try await client.reports(page: 1)
        XCTAssertEqual(try XCTUnwrap(page.reports.first).date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        try await client.resolve(target)
        let requests = await transport.history()
        XCTAssertEqual(requests[2].url?.path, "/api/v1/admin/reports/\(target.uuidString.lowercased())")
        XCTAssertEqual(requests.count, 3)
    }

    func testSettingsBoundsAndPaginationFailBeforeNetworking() async throws {
        let transport = AdminTransport([login(), response(#"{"reportHideThreshold":2}"#)])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        for value in [1, 51] {
            do { try await client.setThreshold(value); XCTFail("Out-of-range threshold must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("2 to 50")) }
        }
        do { _ = try await client.items(page: 0, status: .pending); XCTFail("Invalid page must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("page")) }
        try await client.setThreshold(2)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.path, "/api/v1/admin/settings")
    }

    func testInflightAdminResponseIsDiscardedOnServerChange() async throws {
        let transport = AdminTransport([login()])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        let request = Task { try await client.statistics() }
        await transport.waitForPending()
        user.configure("https://another.example")
        await transport.finish(response(stats))
        do { _ = try await request.value; XCTFail("Old-origin statistics must be discarded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertThrowsError(try client.check())
    }

    func testServerRoleRevocationIsAnExplicitErrorWithoutGuestFallback() async throws {
        let transport = AdminTransport([login(), response(#"{"error":{"code":"forbidden","message":"Admin required"}}"#, status: 403)])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        do { _ = try await client.statistics(); XCTFail("Revoked access must fail") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 403) }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
    }

    private func settle(_ store: CommunityAdminStore, start: () -> Void) async {
        let finished = expectation(description: "Admin operation finished")
        let subscription = store.$busy.dropFirst().first(where: { !$0 }).sink { _ in finished.fulfill() }
        start()
        await fulfillment(of: [finished], timeout: 3)
        subscription.cancel()
    }

    func testStoreErasesAdminDataWhenServerRevokesAccess() async throws {
        let transport = AdminTransport([login(), response(stats),
            response(#"{"error":{"code":"forbidden","message":"Admin required"}}"#, status: 403)])
        let user = try await signedIn(transport)
        let store = CommunityAdminStore()
        store.bind(user)
        await settle(store) { store.load(.statistics, page: 1, query: "", role: "", status: .pending) }
        XCTAssertNotNil(store.statistics)
        await settle(store) { store.load(.statistics, page: 1, query: "", role: "", status: .pending) }
        XCTAssertTrue(store.denied)
        XCTAssertNil(store.statistics)
        XCTAssertNil(store.accounts)
        XCTAssertNil(store.items)
        XCTAssertNil(store.selectedItem)
        XCTAssertTrue(store.imports.isEmpty)
        XCTAssertNotNil(store.failure)
    }

    func testConfirmationFromPreviousAdminScopeCannotRunAfterRebinding() async throws {
        let transport = AdminTransport([login(), login()])
        let user = try await signedIn(transport)
        let store = CommunityAdminStore()
        store.bind(user)
        let previous = try XCTUnwrap(store.contextID)
        user.configure("https://another.example")
        try await user.signIn(email: "admin@example.invalid", password: "example test password")
        store.bind(user)
        XCTAssertNotEqual(store.contextID, previous)
        store.run({ _ in XCTFail("Stale confirmation must not execute"); return nil }, expectedScope: previous)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.failure?.contains("context changed") == true)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
    }

    func testZIPUploadIsFileBackedExplicitCommunityIntentAndByteExact() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        let original = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18))
        try original.write(to: source)
        addTeardownBlock { try FileManager.default.removeItem(at: source) }
        let transport = AdminTransport([login(), response("{\"import\":\(job)}", status: 202)])
        let user = try await signedIn(transport)
        let client = try CommunityAdminClient(user)
        let archive = try await AdminArchiveBuilder.shared.prepare(source)
        addTeardownBlock { try await AdminArchiveBuilder.shared.remove(archive) }
        let result = try await client.upload(archive)
        XCTAssertEqual(result.id, target)
        let requests = await transport.history()
        let request = requests[1]
        XCTAssertNil(request.httpBody)
        XCTAssertNotNil(request.httpBodyStream)
        XCTAssertEqual(request.url?.path, "/api/v1/admin/imports")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Upload-Policy"), "community-review")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        let captured = await transport.uploadBytes()
        let data = try XCTUnwrap(captured)
        let header = try XCTUnwrap(data.range(of: Data("Content-Type: application/zip\r\n\r\n".utf8)))
        XCTAssertEqual(data.subdata(in: header.upperBound..<(header.upperBound + original.count)), original)
        XCTAssertEqual(Int(request.value(forHTTPHeaderField: "Content-Length") ?? ""), data.count)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testZIPBoundsRejectOversizedArchivesWithoutLoadingThemIntoMemory() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        addTeardownBlock { try FileManager.default.removeItem(at: source) }
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(AdminArchiveBuilder.maxBytes + 1))
        try file.close()
        do { _ = try await AdminArchiveBuilder.shared.prepare(source); XCTFail("Oversized ZIP must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("250 MiB")) }
    }
}
