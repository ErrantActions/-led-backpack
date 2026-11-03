import Foundation
import UIKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

struct RGB8: Codable, Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var bytes: [UInt8] { [r, g, b] }
    static let black = RGB8(r: 0, g: 0, b: 0)
}

enum BackgroundRemoval: String, CaseIterable, Identifiable {
    case off = "Keep background", color = "Selected color", edge = "Edge-connected color"
    var id: String { rawValue }
}
enum GIFDirection: String, CaseIterable, Identifiable {
    case forward = "Forward", reverse = "Reverse", pingPong = "Ping-pong"
    var id: String { rawValue }
}

struct CleanupOptions {
    var removal = BackgroundRemoval.off
    var key = RGB8(r: 255, g: 255, b: 255)
    var tolerance = 0.1
    var trimHalos = false
    var haloThreshold = 30
    var removeIsolated = false
    var edgeRegion: PixelRegion?
}

struct PixelRegion {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

enum GIFCleanup {
    static func apply(_ source: PixelFrame, options: CleanupOptions, touches: [Int: RGB8] = [:]) throws -> PixelFrame {
        let w = source.size.width, h = source.size.height
        guard w > 0, h > 0, source.rgb.count == w * h * 3,
              options.tolerance.isFinite, (0...1).contains(options.tolerance),
              (0...255).contains(options.haloThreshold) else {
            throw BackpackError.invalid("Invalid cleanup pixels, tolerance or threshold.")
        }
        var result = source
        let threshold = Int(options.tolerance * 442)
        func matches(_ pixel: Int) -> Bool {
            let offset = pixel * 3
            let dr = Int(source.rgb[offset]) - Int(options.key.r)
            let dg = Int(source.rgb[offset + 1]) - Int(options.key.g)
            let db = Int(source.rgb[offset + 2]) - Int(options.key.b)
            return dr * dr + dg * dg + db * db <= threshold * threshold
        }
        func neighbors(_ pixel: Int) -> [Int] {
            let x = pixel % w, y = pixel / w
            var values: [Int] = []
            if x > 0 { values.append(pixel - 1) }
            if x + 1 < w { values.append(pixel + 1) }
            if y > 0 { values.append(pixel - w) }
            if y + 1 < h { values.append(pixel + w) }
            return values
        }
        var removed = [Bool](repeating: false, count: w * h)
        if options.removal == .color {
            for pixel in 0..<(w * h) { removed[pixel] = matches(pixel) }
        } else if options.removal == .edge {
            let region = options.edgeRegion ?? PixelRegion(x: 0, y: 0, width: w, height: h)
            guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
                  region.x + region.width <= w, region.y + region.height <= h else {
                throw BackpackError.invalid("Background cleanup region is outside the canvas.")
            }
            func inside(_ pixel: Int) -> Bool {
                let x = pixel % w, y = pixel / w
                return x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height
            }
            var queue: [Int] = []
            for pixel in 0..<(w * h) where inside(pixel) && (pixel % w == region.x || pixel % w == region.x + region.width - 1
                || pixel / w == region.y || pixel / w == region.y + region.height - 1) {
                if matches(pixel), !removed[pixel] { removed[pixel] = true; queue.append(pixel) }
            }
            var head = 0
            while head < queue.count {
                let pixel = queue[head]; head += 1
                for next in neighbors(pixel) where inside(next) && !removed[next] && matches(next) {
                    removed[next] = true; queue.append(next)
                }
            }
        }
        for pixel in 0..<(w * h) where removed[pixel] {
            result.rgb.replaceSubrange((pixel * 3)..<(pixel * 3 + 3), with: [0, 0, 0])
        }
        let afterRemoval = result.rgb
        func lit(_ pixel: Int) -> Bool { afterRemoval[(pixel * 3)..<(pixel * 3 + 3)].contains { $0 != 0 } }
        for pixel in 0..<(w * h) where lit(pixel) {
            let adjacent = neighbors(pixel)
            let halo = options.trimHalos && afterRemoval[(pixel * 3)..<(pixel * 3 + 3)].max()! <= UInt8(options.haloThreshold)
                && adjacent.contains { !lit($0) }
            let isolated = options.removeIsolated && adjacent.filter(lit).count <= 1
            if halo || isolated {
                result.rgb.replaceSubrange((pixel * 3)..<(pixel * 3 + 3), with: [0, 0, 0])
            }
        }
        for (pixel, color) in touches {
            guard (0..<(w * h)).contains(pixel) else { throw BackpackError.invalid("Manual touch is outside the canvas.") }
            result.rgb.replaceSubrange((pixel * 3)..<(pixel * 3 + 3), with: color.bytes)
        }
        return result
    }

    static func timing(delays: [Double], first: Int, last: Int, speed: Double,
        overrides: [Int: Double], direction: GIFDirection) throws -> [(index: Int, delay: Double)] {
        guard first >= 0, last < delays.count, first <= last, speed.isFinite, (0.25...4).contains(speed),
              delays.allSatisfy({ $0.isFinite && $0 > 0 }),
              overrides.keys.allSatisfy({ (0..<delays.count).contains($0) }),
              overrides.values.allSatisfy({ $0.isFinite && (0.02...10).contains($0) }) else {
            throw BackpackError.invalid("Invalid GIF timing or frame range.")
        }
        var order = Array(first...last)
        if direction == .reverse { order.reverse() }
        if direction == .pingPong, order.count > 2 { order += order.dropFirst().dropLast().reversed() }
        guard order.count <= 120 else { throw BackpackError.invalid("Trim the animation: this direction would exceed 120 output frames.") }
        return order.map { ($0, max(0.02, min(10, (overrides[$0] ?? delays[$0]) / speed))) }
    }
}

enum SubjectCutout {
    static func png(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw BackpackError.invalid("Subject cutout could not decode the source frame.")
                }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                let request = VNGenerateForegroundInstanceMaskRequest()
                try handler.perform([request])
                guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                    throw BackpackError.invalid("No foreground subject found. Use color-key or manual cleanup for this frame.")
                }
                let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
                let input = CIImage(cgImage: image)
                let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: input.extent)
                guard let filter = CIFilter(name: "CIBlendWithMask", parameters: [
                    kCIInputImageKey: input, kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask)
                ]), let output = filter.outputImage,
                      let cg = CIContext().createCGImage(output, from: input.extent) else {
                    throw BackpackError.invalid("Subject mask rendering failed.")
                }
                let bytes = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
                    throw BackpackError.invalid("Subject cutout PNG encoder is unavailable.")
                }
                CGImageDestinationAddImage(destination, cg, nil)
                guard CGImageDestinationFinalize(destination) else { throw BackpackError.invalid("Could not encode the subject mask.") }
                try Task.checkCancellation()
                return bytes as Data
            }
        }.value
    }
}
