import XCTest
import BackpackProtocol
@testable import LEDBackpack

final class GIFTimingAdjustmentTests: XCTestCase {
    private func gif(delays: [Int] = [30,70], controls: Bool = true) -> Data {
        var bytes = Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,0,0,0,255,255,255])
        for delay in delays {
            if controls { bytes.append(contentsOf: [33,249,4,9,UInt8(truncatingIfNeeded: delay),UInt8(truncatingIfNeeded: delay >> 8),0,0]) }
            bytes.append(contentsOf: [44,0,0,0,0,1,0,1,0,0,2,2,68,1,0])
        }
        bytes.append(59); return bytes
    }
    func testOriginalSpeedPreservesEveryOriginalByte() throws {
        let original = gif()
        XCTAssertEqual(try GIFTimingAdjustment().applying(to: original), original)
    }
    func testSpeedChangesOnlyGraphicControlDelayBytesAndNotOriginal() throws {
        let original = gif(), before = try GIFStructure.inspect(original)
        let edited = try GIFTimingAdjustment(speed: 2).applying(to: original)
        XCTAssertEqual(try GIFStructure.inspect(edited).frames.map(\.delayCentiseconds), [15,35])
        let allowed = Set(before.frames.compactMap(\.controlOffset).flatMap { [$0 + 4,$0 + 5] })
        for index in original.indices where !allowed.contains(index) { XCTAssertEqual(original[index], edited[index]) }
        XCTAssertEqual(try GIFStructure.inspect(original).frames.map(\.delayCentiseconds), [30,70])
    }
    func testSlowingPreservesLongSourcePausesWithoutTenSecondClamp() throws {
        let original = gif(delays: [1200])
        let edited = try GIFTimingAdjustment(speed: 0.5).applying(to: original)
        XCTAssertEqual(try GIFStructure.inspect(edited).frames[0].delayCentiseconds, 2400)
    }
    func testUniformFrameDelayAndSpeedAreSeparateExplicitChoices() throws {
        let edited = try GIFTimingAdjustment(speed: 0.5, uniformCentiseconds: 10).applying(to: gif())
        XCTAssertEqual(try GIFStructure.inspect(edited).frames.map(\.delayCentiseconds), [20,20])
    }
    func testOutOfRangeTimingRejectsInsteadOfClampingOrRepairing() {
        XCTAssertThrowsError(try GIFTimingAdjustment(speed: 0.1).applying(to: gif()))
        XCTAssertThrowsError(try GIFTimingAdjustment(speed: 0.25).applying(to: gif(delays: [65535])))
        XCTAssertThrowsError(try GIFTimingAdjustment(speed: 4, uniformCentiseconds: 1).applying(to: gif()))
    }
    func testMissingControlGetsExplicitNewDelayWithoutChangingPixelStream() throws {
        let original = gif(controls: false)
        let edited = try GIFTimingAdjustment(speed: 0.5).applying(to: original)
        let structure = try GIFStructure.inspect(edited)
        XCTAssertEqual(structure.frames.map(\.delayCentiseconds), [20,20])
        for frame in structure.frames { XCTAssertEqual(Array(edited[frame.imageOffset..<(frame.imageOffset + 15)]), [44,0,0,0,0,1,0,1,0,0,2,2,68,1,0]) }
    }
    func testTotalLoopCountMeansInitialPlayPlusRepeatsNotInfiniteForOne() throws {
        let source = gif()
        let continuous = try GIFTimingAdjustment.repeatingCopy(source, totalLoops: nil)
        XCTAssertEqual(try GIFStructure.inspect(continuous).repeats, 0)
        let three = try GIFTimingAdjustment.repeatingCopy(continuous, totalLoops: 3)
        XCTAssertEqual(try GIFStructure.inspect(three).repeats, 2)
        let once = try GIFTimingAdjustment.repeatingCopy(three, totalLoops: 1)
        XCTAssertNil(try GIFStructure.inspect(once).repeats)
        XCTAssertEqual(once, source)
    }
    func testLoopMetadataKeepsAuthoredPixelFramesAndTiming() throws {
        let original = gif()
        let edited = try GIFTimingAdjustment.repeatingCopy(original, totalLoops: 4)
        let old = try GIFStructure.inspect(original), new = try GIFStructure.inspect(edited)
        XCTAssertEqual(old.frames.map(\.delayCentiseconds), new.frames.map(\.delayCentiseconds))
        for index in old.frames.indices {
            let a = old.frames[index].imageOffset, b = new.frames[index].imageOffset
            XCTAssertEqual(Data(original[a..<(a + 15)]), Data(edited[b..<(b + 15)]))
        }
    }
    func testTimeAndLoopsProduceDistinctExplicitProgramDurations() throws {
        var options = BackpackSendOptions()
        options.programSeconds = 10
        XCTAssertEqual(try options.duration(for: gif()), 10)
        options.limit = .loops; options.totalLoops = 3
        XCTAssertEqual(try options.duration(for: gif()), 3)
        XCTAssertEqual(try options.duration(for: gif(delays: [10,40])), 2)
    }
    func testTooManyLoopsOrLongDerivedDurationRejectExplicitly() {
        var options = BackpackSendOptions(); options.limit = .loops; options.totalLoops = 100
        XCTAssertThrowsError(try options.duration(for: gif(delays: [1000])))
        XCTAssertThrowsError(try GIFTimingAdjustment.repeatingCopy(gif(), totalLoops: 0))
    }
    func testDirectSendUsesOnlyEmptyOrdinarySlotsAndNeverOverwrites() throws {
        let raw = (0..<60).flatMap { index -> [UInt8] in
            [UInt8(index)] + Array(repeating: index == 2 ? UInt8(1) : 0, count: 20)
        }
        guard case .slots(let slots) = try Wire.reply([0x81,0x83,0x35] + Wire.length(raw.count) + raw) else { return XCTFail("Inventory") }
        let inventory = try BackpackErasePlan(deviceID: UUID(), serial: "Synthetic", records: slots)
        let plan = try BackpackDirectSendPlan(inventory: inventory, size: .init(width: 64, height: 64), count: 3)
        XCTAssertEqual(plan.slots, [3,4,5])
        XCTAssertFalse(plan.slots.contains { $0 >= 55 || $0 < 2 })
    }
    func testSingleGIFLoopReceiptRequiresOrderedLoopNotOnlySlotSelection() throws {
        let raw = (0..<60).flatMap { [UInt8($0)] + Array(repeating: UInt8(0), count: 20) }
        guard case .slots(let slots) = try Wire.reply([0x81,0x83,0x35] + Wire.length(raw.count) + raw) else { return XCTFail("Inventory") }
        let plan = try BackpackDirectSendPlan(inventory: .init(deviceID: UUID(), serial: "Synthetic", records: slots), size: .init(width: 64, height: 64), count: 1)
        XCTAssertFalse(plan.verifies(.init(mode: 1, index: UInt8(plan.slots[0]), ids: [UInt8(plan.slots[0])])))
        XCTAssertTrue(plan.verifies(.init(mode: 2, index: 255, ids: plan.slots.map(UInt8.init))))
        XCTAssertFalse(plan.verifies(.init(mode: 2, index: 255, ids: [59])))
    }
    func testSizeOnlySlotMetadataMustNotBeMistakenForEmpty() throws {
        let raw = (0..<60).flatMap { slot -> [UInt8] in
            [UInt8(slot)] + [slot == 2 ? UInt8(9) : 0,0,0,0] + Array(repeating: UInt8(0), count: 16)
        }
        guard case .slots(let slots) = try Wire.reply([0x81,0x83,0x35] + Wire.length(raw.count) + raw) else { return XCTFail("Inventory") }
        XCTAssertTrue(slots[2].occupied)
        let plan = try BackpackDirectSendPlan(inventory: .init(deviceID: UUID(), serial: "Synthetic", records: slots),
            size: .init(width: 64, height: 64), count: 1)
        XCTAssertEqual(plan.slots, [3])
    }
}
