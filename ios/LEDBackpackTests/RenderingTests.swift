import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class RenderingTests: XCTestCase {
    func testTextGIFRoundTrip() throws {
        let size = PanelSize(width: 64, height: 64)
        let frame = try MediaCodec.text("42", subtitle: "SIM", size: size)
        XCTAssertEqual(frame.rgb.count, 12288)
        XCTAssertTrue(frame.rgb.contains { $0 != 0 })
        let data = try MediaCodec.encode([frame, .black(size)], delays: [0.2, 0.3])
        XCTAssertEqual(String(data: data.prefix(6), encoding: .ascii), "GIF89a")
        let decoded = try MediaCodec.decode(data)
        XCTAssertEqual(decoded.images.count, 2)
        XCTAssertEqual(decoded.delays[0], 0.2, accuracy: 0.02)
    }

    func testDirtyMasksReconstructQuantizedTarget() throws {
        let size = PanelSize(width: 64, height: 64)
        let before = try MediaCodec.text("20", subtitle: "SIM", size: size)
        let target = try MediaCodec.text("25", subtitle: "SIM", size: size)
        let masks = try MediaCodec.delta(from: before, to: target)
        var pixels = before.rgb.map { $0 >= 128 ? UInt8(255) : UInt8(0) }
        for body in masks {
            let x0 = Wire.u16(body, 8), y0 = Wire.u16(body, 10)
            let x1 = Wire.u16(body, 12), y1 = Wire.u16(body, 14)
            let stride = (x1 - x0 + 8) / 8
            XCTAssertLessThanOrEqual(body.count - 16, 112)
            for y in y0...y1 {
                for x in x0...x1 where body[16 + (y - y0) * stride + (x - x0) / 8] & (128 >> ((x - x0) % 8)) != 0 {
                    let offset = (y * size.width + x) * 3
                    pixels.replaceSubrange(offset..<(offset + 3), with: body[5..<8])
                }
            }
        }
        XCTAssertEqual(pixels, target.rgb.map { $0 >= 128 ? UInt8(255) : UInt8(0) })
    }

    func testLibraryBackupMergePreservesAttributionAndExcludesPasswords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        let gif = try MediaCodec.encode([MediaCodec.text("A", size: PanelSize(width: 16, height: 16))], delays: [1])
        let credit = Attribution(source: "https://commons.wikimedia.org/", author: "Example", license: "CC0", licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/")
        try library.add(name: "Test", data: gif, attribution: credit)
        let backup = try library.backup()
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("devicePasswords"))
        try library.importBackup(backup)
        XCTAssertEqual(library.state.media.count, 2)
        XCTAssertNotEqual(library.state.media[0].id, library.state.media[1].id)
        XCTAssertEqual(library.state.media[1].attribution, credit)
    }

    func testThemesValidateAndCriticalStatusCannotBeHiddenOrRelabeled() throws {
        let size = PanelSize(width: 64, height: 64)
        let standard = LiveTheme.standard(for: .speed)
        var customized = standard
        customized.topLabel = "FAST"; customized.bottomLabel = "ALL GOOD"
        customized.showSecondary = false; customized.secondaryField = .battery
        customized.animation = .marquee; customized.layout = .left; customized.scale = 1.5
        let expected = try MediaCodec.styled("NO GPS", subtitle: "INVALID / STALE",
            size: size, theme: standard, phase: 0.1, requiredStatus: true)
        let actual = try MediaCodec.styled("NO GPS", subtitle: "INVALID / STALE",
            size: size, theme: customized, phase: 0.8, field: "PHONE 87%", requiredStatus: true)
        XCTAssertEqual(actual, expected)
        customized.foreground = customized.background
        XCTAssertThrowsError(try customized.validate())
        customized = standard; customized.scale = .nan
        XCTAssertThrowsError(try customized.validate())
        customized = standard; customized.refreshInterval = 0
        XCTAssertThrowsError(try customized.validate())
    }

    func testExistingLibraryMigrationAndThemeBackupMerge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Version-one JSON without theme keys must remain readable.
        let original = try JSONEncoder().encode(LibraryState())
        try original.write(to: folder.appendingPathComponent("library.json"))
        let library = try LocalLibrary(folder: folder)
        XCTAssertEqual(library.theme(for: .speed), .standard(for: .speed))
        var theme = LiveTheme.standard(for: .speed)
        theme.foreground = .green; theme.typeface = .rounded; theme.bottomLabel = "MY RIDE"
        try library.saveTheme(theme, for: .speed)
        try library.savePreset(name: "My ride", mode: .speed, theme: theme)
        let reloaded = try LocalLibrary(folder: folder)
        XCTAssertEqual(reloaded.theme(for: .speed), theme)
        XCTAssertEqual(reloaded.state.livePresets?.count, 1)
        let backup = try reloaded.backup()
        try reloaded.importBackup(backup)
        XCTAssertEqual(reloaded.state.livePresets?.count, 2)
        XCTAssertNotEqual(reloaded.state.livePresets?[0].id, reloaded.state.livePresets?[1].id)
        XCTAssertEqual(reloaded.state.livePresets?[1].theme, theme)
    }

    func testThemeRenderingAndDirtyMasksIncludeBackgroundChanges() throws {
        let size = PanelSize(width: 64, height: 64)
        let original = try MediaCodec.demo(mode: .speed, size: size, theme: .standard(for: .speed))
        var theme = LiveTheme.standard(for: .speed)
        theme.foreground = .white; theme.background = .blue
        theme.layout = .stacked; theme.topLabel = "MY RIDE"; theme.secondaryField = .clock
        let target = try MediaCodec.demo(mode: .speed, size: size, theme: theme)
        XCTAssertNotEqual(original, target)
        XCTAssertTrue(target.rgb.enumerated().contains { $0.offset.isMultiple(of: 3) && $0.element == 0 })
        let masks = try MediaCodec.delta(from: original, to: target)
        XCTAssertFalse(masks.isEmpty)
        XCTAssertTrue(masks.allSatisfy { $0.count - 16 <= 112 })
    }
}
