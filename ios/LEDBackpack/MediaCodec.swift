import UIKit
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

struct PixelFrame: Equatable {
    let size: PanelSize
    var rgb: [UInt8]
    var exactLiveColors = false

    func resolvedLive() -> PixelFrame {
        var result = self
        if !exactLiveColors { result.rgb = rgb.map { $0 >= 128 ? 255 : 0 } }
        result.exactLiveColors = true
        return result
    }

    static func black(_ size: PanelSize) -> PixelFrame {
        PixelFrame(size: size, rgb: Array(repeating: 0, count: size.width * size.height * 3))
    }

    @MainActor func image() throws -> UIImage {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(size.width * size.height * 4)
        for offset in stride(from: 0, to: rgb.count, by: 3) {
            rgba += [rgb[offset], rgb[offset + 1], rgb[offset + 2], 255]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw BackpackError.invalid("Could not allocate a preview image.")
        }
        return UIImage(cgImage: image)
    }
}

@MainActor
enum MediaCodec {
    static let renderSizes = [PanelSize(width: 16, height: 16), PanelSize(width: 64, height: 64), PanelSize(width: 96, height: 128)]
    struct Animation {
        var images: [UIImage]
        var delays: [Double]
    }
    enum Fit: String, CaseIterable, Identifiable {
        case fit, fill
        var id: String { rawValue }
    }

