import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class ArtworkPaginationTests: XCTestCase {
    private func item(_ number: Int, title: String = "Generated") throws -> CommunityItem {
        let id = String(format: "33333333-3333-4333-8333-%012d", number)
        let json = """
        {"id":"\(id)","title":"\(title)","category":"pixel-art","tags":[],
        "displayAttribution":"Generated fixture","license":"original",
        "pageUrl":"https://catalog.example/items/\(id)","gifUrl":"https://catalog.example/media/\(id)/original.gif",
        "previewUrl":"https://catalog.example/media/\(id)/preview.png","width":16,"height":16,"frameCount":1,
        "byteSize":100,"variants":[],"likeCount":0,
        "uploader":{"id":"11111111-1111-4111-8111-111111111111","displayName":"Fixture"}}
        """
        return try JSONDecoder().decode(CommunityItem.self, from: Data(json.utf8))
    }
    private func submission(_ number: Int, title: String = "Generated") throws -> CommunitySubmission {
        let id = String(format: "33333333-3333-4333-8333-%012d", number)
        return try JSONDecoder().decode(CommunitySubmission.self, from: Data("""
        {"id":"\(id)","title":"\(title)","status":"pending","moderationReason":"","aiState":"disabled","visibility":"private"}
        """.utf8))
    }
    private func settled(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Pagination did not settle.")
    }
    func testNearEndIsRequiredAndRapidAppearancesFetchOneAcknowledgedPage() async throws {
        let first = try (1...10).map { try item($0) }, additions = try [item(1, title: "Updated"), item(11), item(12)]
        var pages: [Int] = []
        let store = CommunityGalleryStore()
        store.search(valid: { true }, fetch: { page in
            pages.append(page)
            return CommunityPage(items: page == 1 ? first : additions, page: page, limit: 10, total: 12)
        })
        try await settled { !store.loading }
        let oldKey = store.thumbnailKey(first[0], url: first[0].gifUrl)
        store.nearEnd(first[0].id)
        XCTAssertEqual(pages, [1])
        for _ in 0..<20 { store.nearEnd(first[9].id) }
        try await settled { !store.loading }
        XCTAssertEqual(pages, [1, 2])
        XCTAssertEqual(store.items.count, 12); XCTAssertEqual(Set(store.items.map(\.id)).count, 12)
        XCTAssertEqual(store.items.first?.title, "Updated")
        XCTAssertNotEqual(store.thumbnailKey(first[0], url: first[0].gifUrl), oldKey)
        XCTAssertNil(store.nextPage)
        for _ in 0..<20 { store.nearEnd(additions[2].id) }
        XCTAssertEqual(pages, [1, 2])
    }
    func testPageErrorRetainsRowsBlocksAutoRetryAndRetriesTheFailedPage() async throws {
        let a = try item(1), b = try item(2), c = try item(3), d = try item(4)
        var pages: [Int] = [], failed = false
        let store = CommunityGalleryStore()
        store.search(valid: { true }, fetch: { page in
            pages.append(page)
            if page == 2 && !failed { failed = true; throw BackpackError.invalid("Fixture page unavailable") }
            return CommunityPage(items: page == 1 ? [a, b] : [c, d], page: page, limit: 2, total: 4)
        })
        try await settled { !store.loading }; store.nearEnd(b.id)
        try await settled { !store.loading }
        XCTAssertEqual(store.items.map(\.id), [a.id, b.id]); XCTAssertNotNil(store.failure)
        for _ in 0..<20 { store.nearEnd(b.id) }
        XCTAssertEqual(pages, [1, 2])
        store.retry(); try await settled { !store.loading }
        XCTAssertEqual(pages, [1, 2, 2]); XCTAssertEqual(store.items.count, 4); XCTAssertNil(store.failure)
    }
    func testWrongPageAndChangedPageSizeNeverAppend() async throws {
        for changedLimit in [false, true] {
            let a = try item(1), b = try item(2)
            let store = CommunityGalleryStore()
            store.search(valid: { true }, fetch: { page in
                CommunityPage(items: [page == 1 ? a : b], page: page == 1 || changedLimit ? page : 3,
                    limit: page == 2 && changedLimit ? 2 : 1, total: 3)
            })
            try await settled { !store.loading }; store.nearEnd(a.id); try await settled { !store.loading }
            XCTAssertEqual(store.items.map(\.id), [a.id]); XCTAssertNotNil(store.failure)
        }
    }
    func testNoProgressStopsInsteadOfFetchingForeverButUpdatesDuplicateContent() async throws {
        let a = try item(1), updated = try item(1, title: "New bytes")
        var pages: [Int] = []
        let store = CommunityGalleryStore()
        store.search(valid: { true }, fetch: { page in
            pages.append(page)
            return CommunityPage(items: [page == 1 ? a : updated], page: page, limit: 1, total: 100)
        })
        try await settled { !store.loading }; store.nearEnd(a.id); try await settled { !store.loading }
        XCTAssertTrue(store.failure?.contains("no new") == true)
        XCTAssertEqual(store.items.first?.title, "New bytes")
        for _ in 0..<20 { store.nearEnd(a.id) }
        XCTAssertEqual(pages, [1, 2])
    }
    func testLateFilterResponseCannotReplaceNewResults() async throws {
        let old = try item(1), fresh = try item(2)
        var pending: CheckedContinuation<CommunityPage, Never>?
        let started = expectation(description: "Old request")
        let store = CommunityGalleryStore()
        store.search(valid: { true }, fetch: { _ in
            await withCheckedContinuation { pending = $0; started.fulfill() }
        })
        await fulfillment(of: [started], timeout: 5)
        store.search(valid: { true }, fetch: { CommunityPage(items: [fresh], page: $0, limit: 1, total: 1) })
        try await settled { !store.loading }
        pending?.resume(returning: CommunityPage(items: [old], page: 1, limit: 1, total: 1))
        await Task.yield()
        XCTAssertEqual(store.items.map(\.id), [fresh.id]); XCTAssertNil(store.failure)
    }
    func testAccountOrGenerationChangeAndCancelDiscardLateIO() async throws {
        for cancel in [false, true] {
            let a = try item(1)
            var valid = true, pending: CheckedContinuation<CommunityPage, Never>?
            let started = expectation(description: "Context request")
            let store = CommunityGalleryStore()
            store.search(valid: { valid }, fetch: { _ in
                await withCheckedContinuation { pending = $0; started.fulfill() }
            })
            await fulfillment(of: [started], timeout: 5)
            if cancel { store.cancel() } else { valid = false }
            pending?.resume(returning: CommunityPage(items: [a], page: 1, limit: 1, total: 1))
            try await settled { !store.loading }
            XCTAssertTrue(store.items.isEmpty)
        }
    }
    func testUploadsNearEndPreservesStableIDsAndAcknowledgedUpdates() async throws {
        let a = try submission(1), b = try submission(2), updated = try submission(1, title: "Updated"), c = try submission(3)
        var pages: [Int] = []
        let store = CommunityUploadsStore()
        store.search(valid: { true }, fetch: { page in
            pages.append(page)
            return CommunityUploadPage(items: page == 1 ? [a, b] : [updated, c], page: page, limit: 2, total: 3)
        })
        try await settled { !store.loading }
        for _ in 0..<20 { store.nearEnd(b.id) }
        try await settled { !store.loading }
        XCTAssertEqual(pages, [1, 2]); XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.items.first?.title, "Updated"); XCTAssertNil(store.nextPage)
    }
    func testUploadsErrorDoesNotResetRowsOrAutomaticallyRetry() async throws {
        let a = try submission(1), b = try submission(2)
        var pages: [Int] = [], fail = true
        let store = CommunityUploadsStore()
        store.search(valid: { true }, fetch: { page in
            pages.append(page)
            if page == 2 && fail { throw BackpackError.invalid("Upload page offline") }
            return CommunityUploadPage(items: [page == 1 ? a : b], page: page, limit: 1, total: 2)
        })
        try await settled { !store.loading }; store.nearEnd(a.id); try await settled { !store.loading }
        for _ in 0..<20 { store.nearEnd(a.id) }
        XCTAssertEqual(pages, [1, 2]); XCTAssertEqual(store.items.map(\.id), [a.id])
        fail = false; store.retry(); try await settled { !store.loading }
        XCTAssertEqual(pages, [1, 2, 2]); XCTAssertNil(store.failure)
    }
    func testUploadsLateContextAndNoProgressCannotFlood() async throws {
        let a = try submission(1)
        let store = CommunityUploadsStore()
        var pages: [Int] = []
        store.search(valid: { true }, fetch: { page in
            pages.append(page); return CommunityUploadPage(items: [a], page: page, limit: 1, total: 100)
        })
        try await settled { !store.loading }; store.nearEnd(a.id); try await settled { !store.loading }
        for _ in 0..<20 { store.nearEnd(a.id) }
        XCTAssertNotNil(store.failure); XCTAssertEqual(pages, [1, 2])
        var pending: CheckedContinuation<CommunityUploadPage, Never>?
        let started = expectation(description: "Upload context")
        store.search(valid: { true }, fetch: { _ in await withCheckedContinuation { pending = $0; started.fulfill() } })
        await fulfillment(of: [started], timeout: 5); store.cancel()
        pending?.resume(returning: CommunityUploadPage(items: [a], page: 1, limit: 1, total: 1))
        await Task.yield(); XCTAssertTrue(store.items.isEmpty)
    }
}
