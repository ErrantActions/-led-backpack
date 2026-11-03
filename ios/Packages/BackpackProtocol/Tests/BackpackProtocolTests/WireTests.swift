import XCTest
@testable import BackpackProtocol

final class WireTests: XCTestCase {
    struct Vectors: Decodable {
        struct Packet: Decodable { let name: String; let body: String; let sequence: UInt16; let frame: String }
        struct Length: Decodable { let length: Int; let encoded: String }
        let frames: [Packet]
        let lengths: [Length]
        let gif: String
        let hashSlot14: String
        let uploadBodies: [String]
    }

    func bytes(_ text: String) throws -> [UInt8] {
        guard text.count.isMultiple(of: 2) else { throw BackpackError.invalid("Odd hex string.") }
        var result: [UInt8] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let next = text.index(cursor, offsetBy: 2)
            guard let value = UInt8(text[cursor..<next], radix: 16) else { throw BackpackError.invalid("Invalid hex.") }
            result.append(value); cursor = next
        }
        return result
    }

    func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wire-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testJavaScriptFrameAndLengthParity() throws {
        let vectors = try vectors()
        for value in vectors.frames {
            let body = try bytes(value.body), frame = try bytes(value.frame)
            XCTAssertEqual(try Wire.frame(body, sequence: value.sequence), frame, value.name)
            XCTAssertEqual(try Wire.decode(frame).body, body)
            XCTAssertEqual(try Wire.decode(frame).sequence, value.sequence)
        }
        for value in vectors.lengths { XCTAssertEqual(try Wire.length(value.length), try bytes(value.encoded)) }
    }

    func testGIFUploadAndSlotHashParity() throws {
        let vectors = try vectors(), gif = try bytes(vectors.gif)
        XCTAssertEqual(try Wire.contentHash(gif, slot: 14), try bytes(vectors.hashSlot14))
        let messages = try Wire.upload(gif, slot: 14, size: PanelSize(width: 64, height: 64))
        XCTAssertEqual(messages, try vectors.uploadBodies.dropLast().map(bytes))
        XCTAssertEqual(try Wire.playSingle(14), try bytes(vectors.uploadBodies.last!))
    }

    func testCapturedParameterLayoutAndPlayback() throws {
        let packets = try vectors().frames
        let size = try XCTUnwrap(packets.first { $0.name == "dimensions-v291" })
        XCTAssertEqual(try Wire.reply(bytes(size.body)), .size(PanelSize(width: 64, height: 64)))
        let playback = try XCTUnwrap(packets.first { $0.name == "playback" })
        XCTAssertEqual(try Wire.reply(bytes(playback.body)), .playback(Playback(mode: 1, index: 2, ids: [2])))
    }

    func testAssemblerEverySplitAndChecksumRejection() throws {
        let raw = try bytes(vectors().frames[0].frame)
        for index in 1..<raw.count {
            var assembler = FrameAssembler()
            XCTAssertTrue(assembler.push(Array(raw.prefix(index))).frames.isEmpty)
            XCTAssertEqual(assembler.push(Array(raw.dropFirst(index))).frames.count, 1)
        }
        var bad = raw; bad[8] ^= 1
        XCTAssertThrowsError(try Wire.decode(bad))
        var assembler = FrameAssembler()
        XCTAssertEqual(assembler.push(raw + raw).frames.count, 2)
        XCTAssertFalse(assembler.push(bad).errors.isEmpty)
    }

    func testInvalidLengthsPasswordsAndSlots() throws {
        XCTAssertThrowsError(try Wire.length(65536))
        XCTAssertThrowsError(try Wire.initialize(password: "\u{0100}"))
        XCTAssertThrowsError(try Wire.playSingle(60))
        XCTAssertThrowsError(try Wire.slotQuery(page: 6))
        XCTAssertThrowsError(try Wire.reply([0x81, 0x83, 0x1B, 4, 1]))
        XCTAssertThrowsError(try Wire.bitmap(color: [0, 255, 255], x: 0, y: 0, width: 8, height: 8, mask: [1]))
    }

    func testOptionalProgramDwellDoesNotChangeDefaultUpload() throws {
        let gif = try bytes(vectors().gif)
        let messages = try Wire.upload(gif, slot: 14, size: PanelSize(width: 64, height: 64), playSeconds: 30)
        XCTAssertEqual(Array(messages[0][14..<18]), [0, 1, 30, 0])
        XCTAssertThrowsError(try Wire.upload(gif, slot: 14, size: PanelSize(width: 64, height: 64), playSeconds: 0))
    }

    func testSpeedCapAffectsDisplayOnlyAndNeverConvertsInvalidDataToZero() {
        let raw = 40.0
        XCTAssertEqual(SpeedPolicy.display(metersPerSecond: raw, age: 1, mph: true, cap: 60), 60)
        XCTAssertEqual(SpeedPolicy.display(metersPerSecond: raw, age: 1, mph: true, cap: nil), 89)
        XCTAssertEqual(raw, 40)
        XCTAssertEqual(SpeedPolicy.display(metersPerSecond: 10, age: 1, mph: false, cap: nil), 36)
        XCTAssertNil(SpeedPolicy.display(metersPerSecond: -1, age: 1, mph: true, cap: 60))
        XCTAssertNil(SpeedPolicy.display(metersPerSecond: .nan, age: 1, mph: true, cap: 60))
        XCTAssertNil(SpeedPolicy.display(metersPerSecond: 10, age: 6, mph: true, cap: 60))
    }
}
