import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class OfflineIdleTimer: PhoneIdleTimer { var disabled = false }
@MainActor
private final class OfflineBrightness: PhoneScreenBrightness {
    var value = 0.37
    var writes: [Double] = []
}
@MainActor
final class PhoneOfflineTests: XCTestCase {
    private func gif(_ delays: [Int] = [1, 12000], repeats: Int? = nil) -> Data {
        var bytes = Array("GIF89a".utf8) + [1,0,1,0,0x80,0,0,0,0,0,255,255,255]
        if let repeats { bytes += [0x21,0xFF,11] + Array("NETSCAPE2.0".utf8) + [3,1] + Wire.le16(repeats) + [0] }
        for delay in delays {
            bytes += [0x21,0xF9,4,0] + Wire.le16(delay) + [0,0,0x2C,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0]
        }
        return Data(bytes + [0x3B])
    }
    private func controller() -> (PhoneDisplayController, OfflineBrightness, OfflineIdleTimer) {
        let brightness = OfflineBrightness(), idle = OfflineIdleTimer()
        let player = PhoneDisplayController(idleTimer: idle, brightness: brightness)
        player.setForeground(true); player.open(); player.setVisible(true)
        return (player, brightness, idle)
    }
    private func repository() throws -> (PhoneArtworkRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (PhoneArtworkRepository(root: root.appendingPathComponent("library", isDirectory: true)), root)
    }
    func testColdStartPhoneDefaultsDoNotRequestPermissionsOrStartPlayback() {
        let phone = PhoneDisplayController(idleTimer: OfflineIdleTimer(), brightness: OfflineBrightness())
        XCTAssertFalse(phone.presented); XCTAssertFalse(phone.hasArtwork); XCTAssertFalse(phone.keepAwake)
        XCTAssertFalse(phone.brightnessEnabled); XCTAssertFalse(phone.isPlaying)
        XCTAssertEqual(DisplayTargetSelection().target, .phone)
    }
    func testNewArtworkStartsPausedAndPreservesOriginalLongTimingAndRepeats() async throws {
        let (phone, screen, _) = controller()
        let original = gif(repeats: 2)
        try await phone.show(original)
        XCTAssertEqual(phone.data, original); XCTAssertFalse(phone.isPlaying)
        XCTAssertEqual(phone.preview?.duration ?? 0, 120.01, accuracy: 0.0001)
        XCTAssertEqual(phone.preview?.cycles, 3); XCTAssertEqual(screen.value, 0.37)
        phone.play(); XCTAssertTrue(phone.isPlaying)
    }
    func testFailedDecodeKeepsPreviousSelectionAndExplicitErrorRestoresLeases() async throws {
        let (phone, screen, idle) = controller(), id = UUID()
        let original = gif()
        try await phone.show(original, mediaID: id)
        phone.setKeepAwake(true); phone.setBrightness(0.6); phone.setBrightnessEnabled(true)
        do { try await phone.show(Data("invalid new selection".utf8)); XCTFail("Corrupt") } catch { phone.report(error) }
        XCTAssertEqual(phone.data, original); XCTAssertEqual(phone.mediaID, id)
        XCTAssertEqual(screen.value, 0.37); XCTAssertFalse(idle.disabled); XCTAssertFalse(phone.isPlaying)
    }
    func testBrightnessAndAwakeAreSeparateAndReversibleOnBackgroundAndExit() async throws {
        let (phone, screen, idle) = controller()
        try await phone.show(gif([10]))
        phone.setBrightness(0.55); XCTAssertEqual(screen.value, 0.37)
        phone.setBrightnessEnabled(true); XCTAssertEqual(screen.value, 0.55); XCTAssertFalse(idle.disabled)
        phone.setKeepAwake(true); XCTAssertTrue(idle.disabled)
        phone.setForeground(false); XCTAssertEqual(screen.value, 0.37); XCTAssertFalse(idle.disabled)
        phone.dismiss(); XCTAssertEqual(screen.value, 0.37)
    }
    func testReducedMotionAnimationAndDataSavingPoliciesNeedExplicitPlay() async throws {
        let (phone, _, _) = controller()
        phone.setReducedMotion(true); try await phone.show(gif())
        XCTAssertFalse(phone.isPlaying); phone.play(); XCTAssertTrue(phone.isPlaying)
        phone.setDataSaving(true); XCTAssertFalse(phone.isPlaying)
        phone.play(); XCTAssertFalse(phone.isPlaying)
        phone.setDataSaving(false); XCTAssertFalse(phone.isPlaying)
        phone.setAnimationsEnabled(false); phone.play(); XCTAssertFalse(phone.isPlaying)
        phone.setAnimationsEnabled(true); XCTAssertFalse(phone.isPlaying)
        phone.play(); XCTAssertTrue(phone.isPlaying)
    }
    func testTargetChangesRetainIndependentArtworkWithoutSlotOrBluetoothDependencies() async throws {
        let (phone, _, _) = controller(), targets = DisplayTargetSelection(), hardware = UUID()
        let original = gif()
        try await phone.show(original)
        let saved = phone.snapshot()
        targets.stageHardware(hardware); phone.dismiss()
        XCTAssertEqual(targets.target, .hardware); XCTAssertEqual(targets.hardwareArtworkID, hardware)
        XCTAssertEqual(phone.data, saved.data)
        targets.target = .phone; phone.open()
        XCTAssertEqual(targets.hardwareArtworkID, hardware); XCTAssertEqual(phone.data, original)
    }
    func testImportedPngKeepsByteExactOriginalAndSeparateIdentityAcrossCopies() async throws {
        let (store, root) = try repository()
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).pngData { context in
            UIColor.cyan.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        }
        let url = root.appendingPathComponent("still.png"); try bytes.write(to: url)
        let first = try await store.importFile(url), second = try await store.importFile(url)
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(first.suffix, "png")
        let read = try await store.read(first); XCTAssertEqual(read, bytes)
        let list = try await store.list(); XCTAssertEqual(list.count, 2)
        let preview = try GIFPreviewDecoder.phoneDisplay(read); XCTAssertEqual(preview.frames.count, 1)
    }
    func testCorruptImportDoesNotResetExistingLocalLibrary() async throws {
        let (store, root) = try repository(), bytes = gif()
        let valid = root.appendingPathComponent("valid.gif"); try bytes.write(to: valid)
        let item = try await store.importFile(valid)
        let invalid = root.appendingPathComponent("invalid.gif"); try Data("bad".utf8).write(to: invalid)
        do { _ = try await store.importFile(invalid); XCTFail("Corrupt import") } catch {}
        let list = try await store.list(), read = try await store.read(item)
        XCTAssertEqual(list.map(\.id), [item.id]); XCTAssertEqual(read, bytes)
    }
    func testLocalLibraryPersistsOriginalTimingAndDeleteDoesNotAffectSelectedBytes() async throws {
        let (store, root) = try repository(), bytes = gif()
        let url = root.appendingPathComponent("long.gif"); try bytes.write(to: url)
        let item = try await store.importFile(url)
        let reopened = PhoneArtworkRepository(root: root.appendingPathComponent("library"))
        let loaded = try await reopened.read(item); XCTAssertEqual(loaded, bytes)
        let (phone, _, _) = controller(); try await phone.show(loaded, mediaID: item.id)
        try await reopened.remove(item)
        XCTAssertEqual(phone.data, bytes)
        let remaining = try await reopened.list(); XCTAssertTrue(remaining.isEmpty)
    }
    func testImportReaderRejectsOversizeAndSymbolicLinksWithoutTouchingSources() async throws {
        let (store, root) = try repository()
        let large = root.appendingPathComponent("large.gif")
        try Data(repeating: 0, count: 5_000_001).write(to: large)
        do { _ = try await store.importFile(large); XCTFail("Too large") } catch {}
        let source = root.appendingPathComponent("source.gif"); try gif().write(to: source)
        let link = root.appendingPathComponent("linked.gif")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try await store.importFile(link); XCTFail("Link") } catch {}
        let original = try Data(contentsOf: source); XCTAssertEqual(original, gif())
    }
    func testBackgroundSelectionCannotOverwriteRetainedOriginalOrReapplyBrightness() async throws {
        let (phone, screen, _) = controller()
        let bytes = gif(); try await phone.show(bytes)
        phone.setBrightnessEnabled(true); phone.setForeground(false)
        do { try await phone.show(gif([5])); XCTFail("Background selection") } catch {}
        XCTAssertEqual(phone.data, bytes); XCTAssertEqual(screen.value, 0.37)
        XCTAssertNil(phone.preview)
    }
    func testNoLoopMetadataAndOneFrameStayTruthfulRatherThanDuplicatingFrames() async throws {
        let (phone, _, _) = controller()
        try await phone.show(gif([17]))
        XCTAssertEqual(phone.preview?.frames.count, 1); XCTAssertEqual(phone.preview?.cycles, 1)
        XCTAssertFalse(phone.animated)
        let once = try GIFPreviewDecoder.phoneDisplay(gif([3, 12]))
        XCTAssertEqual(once.frames.count, 2); XCTAssertEqual(once.cycles, 1)
        XCTAssertEqual(once.duration, 0.15, accuracy: 0.000001)
        let finite = try GIFPreviewDecoder.phoneDisplay(gif([3, 12], repeats: 2))
        XCTAssertEqual(finite.cycles, 3)
        let forever = try GIFPreviewDecoder.phoneDisplay(gif(repeats: 0))
        XCTAssertNil(forever.cycles); XCTAssertEqual(forever.frameEnds[0], 0.01, accuracy: 0.0001)
    }
}
