import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor CloudTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    private var held = false
    private var pending: CheckedContinuation<Void, Never>?
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected cloud request.") }
        if held { held = false; await withCheckedContinuation { pending = $0 } }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
    func holdNext() { held = true }
    func release() { pending?.resume(); pending = nil }
}

@MainActor
private final class CloudVault: CommunityVault {
    var data: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { data[key] }
    func save(_ data: Data, key: String) throws { self.data[key] = data }
    func remove(_ key: String) throws { data[key] = nil }
}

@MainActor
final class CloudLibraryTests: XCTestCase {
    private let owner = UUID(uuidString: "223609c9-cc77-4818-8951-0c55acdaab4e")!
    private let itemID = UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef")!
    private let root = "https://catalog.example"
    private var itemJSON: String {
        """
        {"id":"\(itemID.uuidString.lowercased())","title":"Cloud loop","category":"memes","tags":["loop"],
        "displayAttribution":"Example creator","attribution":"Example creator","license":"CC0-1.0",
        "licenseUrl":"https://creativecommons.org/publicdomain/zero/1.0/","sourceUrl":null,
        "pageUrl":"\(root)/items/\(itemID.uuidString.lowercased())",
        "gifUrl":"\(root)/media/\(itemID.uuidString.lowercased())/original.gif",
        "previewUrl":"\(root)/media/\(itemID.uuidString.lowercased())/preview.png",
        "width":16,"height":16,"frameCount":2,"byteSize":1000,"variants":[],"likeCount":0,
        "uploader":{"id":"\(owner.uuidString.lowercased())","displayName":"Example"},
        "visibility":"private","status":"pending","moderationReason":"","aiState":"disabled","aiError":null}
        """
    }
    private func response(_ text: String) -> CommunityResponse { CommunityResponse(status: 200, data: Data(text.utf8)) }
    private var login: CommunityResponse {
        response("""
        {"user":{"id":"\(owner.uuidString.lowercased())","email":"example@example.org","displayName":"Example","role":"user","verified":true},
        "token":"test-only-cloud-session-not-real","expiresAt":"2099-01-01T00:00:00.000Z"}
        """)
    }
    private func library(_ action: (LocalLibrary) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(LocalLibrary(folder: folder))
    }
    private func gif() throws -> Data {
        let size = PanelSize(width: 16, height: 16)
        return try MediaCodec.encode([.black(size), MediaCodec.text("A", size: size)], delays: [0.1, 0.1])
    }

    func testUnspecifiedCatalogLicenseRemainsUnspecifiedInLocalCredits() throws {
        let json = itemJSON.replacingOccurrences(of: "\"license\":\"CC0-1.0\"", with: "\"license\":\"unspecified\"")
            .replacingOccurrences(of: "\"displayAttribution\":\"Example creator\"", with: "\"displayAttribution\":\"\"")
        let item = try JSONDecoder().decode(CommunityItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.license, "unspecified")
        XCTAssertEqual(item.credit.license, "unspecified")
        XCTAssertEqual(item.credit.author, "")
        try library { library in
            let saved = try library.saveCatalogGIF(gif(), item: item, origin: CommunityOrigin.parse(root),
                accountID: nil, assetURL: item.gifUrl)
            XCTAssertEqual(saved.attribution?.license, "unspecified")
            XCTAssertEqual(saved.attribution?.author, "")
        }
    }

