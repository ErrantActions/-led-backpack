import XCTest
@testable import LEDBackpack

final class LocalPixelDocumentTests: XCTestCase {
    private let red = LocalPixelColor(r: 255, g: 0, b: 0, a: 255)
    private let blue = LocalPixelColor(r: 0, g: 0, b: 255, a: 128)
    private func document(_ width: Int = 3, _ height: Int = 2) throws -> LocalPixelDocument {
        try LocalPixelDocument(artwork: .blank(width: width, height: height))
    }
    func testAllPresetsAndCustomRectangleKeepExactTransparentDimensions() throws {
        for (width, height) in [(16,16), (32,32), (48,48), (64,64), (96,128), (1,128), (128,1), (7,11)] {
            let value = try document(width, height)
            XCTAssertEqual(value.artwork.width, width); XCTAssertEqual(value.artwork.height, height)
            XCTAssertEqual(value.current.rgba, Array(repeating: 0, count: width * height * 4))
        }
    }
    func testInvalidDimensionsNeverClampOrCreateArtwork() {
        for (width, height) in [(0,1), (1,0), (129,1), (1,129), (-1,10), (Int.max,128)] {
            XCTAssertThrowsError(try LocalPixelArtwork.blank(width: width, height: height))
        }
    }
    func testMappingUsesActualRectangularDimensionsAndRejectsOutsideEdges() {
        XCTAssertEqual(LocalPixelMapping.point(x: 99, y: 49, viewWidth: 100, viewHeight: 50, width: 7, height: 3),
            LocalPixelPoint(x: 6, y: 2))
        XCTAssertEqual(LocalPixelMapping.point(x: 0, y: 0, viewWidth: 100, viewHeight: 50, width: 7, height: 3),
            LocalPixelPoint(x: 0, y: 0))
        for (x, y) in [(-0.1,0.0), (100,0), (0,50), (Double.nan,0), (Double.infinity,0)] {
            XCTAssertNil(LocalPixelMapping.point(x: x, y: y, viewWidth: 100, viewHeight: 50, width: 7, height: 3))
        }
        XCTAssertNil(LocalPixelMapping.point(x: 0, y: 0, viewWidth: 0, viewHeight: 50, width: 7, height: 3))
    }
    func testBrushInterpolatesOneStrokeAndUndoRestoresWholeStroke() throws {
        var value = try document(8, 3)
        try value.paint(.init(x: 0, y: 1), color: red, radius: 0)
        try value.paint(.init(x: 7, y: 1), color: red, radius: 0); value.endStroke()
        for x in 0..<8 { XCTAssertEqual(try value.sample(.init(x: x, y: 1)), red) }
        try value.undo()
        XCTAssertTrue(value.current.rgba.allSatisfy { $0 == 0 })
        XCTAssertFalse(value.canUndo)
        try value.redo()
        XCTAssertEqual(try value.sample(.init(x: 7, y: 1)), red)
    }
    func testEraseRestoresTrueTransparencyRatherThanBlack() throws {
        var value = try document()
        try value.paint(.init(x: 1, y: 1), color: red, radius: 0); value.endStroke()
        try value.paint(.init(x: 1, y: 1), color: .clear, radius: 0); value.endStroke()
        XCTAssertEqual(try value.sample(.init(x: 1, y: 1)), .clear)
        try value.undo(); XCTAssertEqual(try value.sample(.init(x: 1, y: 1)), red)
    }
    func testFailedBrushAndFillPreservePreviousArtAndHistory() throws {
        var value = try document()
        let before = value.artwork
        XCTAssertThrowsError(try value.paint(.init(x: 3, y: 0), color: red, radius: 0))
        XCTAssertThrowsError(try value.paint(.init(x: 0, y: 0), color: red, radius: 5))
        XCTAssertThrowsError(try value.fill(.init(x: -1, y: 0), color: red))
        XCTAssertEqual(value.artwork, before); XCTAssertFalse(value.canUndo)
    }
    func testFillUsesFourConnectedExactRGBA() throws {
        var value = try document(3, 3)
        try value.paint(.init(x: 1, y: 0), color: red, radius: 0)
        try value.paint(.init(x: 1, y: 2), color: red, radius: 0); value.endStroke()
        try value.fill(.init(x: 0, y: 0), color: blue)
        XCTAssertEqual(try value.sample(.init(x: 0, y: 2)), blue)
        XCTAssertEqual(try value.sample(.init(x: 2, y: 0)), .clear)
        XCTAssertEqual(try value.sample(.init(x: 1, y: 1)), red)
    }
    func testStraightAlphaSourceOverOpaqueAndTransparentDestinations() {
        XCTAssertEqual(blue.over(red), LocalPixelColor(r: 127, g: 0, b: 128, a: 255))
        XCTAssertEqual(blue.over(.clear), blue)
        XCTAssertEqual(LocalPixelColor.clear.over(red), red)
        XCTAssertEqual(LocalPixelColor.clear.over(.clear), .clear)
    }
    func testSpriteClipsWithoutScalingAndCreatesOneUndoTransaction() throws {
        var value = try document(3, 2)
        try value.fill(.init(x: 0, y: 0), color: red)
        try value.stamp(rgba: blue.bytes + LocalPixelColor.clear.bytes, width: 2, height: 1, at: .init(x: 2, y: 1))
        XCTAssertEqual(try value.sample(.init(x: 2, y: 1)), blue.over(red))
        XCTAssertEqual(try value.sample(.init(x: 1, y: 1)), red)
        try value.undo(); XCTAssertEqual(try value.sample(.init(x: 2, y: 1)), red)
    }
    func testNegativeSpritePlacementClipsLeftAndTransparentPixelsDoNotErase() throws {
        var value = try document()
        try value.fill(.init(x: 0, y: 0), color: red)
        try value.stamp(rgba: blue.bytes + LocalPixelColor.clear.bytes, width: 2, height: 1, at: .init(x: -1, y: 0))
        XCTAssertEqual(try value.sample(.init(x: 0, y: 0)), red)
    }
    func testMalformedOrNonoverlappingSpriteDoesNotMutate() throws {
        var value = try document()
        let before = value.artwork
        XCTAssertThrowsError(try value.stamp(rgba: [1,2], width: 1, height: 1, at: .init(x: 0, y: 0)))
        XCTAssertThrowsError(try value.stamp(rgba: red.bytes, width: 1, height: 1, at: .init(x: 3, y: 0)))
        XCTAssertEqual(value.artwork, before); XCTAssertFalse(value.canUndo)
    }
    func testFrameAddDuplicateRemoveOrderAndTimingAreUndoable() throws {
        var value = try document()
        try value.fill(.init(x: 0, y: 0), color: red)
        let first = value.current.id
        try value.setTiming(12000); try value.addFrame(copy: true)
        XCTAssertNotEqual(first, value.current.id); XCTAssertEqual(value.current.centiseconds, 12000)
        XCTAssertEqual(try value.sample(.init(x: 0, y: 0)), red)
        try value.moveFrame(-1); XCTAssertEqual(value.artwork.frames[1].id, first)
        try value.removeFrame(); XCTAssertEqual(value.current.id, first)
        try value.undo(); XCTAssertEqual(value.artwork.frames.count, 2)
        try value.addFrame(copy: false); XCTAssertTrue(value.current.rgba.allSatisfy { $0 == 0 })
    }
    func testFrameCountAndLastFrameRemovalAreBounded() throws {
        var value = try document(1, 1)
        XCTAssertThrowsError(try value.removeFrame())
        for _ in 1..<120 { try value.addFrame(copy: false) }
        let before = value.artwork
        XCTAssertThrowsError(try value.addFrame(copy: true)); XCTAssertEqual(value.artwork, before)
        XCTAssertThrowsError(try value.select(120)); XCTAssertEqual(value.artwork, before)
    }
    func testEditedTimingIsWholeGIFCentisecondsWithoutTenSecondCap() throws {
        var value = try document()
        try value.setTiming(65535); XCTAssertEqual(value.current.centiseconds, 65535)
        for invalid in [0, -1, 65536, Int.max] { XCTAssertThrowsError(try value.setTiming(invalid)) }
        XCTAssertEqual(value.current.centiseconds, 65535)
    }
    func testLoopChoicesAreDistinctAndUndoable() throws {
        var value = try document()
        XCTAssertNil(value.artwork.repeats)
        try value.setRepeats(0); XCTAssertEqual(value.artwork.repeats, 0)
        try value.setRepeats(65535); XCTAssertEqual(value.artwork.repeats, 65535)
        try value.undo(); XCTAssertEqual(value.artwork.repeats, 0)
        try value.undo(); XCTAssertNil(value.artwork.repeats)
        XCTAssertThrowsError(try value.setRepeats(65536))
    }
    func testUndoRedoHasOneCombinedLogicalMemoryBudget() throws {
        var art = try LocalPixelArtwork.blank(width: 128, height: 128)
        art.frames = (0..<120).map { _ in LocalPixelFrame(rgba: art.frames[0].rgba) }
        var value = try LocalPixelDocument(artwork: art)
        for index in 1...40 {
            try value.setTiming(index)
            XCTAssertLessThanOrEqual(value.historyBytes, LocalPixelDocument.historyBudget)
        }
        while value.canUndo {
            try value.undo(); XCTAssertLessThanOrEqual(value.historyBytes, LocalPixelDocument.historyBudget)
        }
        while value.canRedo {
            try value.redo(); XCTAssertLessThanOrEqual(value.historyBytes, LocalPixelDocument.historyBudget)
        }
    }
    func testActiveStrokeIsIncludedInMemoryBudget() throws {
        var value = try document(128, 128)
        for index in 1...40 { try value.setTiming(index) }
        try value.paint(.init(x: 1, y: 1), color: red, radius: 4)
        XCTAssertLessThanOrEqual(value.historyBytes, LocalPixelDocument.historyBudget)
        value.endStroke(); XCTAssertLessThanOrEqual(value.historyBytes, LocalPixelDocument.historyBudget)
    }
    func testNewEditAfterUndoDiscardsRedo() throws {
        var value = try document()
        try value.setTiming(20); try value.undo(); XCTAssertTrue(value.canRedo)
        try value.setTiming(30); XCTAssertFalse(value.canRedo)
    }
    func testAuthoredDimAndPaletteChangesAreExplicitUndoableRGBAEdits() throws {
        var value = try document()
        try value.fill(.init(x: 0, y: 0), color: blue)
        try value.dim(0.5)
        XCTAssertEqual(try value.sample(.init(x: 0, y: 0)), LocalPixelColor(r: 0, g: 0, b: 128, a: 128))
        try value.undo(); XCTAssertEqual(try value.sample(.init(x: 0, y: 0)), blue)
        try value.replacePaletteColor(blue, with: red)
        XCTAssertEqual(try value.sample(.init(x: 0, y: 0)), red)
        try value.undo(); XCTAssertEqual(try value.sample(.init(x: 0, y: 0)), blue)
        XCTAssertThrowsError(try value.dim(.nan))
    }
    func testModelRejectsMismatchedBuffersDuplicateFrameIDsAndInvalidMetadata() throws {
        var art = try LocalPixelArtwork.blank(width: 2, height: 3)
        art.frames[0].rgba.removeLast(); XCTAssertThrowsError(try art.validate())
        art = try .blank(width: 1, height: 1); art.frames.append(art.frames[0])
        XCTAssertThrowsError(try art.validate())
        art = try .blank(width: 1, height: 1)
        art.attribution = Attribution(source: String(repeating: "x", count: 2049), author: "", license: "", licenseURL: "")
        XCTAssertThrowsError(try art.validate())
    }
    func testPreviewLoopTimingAndLongPausesAreNotClamped() throws {
        var art = try LocalPixelArtwork.blank(width: 1, height: 1)
        art.frames[0].centiseconds = 12000
        art.frames.append(LocalPixelFrame(rgba: [0,0,0,0], centiseconds: 1))
        XCTAssertEqual(LocalPixelPlayback.position(art, elapsed: 119).index, 0)
        XCTAssertEqual(LocalPixelPlayback.position(art, elapsed: 120.005).index, 1)
        XCTAssertTrue(LocalPixelPlayback.position(art, elapsed: 121).finished)
        art.repeats = 0; XCTAssertFalse(LocalPixelPlayback.position(art, elapsed: 10000).finished)
        art.repeats = 2; XCTAssertFalse(LocalPixelPlayback.position(art, elapsed: 240).finished)
        XCTAssertTrue(LocalPixelPlayback.position(art, elapsed: 361).finished)
    }
}
