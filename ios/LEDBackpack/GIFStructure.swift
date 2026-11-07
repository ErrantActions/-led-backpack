import Foundation
import BackpackProtocol

struct GIFStructure {
    struct Frame {
        let imageOffset: Int
        let controlOffset: Int?
        let delayCentiseconds: Int?
        let disposal: Int
        let transparent, interlaced: Bool
        var previewDelay: Double { Double(max(1, delayCentiseconds ?? 10)) / 100 }
    }
    let frames: [Frame]
    static func isGIF(_ data: Data) -> Bool {
        ["GIF87a", "GIF89a"].contains(String(data: data.prefix(6), encoding: .ascii) ?? "")
    }
    static func inspect(_ data: Data) throws -> GIFStructure {
        guard data.count <= 10_000_000, data.count >= 13, isGIF(data) else {
            throw BackpackError.invalid("GIF inspection requires a complete GIF under 10 MB.")
        }
        let bytes = [UInt8](data)
        func tableBytes(_ flags: UInt8) -> Int { flags & 0x80 == 0 ? 0 : 3 * (1 << (Int(flags & 7) + 1)) }
        func endOfBlocks(_ start: Int) throws -> Int {
            var offset = start
            while offset < bytes.count {
                let count = Int(bytes[offset]); offset += 1
                if count == 0 { return offset }
                guard count <= bytes.count - offset else { throw BackpackError.invalid("Truncated GIF sub-block.") }
                offset += count
            }
            throw BackpackError.invalid("Unterminated GIF sub-block.")
        }
        var offset = 13 + tableBytes(bytes[10]), control: Int?
        guard offset <= bytes.count else { throw BackpackError.invalid("Truncated GIF global palette.") }
        var frames: [Frame] = []
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x21:
                guard offset + 2 < bytes.count else { throw BackpackError.invalid("Truncated GIF extension.") }
                let label = bytes[offset + 1]
                if label == 0xF9 {
                    guard offset + 8 <= bytes.count, bytes[offset + 2] == 4, bytes[offset + 7] == 0 else {
                        throw BackpackError.invalid("Invalid GIF graphic control.")
                    }
                    control = offset; offset += 8
                } else {
                    offset = try endOfBlocks(offset + 2)
                    if label == 1 { control = nil }
                }
            case 0x2C:
                guard offset + 10 <= bytes.count else { throw BackpackError.invalid("Truncated GIF image descriptor.") }
                let flags = bytes[offset + 9], codeOffset = offset + 10 + tableBytes(flags)
                guard codeOffset < bytes.count else { throw BackpackError.invalid("Truncated GIF local palette/code size.") }
                let end = try endOfBlocks(codeOffset + 1)
                frames.append(Frame(imageOffset: offset, controlOffset: control,
                    delayCentiseconds: control.map { Wire.u16(bytes, $0 + 4) },
                    disposal: control.map { Int((bytes[$0 + 3] >> 2) & 7) } ?? 0,
                    transparent: control.map { bytes[$0 + 3] & 1 != 0 } ?? false,
                    interlaced: flags & 0x40 != 0))
                guard frames.count <= 1200 else { throw BackpackError.invalid("GIF inspection supports at most 1200 image frames.") }
                control = nil; offset = end
            case 0x3B:
                guard !frames.isEmpty else { throw BackpackError.invalid("GIF has no image frames.") }
                return GIFStructure(frames: frames)
            default: throw BackpackError.invalid("Unsupported or damaged GIF block.")
            }
        }
        throw BackpackError.invalid("GIF is missing its trailer.")
    }
    var backpackWarnings: [String] {
        var notes: [String] = []
        let long = frames.filter { ($0.delayCentiseconds ?? 0) > 6553 }.count
        let zero = frames.filter { $0.delayCentiseconds == 0 }.count
        let previous = frames.filter { $0.disposal == 3 }.count
        let missing = frames.filter { $0.controlOffset == nil }.count
        let reserved = frames.filter { $0.disposal > 3 }.count
        if long > 0 { notes.append("\(long) frame pause(s) exceed 65.53 seconds. Recovered V2.9.1 firmware wraps its 16-bit delay; backpack timing may differ substantially.") }
        if zero > 0 { notes.append("\(zero) frame(s) specify zero delay. The backpack uses a firmware-specific fallback whose actual duration is unverified; the phone uses its own minimum display interval.") }
        if previous > 0 { notes.append("\(previous) frame(s) restore previous pixels. Complete firmware disposal behavior is unverified; inspect for trails. Frame-canvas cleanup remains an explicit new-copy editor action.") }
        if frames.count > 1 && missing > 0 { notes.append("\(missing) animation frame(s) have no graphic control. Phone previews use a 0.1-second default; device handling is unverified and may differ.") }
        if reserved > 0 { notes.append("\(reserved) frame(s) use reserved disposal codes. Their device rendering is not established; no automatic repair is applied.") }
        return notes
    }
    static func requireBackpackConsent(_ data: Data, approved: Bool) throws {
        let notes = try inspect(data).backpackWarnings
        guard approved || notes.isEmpty else {
            throw BackpackError.invalid("Review backpack GIF compatibility and explicitly acknowledge before any slot is changed. " + notes.joined(separator: " "))
        }
    }
}