    func testSharingRequiresOnlyExplicitConsentWithoutReviewMetadata() async throws {
        let shared = itemJSON.replacingOccurrences(of: "\"visibility\":\"private\"", with: "\"visibility\":\"shared\"")
            .replacingOccurrences(of: "\"license\":\"CC0-1.0\"", with: "\"license\":\"unspecified\"")
        let transport = CloudTransport([login, response("{\"item\":\(shared)}")])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root)
        try await service.signIn(email: "example@example.org", password: "example test password")
        let result = try await service.submitUpload(itemID, sharingAttested: true)
        XCTAssertEqual(result.visibility, "shared")
        let requests = await transport.history()
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.url?.path, "/api/v1/items/\(itemID.uuidString.lowercased())/submit")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Bool])
        XCTAssertEqual(body, ["sharingAttested": true])
    }

    func testGuestCanBrowseDownloadAndSaveWithoutAnAuthRequest() async throws {
        let bytes = try gif()
        let transport = CloudTransport([response("{\"items\":[\(itemJSON)],\"page\":1,\"limit\":24,\"total\":1}"),
            CommunityResponse(status: 200, data: bytes)])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root)
        let page = try await service.items(query: "", category: "", page: 1)
        let item = try XCTUnwrap(page.items.first)
        let downloaded = try await service.download(item.gifUrl)
        try library { library in
            let origin = try CommunityOrigin.parse(root)
            let first = try library.saveCatalogGIF(downloaded, item: item, origin: origin, accountID: nil, assetURL: item.gifUrl)
            let again = try library.saveCatalogGIF(downloaded, item: item, origin: origin, accountID: nil, assetURL: item.gifUrl)
            XCTAssertEqual(first.id, again.id)
            XCTAssertEqual(library.state.media.count, 1)
            XCTAssertEqual(try library.data(first), bytes)
            XCTAssertEqual(first.attribution?.author, "Example creator")
            XCTAssertEqual(first.attribution?.license, "CC0-1.0")
            XCTAssertNil(first.cloudSource?.accountID)
        }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertFalse(service.signedIn)
    }

    func testCloudLibraryLoadsFullPrivateMetadataAndUsesBearer() async throws {
        let transport = CloudTransport([login, response("{\"items\":[\(itemJSON)]}")])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root)
        try await service.signIn(email: "example@example.org", password: "example test password")
        let store = CloudLibraryStore()
        await store.refresh(service)
        XCTAssertNil(store.failure)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.visibility, "private")
        XCTAssertEqual(item.item.displayAttribution, "Example creator")
        XCTAssertEqual(item.item.gifUrl.path, "/media/\(itemID.uuidString.lowercased())/original.gif")
        let requests = await transport.history()
        XCTAssertEqual(requests[1].url?.path, "/api/v1/me/items")
        XCTAssertNotNil(requests[1].value(forHTTPHeaderField: "Authorization"))
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLocalAndCloudCopiesMergeOnlyForTheMatchingServerAndOwner() async throws {
        let transport = CloudTransport([login, response("{\"items\":[\(itemJSON)]}")])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root)
        try await service.signIn(email: "example@example.org", password: "example test password")
        let store = CloudLibraryStore()
        await store.refresh(service)
        let cloud = try XCTUnwrap(store.items.first)
        let origin = try CommunityOrigin.parse(root)
        try library { library in
            let local = try library.saveCatalogGIF(gif(), item: cloud.item, origin: origin, accountID: owner, assetURL: cloud.item.gifUrl)
            XCTAssertTrue(store.cloudOnly(local: library.state.media, origin: origin, owner: owner).isEmpty)
            XCTAssertEqual(store.connectedItem(local, origin: origin, owner: owner)?.id, itemID)
            XCTAssertNil(store.connectedItem(local, origin: origin, owner: UUID()))
            XCTAssertNil(store.connectedItem(local, origin: try CommunityOrigin.parse("https://other.example"), owner: owner))
            XCTAssertTrue(store.cloudOnly(local: library.state.media, origin: origin, owner: UUID()).isEmpty)
            try library.delete(local)
            XCTAssertEqual(store.items.count, 1, "Local deletion must not delete the cloud record")
        }
    }

    func testCloudLinksStayOutOfBackupsAndLegacyMediaStillLoads() throws {
        let item = try JSONDecoder().decode(CommunityItem.self, from: Data(itemJSON.utf8))
        try library { library in
            let origin = try CommunityOrigin.parse(root)
            let saved = try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: owner, assetURL: item.gifUrl)
            XCTAssertEqual(saved.cloudSource?.accountID, owner)
            let backup = try JSONDecoder().decode(LibraryBackup.self, from: library.backup())
            XCTAssertNil(backup.state.media.first?.cloudSource)
            try library.importBackup(JSONEncoder().encode(backup))
            XCTAssertEqual(library.state.media.count, 2)
            XCTAssertNil(library.state.media.last?.cloudSource)
        }
        let old = Data(#"{"id":"7D874074-3784-4B38-A59A-304418DCFB79","name":"Old","created":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedMedia.self, from: old).cloudSource)
    }

    func testCloudUploadLinkPreservesOriginalLocalBytesAndCredits() throws {
        try library { library in
            let bytes = try gif()
            let credit = Attribution(source: "https://example.org", author: "Creator", license: "CC0-1.0", licenseURL: "https://example.org/license")
            try library.add(name: "Local loop", data: bytes, attribution: credit)
            let local = try XCTUnwrap(library.state.media.first)
            try library.connectCloudCopy(mediaID: local.id, itemID: itemID, origin: CommunityOrigin.parse(root), accountID: owner)
            let linked = try XCTUnwrap(library.state.media.first)
            XCTAssertEqual(linked.id, local.id)
            XCTAssertEqual(linked.attribution, credit)
            XCTAssertEqual(try library.data(linked), bytes)
            XCTAssertEqual(linked.cloudSource?.itemID, itemID)
            XCTAssertEqual(linked.cloudSource?.assetURL, "\(root)/media/\(itemID.uuidString.lowercased())/original.gif")
            XCTAssertThrowsError(try library.connectCloudCopy(mediaID: UUID(), itemID: itemID, origin: CommunityOrigin.parse(root), accountID: owner))
        }
    }

    func testCloudPaginationLoadsAdditionalPagesWithoutRepeatingRecords() async throws {
        let otherID = "bbbbbbbb-1234-4567-89ab-abcdefabcdef"
        let second = itemJSON.replacingOccurrences(of: itemID.uuidString.lowercased(), with: otherID)
        let transport = CloudTransport([login,
            response("{\"items\":[\(itemJSON)],\"page\":1,\"limit\":1,\"total\":2}"),
            response("{\"items\":[\(second)],\"page\":2,\"limit\":1,\"total\":2}")])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root)
        try await service.signIn(email: "example@example.org", password: "example test password")
        let store = CloudLibraryStore()
        await store.refresh(service)
        XCTAssertEqual(store.nextPage, 2)
        await store.loadMore(service)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertNil(store.nextPage)
        XCTAssertNil(store.failure)
        let requests = await transport.history()
        let parts = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests[2].url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "page" })?.value, "2")
    }

    func testOwnedNearEndOneFlightAndExhaustion() async throws {
        let second = itemJSON.replacingOccurrences(of: itemID.uuidString.lowercased(), with: "bbbbbbbb-1234-4567-89ab-abcdefabcdef")
        let transport = CloudTransport([login, response("{\"items\":[\(itemJSON)],\"page\":1,\"limit\":1,\"total\":2}"),
            response("{\"items\":[\(second)],\"page\":2,\"limit\":1,\"total\":2}")])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root); try await service.signIn(email: "example@example.org", password: "example test password")
        let store = CloudLibraryStore(); await store.refresh(service)
        for _ in 0..<20 { store.nearEnd(itemID, community: service) }
        for _ in 0..<200 {
            if store.nextPage == nil && !store.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.items.count, 2); XCTAssertNil(store.failure)
        let requests = await transport.history(); XCTAssertEqual(requests.count, 3)
        store.nearEnd(itemID, community: service); await Task.yield()
        let final = await transport.history(); XCTAssertEqual(final.count, 3)
    }

    func testOwnedPagingErrorRequiresExplicitRetryWithoutDroppingRows() async throws {
        let second = itemJSON.replacingOccurrences(of: itemID.uuidString.lowercased(), with: "bbbbbbbb-1234-4567-89ab-abcdefabcdef")
        let transport = CloudTransport([login, response("{\"items\":[\(itemJSON)],\"page\":1,\"limit\":1,\"total\":2}"),
            CommunityResponse(status: 503, data: Data(#"{"error":{"code":"offline","message":"Page offline"}}"#.utf8)),
            response("{\"items\":[\(second)],\"page\":2,\"limit\":1,\"total\":2}")])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root); try await service.signIn(email: "example@example.org", password: "example test password")
        let store = CloudLibraryStore(); await store.refresh(service)
        store.nearEnd(itemID, community: service)
        for _ in 0..<200 {
            if store.failure != nil && !store.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.failure); XCTAssertEqual(store.items.count, 1)
        for _ in 0..<20 { store.nearEnd(itemID, community: service) }
        let failed = await transport.history(); XCTAssertEqual(failed.count, 3)
        await store.retry(service); XCTAssertEqual(store.items.count, 2); XCTAssertNil(store.failure)
        let requests = await transport.history()
        XCTAssertEqual(requests[2].url, requests[3].url)
    }

    func testOwnedLateAccountResultsAreDiscarded() async throws {
        let second = itemJSON.replacingOccurrences(of: itemID.uuidString.lowercased(), with: "bbbbbbbb-1234-4567-89ab-abcdefabcdef")
        let transport = CloudTransport([login, response("{\"items\":[\(itemJSON)],\"page\":1,\"limit\":1,\"total\":2}"),
            response("{\"items\":[\(second)],\"page\":2,\"limit\":1,\"total\":2}")])
        let service = CommunityController(vault: CloudVault(), factory: { _ in transport })
        service.configure(root); try await service.signIn(email: "example@example.org", password: "example test password")
        let store = CloudLibraryStore(); await store.refresh(service); await transport.holdNext()
        store.nearEnd(itemID, community: service)
        for _ in 0..<200 {
            if await transport.history().count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try service.forgetLocalSession(); await store.refresh(service); await transport.release()
        await Task.yield()
        XCTAssertTrue(store.items.isEmpty); XCTAssertNil(store.nextPage)
    }
}
