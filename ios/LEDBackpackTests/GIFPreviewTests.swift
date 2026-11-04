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
        XCTAssertEqual(preview.frames.count, 4)
        XCTAssertEqual(preview.duration, 0.16, accuracy: 0.001)
        XCTAssertEqual(preview.caption, "Animated preview")
        XCTAssertLessThanOrEqual(preview.cost, 20 * 160 * 160 * 4)
    }

    func testLongGIFUsesAnExplicitPosterInsteadOfDecodingEveryFrame() throws {
        let frames = (0..<21).map { $0.isMultiple(of: 2) ? image() : PixelFrame.black(image().size) }
        let data = try MediaCodec.encode(frames, delays: Array(repeating: 0.1, count: 21))
        let preview = try GIFPreviewDecoder.thumbnail(data)
        XCTAssertEqual(preview.frames.count, 1)
        XCTAssertEqual(preview.caption, "Tap to animate")
        XCTAssertEqual(preview.duration, 0)
        let atLimit = try MediaCodec.encode(Array(frames.prefix(20)), delays: Array(repeating: 0.1, count: 20))
        XCTAssertEqual(try GIFPreviewDecoder.thumbnail(atLimit).frames.count, 20)
    }

    func testInvalidAndOversizedDataProduceErrors() {
        XCTAssertThrowsError(try GIFPreviewDecoder.thumbnail(Data("not an image".utf8)))
        XCTAssertThrowsError(try GIFPreviewDecoder.validateOriginal(Data("GIF89a".utf8)))
        XCTAssertThrowsError(try GIFPreviewDecoder.validateOriginal(Data(repeating: 0, count: 5_000_001)))
    }

    func testLongFullPreviewDoesNotPretendItCanBeImported() throws {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 121, nil))
        let first = try XCTUnwrap(image().image().cgImage)
        let second = try XCTUnwrap(PixelFrame.black(image().size).image().cgImage)
        for index in 0..<121 {
            CGImageDestinationAddImage(destination, index.isMultiple(of: 2) ? first : second,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(try GIFPreviewDecoder.originalFrameCount(output as Data), 121)
        XCTAssertThrowsError(try GIFPreviewDecoder.validateOriginal(output as Data))
    }
}
