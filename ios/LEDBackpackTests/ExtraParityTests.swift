import XCTest
import Combine
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class DrawingPreviewMock: DrawingPreviewBackend {
    var drawingPreviewScope: DrawingPreviewScope? = DrawingPreviewScope(deviceID: UUID(), serial: "test-panel",
        size: PanelSize(width: 16, height: 16))
    var frames: [PixelFrame] = []
    var restores = 0
    var abandons = 0
    var errors: [String] = []
    var suspendStart = false
    var suspendPaint = false
    var begin: CheckedContinuation<Void, Error>?
    var paint: CheckedContinuation<Void, Error>?
    var onBegin: (() -> Void)?
    var onPaint: (() -> Void)?
    var onAbandon: (() -> Void)?
    func beginLive() async throws {
        onBegin?()
        if suspendStart { try await withCheckedThrowingContinuation { begin = $0 } }
    }
    func paintLive(_ frame: PixelFrame) async throws {
        frames.append(frame); onPaint?()
        if suspendPaint { try await withCheckedThrowingContinuation { paint = $0 } }
    }
    func endLive() async throws {
        XCTAssertFalse(Task.isCancelled, "Restoration must be a non-canceled operation.")
        restores += 1
    }
    func abandonLivePreview(_ reason: String) { abandons += 1; onAbandon?() }
    func report(_ error: Error) { errors.append(error.localizedDescription) }
}

@MainActor
final class ExtraParityTests: XCTestCase {
    private let size = PanelSize(width: 16, height: 16)
    private func inventory() throws -> [Slot] {
        let bytes = (0..<60).flatMap { id -> [UInt8] in
            [UInt8(id), 0, 0, 0, 0] + Array(repeating: id == 2 ? UInt8(1) : 0, count: 16)
        }
        guard case .slots(let slots) = try Wire.reply([0x81, 0x83, 0x35] + Wire.length(bytes.count) + bytes) else {
            throw BackpackError.invalid("Invalid fixture.")
        }
        return slots
    }
    func testBatchPlanPinsInventoryAndRejectsDuplicateSlotsAndQueuedIDs() throws {
        let snapshot = try BackpackErasePlan(deviceID: UUID(), serial: "test-panel", records: inventory())
        let first = QueuedMedia(mediaID: UUID()), second = QueuedMedia(mediaID: UUID())
        let entries = [BatchTransferEntry(queuedID: first.id, mediaID: first.mediaID, slot: 2),
            BatchTransferEntry(queuedID: second.id, mediaID: second.mediaID, slot: 3)]
        let plan = try BatchTransferPlan(inventory: snapshot, size: size, entries: entries, loopWhenFinished: true)
        XCTAssertEqual(plan.overwrittenSlots, [2])
        XCTAssertEqual(plan.entries.map(\.slot), [2, 3])
        XCTAssertThrowsError(try BatchTransferPlan(inventory: snapshot, size: size,
            entries: [entries[0], entries[0]], loopWhenFinished: false))
        XCTAssertThrowsError(try BatchTransferPlan(inventory: snapshot, size: size, entries: [], loopWhenFinished: false))
        let free = BatchTransferPlan.freeAssignments(queue: [first, second], slots: snapshot.records)
        XCTAssertEqual(free[first.id], 3)
        XCTAssertEqual(free[second.id], 4)
        XCTAssertFalse(free.values.contains(0))
        XCTAssertFalse(free.values.contains(1))
    }

    func testBatchPreparationPreservesMatchedBytesAndSingleFramesWhenFitting() async throws {
        let original = try MediaCodec.encode([.black(size)], delays: [0.2])
        let same = try await BatchGIFPreparation.fit(original, to: size)
        XCTAssertEqual(same, original)
        let resized = try await BatchGIFPreparation.fit(original, to: PanelSize(width: 64, height: 64))
        let decoded = try MediaCodec.decode(resized)
        XCTAssertEqual(decoded.images.count, 1)
        XCTAssertEqual(decoded.images[0].size.width, 64)
        XCTAssertEqual(decoded.images[0].size.height, 64)
        XCTAssertEqual(decoded.delays[0], 0.2, accuracy: 0.01)
    }

