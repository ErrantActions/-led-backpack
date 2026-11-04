import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class MediaOrganizationTests: XCTestCase {
    func testLegacyMediaWithoutOrganizationStillDecodes() throws {
        let data = Data(#"{"id":"7D874074-3784-4B38-A59A-304418DCFB79","name":"Old artwork","created":0}"#.utf8)
        let item = try JSONDecoder().decode(SavedMedia.self, from: data)
        XCTAssertEqual(item.categoryName, "Uncategorized")
        XCTAssertFalse(item.isFavorite)
    }

    func testOrganizingPreservesArtworkAndBackupMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        let data = try MediaCodec.encode([PixelFrame.black(PanelSize(width: 16, height: 16))], delays: [1])
        let credit = Attribution(source: "https://example.org", author: "Example", license: "CC0", licenseURL: "https://example.org/license")
        try library.add(name: "Cat", data: data, attribution: credit, category: "Animals")
        let item = try XCTUnwrap(library.state.media.first)
        try library.organize(item.id, category: "  Pixel art  ", favorite: true)
        let saved = try XCTUnwrap(library.state.media.first)
        XCTAssertEqual(saved.categoryName, "Pixel art")
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(try library.data(saved), data)
        XCTAssertEqual(saved.attribution, credit)
        XCTAssertEqual(library.mediaCategories, ["Pixel art"])
        try library.importBackup(library.backup())
        let imported = try XCTUnwrap(library.state.media.last)
        XCTAssertNotEqual(imported.id, item.id)
        XCTAssertEqual(imported.categoryName, "Pixel art")
        XCTAssertTrue(imported.isFavorite)
        XCTAssertEqual(imported.attribution, credit)
        XCTAssertEqual(try library.data(imported), data)
    }

    func testCategoryLimitAndInvalidBackupDoNotChangeLibrary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        let data = try MediaCodec.encode([PixelFrame.black(PanelSize(width: 16, height: 16))], delays: [1])
        try library.add(name: "Artwork", data: data)
        let item = try XCTUnwrap(library.state.media.first)
        try library.organize(item.id, category: String(repeating: "A", count: 40), favorite: true)
        XCTAssertThrowsError(try library.organize(item.id, category: String(repeating: "A", count: 41), favorite: false))
        XCTAssertTrue(try XCTUnwrap(library.state.media.first).isFavorite)
        var backup = try JSONDecoder().decode(LibraryBackup.self, from: library.backup())
        backup.state.media[0].category = String(repeating: "B", count: 41)
        XCTAssertThrowsError(try library.importBackup(JSONEncoder().encode(backup)))
        XCTAssertEqual(library.state.media.count, 1)
        try library.organize(item.id, category: "  ", favorite: false)
        XCTAssertEqual(library.state.media.first?.categoryName, "Uncategorized")
        XCTAssertFalse(try XCTUnwrap(library.state.media.first).isFavorite)
        XCTAssertThrowsError(try library.organize(UUID(), category: "Animals", favorite: true))
    }
}
