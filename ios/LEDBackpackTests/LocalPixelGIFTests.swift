import XCTest
import ImageIO
@testable import LEDBackpack

enum LocalPixelGIFFixtures {
    static let black = LocalPixelColor(r: 0, g: 0, b: 0, a: 255)
    static let red = LocalPixelColor(r: 255, g: 0, b: 0, a: 255)
    static let green = LocalPixelColor(r: 0, g: 255, b: 0, a: 255)
    static let blue = LocalPixelColor(r: 0, g: 0, b: 255, a: 255)
    struct Patch {
        var x = 0
        var y = 0
        var width = 1
        var height = 1
        var indices: [UInt8] = [1]
        var disposal = 1
        var delay: Int? = 10
        var transparentIndex: UInt8? = nil
        var palette: [LocalPixelColor]? = nil
        var interlaced = false
        var userInput = false
    }
    static func gif(width: Int = 3, height: Int = 1, background: UInt8 = 0,
                    globalPalette: Bool = true, repeats: Int? = nil, patches: [Patch]) -> Data {
        func le(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255)] }
        func table(_ colors: [LocalPixelColor]) -> [UInt8] { colors.flatMap { [$0.r, $0.g, $0.b] } }
        var bytes = Array("GIF89a".utf8) + le(width) + le(height) + [globalPalette ? 0x81 : 0x01, background, 0]
        if globalPalette { bytes += table([black, red, green, blue]) }
        if let repeats { bytes += [0x21,0xFF,11] + Array("NETSCAPE2.0".utf8) + [3,1] + le(repeats) + [0] }
        for patch in patches {
            if let delay = patch.delay {
                let packed = UInt8(patch.disposal << 2) | (patch.transparentIndex == nil ? 0 : 1) | (patch.userInput ? 2 : 0)
                bytes += [0x21,0xF9,4,packed] + le(delay) + [patch.transparentIndex ?? 0,0]
            }
            let flags: UInt8 = (patch.palette == nil ? 0 : 0x81) | (patch.interlaced ? 0x40 : 0)
            bytes += [0x2C] + le(patch.x) + le(patch.y) + le(patch.width) + le(patch.height) + [flags]
            if let colors = patch.palette { bytes += table(colors) }
            let rows = patch.interlaced
                ? Array(stride(from: 0, to: patch.height, by: 8)) + Array(stride(from: 4, to: patch.height, by: 8))
                    + Array(stride(from: 2, to: patch.height, by: 4)) + Array(stride(from: 1, to: patch.height, by: 2))
                : Array(0..<patch.height)
            var compressed: [UInt8] = [], accumulator = 0, bits = 0
            func code(_ value: Int) {
                accumulator |= value << bits; bits += 3
                while bits >= 8 { compressed.append(UInt8(accumulator & 255)); accumulator >>= 8; bits -= 8 }
            }
            for y in rows {
                for x in 0..<patch.width { code(4); code(Int(patch.indices[y * patch.width + x])) }
            }
            code(5)
            if bits > 0 { compressed.append(UInt8(accumulator & 255)) }
            bytes.append(2)
            for start in stride(from: 0, to: compressed.count, by: 255) {
                let end = min(start + 255, compressed.count)
                bytes.append(UInt8(end - start)); bytes += compressed[start..<end]
            }
            bytes.append(0)
        }
        bytes.append(0x3B); return Data(bytes)
    }
    static func rgba(_ colors: [LocalPixelColor]) -> [UInt8] { colors.flatMap(\.bytes) }
}

