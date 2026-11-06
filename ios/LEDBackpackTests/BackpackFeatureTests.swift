import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class BackpackFeatureTests: XCTestCase {
    private func inventory(_ occupied: Set<Int> = [1, 2], marker: UInt8 = 1) throws -> [Slot] {
        let bytes = (0..<60).flatMap { id -> [UInt8] in
            [UInt8(id), 0, 0, 0, 0] + Array(repeating: occupied.contains(id) ? marker : 0, count: 16)
        }
        let reply = try Wire.reply([0x81, 0x83, 0x35] + Wire.length(bytes.count) + bytes)
        guard case .slots(let slots) = reply else { throw BackpackError.invalid("Invalid test inventory.") }
        return slots
    }

    func testErasePlanRequiresCompleteInventoryAndExactDeviceAndIdentifiers() throws {
        let device = UUID()
        let slots = try inventory()
        let plan = try BackpackErasePlan(deviceID: device, serial: "test-panel", records: slots)
        XCTAssertEqual(plan.occupied.map(\.id), [1, 2])
        XCTAssertNoThrow(try plan.validate(deviceID: device, serial: "test-panel", records: Array(slots.reversed())))
        XCTAssertThrowsError(try plan.validate(deviceID: UUID(), serial: "test-panel", records: slots))
        XCTAssertThrowsError(try plan.validate(deviceID: device, serial: "other", records: slots))
        XCTAssertThrowsError(try plan.validate(deviceID: device, serial: "test-panel", records: inventory(marker: 2)))
        XCTAssertThrowsError(try BackpackErasePlan(deviceID: device, serial: "test-panel", records: Array(slots.dropLast())))
        XCTAssertThrowsError(try BackpackErasePlan(deviceID: device, serial: "", records: slots))
    }

    func testEraseUsesKnownPerSlotDeleteNotAnInventedResetOpcode() throws {
        XCTAssertEqual(try Wire.deleteSlot(0), [0xc1, 2, 8, 2, 0, 0])
        XCTAssertEqual(try Wire.deleteSlot(59), [0xc1, 2, 8, 2, 0, 59])
        XCTAssertThrowsError(try Wire.deleteSlot(-1))
        XCTAssertThrowsError(try Wire.deleteSlot(60))
    }

    func testNowPlayingDoesNotInventLoopPhaseOrScreenReadback() {
        XCTAssertEqual(BackpackPlaybackStatus.reportedSlot(Playback(mode: 0, index: 3, ids: [])), 3)
        XCTAssertEqual(BackpackPlaybackStatus.reportedSlot(Playback(mode: 1, index: 59, ids: [])), 59)
        let loop = Playback(mode: 2, index: 255, ids: [2, 4])
        XCTAssertNil(BackpackPlaybackStatus.reportedSlot(loop))
        XCTAssertTrue(BackpackPlaybackStatus.caption(loop).contains("2, 4"))
        XCTAssertTrue(BackpackPlaybackStatus.caption(loop).contains("not reported"))
        XCTAssertNil(BackpackPlaybackStatus.reportedSlot(nil))
    }

    func testPlaylistReorderAndDeletionKeepDuplicateEntriesAndTimingsTogether() throws {
        let original = SavedPlaylist(name: "Rotation", slots: [1, 2, 1], durations: [3, 5, 7])
        var draft = try PlaylistDraft(original)
        XCTAssertEqual(Set(draft.entries.map(\.id)).count, 3)
        try draft.move(IndexSet(integer: 0), to: 3)
        XCTAssertEqual(draft.entries.map(\.slot), [2, 1, 1])
        XCTAssertEqual(draft.entries.map(\.seconds), [5, 7, 3])
        try draft.remove(IndexSet(integer: 1))
        XCTAssertEqual(draft.entries.map(\.seconds), [5, 3])
        try draft.append(59)
        XCTAssertEqual(draft.entries.last?.slot, 59)
        XCTAssertThrowsError(try draft.append(60))
        XCTAssertThrowsError(try draft.move(IndexSet(integer: 100), to: 0))
        XCTAssertThrowsError(try PlaylistDraft(SavedPlaylist(name: "Invalid", slots: [1, 2], durations: [1])))
        var full = PlaylistDraft()
        for _ in 0..<60 { try full.append(1) }
        XCTAssertThrowsError(try full.append(1))
    }

    func testPlaylistBindingIsOptionalForLegacyButEnforcedForNewLists() throws {
        let list = SavedPlaylist(name: "Bound", slots: [1, 2], durations: [1, 2], panelSerial: "test-panel")
        XCTAssertNoThrow(try list.validateForDevice(serial: "test-panel", inventory: inventory()))
        XCTAssertThrowsError(try list.validateForDevice(serial: "other", inventory: inventory()))
        XCTAssertThrowsError(try list.validateForDevice(serial: "test-panel", inventory: inventory([1])))
        let old = Data(#"{"id":"12345678-1234-4567-89ab-123456789abc","name":"Legacy","slots":[1]}"#.utf8)
        let legacy = try JSONDecoder().decode(SavedPlaylist.self, from: old)
        XCTAssertNil(legacy.panelSerial)
        XCTAssertNoThrow(try legacy.validateForDevice(serial: "test-panel", inventory: inventory()))
    }

    func testBrushInterpolatesGapsAndUndoTreatsAStrokeAsOneAction() throws {
        var drawing = PixelDrawingDocument()
        try drawing.resetCanvas(PanelSize(width: 16, height: 16))
        let red = RGB8(r: 255, g: 0, b: 0)
        try drawing.paint(x: 0, y: 0, color: red, radius: 0)
        try drawing.paint(x: 15, y: 0, color: red, radius: 0)
        drawing.endStroke()
        for x in 0..<16 { XCTAssertEqual(try drawing.sample(x: x, y: 0), red) }
        try drawing.undo()
        XCTAssertTrue(drawing.current.pixels.rgb.allSatisfy { $0 == 0 })
        try drawing.redo()
        XCTAssertEqual(try drawing.sample(x: 8, y: 0), red)
    }

    func testAnimationFrameCopiesAreIndependentAndTimingsAndOrderAreEditable() throws {
        var drawing = PixelDrawingDocument()
        try drawing.resetCanvas(PanelSize(width: 16, height: 16))
        try drawing.paint(x: 0, y: 0, color: RGB8(r: 255, g: 0, b: 0), radius: 0)
        drawing.endStroke()
        let first = drawing.current.id
        try drawing.addFrame(copy: true)
        XCTAssertNotEqual(first, drawing.current.id)
        try drawing.paint(x: 0, y: 0, color: .black, radius: 0)
        drawing.endStroke()
        XCTAssertEqual(drawing.frames[0].pixels.rgb[0], 255)
        XCTAssertEqual(drawing.frames[1].pixels.rgb[0], 0)
        try drawing.setDelay(0.02)
        try drawing.moveFrame(by: -1)
        XCTAssertEqual(drawing.selected, 0)
        XCTAssertEqual(drawing.current.delay, 0.02)
        try drawing.deleteFrame()
        XCTAssertEqual(drawing.frames.count, 1)
        XCTAssertThrowsError(try drawing.deleteFrame())
        XCTAssertThrowsError(try drawing.setDelay(.nan))
        XCTAssertThrowsError(try drawing.setDelay(10.01))
        XCTAssertThrowsError(try drawing.paint(x: -1, y: 0, color: .black, radius: 0))
    }

    func testAnimationAllowsExactlyOneThrough120Frames() throws {
        var drawing = PixelDrawingDocument()
        try drawing.resetCanvas(PanelSize(width: 16, height: 16))
        XCTAssertEqual(try MediaCodec.decode(MediaCodec.encode(drawing.frames.map(\.pixels),
            delays: drawing.frames.map(\.delay))).images.count, 1)
        for _ in 1..<120 { try drawing.addFrame(copy: false) }
        XCTAssertEqual(drawing.frames.count, 120)
        XCTAssertThrowsError(try drawing.addFrame(copy: true))
    }

    private var gifHeader: [UInt8] {
        Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 255, 255, 255]
    }
    private var gifImage: [UInt8] { [0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0] }

    func testGhostRepairPreservesTimingTransparencyCompressedPixelsAndOriginalBytes() throws {
        let control: [UInt8] = [0x21, 0xf9, 4, 5, 10, 0, 0, 0]
        let comment = [UInt8]([0x21, 0xfe, 8]) + control + [0]
        let original = Data(gifHeader + comment + control + gifImage + [0x3b])
        let savedOriginal = original
        var expected = [UInt8](original)
        expected[gifHeader.count + comment.count + 3] = 9
        let repaired = try GIFFrameDisposal.resettingCanvas(original)
        XCTAssertEqual(repaired, Data(expected))
        XCTAssertEqual(original, savedOriginal)
        XCTAssertEqual(try MediaCodec.decode(repaired).images.count, 1)
        XCTAssertEqual(try MediaCodec.decode(repaired).delays[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(try GIFFrameDisposal.resettingCanvas(repaired), repaired)
    }

    func testGhostRepairAddsControlOnlyWhenMissingAndRejectsTruncation() throws {
        let original = Data(gifHeader + gifImage + [0x3b])
        let repaired = try GIFFrameDisposal.resettingCanvas(original)
        XCTAssertEqual(repaired, Data(gifHeader + [0x21, 0xf9, 4, 8, 10, 0, 0, 0] + gifImage + [0x3b]))
        for count in [0, 6, 12, 19, original.count - 1] {
            XCTAssertThrowsError(try GIFFrameDisposal.resettingCanvas(Data(original.prefix(count))))
        }
        XCTAssertThrowsError(try GIFFrameDisposal.resettingCanvas(Data("not a GIF".utf8)))
    }

    func testEditedGIFIsANewLocalCopyWithoutReplacingOrReassociatingCloudOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        let source = try MediaCodec.encode([.black(PanelSize(width: 16, height: 16))], delays: [1])
        let origin = try CommunityOrigin.parse("https://catalog.example")
        let itemID = UUID(), accountID = UUID()
        let credit = Attribution(source: "https://example.invalid/art", author: "Test", license: "unspecified", licenseURL: "")
        let original = try library.savePrivateCloudGIF(source, title: "Original", attribution: credit, category: "Pixel",
            origin: origin, accountID: accountID, itemID: itemID,
            assetURL: XCTUnwrap(URL(string: "https://catalog.example/api/v1/cloud/items/\(itemID.uuidString.lowercased())/media")))
        var pixels = PixelFrame.black(PanelSize(width: 16, height: 16)); pixels.rgb[0] = 255
        let edited = try MediaCodec.encode([pixels], delays: [1])
        try library.add(name: "Edited copy", data: edited, attribution: original.attribution, category: original.category)
        let copy = try XCTUnwrap(library.state.media.first(where: { $0.id != original.id }))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNil(copy.cloudSource)
        XCTAssertEqual(copy.attribution, credit)
        XCTAssertEqual(copy.category, "Pixel")
        XCTAssertEqual(try library.data(original), source)
        XCTAssertEqual(try library.data(copy), edited)
        try library.savePlaylist(name: "Bound", slots: [1], durations: [3], panelSerial: "test-panel")
        try library.importBackup(library.backup())
        XCTAssertEqual(library.state.playlists.last?.panelSerial, "test-panel")
        XCTAssertEqual(library.state.version, 1)
    }
}
