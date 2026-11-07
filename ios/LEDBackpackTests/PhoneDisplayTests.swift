import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class FakePhoneIdleTimer: PhoneIdleTimer {
    var disabled: Bool { didSet { writes.append(disabled) } }
    var writes: [Bool] = []
    init(_ initial: Bool = false) { disabled = initial }
}

@MainActor
final class PhoneDisplayTests: XCTestCase {
    private let size = PanelSize(width: 16, height: 16)
    private func gif(animated: Bool = true, loops: Int = 0) throws -> Data {
        let black = PixelFrame.black(size)
        var red = black; red.rgb[0] = 255
        return try MediaCodec.encode(animated ? [black, red] : [red],
            delays: animated ? [0.04, 0.12] : [1], loopCount: loops)
    }
    private func activate(_ phone: PhoneDisplayController) {
        phone.open(); phone.setForeground(true); phone.setVisible(true)
    }

    func testPhoneColdStartAndStaticDisplayNeedNoDeviceAccountOrSlot() async throws {
        let timer = FakePhoneIdleTimer()
        let phone = PhoneDisplayController(idleTimer: timer)
        XCTAssertFalse(phone.hasArtwork)
        activate(phone)
        try await phone.show(gif(animated: false))
        XCTAssertTrue(phone.presented)
        XCTAssertTrue(phone.hasArtwork)
        XCTAssertFalse(phone.animated)
        XCTAssertFalse(phone.isPlaying)
        XCTAssertEqual(phone.preview?.frames.count, 1)
        XCTAssertFalse(timer.disabled)
        XCTAssertTrue(timer.writes.isEmpty)
        XCTAssertNil(phone.snapshot().mediaID)
    }

    func testSavedViewerPolicyStopsAutomaticPlaybackWithoutRestartAndRetainsManualPlay() async throws {
        let phone = PhoneDisplayController(idleTimer: FakePhoneIdleTimer())
        activate(phone)
        try await phone.show(gif())
        try await phone.applyValidatedGameGIF(gif(), expectedRevision: phone.artworkRevision,
            nextRevision: UUID(), explicitlyArmedPlayback: true)
        XCTAssertTrue(phone.isPlaying)
        phone.setViewerAutomaticPlaybackAllowed(false)
        XCTAssertFalse(phone.isPlaying)
        phone.setViewerAutomaticPlaybackAllowed(true)
        XCTAssertFalse(phone.isPlaying)
        phone.setViewerAutomaticPlaybackAllowed(false)
        phone.play()
        XCTAssertTrue(phone.isPlaying)
    }

    func testSavedViewerPolicySuppressesIncomingAnimationAndHandoffWithoutChangingLocalControls() async throws {
        let phone = PhoneDisplayController(idleTimer: FakePhoneIdleTimer())
        activate(phone)
        try await phone.show(gif())
        phone.play()
        phone.setViewerAutomaticPlaybackAllowed(false)
        XCTAssertTrue(phone.isPlaying)
        let before = phone.snapshot()
        try await phone.applyValidatedGameGIF(gif(), expectedRevision: phone.artworkRevision,
            nextRevision: UUID(), explicitlyArmedPlayback: true, handoffSender: true)
        XCTAssertFalse(phone.isPlaying)
        XCTAssertNil(phone.peerHandoff)
        XCTAssertEqual(phone.animationsEnabled, before.animationsEnabled)
        XCTAssertEqual(phone.dataSaving, before.dataSaving)
        phone.setViewerAutomaticPlaybackAllowed(true)
        XCTAssertFalse(phone.isPlaying)
    }

    func testSavedViewerPolicyChangesInvalidatePeerPolicyOnlyWhenChanged() {
        let phone = PhoneDisplayController(idleTimer: FakePhoneIdleTimer())
        var changes = 0
        phone.peerPlaybackPolicyChanged = { changes += 1 }
        let original = phone.playbackPolicyRevision
        phone.setViewerAutomaticPlaybackAllowed(true)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(phone.playbackPolicyRevision, original)
        phone.setViewerAutomaticPlaybackAllowed(false)
        XCTAssertEqual(changes, 1)
        XCTAssertNotEqual(phone.playbackPolicyRevision, original)
        phone.setViewerAutomaticPlaybackAllowed(false)
        XCTAssertEqual(changes, 1)
    }