    func testQueuePersistsReordersDeletesAndBackupRemapsWithoutContentDedup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        let bytes = try MediaCodec.encode([.black(size)], delays: [1])
        try library.add(name: "First independent copy", data: bytes)
        try library.add(name: "Second independent copy", data: bytes)
        let ids = library.state.media.map(\.id)
        XCTAssertEqual(ids.count, 2)
        try library.enqueue(ids)
        try library.enqueue([ids[0]])
        let queue = try XCTUnwrap(library.state.transferQueue)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(Set(queue.map(\.id)).count, 3)
        let order = Array(queue.map(\.id).reversed())
        try library.reorderQueuedMedia(order)
        XCTAssertEqual(library.state.transferQueue?.map(\.id), order)
        XCTAssertThrowsError(try library.reorderQueuedMedia([UUID()]))
        XCTAssertEqual(try LocalLibrary(folder: folder).state.transferQueue?.count, 3)
        let backup = try library.backup()
        try library.importBackup(backup)
        XCTAssertEqual(library.state.transferQueue?.count, 6)
        XCTAssertEqual(Set(library.state.transferQueue?.map(\.id) ?? []).count, 6)
        XCTAssertEqual(library.state.media.count, 4)
        XCTAssertEqual(library.state.version, 1)
        let deleted = try XCTUnwrap(library.state.media.first)
        try library.delete(deleted)
        XCTAssertFalse(library.state.transferQueue?.contains { $0.mediaID == deleted.id } == true)
    }

    func testQueueLimitsRejectUnknownMediaAndMoreThan60Entries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try LocalLibrary(folder: folder)
        XCTAssertThrowsError(try library.enqueue([UUID()]))
        XCTAssertNil(library.state.transferQueue)
        try library.add(name: "Test", data: MediaCodec.encode([.black(size)], delays: [1]))
        let id = try XCTUnwrap(library.state.media.first?.id)
        try library.enqueue(Array(repeating: id, count: 60))
        XCTAssertThrowsError(try library.enqueue([id]))
        XCTAssertEqual(library.state.transferQueue?.count, 60)
    }

    func testTextEffectsPreserveStaticAndBoundAllAnimatedFrames() throws {
        for effect in TextArtworkEffect.allCases {
            let frames = try TextArtworkEffects.frames("A", size: size, font: .pixel, alignment: .center,
                color: .cyan, effect: effect)
            XCTAssertEqual(frames.first?.size, size)
            XCTAssertTrue((1...120).contains(frames.count))
            if effect == .still { XCTAssertEqual(frames.count, 1) }
            else { XCTAssertGreaterThan(frames.count, 1) }
            let decoded = try MediaCodec.decode(MediaCodec.encode(frames, delays: Array(repeating: 0.08, count: frames.count)))
            XCTAssertEqual(decoded.images.count, frames.count)
        }
        let original = try TextArtwork.render("A", size: size, font: .pixel, alignment: .center, color: .cyan)
        let staticFrame = try TextArtworkEffects.frame("A", size: size, font: .pixel, alignment: .center,
            color: .cyan, effect: .still, phase: 0)
        XCTAssertEqual(staticFrame, original)
    }

    func testRevealEndpointsAndEffectTimingRejectNonfinitePhase() throws {
        let first = try TextArtworkEffects.frame("A", size: size, font: .pixel, alignment: .center,
            color: .cyan, effect: .reveal, phase: 0)
        let last = try TextArtworkEffects.frame("A", size: size, font: .pixel, alignment: .center,
            color: .cyan, effect: .reveal, phase: 1)
        XCTAssertTrue(first.rgb.allSatisfy { $0 == 0 })
        XCTAssertEqual(last, try TextArtwork.render("A", size: size, font: .pixel, alignment: .center, color: .cyan))
        XCTAssertThrowsError(try TextArtworkEffects.frame("A", size: size, font: .pixel, alignment: .center,
            color: .cyan, effect: .breathe, phase: .nan))
        XCTAssertThrowsError(try TextArtworkEffects.frame("A", size: size, font: .pixel, alignment: .center,
            color: .cyan, effect: .bounce, phase: 1.01))
    }

    func testFirstLiveFrameExplicitlyClearsEveryPixelIncludingBlack() throws {
        let black = PixelFrame.black(size)
        XCTAssertTrue(try MediaCodec.delta(from: black, to: black).isEmpty)
        let clear = try MediaCodec.delta(from: black, to: black, forceFullFrame: true)
        XCTAssertEqual(clear.count, 1)
        XCTAssertEqual(Array(clear[0][5..<8]), [0, 0, 0])
        XCTAssertEqual(Array(clear[0].dropFirst(16)), Array(repeating: 255, count: 32))
        var ink = black; ink.rgb[0] = 100; ink.exactLiveColors = true
        let full = try MediaCodec.delta(from: black, to: ink, forceFullFrame: true)
        XCTAssertEqual(full.flatMap { $0.dropFirst(16) }.reduce(0) { $0 + $1.nonzeroBitCount }, 16 * 16)
        XCTAssertTrue(full.allSatisfy { $0.count - 16 <= 112 })
    }

    func testLiveFrameRejectsMismatchedPixelBuffersRatherThanIndexingPastThem() {
        let invalid = PixelFrame(size: size, rgb: [0])
        XCTAssertThrowsError(try MediaCodec.delta(from: .black(size), to: invalid))
        XCTAssertThrowsError(try MediaCodec.delta(from: invalid, to: .black(size)))
    }

    func testLiveDrawingCoalescesTouchesAndRestoresWithoutCanceledTask() async throws {
        let panel = DrawingPreviewMock()
        panel.suspendPaint = true
        let first = expectation(description: "Initial frame")
        let second = expectation(description: "Latest coalesced frame")
        panel.onPaint = { if panel.frames.count == 1 { first.fulfill() } else if panel.frames.count == 2 { second.fulfill() } }
        let preview = DrawingLivePreview(panel: panel)
        try preview.start(.black(size))
        await fulfillment(of: [first], timeout: 3)
        var drawing = PixelFrame.black(size); drawing.rgb[0] = 100
        preview.offer(drawing)
        drawing.rgb[0] = 200
        preview.offer(drawing)
        panel.suspendPaint = false; panel.paint?.resume(); panel.paint = nil
        await fulfillment(of: [second], timeout: 3)
        await preview.stop()
        XCTAssertEqual(panel.frames.count, 2)
        XCTAssertEqual(panel.frames.last?.rgb[0], 200)
        XCTAssertEqual(panel.frames.last?.exactLiveColors, true)
        XCTAssertEqual(panel.restores, 1)
        XCTAssertEqual(preview.state, .idle)
    }

    func testStopDuringLiveStartupWaitsThenRestores() async throws {
        let panel = DrawingPreviewMock()
        panel.suspendStart = true
        let starting = expectation(description: "Starting")
        panel.onBegin = { starting.fulfill() }
        let preview = DrawingLivePreview(panel: panel)
        try preview.start(.black(size))
        await fulfillment(of: [starting], timeout: 3)
        let stopping = expectation(description: "Stopping")
        let subscription = preview.$state.first(where: { $0 == .stopping }).sink { _ in stopping.fulfill() }
        let stop = Task { await preview.stop() }
        await fulfillment(of: [stopping], timeout: 3)
        panel.begin?.resume(); panel.begin = nil
        await stop.value
        subscription.cancel()
        XCTAssertEqual(panel.frames.count, 0)
        XCTAssertEqual(panel.restores, 1)
        XCTAssertEqual(preview.state, .idle)
    }

    func testLiveDrawingNeverRestoresOldPlaybackOntoAnotherDevice() async throws {
        let panel = DrawingPreviewMock()
        panel.suspendPaint = true
        let painted = expectation(description: "Frame sent")
        panel.onPaint = { painted.fulfill() }
        let abandoned = expectation(description: "Old session abandoned")
        panel.onAbandon = { abandoned.fulfill() }
        let preview = DrawingLivePreview(panel: panel)
        try preview.start(.black(size))
        await fulfillment(of: [painted], timeout: 3)
        panel.drawingPreviewScope = DrawingPreviewScope(deviceID: UUID(), serial: "other", size: size)
        panel.suspendPaint = false; panel.paint?.resume(); panel.paint = nil
        await fulfillment(of: [abandoned], timeout: 3)
        XCTAssertEqual(panel.restores, 0)
        XCTAssertEqual(panel.abandons, 1)
        XCTAssertNotNil(preview.failure)
    }

    func testLiveDrawingRejectsWrongCanvasAndDoesNotResumeAfterBackground() async throws {
        let panel = DrawingPreviewMock()
        let preview = DrawingLivePreview(panel: panel)
        XCTAssertThrowsError(try preview.start(.black(PanelSize(width: 64, height: 64))))
        preview.setBackground(true)
        XCTAssertThrowsError(try preview.start(.black(size)))
        preview.setBackground(false)
        XCTAssertEqual(preview.state, .idle)
        XCTAssertEqual(panel.frames.count, 0)
    }
}
