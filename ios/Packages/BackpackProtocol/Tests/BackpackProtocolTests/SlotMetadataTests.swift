import XCTest
@testable import BackpackProtocol

final class SlotMetadataTests: XCTestCase {
    func testCompleteMetadataDeterminesOccupancyAndSnapshotEquality() throws {
        let first = [UInt8(3)] + [9,0,0,0] + Array(repeating: UInt8(0), count: 16)
        let second = [UInt8(3)] + [10,0,0,0] + Array(repeating: UInt8(0), count: 16)
        guard case .slots(let a) = try Wire.reply([0x81,0x83,0x35] + Wire.length(first.count) + first),
              case .slots(let b) = try Wire.reply([0x81,0x83,0x35] + Wire.length(second.count) + second) else { return XCTFail("Slots") }
        XCTAssertTrue(a[0].occupied); XCTAssertNotEqual(a[0], b[0])
        XCTAssertEqual(a[0].identifier, Array(repeating: 0, count: 16))
        XCTAssertFalse(a[0].hasUsableIdentifier)
    }
    func testUnavailableMarkerIsOccupiedButNotAUsableCachedFingerprint() throws {
        let record = [UInt8(4)] + Array(repeating: UInt8(1), count: 20)
        guard case .slots(let slots) = try Wire.reply([0x81,0x83,0x35] + Wire.length(record.count) + record) else { return XCTFail("Slots") }
        XCTAssertTrue(slots[0].occupied); XCTAssertFalse(slots[0].hasUsableIdentifier)
        XCTAssertEqual(slots[0].metadataKey, Array(repeating: 1, count: 20))
    }
}
