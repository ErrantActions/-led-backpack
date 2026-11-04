import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class TextArtworkTests: XCTestCase {
    private let size = PanelSize(width: 64, height: 64)

    private func coloredPixels(_ frame: PixelFrame) -> [Int] {
        stride(from: 0, to: frame.rgb.count, by: 3).filter {
            frame.rgb[$0] != 0 || frame.rgb[$0 + 1] != 0 || frame.rgb[$0 + 2] != 0
        }.map { $0 / 3 }
    }

    func testPixelFontIsCrispAndAsymmetricGlyphIsUpright() throws {
        let small = PanelSize(width: 16, height: 16)
        let frame = try TextArtwork.render("F", size: small, font: .pixel, alignment: .center, color: .cyan)
        XCTAssertEqual(Set(frame.rgb), Set([UInt8(0), 255]))
        XCTAssertEqual(coloredPixels(frame).count, 56)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * 16 + x) * 3
            return Array(frame.rgb[offset..<(offset + 3)])
        }
        XCTAssertEqual(pixel(12, 1), [0, 255, 255])
        XCTAssertEqual(pixel(12, 14), [0, 0, 0])
        XCTAssertEqual(pixel(3, 14), [0, 255, 255])
        let gif = try MediaCodec.encode([frame], delays: [1])
        let decoded = try MediaCodec.decode(gif)
        XCTAssertEqual(try MediaCodec.transform(XCTUnwrap(decoded.images.first), size: small, fit: .fit, turns: 0, brightness: 1), frame)
    }

    func testMeasuredPixelWrappingFitsWithoutLosingWords() throws {
        let layout = try TextArtwork.pixelLayout("hello world", size: size)
        XCTAssertEqual(layout.lines, ["HELLO", "WORLD"])
        XCTAssertEqual(layout.scale, 2)
        XCTAssertLessThanOrEqual(layout.height, size.height - layout.padding * 2)
        for line in layout.lines { XCTAssertLessThanOrEqual(layout.width(of: line), size.width - layout.padding * 2) }
        XCTAssertEqual(try TextArtwork.pixelLayout("HELLO\nWORLD", size: size).lines, ["HELLO", "WORLD"])
        XCTAssertThrowsError(try TextArtwork.pixelLayout("HELLO WORLD", size: PanelSize(width: 16, height: 16)))
    }

    func testAlignmentChangesPositionNotGlyphPixels() throws {
        let left = try TextArtwork.render("HI", size: size, font: .pixel, alignment: .left, color: .cyan)
        let center = try TextArtwork.render("HI", size: size, font: .pixel, alignment: .center, color: .cyan)
        let right = try TextArtwork.render("HI", size: size, font: .pixel, alignment: .right, color: .cyan)
        let a = coloredPixels(left), b = coloredPixels(center), c = coloredPixels(right)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(b.count, c.count)
        XCTAssertEqual(a.map { $0 % 64 }.min(), 2)
        XCTAssertEqual(b.map { $0 % 64 }.min(), 4)
        XCTAssertEqual(c.map { $0 % 64 }.min(), 7)
    }

    func testScrollingIsBoundedAndDoesNotJumpOverFontPixels() throws {
        let frames = try TextArtwork.animation("F", size: size, font: .pixel, color: .cyan)
        XCTAssertLessThanOrEqual(frames.count, 120)
        XCTAssertTrue(try XCTUnwrap(frames.first).rgb.allSatisfy { $0 == 0 })
        XCTAssertTrue(try XCTUnwrap(frames.last).rgb.allSatisfy { $0 == 0 })
        let completePositions = frames.compactMap { frame -> Int? in
            let pixels = coloredPixels(frame)
            guard pixels.count == 14 * 3 * 3 else { return nil }
            return pixels.map { $0 % 64 }.min()
        }
        XCTAssertGreaterThan(completePositions.count, 10)
        for (first, second) in zip(completePositions, completePositions.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(first - second), 3)
        }
        XCTAssertThrowsError(try TextArtwork.animation(String(repeating: "A", count: 80), size: size, font: .pixel, color: .cyan))
    }

    func testUnsupportedPixelTextIsExplicitAndSystemFontsRemainAvailable() throws {
        XCTAssertThrowsError(try TextArtwork.render("猫", size: size, font: .pixel, alignment: .center, color: .cyan))
        XCTAssertThrowsError(try TextArtwork.render("", size: size, font: .pixel, alignment: .center, color: .cyan))
        XCTAssertThrowsError(try TextArtwork.render(String(repeating: "A", count: 81), size: size, font: .pixel, alignment: .center, color: .cyan))
        XCTAssertThrowsError(try TextArtwork.render("HELLO", size: size, font: .pixel, alignment: .center, color: .black))
        let unicode = try TextArtwork.render("Café 猫", size: size, font: .system, alignment: .center, color: .cyan)
        XCTAssertFalse(coloredPixels(unicode).isEmpty)
    }
}
