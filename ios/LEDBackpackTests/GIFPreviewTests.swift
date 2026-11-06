import XCTest
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class GIFPreviewTests: XCTestCase {
    private func image() -> PixelFrame {
        var frame = PixelFrame.black(PanelSize(width: 16, height: 16))
        frame.rgb.replaceSubrange(0..<3, with: [255, 0, 0])
        return frame
    }

    func testAnimatedThumbnailPreservesVariableFrameDelays() throws {
        let data = try MediaCodec.encode([image(), .black(image().size)], delays: [0.04, 0.12])
        try GIFPreviewDecoder.validateOriginal(data)
        let preview = try GIFPreviewDecoder.thumbnail(data)
        XCTAssertEqual(preview.frames.count, 2)
        XCTAssertEqual(preview.duration, 0.16, accuracy: 0.001)
        XCTAssertEqual(preview.frameIndex(at: 0), 0)
        XCTAssertEqual(preview.frameIndex(at: 0.039), 0)
        XCTAssertEqual(preview.frameIndex(at: 0.04), 1)
        XCTAssertEqual(preview.frameIndex(at: 0.159), 1)
        XCTAssertEqual(preview.frameIndex(at: 0.16), 0)
        XCTAssertLessThanOrEqual(preview.cost, 20 * 160 * 160 * 4)
    }

    func testSingleFrameRemainsStillWithoutDuplicatingFrames() throws {
        let preview = try GIFPreviewDecoder.thumbnail(MediaCodec.encode([image()], delays: [1]))
        XCTAssertEqual(preview.frames.count, 1)
        XCTAssertEqual(preview.duration, 0)
        XCTAssertEqual(preview.frameIndex(at: 100), 0)
    }

    func testLongAnimationsRetainEveryFrameWithinMemoryBudget() throws {
        for count in [20, 21, 120, 121, 1200] {
            let preview = try GIFPreviewDecoder.thumbnail(animation(frameCount: count))
            XCTAssertEqual(preview.frames.count, count)
            XCTAssertEqual(preview.duration, Double(count) * 0.1, accuracy: 0.001)
            XCTAssertEqual(preview.frameIndex(at: preview.duration - 0.01), count - 1)
            XCTAssertLessThanOrEqual(preview.cost, 8_000_000)
        }
        XCTAssertThrowsError(try GIFPreviewDecoder.thumbnail(animation(frameCount: 1201)))
    }

    func testLongUnevenDelaysDoNotFallBackToAStillPoster() throws {
        let data = try MediaCodec.encode([image(), .black(image().size)], delays: [0.03, 10])
        let preview = try GIFPreviewDecoder.thumbnail(data)
        XCTAssertEqual(preview.frames.count, 2)
        XCTAssertEqual(preview.duration, 10.03, accuracy: 0.001)
        XCTAssertEqual(preview.frameIndex(at: 0.02), 0)
        XCTAssertEqual(preview.frameIndex(at: 9), 1)
        XCTAssertEqual(preview.frameIndex(at: 10.04), 0)
        XCTAssertEqual(preview.frameIndex(at: -.infinity), 0)
        XCTAssertEqual(preview.frameIndex(at: .nan), 0)
    }

    func testInvalidAndOversizedDataProduceErrors() {
        XCTAssertThrowsError(try GIFPreviewDecoder.thumbnail(Data("not an image".utf8)))
        XCTAssertThrowsError(try GIFPreviewDecoder.validateOriginal(Data("GIF89a".utf8)))
        XCTAssertThrowsError(try GIFPreviewDecoder.validateOriginal(Data(repeating: 0, count: 5_000_001)))
    }

    func testLongFullPreviewDoesNotPretendItCanBeImported() throws {
        let output = try animation(frameCount: 121)
        XCTAssertEqual(try GIFPreviewDecoder.originalFrameCount(output), 121)
        XCTAssertThrowsError(try GIFPreviewDecoder.validateOriginal(output))
    }

    private func animation(frameCount: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frameCount, nil))
        let size = PanelSize(width: 64, height: 64)
        var marked = PixelFrame.black(size)
        marked.rgb[0] = 255
        let first = try XCTUnwrap(marked.image().cgImage)
        let second = try XCTUnwrap(PixelFrame.black(size).image().cgImage)
        for index in 0..<frameCount {
            CGImageDestinationAddImage(destination, index.isMultiple(of: 2) ? first : second,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
