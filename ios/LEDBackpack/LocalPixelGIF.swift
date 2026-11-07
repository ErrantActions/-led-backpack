import Foundation
import ImageIO
import BackpackProtocol

// The shared structural reader owns block validation. ImageIO owns LZW/palette/interlace
// decoding; this local editor alone materializes independent logical-canvas RGBA frames.
enum LocalPixelGIF {
    private struct Rectangle {
        let x, y, width, height: Int
    }

    static func decode(_ data: Data, source: CGImageSource, attribution: Attribution?) throws -> LocalPixelArtwork {
        try Task.checkCancellation()
        guard data.count <= LocalPixelCodec.fileBudget else { throw BackpackError.invalid("GIF exceeds the 5 MB input budget.") }
        let structure = try GIFStructure.inspect(data), bytes = [UInt8](data)
        func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        let width = word(6), height = word(8), count = structure.frames.count
        guard (1...128).contains(width), (1...128).contains(height), (1...120).contains(count),
              CGImageSourceGetCount(source) == count, width * height * count * 4 <= 8_000_000 else {
            throw BackpackError.invalid("GIF import requires 1…128 logical-canvas sides, 1…120 frames and at most 8 MB decoded RGBA. No resizing or frame dropping.")
        }
        func tableBytes(_ flags: UInt8) -> Int { flags & 0x80 == 0 ? 0 : 3 * (1 << (Int(flags & 7) + 1)) }
        let globalTableBytes = tableBytes(bytes[10]), headerEnd = 13 + globalTableBytes
        let backgroundIndex = Int(bytes[11])
        guard globalTableBytes == 0 || backgroundIndex < globalTableBytes / 3 else {
            throw BackpackError.invalid("GIF background index is outside the global color table.")
        }
        let background: LocalPixelColor
        if globalTableBytes > 0 {
            let offset = 13 + backgroundIndex * 3
            background = LocalPixelColor(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], a: 255)
        } else { background = .clear }

        func blocksEnd(_ start: Int) throws -> Int {
            var cursor = start
            while cursor < bytes.count {
                let length = Int(bytes[cursor]); cursor += 1
                if length == 0 { return cursor }
                guard length <= bytes.count - cursor else { throw BackpackError.invalid("Truncated GIF image data.") }
                cursor += length
            }
            throw BackpackError.invalid("GIF image data has no terminator.")
        }
        var repeats: Int?
        func checkExtensions(from start: Int, to end: Int) throws {
            var cursor = start
            while cursor < end {
                guard cursor + 2 < bytes.count, bytes[cursor] == 0x21 else {
                    throw BackpackError.invalid("Unexpected GIF block between image frames.")
                }
                guard bytes[cursor + 1] != 0x01 else {
                    throw BackpackError.invalid("GIF plain-text rendering blocks are unavailable in the pixel studio. Original bytes retained.")
                }
                let extensionEnd = try blocksEnd(cursor + 2)
                guard extensionEnd <= end else { throw BackpackError.invalid("GIF extension overlaps an image descriptor.") }
                if bytes[cursor + 1] == 0xFF, bytes[cursor + 2] == 11 {
                    let identifier = String(bytes: bytes[cursor + 3..<cursor + 14], encoding: .ascii)
                    if identifier == "NETSCAPE2.0" || identifier == "ANIMEXTS1.0" {
                        var block = cursor + 14
                        while block < extensionEnd, bytes[block] != 0 {
                            let length = Int(bytes[block])
                            if bytes[block + 1] == 1 {
                                guard length == 3 else { throw BackpackError.invalid("GIF loop extension has an invalid repeat block.") }
                                let value = word(block + 2)
                                guard repeats == nil || repeats == value else {
                                    throw BackpackError.invalid("GIF contains conflicting repeat extensions; no loop behavior was guessed.")
                                }
                                repeats = value
                            }
                            block += length + 1
                        }
                    }
                }
                cursor = extensionEnd
            }
        }

