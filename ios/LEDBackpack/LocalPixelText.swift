import Foundation
import BackpackProtocol

struct LocalPixelStamp: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

@MainActor
enum LocalPixelText {
    static func stamp(_ text: String, color: LocalPixelColor) throws -> LocalPixelStamp {
        guard !text.isEmpty, text.count <= 21, TextArtwork.canDrawPixel(text) else {
            throw BackpackError.invalid("Use 1…21 characters from the existing 5×7 ASCII pixel font. Unsupported characters are not substituted.")
        }
        let width = text.count * 6 - 1
        var rgba = [UInt8](repeating: 0, count: width * 7 * 4)
        for (index, character) in text.enumerated() {
            let rows = try TextArtwork.glyphRows(character)
            for y in 0..<7 {
                for x in 0..<5 where rows[y] & (1 << (4 - x)) != 0 {
                    let offset = (y * width + index * 6 + x) * 4
                    rgba.replaceSubrange(offset..<offset + 4, with: color.bytes)
                }
            }
        }
        return LocalPixelStamp(width: width, height: 7, rgba: rgba)
    }
}
