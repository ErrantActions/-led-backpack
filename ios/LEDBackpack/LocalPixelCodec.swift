import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

enum LocalPixelCodec {
    static let fileBudget = 5_000_000
    static func image(_ rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard (1...128).contains(width), (1...128).contains(height), rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw BackpackError.invalid("Could not allocate the bounded RGBA canvas.")
        }
        return image
    }

    static func decode(_ data: Data, attribution: Attribution? = nil) throws -> LocalPixelArtwork {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= fileBudget,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let raw = CGImageSourceGetType(source), let type = UTType(raw as String),
              [.png, .jpeg, .webP, .gif].contains(type) else {
            throw BackpackError.invalid("Import supports PNG/JPEG/WebP stills or composed GIF under 5 MB.")
        }
        let count = CGImageSourceGetCount(source)
        guard (1...120).contains(count), type == .gif || count == 1 else {
            throw BackpackError.invalid("Use 1…120-frame GIF for animation; APNG/animated WebP are unavailable.")
        }
        if type == .gif { return try LocalPixelGIF.decode(data, source: source, attribution: attribution) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...128).contains(width), (1...128).contains(height), width * height * count * 4 <= 8_000_000 else {
            throw BackpackError.invalid("Studio import requires actual dimensions 1…128 and at most 8 MB decoded RGBA. No automatic downscaling.")
        }
        var frames: [LocalPixelFrame] = []
        var actualWidth = width, actualHeight = height
        for index in 0..<count {
            try Task.checkCancellation()
            let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            guard frameProperties[kCGImagePropertyPixelWidth as String] as? Int == width,
                  frameProperties[kCGImagePropertyPixelHeight as String] as? Int == height else {
                throw BackpackError.invalid("Inconsistent source frame dimensions; no composition was guessed.")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCache: false
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                  (1...128).contains(cg.width), (1...128).contains(cg.height),
                  cg.width * cg.height == width * height else { throw BackpackError.invalid("Exact oriented source dimensions could not be decoded.") }
            actualWidth = cg.width; actualHeight = cg.height
            let rgba = try pixels(cg)
            frames.append(LocalPixelFrame(rgba: rgba))
        }
        let artwork = LocalPixelArtwork(width: actualWidth, height: actualHeight, frames: frames,
            attribution: attribution)
        try artwork.validate()
        return artwork
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard success else { throw BackpackError.invalid("Could not decode bounded RGBA pixels.") }
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[offset + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 { rgba[offset + channel] = UInt8(min(255, (Int(rgba[offset + channel]) * 255 + alpha / 2) / alpha)) }
            }
        }
        return rgba
    }

    static func png(_ artwork: LocalPixelArtwork, frame: Int) throws -> Data {
        try Task.checkCancellation(); try artwork.validate()
        guard artwork.frames.indices.contains(frame) else { throw BackpackError.invalid("Choose an existing frame for PNG export.") }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
            throw BackpackError.invalid("PNG exporter unavailable.")
        }
        let cg = try image(artwork.frames[frame].rgba, width: artwork.width, height: artwork.height)
        var properties: [CFString: Any] = [:]
        if let attribution = artwork.attribution {
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGAuthor: attribution.author,
                kCGImagePropertyPNGDescription: String(decoding: try JSONEncoder().encode(attribution), as: UTF8.self)
            ]
        }
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), result.length <= fileBudget else {
            throw BackpackError.invalid("PNG export failed or exceeded 5 MB. Artwork unchanged.")
        }
        return result as Data
    }

    // Independent full-canvas frames, exact per-frame palettes and clear/literal LZW avoid lossy quantization.
    // GIF cannot represent partial alpha or more than 256 colors: reject, never flatten silently.
    static func gif(_ artwork: LocalPixelArtwork) throws -> Data {
        try artwork.validate(); try Task.checkCancellation()
        func le(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255)] }
        var bytes = Array("GIF89a".utf8) + le(artwork.width) + le(artwork.height)
        bytes += [0x80, 0, 0, 0, 0, 0, 0, 0, 0]
        if let repeats = artwork.repeats {
            bytes += [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1] + le(repeats) + [0]
        }
        func blocks(_ payload: [UInt8]) -> [UInt8] {
            var result: [UInt8] = []
            for start in stride(from: 0, to: payload.count, by: 255) {
                let end = min(start + 255, payload.count)
                result.append(UInt8(end - start)); result += payload[start..<end]
            }
            result.append(0); return result
        }
        if let attribution = artwork.attribution {
            bytes += [0x21, 0xFE] + blocks(Array(try JSONEncoder().encode(attribution)))
        }
        let transparentAnimation = artwork.frames.contains { frame in
            stride(from: 3, to: frame.rgba.count, by: 4).contains { frame.rgba[$0] == 0 }
        }
        for frame in artwork.frames {
            try Task.checkCancellation()
            var palette: [LocalPixelColor] = [], lookup: [LocalPixelColor: UInt8] = [:], indices: [UInt8] = []
            // Reserve a transparent backing even for opaque frames in a mixed animation,
            // so disposal 2 never leaves an opaque background under the next RGBA frame.
            let transparent = transparentAnimation
            if transparent { palette = [.clear]; lookup[.clear] = 0 }
            for offset in stride(from: 0, to: frame.rgba.count, by: 4) {
                let alpha = frame.rgba[offset + 3]
                guard alpha == 0 || alpha == 255 else {
                    throw BackpackError.invalid("GIF has only binary transparency. This artwork has partial alpha; use PNG or edit alpha explicitly. No export was saved.")
                }
                let color = alpha == 0 ? .clear : LocalPixelColor(r: frame.rgba[offset], g: frame.rgba[offset + 1], b: frame.rgba[offset + 2], a: alpha)
                if lookup[color] == nil {
                    guard palette.count < 256 else {
                        throw BackpackError.invalid(transparent
                            ? "Exact GIF export with transparency reserves one entry per frame: at most 255 opaque colors. Use PNG or explicitly simplify the palette; no automatic quantization."
                            : "A frame exceeds GIF's 256-color palette. Use PNG or explicitly simplify the palette; no automatic quantization.")
                    }
                    lookup[color] = UInt8(palette.count); palette.append(color)
                }
                guard let index = lookup[color] else { throw BackpackError.invalid("Could not construct exact GIF palette.") }
                indices.append(index)
            }
            bytes += [0x21, 0xF9, 4, transparent ? 9 : 8] + le(frame.centiseconds) + [0, 0]
            bytes += [0x2C, 0, 0, 0, 0] + le(artwork.width) + le(artwork.height) + [0x87]
            for index in 0..<256 {
                let color = index < palette.count ? palette[index] : .clear
                bytes += [color.r, color.g, color.b]
            }
            var compressed: [UInt8] = [], accumulator = 0, bits = 0
            func code(_ value: Int) {
                accumulator |= value << bits; bits += 9
                while bits >= 8 { compressed.append(UInt8(accumulator & 255)); accumulator >>= 8; bits -= 8 }
            }
            for index in indices { code(256); code(Int(index)) }
            code(257)
            if bits > 0 { compressed.append(UInt8(accumulator & 255)) }
            bytes += [8] + blocks(compressed)
            guard bytes.count < fileBudget else { throw BackpackError.invalid("GIF output exceeds 5 MB; shorten the animation explicitly.") }
        }
        bytes.append(0x3B)
        return Data(bytes)
    }
}
