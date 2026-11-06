import UIKit
import BackpackProtocol

enum TextArtworkEffect: String, CaseIterable, Identifiable {
    case still = "Static", scroll = "Scrolling", breathe = "Breathe"
    case reveal = "Reveal", rainbow = "Rainbow", bounce = "Bounce"
    var id: String { rawValue }
    var animated: Bool { self != .still }
}

@MainActor
enum TextArtworkEffects {
    static func frame(_ text: String, size: PanelSize, font: ArtworkFont, alignment: ArtworkAlignment,
        color: UIColor, effect: TextArtworkEffect, phase: Double, pixelScale: Int? = nil) throws -> PixelFrame {
        guard phase.isFinite, (0...1).contains(phase) else { throw BackpackError.invalid("Invalid text-effect position.") }
        if effect == .scroll {
            return try TextArtwork.scrollingFrame(text, size: size, font: font, color: color, phase: phase, pixelScale: pixelScale)
        }
        let base = try TextArtwork.render(text, size: size, font: font, alignment: alignment, color: color, pixelScale: pixelScale)
        var result = base
        switch effect {
        case .still: break
        case .scroll: break
        case .breathe:
            let amount = 0.25 + 0.75 * (1 - cos(phase * 2 * .pi)) / 2
            result.rgb = base.rgb.map { UInt8((Double($0) * amount).rounded()) }
        case .reveal:
            let end = Int((Double(size.width) * phase).rounded())
            for y in 0..<size.height {
                for x in end..<size.width {
                    let offset = (y * size.width + x) * 3
                    result.rgb.replaceSubrange(offset..<(offset + 3), with: [0, 0, 0])
                }
            }
        case .rainbow:
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(hue: phase, saturation: 1, brightness: 1, alpha: 1)
                .getRed(&r, green: &g, blue: &b, alpha: &alpha) else {
                throw BackpackError.invalid("Could not render rainbow text.")
            }
            for pixel in 0..<(size.width * size.height) {
                let offset = pixel * 3
                let intensity = Double(base.rgb[offset..<(offset + 3)].max() ?? 0)
                result.rgb.replaceSubrange(offset..<(offset + 3),
                    with: [r, g, b].map { UInt8(max(0, min(255, Int((Double($0) * intensity).rounded())))) })
            }
        case .bounce:
            result = .black(size)
            let shift = Int((sin(phase * 2 * .pi) * Double(max(1, size.width / 12))).rounded())
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let destination = x + shift
                    if (0..<size.width).contains(destination) {
                        let source = (y * size.width + x) * 3, target = (y * size.width + destination) * 3
                        result.rgb.replaceSubrange(target..<(target + 3), with: base.rgb[source..<(source + 3)])
                    }
                }
            }
        }
        return result
    }

    static func frames(_ text: String, size: PanelSize, font: ArtworkFont, alignment: ArtworkAlignment,
        color: UIColor, effect: TextArtworkEffect, pixelScale: Int? = nil) throws -> [PixelFrame] {
        if effect == .scroll {
            return try TextArtwork.animation(text, size: size, font: font, color: color, pixelScale: pixelScale)
        }
        let count = effect.animated ? 40 : 1
        return try (0..<count).map { index in
            let phase = count == 1 ? 0 : Double(index) / Double(effect == .reveal ? count - 1 : count)
            return try frame(text, size: size, font: font, alignment: alignment, color: color,
                effect: effect, phase: phase, pixelScale: pixelScale)
        }
    }
}
