import Foundation
import BackpackProtocol

enum InkEffect: String, Codable, Hashable, CaseIterable, Identifiable {
    case solid = "Solid", morph = "Color morph", rainbow = "Rainbow sweep"
    case stripes = "Moving stripes", checker = "Checker", sparkle = "Pixel sparkle"
    var id: String { rawValue }
}

enum GaugeStyle: String, Codable, Hashable, CaseIterable, Identifiable {
    case none = "None", bar = "Bar", arc = "Arc"
    var id: String { rawValue }
}

extension PixelInk {
    var rgb: [UInt8] {
        switch self {
        case .black: return [0, 0, 0]
        case .white: return [255, 255, 255]
        case .cyan: return [0, 255, 255]
        case .magenta: return [255, 0, 255]
        case .green: return [0, 255, 0]
        case .yellow: return [255, 255, 0]
        case .red: return [255, 0, 0]
        case .blue: return [0, 0, 255]
        }
    }
}

enum InkPainter {
    static func apply(_ template: PixelFrame, theme: LiveTheme, phase: Double) -> PixelFrame {
        var result = PixelFrame.black(template.size)
        result.exactLiveColors = true
        let ink = theme.foreground.rgb, background = theme.background.rgb, accent = theme.accent.rgb
        let cycle = phase * theme.colorSpeed
        let rainbow: [[UInt8]] = [[255, 0, 0], [255, 255, 0], [0, 255, 0], [0, 255, 255], [0, 0, 255], [255, 0, 255]]
        for pixel in 0..<(template.size.width * template.size.height) {
            let offset = pixel * 3
            let inkDistance = (0..<3).reduce(0) { $0 + abs(Int(template.rgb[offset + $1]) - Int(ink[$1])) }
            let backgroundDistance = (0..<3).reduce(0) { $0 + abs(Int(template.rgb[offset + $1]) - Int(background[$1])) }
            var color = background
            if inkDistance < backgroundDistance {
                let x = pixel % template.size.width, y = pixel / template.size.width
                switch theme.inkEffect {
                case .solid: color = ink
                case .morph:
                    let blend = (sin(cycle * .pi * 2) + 1) / 2
                    color = (0..<3).map { UInt8(max(0, min(255, Int((Double(ink[$0]) * (1 - blend) + Double(accent[$0]) * blend).rounded())))) }
                case .rainbow:
                    color = rainbow[(x / 4 + y / 6 + Int(cycle * 12)) % rainbow.count]
                case .stripes:
                    color = (x + y + Int(cycle * 24)) / 4 % 2 == 0 ? ink : accent
                case .checker:
                    color = (x / 4 + y / 4 + Int(cycle * 4)) % 2 == 0 ? ink : accent
                case .sparkle:
                    let seed = (x * 73 + y * 151 + Int(cycle * 12) * 37) % 29
                    color = seed < 3 ? accent : ink
                }
            }
            result.rgb.replaceSubrange(offset..<(offset + 3), with: color)
        }
        return result
    }
}