    func testPauseAndBackgroundFreezePlayheadInsteadOfAdvancingWhileHidden() throws {
        let start = ContinuousClock().now
        var clock = PhonePlaybackClock()
        clock.start(at: start)
        clock.pause(at: start.advanced(by: .milliseconds(150)))
        XCTAssertEqual(clock.elapsed(at: start.advanced(by: .seconds(100))), 0.15, accuracy: 0.00001)
        clock.start(at: start.advanced(by: .seconds(100)))
        XCTAssertEqual(clock.elapsed(at: start.advanced(by: .milliseconds(100050))), 0.2, accuracy: 0.00001)
        XCTAssertThrowsError(try clock.reset(to: .nan))
        XCTAssertThrowsError(try clock.reset(to: -1))
    }

    func testReducedMotionRequiresExplicitPlayAndBackgroundReleasesDecodedFrames() async throws {
        let phone = PhoneDisplayController(idleTimer: FakePhoneIdleTimer(), reducedMotion: true)
        activate(phone)
        try await phone.show(gif())
        XCTAssertFalse(phone.isPlaying)
        phone.play()
        XCTAssertTrue(phone.isPlaying)
        phone.setForeground(false)
        XCTAssertFalse(phone.isPlaying)
        XCTAssertNil(phone.preview)
        XCTAssertTrue(phone.hasArtwork)
        phone.setForeground(true)
        try await phone.restore(phone.snapshot())
        XCTAssertTrue(phone.isPlaying)
        phone.pause()
        XCTAssertFalse(phone.isPlaying)
        phone.setVisible(false)
        phone.setVisible(true)
        XCTAssertFalse(phone.isPlaying)
    }

    func testIdleTimerLeaseRestoresPriorFalseAndPriorTrueExactly() {
        for original in [false, true] {
            let timer = FakePhoneIdleTimer(original)
            let lease = PhoneIdleTimerLease(timer: timer)
            lease.update(requested: true)
            XCTAssertTrue(timer.disabled)
            lease.update(requested: true)
            lease.update(requested: false)
            XCTAssertEqual(timer.disabled, original)
            lease.update(requested: false)
            XCTAssertEqual(timer.disabled, original)
        }
    }

    func testKeepAwakeIsOptInForStillsAndRestoredOnBackgroundDismissAndPicker() async throws {
        let timer = FakePhoneIdleTimer()
        let phone = PhoneDisplayController(idleTimer: timer)
        activate(phone)
        try await phone.show(gif(animated: false))
        XCTAssertFalse(timer.disabled)
        phone.setKeepAwake(true)
        XCTAssertTrue(timer.disabled)
        phone.setVisible(false)
        XCTAssertFalse(timer.disabled)
        phone.setVisible(true)
        try await phone.restore(phone.snapshot())
        XCTAssertTrue(timer.disabled)
        phone.setForeground(false)
        XCTAssertFalse(timer.disabled)
        phone.setForeground(true)
        try await phone.restore(phone.snapshot())
        XCTAssertTrue(timer.disabled)
        phone.dismiss()
        XCTAssertFalse(timer.disabled)
        XCTAssertNil(phone.preview)
    }

    func testSnapshotRoundTripRestoresOriginalBytesAndPausedFrameWithoutSlots() async throws {
        let bytes = try gif()
        let id = UUID()
        let snapshot = PhoneDisplaySnapshot(data: bytes, mediaID: id, elapsed: 0.08,
            wantsPlayback: false, motionOverride: false, keepAwake: true)
        let decoded = try JSONDecoder().decode(PhoneDisplaySnapshot.self, from: JSONEncoder().encode(snapshot))
        let timer = FakePhoneIdleTimer()
        let replacement = PhoneDisplayController(idleTimer: timer)
        activate(replacement)
        try await replacement.restore(decoded)
        XCTAssertEqual(replacement.data, bytes)
        XCTAssertEqual(replacement.mediaID, id)
        XCTAssertFalse(replacement.isPlaying)
        XCTAssertEqual(replacement.position().index, 1)
        XCTAssertTrue(timer.disabled)
        XCTAssertEqual(replacement.snapshot().elapsed, 0.08, accuracy: 0.00001)
        replacement.dismiss()
        XCTAssertFalse(timer.disabled)
    }

