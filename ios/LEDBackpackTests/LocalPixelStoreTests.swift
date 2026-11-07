import XCTest
import Combine
@testable import LEDBackpack

@MainActor
final class LocalPixelStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("LocalPixelFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func settled(_ store: LocalPixelStore, action: () -> Void) async {
        let done = expectation(description: "Bounded local studio operation finishes")
        let observation = store.$busy.drop(while: { !$0 }).filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
        action()
        await fulfillment(of: [done], timeout: 10)
        withExtendedLifetime(observation) {}
    }
    func testColdStartIsTransparentPausedAndHasNoOriginalOrPlaybackSideEffect() {
        let store = LocalPixelStore()
        XCTAssertFalse(store.busy); XCTAssertFalse(store.playing); XCTAssertNil(store.original)
        XCTAssertEqual(store.document.artwork.width, 64); XCTAssertEqual(store.document.artwork.height, 64)
        XCTAssertTrue(store.document.current.rgba.allSatisfy { $0 == 0 })
    }
    func testInvalidNewCanvasPreservesCurrentDocumentAndSource() {
        let store = LocalPixelStore(), before = store.document.artwork
        store.newDocument(width: 129, height: 1)
        XCTAssertEqual(store.document.artwork, before); XCTAssertNotNil(store.failure)
    }
    func testDocumentSelectionForegroundAndCancelInvalidateLateResultTickets() {
        let store = LocalPixelStore(), first = store.ticket
        XCTAssertTrue(store.accepts(first))
        store.change { try $0.addFrame(copy: false) }
        XCTAssertFalse(store.accepts(first))
        let second = store.ticket
        store.change { try $0.select(0) }
        XCTAssertFalse(store.accepts(second))
        let third = store.ticket
        store.cancel(); XCTAssertFalse(store.accepts(third))
        let fourth = store.ticket
        store.setForeground(false); XCTAssertFalse(store.accepts(fourth))
        store.setForeground(true); XCTAssertFalse(store.accepts(fourth))
    }
    func testReducedMotionDataSavingAndBackgroundBlockPreviewWithoutResumingIt() {
        let store = LocalPixelStore()
        store.change { try $0.addFrame(copy: false) }
        store.play(reducedMotion: true, dataSaving: false); XCTAssertFalse(store.playing)
        store.play(reducedMotion: false, dataSaving: true); XCTAssertFalse(store.playing)
        store.play(reducedMotion: false, dataSaving: false); XCTAssertTrue(store.playing)
        store.setForeground(false); XCTAssertFalse(store.playing)
        store.setForeground(true); XCTAssertFalse(store.playing)
    }
    func testEditableProjectPersistsOriginalTimingAlphaLoopAttributionAndSelectedFrame() async throws {
        let repository = LocalPixelRepository(root: try root())
        var artwork = try LocalPixelFixtures.artwork(2, 1)
        artwork.frames[0].rgba[3] = 128
        artwork.frames.append(LocalPixelFrame(rgba: [0,0,0,0, 0,0,255,255], centiseconds: 65535))
        artwork.repeats = 0
        let original = LocalPixelFixtures.gif(delays: [1,12000], repeats: 4)
        let project = LocalPixelProject(artwork: artwork, selected: 1, original: original, originalName: "Unchanged source")
        let entry = try await repository.save(project, name: "Editable RGBA")
        let reopened = try await repository.read(entry)
        XCTAssertEqual(reopened.artwork, artwork); XCTAssertEqual(reopened.selected, 1)
        XCTAssertEqual(reopened.original, original); XCTAssertEqual(reopened.originalName, "Unchanged source")
        let entries = try await repository.list(); XCTAssertEqual(entries.count, 1)
    }
    func testRepositoryUsesNewIdentitiesAndExactOwnedRemoval() async throws {
        let repository = LocalPixelRepository(root: try root())
        let project = LocalPixelProject(artwork: try LocalPixelFixtures.artwork(), selected: 0, original: nil, originalName: nil)
        let first = try await repository.save(project, name: "Same"), second = try await repository.save(project, name: "Same")
        XCTAssertNotEqual(first.id, second.id)
        try await repository.remove(first)
        let entries = try await repository.list()
        XCTAssertEqual(entries.map(\.id), [second.id])
        let reopened = try await repository.read(second); XCTAssertEqual(reopened.artwork, project.artwork)
    }
    func testCorruptOrChangedProjectDoesNotReplaceCurrentArtworkOrResetIndex() async throws {
        let folder = try root(), repository = LocalPixelRepository(root: folder)
        let project = LocalPixelProject(artwork: try LocalPixelFixtures.artwork(), selected: 0, original: nil, originalName: nil)
        let entry = try await repository.save(project, name: "Preserved entry")
        try Data("damaged".utf8).write(to: folder.appendingPathComponent(entry.filename))
        let store = LocalPixelStore(repository: repository), before = store.document.artwork
        await settled(store) { store.openProject(entry) }
        XCTAssertEqual(store.document.artwork, before); XCTAssertNotNil(store.failure)
        let entries = try await repository.list(); XCTAssertEqual(entries.map(\.id), [entry.id])
    }
    func testReservedDisposalGIFImportRetainsReadOriginalAndPreviousArt() async throws {
        let folder = try root(), url = folder.appendingPathComponent("reserved.gif")
        let bytes = LocalPixelFixtures.gif(disposal: 7); try bytes.write(to: url)
        let store = LocalPixelStore(), before = store.document.artwork
        await settled(store) { store.importFile(url, sprite: false, at: .init(x: 0, y: 0)) }
        XCTAssertEqual(store.document.artwork, before); XCTAssertEqual(store.retainedImport, bytes)
        XCTAssertNil(store.original); XCTAssertNotNil(store.failure); XCTAssertFalse(store.playing)
    }
    func testSuccessfulGIFImportRetainsByteExactOriginalAndDoesNotStartPreview() async throws {
        let folder = try root(), url = folder.appendingPathComponent("source.gif")
        let bytes = LocalPixelFixtures.gif(delays: [0,12000], repeats: 2); try bytes.write(to: url)
        let store = LocalPixelStore()
        await settled(store) { store.importFile(url, sprite: false, at: .init(x: 0, y: 0)) }
        XCTAssertNil(store.failure); XCTAssertEqual(store.original, bytes)
        XCTAssertEqual(store.document.artwork.frames.map(\.centiseconds), [0,12000])
        XCTAssertEqual(store.document.artwork.repeats, 2); XCTAssertFalse(store.playing)
    }
    func testAnimatedSpriteIsRejectedWithoutReplacingSelectedFrame() async throws {
        let folder = try root(), url = folder.appendingPathComponent("animation.gif")
        let bytes = LocalPixelFixtures.gif(); try bytes.write(to: url)
        let store = LocalPixelStore(), before = store.document.artwork
        await settled(store) { store.importFile(url, sprite: true, at: .init(x: 0, y: 0)) }
        XCTAssertEqual(store.document.artwork, before); XCTAssertEqual(store.retainedImport, bytes)
        XCTAssertNotNil(store.failure)
    }
    func testExportSavesRealLocalCopyWithoutChangingDocumentOrStartingPreview() async throws {
        let folder = try root()
        let library = PhoneArtworkLibrary(repository: PhoneArtworkRepository(root: folder.appendingPathComponent("originals")))
        let store = LocalPixelStore()
        store.newDocument(width: 7, height: 11)
        store.change { try $0.fill(.init(x: 0, y: 0), color: .cyan) }
        let before = store.document.artwork
        await settled(store) { store.export(animated: false, name: "Offline PNG", library: library) }
        XCTAssertNil(store.failure); XCTAssertEqual(store.document.artwork, before); XCTAssertFalse(store.playing)
        XCTAssertEqual(library.items.count, 1)
        let entry = try XCTUnwrap(library.items.first)
        XCTAssertEqual(entry.suffix, "png")
        let bytes = try await library.bytes(entry)
        let pixels = try LocalPixelFixtures.decodedPixels(bytes)
        XCTAssertEqual(pixels.width, 7); XCTAssertEqual(pixels.height, 11)
        // The studio receives no phone-player or hardware reference in its export path.
    }
    func testInvalidGIFExportDoesNotAddAnyLibraryCopyAndKeepsRGBA() async throws {
        let folder = try root()
        let library = PhoneArtworkLibrary(repository: PhoneArtworkRepository(root: folder.appendingPathComponent("originals")))
        let store = LocalPixelStore()
        store.change { try $0.fill(.init(x: 0, y: 0), color: LocalPixelColor(r: 255, g: 0, b: 0, a: 128)) }
        let before = store.document.artwork
        await settled(store) { store.export(animated: true, name: "Cannot flatten", library: library) }
        XCTAssertNotNil(store.failure); XCTAssertTrue(library.items.isEmpty); XCTAssertEqual(store.document.artwork, before)
    }
    func testProjectCountBudgetIsExplicitAndNeverDeletesExistingEntries() async throws {
        let folder = try root()
        let entries = (0..<30).map { LocalPixelProjectEntry(id: UUID(), name: "Owned \($0)", byteCount: 1) }
        try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("index.json"))
        let repository = LocalPixelRepository(root: folder)
        let project = LocalPixelProject(artwork: try LocalPixelFixtures.artwork(), selected: 0, original: nil, originalName: nil)
        do { _ = try await repository.save(project, name: "Excess"); XCTFail("Must enforce project count") } catch {}
        let preserved = try await repository.list(); XCTAssertEqual(preserved.map(\.id), entries.map(\.id))
    }
    func testProjectSourceAndSelectedFrameBoundsAreCheckedBeforePersistence() async throws {
        let repository = LocalPixelRepository(root: try root())
        let art = try LocalPixelFixtures.artwork()
        for project in [
            LocalPixelProject(artwork: art, selected: 1, original: nil, originalName: nil),
            LocalPixelProject(artwork: art, selected: 0, original: Data(repeating: 0, count: 5_000_001), originalName: nil)
        ] {
            do { _ = try await repository.save(project, name: "Invalid"); XCTFail("Must reject invalid project") } catch {}
        }
        let entries = try await repository.list(); XCTAssertTrue(entries.isEmpty)
    }
    func testTextReusesExistingGlyphRowsAndOneUndoableTransparentStamp() throws {
        let color = LocalPixelColor(r: 255, g: 0, b: 0, a: 128)
        let stamp = try LocalPixelText.stamp("A", color: color)
        XCTAssertEqual(stamp.width, 5); XCTAssertEqual(stamp.height, 7)
        let rows = try TextArtwork.glyphRows("A")
        for y in 0..<7 {
            for x in 0..<5 {
                let offset = (y * 5 + x) * 4
                XCTAssertEqual(Array(stamp.rgba[offset..<offset + 4]),
                    rows[y] & (1 << (4 - x)) == 0 ? [0,0,0,0] : color.bytes)
            }
        }
        var document = try LocalPixelDocument(artwork: .blank(width: 8, height: 8))
        let before = document.artwork
        try document.stamp(rgba: stamp.rgba, width: stamp.width, height: stamp.height, at: .init(x: 1, y: 1))
        try document.undo(); XCTAssertEqual(document.artwork, before); XCTAssertFalse(document.canUndo)
        for invalid in ["", "🙂", String(repeating: "A", count: 22)] {
            XCTAssertThrowsError(try LocalPixelText.stamp(invalid, color: color))
        }
    }
    func testOwnedFileReaderEnforcesIndexBudgetBeforeLoadingAndDoesNotResetBytes() throws {
        let folder = try root(), url = folder.appendingPathComponent("oversized-index.json")
        let bytes = Data(repeating: 32, count: 100_001); try bytes.write(to: url)
        XCTAssertThrowsError(try LocalPixelOwnedFile.read(url, maximum: 100_000))
        XCTAssertEqual(try LocalPixelOwnedFile.read(url, maximum: 100_001), bytes)
    }
    func testBackgroundRejectsNewProcessingWithoutLeavingBusyOrAcceptingLateResult() {
        let store = LocalPixelStore(), before = store.document.artwork, stamp = store.ticket
        store.setForeground(false)
        store.importFile(URL(fileURLWithPath: "unread-source.gif"), sprite: false, at: .init(x: 0, y: 0))
        XCTAssertFalse(store.busy); XCTAssertFalse(store.playing); XCTAssertFalse(store.accepts(stamp))
        XCTAssertNotNil(store.failure); XCTAssertEqual(store.document.artwork, before)
    }
    func testComposedOptimizedImportSavesEditableFramesAndByteExactOriginalWithDisposal() async throws {
        let folder = try root(), url = folder.appendingPathComponent("composed-source.gif")
        let bytes = LocalPixelGIFFixtures.gif(repeats: 2, patches: [
            .init(x: 1, indices: [1], disposal: 3, delay: 12000, transparentIndex: 0),
            .init(x: 2, indices: [3], disposal: 2, delay: 0, transparentIndex: 0)
        ])
        try bytes.write(to: url)
        let repository = LocalPixelRepository(root: folder.appendingPathComponent("projects"))
        let store = LocalPixelStore(repository: repository)
        await settled(store) { store.importFile(url, sprite: false, at: .init(x: 0, y: 0)) }
        XCTAssertNil(store.failure); XCTAssertFalse(store.playing)
        XCTAssertEqual(store.original, bytes); XCTAssertEqual(store.document.artwork.width, 3)
        XCTAssertEqual(store.document.artwork.frames[0].rgba,
            LocalPixelGIFFixtures.rgba([.clear,LocalPixelGIFFixtures.red,.clear]))
        XCTAssertEqual(store.document.artwork.frames[1].rgba,
            LocalPixelGIFFixtures.rgba([.clear,.clear,LocalPixelGIFFixtures.blue]))
        await settled(store) { store.saveProject(name: "Composed editable copy") }
        let entry = try XCTUnwrap(store.projects.first)
        let project = try await repository.read(entry)
        XCTAssertEqual(project.original, bytes)
        XCTAssertEqual(project.artwork.frames.map(\.centiseconds), [12000,0])
        XCTAssertEqual(project.artwork.repeats, 2)
        XCTAssertEqual(try GIFStructure.inspect(try XCTUnwrap(project.original)).frames.map(\.disposal), [3,2])
    }
}
