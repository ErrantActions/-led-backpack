import XCTest
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class AvatarPhotoImportTests: XCTestCase {
    private func image() throws -> CGImage {
        let size = PanelSize(width: 16, height: 8)
        let bytes = try MediaCodec.encode([.black(size)], delays: [0.1])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testPhotosImportPreservesAllGIFBytesAndFrames() throws {
        let size = PanelSize(width: 16, height: 16)
        let bytes = try MediaCodec.encode([.black(size), MediaCodec.text("A", size: size)], delays: [0.1, 0.3])
        XCTAssertEqual(try NativeAvatarPhoto.compatibleData(bytes), bytes)
        let selection = try NativeAvatarSelection(bytes: bytes, expectedVersion: UUID(), scope: UUID())
        XCTAssertEqual(selection.bytes, bytes)
    }

    func testHEICPhotoCreatesOrientedJPEGWithoutChangingOriginal() throws {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("HEIC encoding is unavailable in this test runtime.")
        }
        CGImageDestinationAddImage(destination, try image(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("HEIC encoding is unavailable in this test runtime.") }
        let original = encoded as Data
        let compatible = try NativeAvatarPhoto.compatibleData(original)
        XCTAssertEqual(try NativeAvatarInput.kind(compatible).mime, "image/jpeg")
        XCTAssertEqual(encoded as Data, original)
        let selection = try NativeAvatarSelection(bytes: compatible, expectedVersion: nil, scope: UUID())
        XCTAssertEqual(selection.orientedStill.width, 8)
        XCTAssertEqual(selection.orientedStill.height, 16)
    }

    func testPhotoImportRejectsInvalidOrOversizedInput() {
        XCTAssertThrowsError(try NativeAvatarPhoto.compatibleData(Data()))
        XCTAssertThrowsError(try NativeAvatarPhoto.compatibleData(Data("GIF89a-not-an-image".utf8)))
        XCTAssertThrowsError(try NativeAvatarPhoto.compatibleData(Data(repeating: 0, count: 20_000_001)))
    }

    func testSupportedStillKeepsOriginalBytesAndSelectionScope() throws {
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = encoded as Data
        let bytes = try NativeAvatarPhoto.compatibleData(original)
        XCTAssertEqual(bytes, original)
        let scope = UUID(), version = UUID()
        let selection = try NativeAvatarSelection(bytes: bytes, expectedVersion: version, scope: scope)
        XCTAssertEqual(selection.scope, scope)
        XCTAssertEqual(selection.expectedVersion, version)
        XCTAssertEqual(try selection.preview(crop: nil).width, 16)
    }
}
