import XCTest
import UIKit
import ImageIO
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class StudioTests: XCTestCase {
    func pixelFrame(_ width: Int, _ height: Int, fill: RGB8) -> PixelFrame {
        PixelFrame(size: PanelSize(width: width, height: height),
            rgb: Array(repeating: fill.bytes, count: width * height).flatMap { $0 })
    }

    func testEdgeRemovalPreservesEnclosedMatchingPixels() throws {
        var frame = pixelFrame(7, 7, fill: RGB8(r: 255, g: 255, b: 255))
        for y in 1...5 {
            for x in 1...5 {
                frame.rgb.replaceSubrange(((y * 7 + x) * 3)..<((y * 7 + x) * 3 + 3), with: [255, 0, 0])
            }
        }
        frame.rgb.replaceSubrange((24 * 3)..<(24 * 3 + 3), with: [255, 255, 255])
        let edge = try GIFCleanup.apply(frame, options: CleanupOptions(removal: .edge, tolerance: 0))
        XCTAssertEqual(Array(edge.rgb[0..<3]), [0, 0, 0])
        XCTAssertEqual(Array(edge.rgb[(24 * 3)..<(24 * 3 + 3)]), [255, 255, 255])
        let keyed = try GIFCleanup.apply(frame, options: CleanupOptions(removal: .color, tolerance: 0))
        XCTAssertEqual(Array(keyed.rgb[(24 * 3)..<(24 * 3 + 3)]), [0, 0, 0])
    }

    func testEdgeRemovalStartsAtFittedImageBoundsNotBlackLetterboxing() throws {
        var frame = pixelFrame(8, 8, fill: .black)
        for y in 2...5 {
            for x in 0..<8 { frame.rgb.replaceSubrange(((y * 8 + x) * 3)..<((y * 8 + x) * 3 + 3), with: [255, 255, 255]) }
        }
        frame.rgb.replaceSubrange(((3 * 8 + 3) * 3)..<((3 * 8 + 3) * 3 + 3), with: [0, 255, 255])
        let clean = try GIFCleanup.apply(frame, options: CleanupOptions(removal: .edge, tolerance: 0,
            edgeRegion: PixelRegion(x: 0, y: 2, width: 8, height: 4)))
        XCTAssertEqual(clean.rgb.filter { $0 == 255 }.count, 2)
    }

    func testHaloNoiseAndManualOverrides() throws {
        var frame = pixelFrame(5, 5, fill: .black)
        frame.rgb.replaceSubrange(18..<21, with: [10, 10, 10])
        let clean = try GIFCleanup.apply(frame, options: CleanupOptions(trimHalos: true, haloThreshold: 20),
            touches: [12: RGB8(r: 0, g: 255, b: 255)])
        XCTAssertEqual(Array(clean.rgb[18..<21]), [0, 0, 0])
        XCTAssertEqual(Array(clean.rgb[36..<39]), [0, 255, 255])
        XCTAssertThrowsError(try GIFCleanup.apply(frame, options: CleanupOptions(), touches: [100: .black]))
    }

    func testReversePingPongAndDelayOverrides() throws {
        let delays = [0.1, 0.2, 0.3]
        let reversed = try GIFCleanup.timing(delays: delays, first: 0, last: 2, speed: 2, overrides: [1: 0.4], direction: .reverse)
        XCTAssertEqual(reversed.map(\.index), [2, 1, 0])
        XCTAssertEqual(reversed.map(\.delay), [0.15, 0.2, 0.05])
        let ping = try GIFCleanup.timing(delays: delays, first: 0, last: 2, speed: 1, overrides: [:], direction: .pingPong)
        XCTAssertEqual(ping.map(\.index), [0, 1, 2, 1])
        XCTAssertThrowsError(try GIFCleanup.timing(delays: delays, first: 2, last: 1, speed: 1, overrides: [:], direction: .forward))
        XCTAssertThrowsError(try GIFCleanup.timing(delays: delays, first: 0, last: 2, speed: .nan, overrides: [:], direction: .forward))
    }

    func testGIFRepeatMetadata() throws {
        let frame = pixelFrame(16, 16, fill: RGB8(r: 0, g: 255, b: 255))
        let data = try MediaCodec.encode([frame], delays: [0.2], loopCount: 3)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [String: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount as String] as? Int, 3)
    }

    func testColorMorphSurvivesLiveDeltaWithoutBinaryQuantization() throws {
        let size = PanelSize(width: 64, height: 64)
        var theme = LiveTheme.standard(for: .speed)
        theme.inkEffect = .morph; theme.foreground = .red; theme.accent = .blue
        let frame = try MediaCodec.styled("42", subtitle: "MPH", size: size, theme: theme, phase: 0)
        XCTAssertTrue(frame.exactLiveColors)
        XCTAssertTrue(frame.rgb.contains { $0 > 0 && $0 < 255 })
        let masks = try MediaCodec.delta(from: .black(size), to: frame)
        XCTAssertTrue(masks.contains { $0[5] > 0 && $0[5] < 255 })
        XCTAssertTrue(masks.allSatisfy { $0.count - 16 <= 112 })
    }

    func testThemeMigrationDefaultsAndGaugeChangesPixels() throws {
        let legacy = Data(#"{"foreground":"cyan","background":"black","typeface":"Monospaced"}"#.utf8)
        let decoded = try JSONDecoder().decode(LiveTheme.self, from: legacy)
        XCTAssertEqual(decoded.inkEffect, .solid)
        XCTAssertEqual(decoded.gauge, .none)
        let size = PanelSize(width: 64, height: 64)
        let plain = try MediaCodec.demo(mode: .speed, size: size, theme: decoded)
        var gauged = decoded; gauged.gauge = .arc; gauged.gaugeMaximum = 60
        XCTAssertNotEqual(try MediaCodec.demo(mode: .speed, size: size, theme: gauged), plain)
        gauged.gaugeMaximum = gauged.gaugeMinimum
        XCTAssertThrowsError(try gauged.validate())
    }

    func testSlotPreviewRequiresMatchingIdentifierAndSurvivesBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        let data = try MediaCodec.encode([pixelFrame(16, 16, fill: .black)], delays: [1])
        try library.add(name: "Cached artwork", data: data)
        let media = try XCTUnwrap(library.state.media.first)
        let identifier = [UInt8](repeating: 1, count: 16)
        try library.rememberSlot(panel: "test-panel", slot: 12, identifier: identifier, mediaID: media.id)
        XCTAssertEqual(try library.cachedSlot(panel: "test-panel", slot: 12, identifier: identifier), data)
        XCTAssertNil(try library.cachedSlot(panel: "test-panel", slot: 12, identifier: [UInt8](repeating: 2, count: 16)))
        try library.savePlaylist(name: "Timed", slots: [12, 14], durations: [2, 7])
        XCTAssertEqual(library.state.playlists.first?.durations, [2, 7])
        try library.importBackup(library.backup())
        XCTAssertEqual(library.state.playlists.last?.durations, [2, 7])
    }
}
