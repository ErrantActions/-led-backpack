import Foundation
import BackpackProtocol

enum GIFFrameDisposal {
    static func resettingCanvas(_ data: Data) throws -> Data {
        guard data.count <= 10_000_000 else { throw BackpackError.invalid("GIF repair input exceeds 10 MB.") }
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes.count <= 10_000_000,
              ["GIF87a", "GIF89a"].contains(String(bytes: bytes.prefix(6), encoding: .ascii) ?? "") else {
            throw BackpackError.invalid("Frame-canvas repair requires a GIF under 10 MB.")
        }
        func tableBytes(_ flags: UInt8) -> Int {
            flags & 0x80 == 0 ? 0 : 3 * (1 << (Int(flags & 7) + 1))
        }
        func blocksEnd(_ start: Int) throws -> Int {
            var offset = start
            while offset < bytes.count {
                let count = Int(bytes[offset]); offset += 1
                if count == 0 { return offset }
                guard count <= bytes.count - offset else { throw BackpackError.invalid("Truncated GIF data block.") }
                offset += count
            }
            throw BackpackError.invalid("Unterminated GIF data block.")
        }
        var offset = 13 + tableBytes(bytes[10])
        guard offset <= bytes.count else { throw BackpackError.invalid("Truncated GIF color table.") }
        var result = Array(bytes.prefix(offset))
        result.replaceSubrange(0..<6, with: Array("GIF89a".utf8))
        var hasControl = false
        var images = 0
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x21:
                guard offset + 2 < bytes.count else { throw BackpackError.invalid("Truncated GIF extension.") }
                let label = bytes[offset + 1]
                if label == 0xf9 {
                    guard offset + 8 <= bytes.count, bytes[offset + 2] == 4, bytes[offset + 7] == 0 else {
                        throw BackpackError.invalid("Invalid GIF frame control.")
                    }
                    var control = Array(bytes[offset..<(offset + 8)])
                    // Change disposal only; preserve transparency, timing and palette indexes.
                    control[3] = (control[3] & 0xe3) | 0x08
                    result += control
                    hasControl = true; offset += 8
                } else {
                    let end = try blocksEnd(offset + 2)
                    result += bytes[offset..<end]
                    if label == 1 { hasControl = false }
                    offset = end
                }
            case 0x2c:
                guard offset + 10 <= bytes.count else { throw BackpackError.invalid("Truncated GIF image descriptor.") }
                let code = offset + 10 + tableBytes(bytes[offset + 9])
                guard code < bytes.count else { throw BackpackError.invalid("Truncated GIF image palette/code size.") }
                let end = try blocksEnd(code + 1)
                if !hasControl { result += [0x21, 0xf9, 4, 8, 10, 0, 0, 0] }
                result += bytes[offset..<end]
                images += 1
                guard images <= 1200 else { throw BackpackError.invalid("GIF repair supports at most 1200 frames.") }
                hasControl = false; offset = end
            case 0x3b:
                guard images > 0 else { throw BackpackError.invalid("GIF contains no image frames.") }
                result += bytes[offset...]
                return Data(result)
            default:
                throw BackpackError.invalid("Unsupported or damaged GIF block.")
            }
        }
        throw BackpackError.invalid("GIF is missing its trailer.")
    }
}
