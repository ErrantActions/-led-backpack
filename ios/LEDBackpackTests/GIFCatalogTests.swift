import XCTest
import Combine
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class GIFCatalogTests: XCTestCase {
    private func page(_ id: Int, rank: Int = 1, mime: String = "image/gif", bytes: Int = 1000,
        license: String? = "CC0", host: String = "upload.wikimedia.org") -> [String: Any] {
        var metadata: [String: Any] = ["Artist": ["value": "<a>Example &amp; Co</a>"]]
        if let license { metadata["LicenseShortName"] = ["value": license] }
        return [
            "pageid": id, "title": "File:Example \(id).gif", "index": rank,
            "imageinfo": [[
                "url": "https://\(host)/example\(id).gif",
                "thumburl": "https://\(host)/thumb\(id).gif",
                "descriptionurl": "https://commons.wikimedia.org/wiki/File:Example_\(id).gif",
                "mime": mime, "size": bytes, "width": 64, "height": 64, "extmetadata": metadata
            ]]
        ]
    }

    private func response(_ pages: [[String: Any]], next: Int? = nil) throws -> Data {
        var value: [String: Any] = ["batchcomplete": true, "query": ["pages": pages]]
        if let next { value["continue"] = ["gsroffset": next, "continue": "gsroffset||"] }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func result(_ id: Int) throws -> GIFResult {
        try XCTUnwrap(CommonsSearch.decode(response([page(id)])).items.first)
    }

    func testRequestUsesGIFMimeTopicPaginationAndBoundedThumbnails() throws {
        let url = try CommonsSearch.requestURL("cat", topic: .pixelArt, offset: 20)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parameters["gsrsearch"], "pixel art cat filemime:image/gif")
        XCTAssertEqual(parameters["gsroffset"], "20")
        XCTAssertEqual(parameters["gsrnamespace"], "6")
        XCTAssertEqual(parameters["iiurlwidth"], "240")
        XCTAssertEqual(parameters["iiurlheight"], "240")
        XCTAssertFalse(parameters["gsrsearch"]?.contains("ext:gif") ?? true)
        XCTAssertNoThrow(try CommonsSearch.requestURL("", topic: .all))
        XCTAssertThrowsError(try CommonsSearch.requestURL(String(repeating: "A", count: 101)))
        XCTAssertThrowsError(try CommonsSearch.requestURL("cat", offset: -1))
    }

    func testRelevanceCreditsAndPaginationSurviveDecoding() throws {
        let decoded = try CommonsSearch.decode(response([page(1, rank: 2), page(2, rank: 1)], next: 20))
        XCTAssertEqual(decoded.items.map(\.id), [2, 1])
        XCTAssertEqual(decoded.nextOffset, 20)
        let first = try XCTUnwrap(decoded.items.first)
        XCTAssertEqual(first.attribution.author, "Example & Co")
        XCTAssertEqual(first.attribution.license, "CC0")
        XCTAssertEqual(first.previewURL.host, "upload.wikimedia.org")
        XCTAssertEqual(first.width, 64)
        XCTAssertEqual(decoded.excludedCount, 0)
    }

    func testUnusableResultsAreExplicitlyCounted() throws {
        let decoded = try CommonsSearch.decode(response([
            page(1), page(2, mime: "image/jpeg"), page(3, bytes: 5_000_001),
            page(4, license: nil), page(5, host: "example.org")
        ]))
        XCTAssertEqual(decoded.items.map(\.id), [1])
        XCTAssertEqual(decoded.excludedCount, 4)
        XCTAssertEqual(try CommonsSearch.decode(response([page(6, bytes: 5_000_000)])).items.count, 1)
    }

    func testEmptyAndInvalidResponsesAreNotConfused() throws {
        let empty = try CommonsSearch.decode(Data(#"{"batchcomplete":true}"#.utf8))
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertThrowsError(try CommonsSearch.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try CommonsSearch.decode(Data("not JSON".utf8)))
        XCTAssertThrowsError(try CommonsSearch.decode(Data(#"{"error":{"code":"badsearch","info":"Invalid search"}}"#.utf8)))
        XCTAssertThrowsError(try CommonsSearch.decode(response([], next: 0)))
        let warning = try CommonsSearch.decode(Data(#"{"batchcomplete":true,"warnings":{"main":{"warnings":"Try a broader query"}}}"#.utf8))
        XCTAssertEqual(warning.notice, "Try a broader query")
    }

    private func waitForLoading(_ catalog: GIFCatalog) async {
        guard catalog.loading else { return }
        let settled = expectation(description: "Catalog request settled")
        let token = catalog.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in settled.fulfill() }
        await fulfillment(of: [settled], timeout: 5)
        withExtendedLifetime(token) {}
    }

    func testCatalogPaginationDeduplicatesResults() async throws {
        let first = try result(1), second = try result(2)
        var offsets: [Int] = []
        let catalog = GIFCatalog { _, _, offset in
            offsets.append(offset)
            return GIFSearchPage(items: offset == 0 ? [first] : [first, second],
                nextOffset: offset == 0 ? 20 : nil, excludedCount: 0, notice: nil)
        }
        catalog.search("cat", topic: .animals)
        await waitForLoading(catalog)
        catalog.nearEnd(first.id)
        await waitForLoading(catalog)
        XCTAssertEqual(catalog.results.map(\.id), [1, 2])
        XCTAssertEqual(offsets, [0, 20])
        XCTAssertNil(catalog.nextOffset)
    }

    func testCatalogErrorsAreVisibleAndDoNotLeaveSearchBusy() async {
        let catalog = GIFCatalog { _, _, _ in throw BackpackError.invalid("Catalog unavailable") }
        catalog.search("cat", topic: .animals)
        await waitForLoading(catalog)
        XCTAssertEqual(catalog.errorMessage, "Catalog unavailable")
        XCTAssertFalse(catalog.loading)
        XCTAssertTrue(catalog.searched)
    }

    func testNewSearchDoesNotAcceptCancelledResults() async throws {
        let old = try result(1), recent = try result(2)
        let started = expectation(description: "First request started")
        var pending: CheckedContinuation<GIFSearchPage, Error>?
        let catalog = GIFCatalog { query, _, _ in
            if query == "old" {
                return try await withCheckedThrowingContinuation {
                    pending = $0
                    started.fulfill()
                }
            }
            return GIFSearchPage(items: [recent], nextOffset: nil, excludedCount: 0, notice: nil)
        }
        catalog.search("old", topic: .all)
        await fulfillment(of: [started], timeout: 5)
        catalog.search("new", topic: .all)
        await waitForLoading(catalog)
        pending?.resume(returning: GIFSearchPage(items: [old], nextOffset: nil, excludedCount: 0, notice: nil))
        await Task.yield()
        XCTAssertEqual(catalog.results.map(\.id), [2])
        XCTAssertNil(catalog.errorMessage)
        XCTAssertFalse(catalog.loading)
    }

    func testNearEndRejectsFloodErrorsAndRetriesTheSameOffset() async throws {
        let first = try result(1), second = try result(2)
        var offsets: [Int] = [], failure = true
        let catalog = GIFCatalog { _, _, offset in
            offsets.append(offset)
            if offset == 20 && failure { throw BackpackError.invalid("Page offline") }
            return GIFSearchPage(items: offset == 0 ? [first] : [second],
                nextOffset: offset == 0 ? 20 : nil, excludedCount: 0, notice: nil)
        }
        catalog.search("cat", topic: .animals); await waitForLoading(catalog)
        for _ in 0..<20 { catalog.nearEnd(first.id) }
        await waitForLoading(catalog)
        XCTAssertEqual(offsets, [0, 20]); XCTAssertEqual(catalog.results, [first])
        for _ in 0..<20 { catalog.nearEnd(first.id) }
        XCTAssertEqual(offsets, [0, 20])
        failure = false; catalog.retry(); await waitForLoading(catalog)
        XCTAssertEqual(offsets, [0, 20, 20]); XCTAssertNil(catalog.errorMessage)
        for _ in 0..<20 { catalog.nearEnd(second.id) }
        XCTAssertEqual(offsets, [0, 20, 20])
    }

    func testNoProgressIsVisibleAndDuplicateBytesInvalidatePreviewKey() async throws {
        let first = try result(1)
        let changed = GIFResult(id: first.id, title: "Updated", url: first.url, page: first.page,
            attribution: first.attribution, previewURL: first.previewURL, width: first.width, height: first.height, bytes: 2000)
        var offsets: [Int] = []
        let catalog = GIFCatalog { _, _, offset in
            offsets.append(offset)
            return GIFSearchPage(items: [offset == 0 ? first : changed], nextOffset: offset + 20, excludedCount: 0, notice: nil)
        }
        catalog.search("cat", topic: .animals); await waitForLoading(catalog)
        let key = catalog.thumbnailKey(first)
        catalog.nearEnd(first.id); await waitForLoading(catalog)
        XCTAssertTrue(catalog.errorMessage?.contains("no new") == true)
        XCTAssertEqual(catalog.results.first?.bytes, 2000)
        XCTAssertNotEqual(catalog.thumbnailKey(first), key)
        catalog.nearEnd(first.id); XCTAssertEqual(offsets, [0, 20])
    }
}
