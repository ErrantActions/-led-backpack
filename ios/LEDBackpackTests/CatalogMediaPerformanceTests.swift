import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor MediaPerformanceTransport: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected media performance request.") }
        let response = responses.removeFirst()
        guard response.data.count <= maxBytes else { throw BackpackError.invalid("Response exceeds media budget.") }
        return response
    }
    func history() -> [URLRequest] { requests }
}

@MainActor
private final class MediaPerformanceVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class CatalogMediaPerformanceTests: XCTestCase {
    private let root = "https://catalog.example"
    private let etag = "\"\(String(repeating: "a", count: 64))\""
    private var configuration: CommunityResponse {
        CommunityResponse(status: 200, data: Data(#"{"requireEmailVerification":false,"catalogMediaValidationEnabled":true}"#.utf8))
    }
    private func service(_ transport: MediaPerformanceTransport) async throws -> CommunityController {
        let service = CommunityController(vault: MediaPerformanceVault(), factory: { _ in transport })
        service.configure(root)
        try await service.loadConfig()
        return service
    }

    func testMediaRevalidatesBeforeReusingBytesAndClearsOnAccountScopeChange() async throws {
        let bytes = Data("synthetic-media".utf8)
        let transport = MediaPerformanceTransport([configuration,
            CommunityResponse(status: 200, data: bytes, headers: ["etag": etag]),
            CommunityResponse(status: 304, data: Data(), headers: ["etag": etag]),
            CommunityResponse(status: 200, data: bytes, headers: ["etag": etag])])
        let service = try await service(transport)
        let url = try XCTUnwrap(URL(string: "\(root)/media/example/preview.png"))
        let first = try await service.download(url)
        let second = try await service.download(url)
        XCTAssertEqual(first, bytes); XCTAssertEqual(second, bytes)
        try service.forgetLocalSession()
        _ = try await service.download(url)
        let requests = await transport.history()
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "If-None-Match"), etag)
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testMediaNeverUsesCachedBytesAfterRevocation() async throws {
        let transport = MediaPerformanceTransport([configuration,
            CommunityResponse(status: 200, data: Data([1, 2]), headers: ["etag": etag]),
            CommunityResponse(status: 404, data: Data()),
            CommunityResponse(status: 304, data: Data(), headers: ["etag": etag])])
        let service = try await service(transport)
        let url = try XCTUnwrap(URL(string: "\(root)/media/example/preview.png"))
        _ = try await service.download(url)
        do { _ = try await service.download(url); XCTFail("Revoked access must not return cached artwork.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("404")) }
        do { _ = try await service.download(url); XCTFail("An unchanged response without cached bytes must fail.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unchanged-media")) }
        let requests = await transport.history()
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testMediaRejectsMismatchedUnchangedValidator() async throws {
        let transport = MediaPerformanceTransport([configuration,
            CommunityResponse(status: 200, data: Data([1]), headers: ["etag": etag]),
            CommunityResponse(status: 304, data: Data(), headers: ["etag": "\"different\""])])
        let service = try await service(transport)
        let url = try XCTUnwrap(URL(string: "\(root)/media/example/preview.png"))
        _ = try await service.download(url)
        do { _ = try await service.download(url); XCTFail("Mismatched validators must not authorize old bytes.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unchanged-media")) }
    }

    func testMediaRespectsNoStoreEvenWithAValidator() async throws {
        let transport = MediaPerformanceTransport([configuration,
            CommunityResponse(status: 200, data: Data([1]), headers: ["etag": etag, "cache-control": "no-store"]),
            CommunityResponse(status: 304, data: Data(), headers: ["etag": etag])])
        let service = try await service(transport)
        let url = try XCTUnwrap(URL(string: "\(root)/media/example/preview.png"))
        _ = try await service.download(url)
        do { _ = try await service.download(url); XCTFail("No-store bytes must not satisfy a later unchanged response.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unchanged-media")) }
        let requests = await transport.history()
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testMediaMemoryCacheBoundsEntriesAndRequiresStrongValidators() throws {
        var cache = CatalogMediaCache()
        let url = try XCTUnwrap(URL(string: "\(root)/media/first"))
        cache.store(Data([1]), etag: "untrusted", for: url)
        XCTAssertNil(cache.entry(for: url, maximumBytes: 10))
        for index in 0..<17 {
            let target = try XCTUnwrap(URL(string: "\(root)/media/\(index)"))
            cache.store(Data(repeating: 1, count: 10), etag: etag, for: target)
        }
        XCTAssertEqual(cache.byteCount, 160)
        XCTAssertNil(cache.entry(for: try XCTUnwrap(URL(string: "\(root)/media/0")), maximumBytes: 10))
        XCTAssertNil(cache.entry(for: try XCTUnwrap(URL(string: "\(root)/media/16")), maximumBytes: 9))
        cache.clear()
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testGalleryKeepsStableServerContentRevisionAcrossRefreshes() async throws {
        let json = """
        {"items":[{"id":"abcdefab-1234-4567-89ab-abcdefabcdef","title":"Artwork","category":"memes","tags":[],
        "displayAttribution":"Example","license":"CC0-1.0","licenseUrl":null,"sourceUrl":null,
        "pageUrl":"\(root)/items/example","gifUrl":"\(root)/media/example/original.gif",
        "previewUrl":"\(root)/media/example/preview.png","width":16,"height":16,"frameCount":1,"byteSize":10,
        "uploader":{"id":null,"displayName":"Example"},"likeCount":0,"variants":[],
        "contentRevision":"\(String(repeating: "a", count: 64))"}],"page":1,"limit":24,"total":1}
        """
        let page = try JSONDecoder().decode(CommunityPage.self, from: Data(json.utf8))
        let store = CommunityGalleryStore()
        store.search(valid: { true }, fetch: { _ in page })
        for _ in 0..<100 where store.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        let first = try XCTUnwrap(store.items.first)
        let initialKey = store.thumbnailKey(first, url: first.previewUrl)
        store.search(valid: { true }, fetch: { _ in page })
        for _ in 0..<100 where store.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        let refreshed = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.thumbnailKey(refreshed, url: refreshed.previewUrl), initialKey)
    }
}