    func testFailedArtworkOrSnapshotDoesNotReplaceCurrentArtwork() async throws {
        let phone = PhoneDisplayController(idleTimer: FakePhoneIdleTimer())
        activate(phone)
        let bytes = try gif()
        try await phone.show(bytes)
        do { try await phone.show(Data("not an image".utf8)); XCTFail("Corrupt selection") } catch {}
        XCTAssertEqual(phone.data, bytes)
        let bad = PhoneDisplaySnapshot(data: Data("invalid".utf8), mediaID: nil, elapsed: 0,
            wantsPlayback: true, motionOverride: false, keepAwake: false)
        do { try await phone.restore(bad); XCTFail("Corrupt snapshot") } catch {}
        XCTAssertEqual(phone.data, bytes)
        let empty = PhoneDisplaySnapshot(data: nil, mediaID: nil, elapsed: 10,
            wantsPlayback: true, motionOverride: false, keepAwake: false)
        do { try await phone.restore(empty); XCTFail("Invalid empty snapshot") } catch {}
        XCTAssertEqual(phone.data, bytes)
    }

    func testPhoneDecoderPreservesTimingAndFiniteRepeatMetadataWithoutFrameDuplication() async throws {
        let data = try gif(loops: 1)
        let phone = try GIFPreviewDecoder.phoneDisplay(data)
        XCTAssertEqual(phone.frames.count, 2)
        XCTAssertEqual(phone.frameEnds[0], 0.04, accuracy: 0.001)
        XCTAssertEqual(phone.duration, 0.16, accuracy: 0.001)
        XCTAssertEqual(phone.cycles, 2)
        let controller = PhoneDisplayController(idleTimer: FakePhoneIdleTimer())
        activate(controller)
        try await controller.restore(PhoneDisplaySnapshot(data: data, mediaID: nil, elapsed: 0.32,
            wantsPlayback: true, motionOverride: false, keepAwake: false))
        XCTAssertTrue(controller.position().finished)
        XCTAssertEqual(controller.position().index, 1)
        XCTAssertFalse(controller.isPlaying)
        controller.play()
        XCTAssertTrue(controller.isPlaying)
        XCTAssertFalse(controller.position().finished)
    }

    func testPhoneDecoderUsesLargerBoundedFramesAndSupportsPngStills() throws {
        let source = PixelFrame.black(PanelSize(width: 96, height: 128))
        let data = try MediaCodec.encode([source], delays: [1])
        let decoded = try GIFPreviewDecoder.phoneDisplay(data)
        XCTAssertEqual(decoded.frames[0].size.width, 96)
        XCTAssertEqual(decoded.frames[0].size.height, 128)
        XCTAssertLessThanOrEqual(decoded.cost, 40_000_000)
        let png = try XCTUnwrap(source.image().pngData())
        let still = try GIFPreviewDecoder.phoneDisplay(png)
        XCTAssertEqual(still.frames.count, 1)
        XCTAssertEqual(still.duration, 0)
        XCTAssertThrowsError(try GIFPreviewDecoder.phoneDisplay(Data(repeating: 0, count: 5_000_001)))
    }

    func testLocalFileReadingIsBoundedAndNeverModifiesTheSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try gif()
        try original.write(to: url)
        XCTAssertEqual(try PhoneDisplayFileReader.read(url), original)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 5_000_001); try file.close()
        XCTAssertThrowsError(try PhoneDisplayFileReader.read(url))
        XCTAssertThrowsError(try PhoneDisplayFileReader.read(XCTUnwrap(URL(string: "https://example.invalid/art.gif"))))
    }

    func testBackgroundChangesCannotReplaceOrDecodeOverTheOriginalPhoneArtwork() async throws {
        let phone = PhoneDisplayController(idleTimer: FakePhoneIdleTimer())
        activate(phone)
        let original = try gif()
        try await phone.show(original)
        let checkpoint = phone.snapshot()
        phone.setForeground(false)
        do { try await phone.show(Data("invalid new artwork".utf8)); XCTFail("Background change") } catch {}
        do { try await phone.restore(checkpoint); XCTFail("Background restore") } catch {}
        XCTAssertEqual(phone.data, original)
        XCTAssertNil(phone.preview)
        XCTAssertFalse(phone.isPlaying)
    }
}