        // A transparent first graphic exposes the transparent backing surface. An opaque
        // graphic uses the declared logical-screen background. Disposal 2 uses that frame's
        // transparent backing when present, otherwise the declared background color.
        let initialBackground = structure.frames[0].transparent ? LocalPixelColor.clear : background
        var canvas = Array(repeating: initialBackground.bytes, count: width * height).flatMap { $0 }
        var frames: [LocalPixelFrame] = [], cursor = headerEnd
        for frame in structure.frames {
            try Task.checkCancellation()
            try checkExtensions(from: cursor, to: frame.imageOffset)
            guard (0...3).contains(frame.disposal) else {
                throw BackpackError.invalid("GIF uses reserved disposal code \(frame.disposal); composition is undefined. Original retained.")
            }
            if let control = frame.controlOffset, bytes[control + 3] & 2 != 0 {
                throw BackpackError.invalid("GIF waits for user input; interactive GIF timing is unavailable. Original retained.")
            }
            let offset = frame.imageOffset
            let rect = Rectangle(x: word(offset + 1), y: word(offset + 3), width: word(offset + 5), height: word(offset + 7))
            guard rect.width > 0, rect.height > 0, rect.x + rect.width <= width, rect.y + rect.height <= height else {
                throw BackpackError.invalid("A GIF image rectangle lies outside its logical canvas. No clipping or dimension widening was applied.")
            }
            let localTableBytes = tableBytes(bytes[offset + 9])
            let paletteCount = (localTableBytes > 0 ? localTableBytes : globalTableBytes) / 3
            guard paletteCount > 0 else { throw BackpackError.invalid("GIF frame has no active color table.") }
            if frame.transparent, let control = frame.controlOffset {
                guard Int(bytes[control + 6]) < paletteCount else {
                    throw BackpackError.invalid("GIF transparent index is outside its active color table.")
                }
            }
            let codeOffset = offset + 10 + localTableBytes
            guard (2...8).contains(Int(bytes[codeOffset])) else { throw BackpackError.invalid("Invalid GIF LZW minimum code size.") }
            let end = try blocksEnd(codeOffset + 1)

            // Isolate exactly one encoded patch at (0,0), retaining both palettes and
            // interlacing. This avoids depending on undocumented ImageIO multi-frame
            // coalescing or accidentally applying disposal twice.
            let patch: [UInt8] = try autoreleasepool {
                var isolated = Array(bytes[0..<headerEnd])
                isolated.replaceSubrange(0..<6, with: Array("GIF89a".utf8))
                isolated[6] = UInt8(rect.width & 255); isolated[7] = UInt8(rect.width >> 8)
                isolated[8] = UInt8(rect.height & 255); isolated[9] = UInt8(rect.height >> 8)
                if let control = frame.controlOffset {
                    var graphic = Array(bytes[control..<control + 8])
                    graphic[3] &= 1
                    isolated += graphic
                }
                var descriptor = Array(bytes[offset..<end])
                descriptor[1] = 0; descriptor[2] = 0; descriptor[3] = 0; descriptor[4] = 0
                isolated += descriptor; isolated.append(0x3B)
                guard let imageSource = CGImageSourceCreateWithData(Data(isolated) as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateImageAtIndex(imageSource, 0,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                      image.width == rect.width, image.height == rect.height,
                      CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete else {
                    throw BackpackError.invalid("ImageIO could not decode a complete GIF patch at its exact dimensions.")
                }
                return try LocalPixelCodec.pixels(image)
            }
            try Task.checkCancellation()
            let previous = frame.disposal == 3 ? canvas : nil
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let input = (y * rect.width + x) * 4
                    guard patch[input + 3] == 0 || patch[input + 3] == 255 else {
                        throw BackpackError.invalid("ImageIO returned non-binary GIF alpha. Previous artwork retained.")
                    }
                    if patch[input + 3] == 0 {
                        guard frame.transparent else { throw BackpackError.invalid("Opaque GIF patch decoded with unexpected transparency.") }
                        continue
                    }
                    let output = ((rect.y + y) * width + rect.x + x) * 4
                    canvas.replaceSubrange(output..<output + 4, with: patch[input..<input + 4])
                }
            }
            frames.append(LocalPixelFrame(rgba: canvas, centiseconds: frame.delayCentiseconds ?? 10))
            if frame.disposal == 2 {
                let clear = frame.transparent ? LocalPixelColor.clear : background
                for y in rect.y..<rect.y + rect.height {
                    for x in rect.x..<rect.x + rect.width {
                        let output = (y * width + x) * 4
                        canvas.replaceSubrange(output..<output + 4, with: clear.bytes)
                    }
                }
            } else if let previous { canvas = previous }
            cursor = end
        }
        var tail = cursor
        while tail < bytes.count, bytes[tail] == 0x21 { tail = try blocksEnd(tail + 2) }
        guard tail < bytes.count, bytes[tail] == 0x3B else { throw BackpackError.invalid("Unexpected trailing GIF block.") }
        try checkExtensions(from: cursor, to: tail)
        let artwork = LocalPixelArtwork(width: width, height: height, frames: frames,
            repeats: repeats, attribution: attribution)
        try artwork.validate()
        return artwork
    }
}