final class LocalPixelGIFTests: XCTestCase {
    private typealias F = LocalPixelGIFFixtures
    func testPartialRectanglesUseLogicalDimensionsAndRetainPreviousPixels() throws {
        let bytes = F.gif(patches: [
            .init(width: 3, indices: [1,1,1]),
            .init(x: 1, indices: [3])
        ])
        let art = try LocalPixelCodec.decode(bytes)
        XCTAssertEqual(art.width, 3); XCTAssertEqual(art.height, 1)
        XCTAssertEqual(art.frames[0].rgba, F.rgba([F.red,F.red,F.red]))
        XCTAssertEqual(art.frames[1].rgba, F.rgba([F.red,F.blue,F.red]))
    }
    func testTransparentPatchPixelsPreserveDestinationInsteadOfClearingIt() throws {
        let bytes = F.gif(patches: [
            .init(width: 3, indices: [1,1,1]),
            .init(width: 2, indices: [0,3], transparentIndex: 0)
        ])
        let art = try LocalPixelCodec.decode(bytes)
        XCTAssertEqual(art.frames[1].rgba, F.rgba([F.red,F.blue,F.red]))
    }
    func testTransparentFirstSubrectangleExposesTransparentLogicalCanvas() throws {
        let art = try LocalPixelCodec.decode(F.gif(patches: [.init(x: 1, indices: [1], transparentIndex: 0)]))
        XCTAssertEqual(art.frames[0].rgba, F.rgba([.clear,F.red,.clear]))
    }
    func testOpaqueFirstSubrectangleUsesDeclaredBackgroundColor() throws {
        let art = try LocalPixelCodec.decode(F.gif(background: 2, patches: [.init(x: 1, indices: [1])]))
        XCTAssertEqual(art.frames[0].rgba, F.rgba([F.green,F.red,F.green]))
    }
    func testDisposalBackgroundRestoresOnlyOpaqueFrameRectangleToGlobalBackground() throws {
        let art = try LocalPixelCodec.decode(F.gif(background: 2, patches: [
            .init(width: 3, indices: [1,1,1]),
            .init(x: 1, indices: [3], disposal: 2),
            .init(x: 2, indices: [3])
        ]))
        XCTAssertEqual(art.frames[1].rgba, F.rgba([F.red,F.blue,F.red]))
        XCTAssertEqual(art.frames[2].rgba, F.rgba([F.red,F.green,F.blue]))
    }
    func testDisposalBackgroundOfTransparentFrameClearsOnlyItsRectangle() throws {
        let art = try LocalPixelCodec.decode(F.gif(patches: [
            .init(width: 3, indices: [1,1,1], transparentIndex: 0),
            .init(x: 1, indices: [3], disposal: 2, transparentIndex: 0),
            .init(x: 2, indices: [2], transparentIndex: 0)
        ]))
        XCTAssertEqual(art.frames[1].rgba, F.rgba([F.red,F.blue,F.red]))
        XCTAssertEqual(art.frames[2].rgba, F.rgba([F.red,.clear,F.green]))
    }
    func testRestorePreviousUsesCanvasBeforeFrameRatherThanLastRenderedFrame() throws {
        let art = try LocalPixelCodec.decode(F.gif(patches: [
            .init(width: 3, indices: [1,1,1]),
            .init(x: 1, indices: [3], disposal: 3),
            .init(x: 2, indices: [2])
        ]))
        XCTAssertEqual(art.frames[1].rgba, F.rgba([F.red,F.blue,F.red]))
        XCTAssertEqual(art.frames[2].rgba, F.rgba([F.red,F.red,F.green]))
    }
    func testConsecutiveRestorePreviousFramesDoNotAccumulatePatches() throws {
        let art = try LocalPixelCodec.decode(F.gif(patches: [
            .init(width: 3, indices: [1,1,1]),
            .init(indices: [3], disposal: 3),
            .init(x: 1, indices: [2], disposal: 3),
            .init(x: 2, indices: [3], disposal: 0)
        ]))
        XCTAssertEqual(art.frames[1].rgba, F.rgba([F.blue,F.red,F.red]))
        XCTAssertEqual(art.frames[2].rgba, F.rgba([F.red,F.green,F.red]))
        XCTAssertEqual(art.frames[3].rgba, F.rgba([F.red,F.red,F.blue]))
    }
    func testLocalPaletteAndInterlacingAreDecodedByImageIOAtExactPatchSize() throws {
        let indices: [UInt8] = [1,1, 2,2, 3,3, 1,1]
        let palette: [LocalPixelColor] = [.clear,F.blue,F.red,F.green]
        let art = try LocalPixelCodec.decode(F.gif(width: 3, height: 4, patches: [
            .init(x: 1, width: 2, height: 4, indices: indices, palette: palette, interlaced: true)
        ]))
        XCTAssertEqual(art.frames[0].rgba, F.rgba([
            F.black,F.blue,F.blue, F.black,F.red,F.red,
            F.black,F.green,F.green, F.black,F.blue,F.blue
        ]))
    }
    func testNoGlobalPaletteUsesTransparentBackingAndLocalPaletteForPatch() throws {
        let art = try LocalPixelCodec.decode(F.gif(globalPalette: false, patches: [
            .init(x: 1, indices: [1], palette: [F.black,F.red,F.green,F.blue])
        ]))
        XCTAssertEqual(art.frames[0].rgba, F.rgba([.clear,F.red,.clear]))
    }
    func testComposedImportKeepsExactZeroLongMaximumDelayAndLoopMetadata() throws {
        for repeats in [Optional<Int>.none, Optional(0), Optional(7), Optional(65535)] {
            let original = F.gif(repeats: repeats, patches: [
                .init(width: 3, indices: [1,0,1], disposal: 1, delay: 0, transparentIndex: 0),
                .init(x: 1, indices: [3], disposal: 3, delay: 12000),
                .init(x: 2, indices: [2], disposal: 2, delay: 65535)
            ])
            let retained = original
            let art = try LocalPixelCodec.decode(original)
            XCTAssertEqual(art.frames.map(\.centiseconds), [0,12000,65535])
            XCTAssertEqual(art.repeats, repeats); XCTAssertEqual(original, retained)
            XCTAssertEqual(try GIFStructure.inspect(original).frames.map(\.disposal), [1,3,2])
        }
    }
    func testMissingGraphicControlUsesSharedLocalDefaultWithoutRewritingSource() throws {
        let original = F.gif(patches: [.init(x: 1, indices: [3], disposal: 0, delay: nil)])
        let art = try LocalPixelCodec.decode(original)
        XCTAssertEqual(art.frames[0].centiseconds, 10)
        XCTAssertNil(try GIFStructure.inspect(original).frames[0].delayCentiseconds)
        XCTAssertEqual(art.frames[0].rgba, F.rgba([F.black,F.blue,F.black]))
    }
    func testSubrectangleOutsideCanvasAndInvalidTransparentPaletteIndexFailExplicitly() {
        for original in [
            F.gif(patches: [.init(x: 2, width: 2, indices: [1,1])]),
            F.gif(height: 1, patches: [.init(y: 1)]),
            F.gif(patches: [.init(transparentIndex: 4)])
        ] { XCTAssertThrowsError(try LocalPixelCodec.decode(original)) }
    }
    func testPlainTextAndUserInputRemainExplicitlyUnsupportedAndCommentPayloadsAreNotTrailers() throws {
        let normal = F.gif(patches: [.init(x: 1)])
        let headerEnd = 25
        let text = Data(normal.prefix(headerEnd)) + Data([0x21,0x01,12] + Array(repeating: UInt8(0), count: 12) + [1,65,0]) + normal.dropFirst(headerEnd)
        XCTAssertThrowsError(try LocalPixelCodec.decode(text))
        XCTAssertThrowsError(try LocalPixelCodec.decode(F.gif(patches: [.init(userInput: true)])))
        let comment = Data(normal.dropLast()) + Data([0x21,0xFE,3,0x3B,65,66,0,0x3B])
        XCTAssertEqual(try LocalPixelCodec.decode(comment).frames[0].rgba, F.rgba([F.black,F.red,F.black]))
    }
    func testComposedTransparentGIFExportsIndependentFramesWithSamePixelsTimingAndLoops() throws {
        let original = F.gif(repeats: 4, patches: [
            .init(x: 1, indices: [1], disposal: 3, delay: 12000, transparentIndex: 0),
            .init(x: 2, indices: [3], disposal: 2, delay: 5, transparentIndex: 0)
        ])
        let art = try LocalPixelCodec.decode(original)
        let exported = try LocalPixelCodec.gif(art), again = try LocalPixelCodec.decode(exported)
        XCTAssertEqual(again.frames.map(\.rgba), art.frames.map(\.rgba))
        XCTAssertEqual(again.frames.map(\.centiseconds), [12000,5])
        XCTAssertEqual(again.repeats, 4)
        XCTAssertEqual(try GIFStructure.inspect(original).frames.map(\.disposal), [3,2])
    }
    func testCancelledComposedDecodeDoesNotPublishResult() async throws {
        let original = F.gif(patches: (0..<120).map { index in
            F.Patch(x: index % 3, indices: [UInt8(index % 3 + 1)], disposal: index % 4, transparentIndex: 0)
        })
        let worker = Task {
            try await LocalPixelWork.run { try LocalPixelCodec.decode(original) }
        }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled composition must not be accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testCompositionOutputBudgetAccepts120Exact128FramesButRejects121() throws {
        let patch = F.Patch(width: 128, height: 128, indices: Array(repeating: 1, count: 128 * 128), disposal: 3, transparentIndex: 0)
        let original = F.gif(width: 128, height: 128, patches: Array(repeating: patch, count: 120))
        let art = try LocalPixelCodec.decode(original)
        XCTAssertEqual(art.frames.count, 120); XCTAssertEqual(art.width, 128); XCTAssertEqual(art.height, 128)
        XCTAssertEqual(art.byteCost, 128 * 128 * 4 * 120)
        XCTAssertThrowsError(try LocalPixelCodec.decode(F.gif(patches: Array(repeating: .init(), count: 121))))
    }
    func testMixedOpaqueAndTransparentFullFrameExportDoesNotLeaveBlackTrails() throws {
        var art = try LocalPixelArtwork.blank(width: 3, height: 1)
        art.frames = [
            LocalPixelFrame(rgba: F.rgba([F.red,F.red,F.red]), centiseconds: 1),
            LocalPixelFrame(rgba: F.rgba([.clear,F.blue,.clear]), centiseconds: 20),
            LocalPixelFrame(rgba: F.rgba([F.green,F.green,F.green]), centiseconds: 12000),
            LocalPixelFrame(rgba: F.rgba([.clear,.clear,F.red]), centiseconds: 2)
        ]
        let exported = try LocalPixelCodec.gif(art), again = try LocalPixelCodec.decode(exported)
        XCTAssertEqual(again.frames.map(\.rgba), art.frames.map(\.rgba))
        XCTAssertEqual(again.frames.map(\.centiseconds), art.frames.map(\.centiseconds))
        XCTAssertTrue(try GIFStructure.inspect(exported).frames.allSatisfy(\.transparent))
    }
    func testMixedTransparencyReservesPaletteEntryAndNeverSilentlyDropsAnOpaqueColor() throws {
        var art = try LocalPixelArtwork.blank(width: 128, height: 2)
        art.frames[0].rgba = (0..<256).flatMap { [UInt8($0),0,0,255] }
        art.frames.append(LocalPixelFrame(rgba: Array(repeating: 0, count: 128 * 2 * 4)))
        let before = art
        XCTAssertThrowsError(try LocalPixelCodec.gif(art))
        XCTAssertEqual(art, before)
    }
    func testAnimextsLoopExtensionIsPreservedAndConflictingRepeatBlocksAreRejected() throws {
        var bytes = F.gif(repeats: 5, patches: [.init(x: 1)])
        let signature = try XCTUnwrap(bytes.range(of: Data("NETSCAPE2.0".utf8)))
        bytes.replaceSubrange(signature, with: Data("ANIMEXTS1.0".utf8))
        XCTAssertEqual(try LocalPixelCodec.decode(bytes).repeats, 5)
        let secondLoop = Data([0x21,0xFF,11]) + Data("NETSCAPE2.0".utf8) + Data([3,1,6,0,0])
        let conflict = Data(bytes.dropLast()) + secondLoop + Data([0x3B])
        XCTAssertThrowsError(try LocalPixelCodec.decode(conflict))
    }
}