    static func decode(_ data: Data) throws -> Animation {
        guard data.count <= 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw BackpackError.invalid("Choose a supported image/GIF smaller than 10 MB.")
        }
        let count = CGImageSourceGetCount(source)
        guard (1...120).contains(count) else { throw BackpackError.invalid("Choose media with 1 to 120 frames.") }
        var images: [UIImage] = [], delays: [Double] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            guard width > 0, height > 0, width <= 4096, height <= 4096 else {
                throw BackpackError.invalid("Image dimensions must be at most 4096 x 4096.")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw BackpackError.invalid("Could not decode frame \(index + 1).")
            }
            images.append(UIImage(cgImage: cg))
            let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] ?? [:]
            let delay = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                ?? gif[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.1
            delays.append(max(0.02, min(10, delay)))
        }
        return Animation(images: images, delays: delays)
    }

    static func canvas(_ size: PanelSize, paint: (CGContext) throws -> Void) throws -> PixelFrame {
        guard renderSizes.contains(size) else {
            throw BackpackError.invalid("Rendering supports 16x16, 64x64 and 96x128 panels.")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(size.width), height: CGFloat(size.height)), format: format)
        var paintFailure: Error?
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)))
            context.cgContext.setShouldAntialias(false)
            do { try paint(context.cgContext) }
            catch { paintFailure = error }
        }
        if let paintFailure { throw paintFailure }
        guard let cg = image.cgImage else { throw BackpackError.invalid("Could not render pixels.") }
        var rgba = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // PixelFrame rows already follow the rendered CGImage's top-down order.
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(size.width), height: CGFloat(size.height)))
            return true
        }
        guard success else { throw BackpackError.invalid("Could not allocate pixel buffer.") }
        var rgb = [UInt8](repeating: 0, count: size.width * size.height * 3)
        for index in 0..<(size.width * size.height) {
            for channel in 0..<3 { rgb[index * 3 + channel] = rgba[index * 4 + channel] }
        }
        return PixelFrame(size: size, rgb: rgb)
    }

    static func transform(_ image: UIImage, size: PanelSize, fit: Fit, turns: Int, brightness: Double) throws -> PixelFrame {
        var frame = try canvas(size) { context in
            let center = CGPoint(x: CGFloat(size.width) / 2, y: CGFloat(size.height) / 2)
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: CGFloat(turns % 4) * .pi / 2)
            let rotated = !turns.isMultiple(of: 2)
            let available = CGSize(width: CGFloat(rotated ? size.height : size.width), height: CGFloat(rotated ? size.width : size.height))
            let ratio = fit == .fit
                ? min(available.width / image.size.width, available.height / image.size.height)
                : max(available.width / image.size.width, available.height / image.size.height)
            let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: -target.width / 2, y: -target.height / 2, width: target.width, height: target.height))
        }

        frame.rgb = frame.rgb.map { UInt8(max(0, min(255, Int(Double($0) * brightness)))) }
        return frame
    }

    static func footprint(_ image: UIImage, size: PanelSize, fit: Fit, turns: Int) -> PixelRegion {
        if fit == .fill { return PixelRegion(x: 0, y: 0, width: size.width, height: size.height) }
        let rotated = !turns.isMultiple(of: 2)
        let width = rotated ? image.size.height : image.size.width
        let height = rotated ? image.size.width : image.size.height
        let ratio = min(CGFloat(size.width) / width, CGFloat(size.height) / height)
        let x = max(0, Int(((CGFloat(size.width) - width * ratio) / 2).rounded(.down)))
        let y = max(0, Int(((CGFloat(size.height) - height * ratio) / 2).rounded(.down)))
        return PixelRegion(x: x, y: y, width: min(size.width - x, max(1, Int((width * ratio).rounded(.up)))),
            height: min(size.height - y, max(1, Int((height * ratio).rounded(.up)))))
    }

    static func encode(_ frames: [PixelFrame], delays: [Double], loopCount: Int = 0) throws -> Data {
        guard !frames.isEmpty, frames.count <= 120, frames.count == delays.count,
              frames.allSatisfy({ $0.size == frames[0].size }), (0...65535).contains(loopCount),
              delays.allSatisfy({ $0.isFinite && (0.02...10).contains($0) }) else {
            throw BackpackError.invalid("Invalid animation frames or timings.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw BackpackError.invalid("GIF encoder is unavailable.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary)
        for (index, frame) in frames.enumerated() {
            guard let image = try frame.image().cgImage else { throw BackpackError.invalid("Could not encode frame.") }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: max(0.02, delays[index])]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw BackpackError.invalid("GIF encoding failed.") }
        guard data.length <= 5_000_000 else { throw BackpackError.invalid("Encoded GIF exceeds the 5 MB app limit.") }
        return data as Data
    }

    static func text(_ text: String, subtitle: String = "", size: PanelSize, color: UIColor = .cyan, offset: CGFloat = 0) throws -> PixelFrame {
        try canvas(size) { _ in
            let maximum = CGFloat(size.height) * (subtitle.isEmpty ? 0.7 : 0.48)
            let count = max(1, text.count)
            let pointSize = max(5, min(maximum, CGFloat(size.width) * 1.5 / CGFloat(count)))
            let font = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let bounds = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (CGFloat(size.width) - bounds.width) / 2 + offset,
                y: (CGFloat(size.height) - bounds.height) / 2 - (subtitle.isEmpty ? 0 : CGFloat(size.height) * 0.12)),
                withAttributes: attributes)
            if !subtitle.isEmpty {
                let small: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: max(5, CGFloat(size.height) * 0.13), weight: .medium),
                    .foregroundColor: color
                ]
                let label = (subtitle as NSString).size(withAttributes: small)
                (subtitle as NSString).draw(at: CGPoint(x: (CGFloat(size.width) - label.width) / 2,
                    y: CGFloat(size.height) * 0.76), withAttributes: small)
            }
        }
    }

    static func marquee(_ text: String, subtitle: String, size: PanelSize, color: UIColor = .cyan, phase: Double) throws -> PixelFrame {
        try canvas(size) { _ in
            let font = UIFont.monospacedSystemFont(ofSize: max(6, CGFloat(size.height) * 0.4), weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let bounds = (text as NSString).size(withAttributes: attributes)
            let travel = CGFloat(size.width) + bounds.width
            (text as NSString).draw(at: CGPoint(x: CGFloat(size.width) - CGFloat(phase) * travel,
                y: CGFloat(size.height) * 0.18), withAttributes: attributes)
            let small: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: max(5, CGFloat(size.height) * 0.12), weight: .medium),
                .foregroundColor: color
            ]
            (subtitle as NSString).draw(at: CGPoint(x: 1, y: CGFloat(size.height) * 0.78), withAttributes: small)
        }
    }

    static func delta(from previous: PixelFrame, to target: PixelFrame) throws -> [[UInt8]] {
        guard previous.size == target.size else { throw BackpackError.invalid("Live frame size changed.") }
        let size = target.size
        var groups: [Int: [Int]] = [:]
        for pixel in 0..<(size.width * size.height) {
            let offset = pixel * 3
            let old = (0..<3).map { previous.exactLiveColors ? Int(previous.rgb[offset + $0]) : previous.rgb[offset + $0] >= 128 ? 255 : 0 }
            let next = (0..<3).map { target.exactLiveColors ? Int(target.rgb[offset + $0]) : target.rgb[offset + $0] >= 128 ? 255 : 0 }
            if old == next { continue }
            let color = next[0] << 16 | next[1] << 8 | next[2]
            groups[color, default: []].append(pixel)
        }
        var bodies: [[UInt8]] = []
        let colors = groups.keys.filter { $0 != 0 }.sorted() + (groups[0] == nil ? [] : [0])
        for color in colors {
            guard let pixels = groups[color], !pixels.isEmpty else { continue }
            let xs = pixels.map { $0 % size.width }, ys = pixels.map { $0 / size.width }
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { continue }
            let width = x1 - x0 + 1, strideBytes = (width + 7) / 8
            let rows = max(1, 112 / strideBytes)
            for top in stride(from: y0, through: y1, by: rows) {
                let bottom = min(y1, top + rows - 1)
                var mask = [UInt8](repeating: 0, count: strideBytes * (bottom - top + 1))
                for pixel in pixels {
                    let y = pixel / size.width, x = pixel % size.width
                    if y >= top && y <= bottom {
                        mask[(y - top) * strideBytes + (x - x0) / 8] |= 128 >> ((x - x0) % 8)
                    }
                }
                if mask.allSatisfy({ $0 == 0 }) { continue }
                bodies.append(try Wire.bitmap(color: [UInt8((color >> 16) & 255), UInt8((color >> 8) & 255), UInt8(color & 255)],
                    x: x0, y: top, width: width, height: bottom - top + 1, mask: mask))
            }
        }
        return bodies
    }
}
