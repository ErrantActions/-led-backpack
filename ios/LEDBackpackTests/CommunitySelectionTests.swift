import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class CommunitySelectionTests: XCTestCase {
    private let id = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let base = "https://catalog.example"
    private func gif() -> Data {
        Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,0,0,0,255,255,255,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
    }
    private func item(_ id: UUID? = nil) throws -> CommunityItem {
        let id = id ?? self.id, prefix = "\(base)/media/\(id.uuidString.lowercased())"
        let object: [String: Any] = ["id":id.uuidString,"title":"Fixture credit preserved","category":"other","tags":[],
            "displayAttribution":"Fixture creator","license":"unspecified","pageUrl":"\(base)/items/\(id.uuidString)",
            "gifUrl":prefix + "/original.gif","previewUrl":prefix + "/preview.png","width":1,"height":1,"frameCount":1,"byteSize":gif().count,
            "uploader":["id":UUID().uuidString,"displayName":"Fixture"],"likeCount":0,"variants":[]]
        return try JSONDecoder().decode(CommunityItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func library() throws -> LocalLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("community-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try LocalLibrary(folder: root)
    }
    func testTapsToggleSelectionInsteadOfOpeningDetails() throws {
        var selection = CommunitySelection()
        try selection.toggle(id); XCTAssertEqual(selection.ids, [id])
        try selection.toggle(id); XCTAssertTrue(selection.ids.isEmpty)
    }
    func testMultipleSelectionPreservesDeliberateOrder() throws {
        let a = try item(), b = try item(UUID())
        var selection = CommunitySelection(); try selection.toggle(b.id); try selection.toggle(a.id)
        XCTAssertEqual(try selection.selected(from: [a,b]).map(\.id), [b.id,a.id])
    }
    func testSelectionBoundFailsExplicitlyWithoutDroppingExistingChoices() throws {
        var selection = CommunitySelection()
        for _ in 0..<20 { try selection.toggle(UUID()) }
        let previous = selection.ids
        XCTAssertThrowsError(try selection.toggle(UUID()))
        XCTAssertEqual(selection.ids, previous)
    }
    func testMissingOrDuplicateCurrentItemsFailClosed() throws {
        var selection = CommunitySelection(); try selection.toggle(id)
        XCTAssertThrowsError(try selection.selected(from: []))
        let item = try item(); XCTAssertThrowsError(try selection.selected(from: [item,item]))
    }
    func testFavoritesSaveLocalCopyWithCreditsAndNoSendQueue() throws {
        let library = try library(), item = try item(), origin = try CommunityOrigin.parse(base)
        let copy = try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: nil, assetURL: item.gifUrl, favorite: true)
        XCTAssertTrue(copy.isFavorite); XCTAssertEqual(copy.attribution, item.credit)
        XCTAssertEqual(try library.data(copy), gif())
        XCTAssertTrue(library.state.transferQueue?.isEmpty ?? true)
    }
    func testFavoritingExistingLocalCopyDoesNotDuplicateOrClearPriorState() throws {
        let library = try library(), item = try item(), origin = try CommunityOrigin.parse(base)
        let first = try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: nil, assetURL: item.gifUrl)
        let favorite = try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: nil, assetURL: item.gifUrl, favorite: true)
        XCTAssertEqual(first.id, favorite.id); XCTAssertEqual(library.state.media.count, 1)
        XCTAssertTrue(favorite.isFavorite)
        let ordinary = try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: nil, assetURL: item.gifUrl)
        XCTAssertTrue(ordinary.isFavorite)
    }
    func testSendAddsOnlyLocalQueueNoFavoriteOrHardwareChange() throws {
        let library = try library(), item = try item(), origin = try CommunityOrigin.parse(base)
        let copy = try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: nil, assetURL: item.gifUrl, queued: true)
        XCTAssertEqual(library.state.transferQueue?.map(\.mediaID), [copy.id])
        XCTAssertFalse(copy.isFavorite); XCTAssertEqual(try library.data(copy), gif())
    }
    func testFullQueueRejectsBeforeSavingNewLibraryItem() throws {
        let library = try library(), first = try item(), next = try item(UUID()), origin = try CommunityOrigin.parse(base)
        let existing = try library.saveCatalogGIF(gif(), item: first, origin: origin, accountID: nil, assetURL: first.gifUrl)
        try library.enqueue(Array(repeating: existing.id, count: 60))
        XCTAssertThrowsError(try library.saveCatalogGIF(gif(), item: next, origin: origin, accountID: nil, assetURL: next.gifUrl, queued: true))
        XCTAssertEqual(library.state.media.count, 1); XCTAssertEqual(library.state.transferQueue?.count, 60)
    }
    func testFailedExistingCopyQueueCommitDoesNotClaimFavoriteSuccess() throws {
        let library = try library(), item = try item(), origin = try CommunityOrigin.parse(base)
        let existing = try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: nil, assetURL: item.gifUrl)
        try library.enqueue(Array(repeating: existing.id, count: 60))
        XCTAssertThrowsError(try library.saveCatalogGIF(gif(), item: item, origin: origin, accountID: nil, assetURL: item.gifUrl, favorite: true, queued: true))
        XCTAssertFalse(library.state.media[0].isFavorite)
    }
    func testStoreInvalidationDropsSelectionWithoutTouchingLibraryOrRadio() {
        let store = CommunitySelectionStore()
        store.toggle(id); XCTAssertEqual(store.selection.ids, [id])
        store.invalidate()
        XCTAssertTrue(store.selection.ids.isEmpty); XCTAssertFalse(store.busy); XCTAssertFalse(store.queueReady)
    }
}
