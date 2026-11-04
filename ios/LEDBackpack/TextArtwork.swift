import UIKit
import BackpackProtocol

enum ArtworkFont: String, CaseIterable, Identifiable {
    case pixel = "Pixel", mono = "Monospaced", rounded = "Rounded", system = "System"
    var id: String { rawValue }
    func font(_ points: CGFloat) -> UIFont {
        switch self {
        case .pixel, .mono: return LiveTypeface.mono.font(points)
        case .rounded: return LiveTypeface.rounded.font(points)
        case .system: return LiveTypeface.system.font(points)
        }
    }
}

enum ArtworkAlignment: String, CaseIterable, Identifiable {
    case left = "Left", center = "Center", right = "Right"
    var id: String { rawValue }
    var native: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

struct PixelTextLayout: Equatable {
    let lines: [String]
    let scale: Int
    let padding: Int
    var height: Int { lines.count * 7 * scale + max(0, lines.count - 1) * scale }
    func width(of line: String) -> Int { max(0, line.count * 6 - 1) * scale }
}

@MainActor
enum TextArtwork {
    private static let glyphs: [Character: [UInt8]] = [
        " ": [0,0,0,0,0,0,0],
        "A": [14,17,17,31,17,17,17], "B": [30,17,17,30,17,17,30],
        "C": [14,17,16,16,16,17,14], "D": [30,17,17,17,17,17,30],
        "E": [31,16,16,30,16,16,31], "F": [31,16,16,30,16,16,16],
        "G": [14,17,16,23,17,17,15], "H": [17,17,17,31,17,17,17],
        "I": [14,4,4,4,4,4,14], "J": [7,2,2,2,18,18,12],
        "K": [17,18,20,24,20,18,17], "L": [16,16,16,16,16,16,31],
        "M": [17,27,21,21,17,17,17], "N": [17,25,21,19,17,17,17],
        "O": [14,17,17,17,17,17,14], "P": [30,17,17,30,16,16,16],
        "Q": [14,17,17,17,21,18,13], "R": [30,17,17,30,20,18,17],
        "S": [15,16,16,14,1,1,30], "T": [31,4,4,4,4,4,4],
        "U": [17,17,17,17,17,17,14], "V": [17,17,17,17,17,10,4],
        "W": [17,17,17,21,21,21,10], "X": [17,17,10,4,10,17,17],
        "Y": [17,17,10,4,4,4,4], "Z": [31,1,2,4,8,16,31],
        "0": [14,17,19,21,25,17,14], "1": [4,12,4,4,4,4,14],
        "2": [14,17,1,2,4,8,31], "3": [30,1,1,14,1,1,30],
        "4": [2,6,10,18,31,2,2], "5": [31,16,16,30,1,1,30],
        "6": [14,16,16,30,17,17,14], "7": [31,1,2,4,8,8,8],
        "8": [14,17,17,14,17,17,14], "9": [14,17,17,15,1,1,14],
        ".": [0,0,0,0,0,6,6], ",": [0,0,0,0,6,6,4],
        "!": [4,4,4,4,4,0,4], "?": [14,17,1,2,4,0,4],
        ":": [0,6,6,0,6,6,0], ";": [0,6,6,0,6,6,4],
        "-": [0,0,0,31,0,0,0], "_": [0,0,0,0,0,0,31],
        "+": [0,4,4,31,4,4,0], "=": [0,0,31,0,31,0,0],
        "/": [1,2,2,4,8,8,16], "\\": [16,8,8,4,2,2,1],
        "'": [4,4,2,0,0,0,0], "\"": [10,10,5,0,0,0,0],
        "(": [2,4,8,8,8,4,2], ")": [8,4,2,2,2,4,8],
        "[": [14,8,8,8,8,8,14], "]": [14,2,2,2,2,2,14],
        "<": [1,2,4,8,4,2,1], ">": [16,8,4,2,4,8,16],
        "#": [10,10,31,10,31,10,10], "%": [25,25,2,4,8,19,19],
        "&": [12,18,20,8,21,18,13], "*": [0,21,14,31,14,21,0],
        "@": [14,17,23,21,23,16,14], "|": [4,4,4,4,4,4,4]
    ]

    private static func check(_ text: String, size: PanelSize) throws {
        guard MediaCodec.renderSizes.contains(size) else { throw BackpackError.invalid("Choose a supported canvas size.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 80 else {
            throw BackpackError.invalid("Enter 1 to 80 characters.")
        }
    }

    private static func pixelMessage(_ text: String) throws -> String {
        let value = text.uppercased()
        guard value.count <= 80, value.allSatisfy({ $0 == "\n" || glyphs[$0] != nil }) else {
            throw BackpackError.invalid("Pixel font supports A-Z, digits and basic punctuation. Choose a system font for other characters.")
        }
        return value
    }

    private static func wrapped(_ text: String, columns: Int) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            let words = paragraph.split(separator: " ").map(String.init)
            if words.isEmpty { lines.append(""); continue }
            var line = ""
            for word in words {
                var remaining = word
                while !remaining.isEmpty {
                    let space = line.isEmpty ? 0 : 1
                    if line.count + space + remaining.count <= columns {
                        line += (space == 0 ? "" : " ") + remaining
                        remaining = ""
                    } else if !line.isEmpty {
                        lines.append(line); line = ""
                    } else {
                        lines.append(String(remaining.prefix(columns)))
                        remaining = String(remaining.dropFirst(columns))
                    }
                }
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    static func pixelLayout(_ text: String, size: PanelSize) throws -> PixelTextLayout {
        try check(text, size: size)
        let text = try pixelMessage(text)
        let padding = max(1, min(size.width, size.height) / 32)
        let width = size.width - padding * 2, height = size.height - padding * 2
        let maximum = min(width / 5, height / 7)
        guard maximum >= 1 else { throw BackpackError.invalid("The canvas is too small for pixel text.") }
        for scale in stride(from: maximum, through: 1, by: -1) {
            let columns = (width + scale) / (6 * scale)
            guard columns > 0 else { continue }
            let layout = PixelTextLayout(lines: wrapped(text, columns: columns), scale: scale, padding: padding)
            if layout.height <= height { return layout }
        }
        throw BackpackError.invalid("All text will not fit clearly. Shorten it or use a scrolling message.")
    }

    private static func rgb(_ color: UIColor) throws -> [UInt8] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a), [r,g,b,a].allSatisfy(\.isFinite) else {
            throw BackpackError.invalid("Choose an RGB ink color.")
        }
        let result = [r,g,b].map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
        guard a > 0, result.contains(where: { $0 != 0 }) else {
            throw BackpackError.invalid("Choose a visible text color; black is invisible on the black canvas.")
        }
        return result
    }

    private static func paint(_ text: String, into frame: inout PixelFrame, x: Int, y: Int, scale: Int, color: [UInt8]) throws {
        for (index, letter) in text.enumerated() {
            guard let glyph = glyphs[letter] else { throw BackpackError.invalid("Unsupported pixel-font character.") }
            for row in 0..<7 {
                for column in 0..<5 where glyph[row] & (1 << (4 - column)) != 0 {
                    for dy in 0..<scale {
                        let py = y + row * scale + dy
                        for dx in 0..<scale {
                            let px = x + index * 6 * scale + column * scale + dx
                            if px >= 0, px < frame.size.width, py >= 0, py < frame.size.height {
                                let offset = (py * frame.size.width + px) * 3
                                frame.rgb.replaceSubrange(offset..<(offset + 3), with: color)
                            }
                        }
                    }
                }
            }
        }
    }

    static func render(_ text: String, size: PanelSize, font: ArtworkFont, alignment: ArtworkAlignment, color: UIColor) throws -> PixelFrame {
        try check(text, size: size)
        let ink = try rgb(color)
        if font != .pixel { return try systemText(text, size: size, font: font, alignment: alignment, color: color) }
        let layout = try pixelLayout(text, size: size)
        var frame = PixelFrame.black(size)
        let top = (size.height - layout.height) / 2
        for (index, line) in layout.lines.enumerated() {
            let x: Int
            switch alignment {
            case .left: x = layout.padding
            case .center: x = (size.width - layout.width(of: line)) / 2
            case .right: x = size.width - layout.padding - layout.width(of: line)
            }
            try paint(line, into: &frame, x: x, y: top + index * 8 * layout.scale, scale: layout.scale, color: ink)
        }
        return frame
    }

    private static func systemText(_ text: String, size: PanelSize, font: ArtworkFont, alignment: ArtworkAlignment, color: UIColor) throws -> PixelFrame {
        let padding = CGFloat(max(1, min(size.width, size.height) / 32))
        let width = CGFloat(size.width) - padding * 2, height = CGFloat(size.height) - padding * 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.native
        paragraph.lineBreakMode = .byWordWrapping
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        var points = height
        while points >= 5 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font.font(points), .foregroundColor: color, .paragraphStyle: paragraph
            ]
            let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: options, attributes: attributes, context: nil)
            if ceil(bounds.width) <= width, ceil(bounds.height) <= height {
                return try MediaCodec.canvas(size) { _ in
                    let top = floor((CGFloat(size.height) - ceil(bounds.height)) / 2)
                    (text as NSString).draw(with: CGRect(x: padding, y: top, width: width, height: ceil(bounds.height)),
                        options: options, attributes: attributes, context: nil)
                }
            }
            points -= 0.5
        }
        throw BackpackError.invalid("The text is too long to render clearly. Shorten it or use scrolling.")
    }

    private static func scrollingPlan(_ text: String, size: PanelSize, font: ArtworkFont) throws -> (text: String, scale: Int, width: Int, frames: Int) {
        try check(text, size: size)
        guard !text.contains("\n") else { throw BackpackError.invalid("Scrolling GIFs use a single line of text.") }
        let value = font == .pixel ? try pixelMessage(text) : text
        let scale = max(1, min(3, (size.height - 4) / 7))
        let width: Int
        if font == .pixel { width = max(0, value.count * 6 - 1) * scale }
        else { width = Int(ceil((value as NSString).size(withAttributes: [.font: font.font(CGFloat(size.height) * 0.4)]).width)) }
        let travel = size.width + width + 4
        let step = font == .pixel ? scale : 2
        let frames = max(20, Int(ceil(Double(travel) / Double(step))) + 1)
        guard frames <= 120 else {
            throw BackpackError.invalid("Shorten this scrolling GIF to keep motion smooth within 120 frames. Longer messages can use the Live screen.")
        }
        return (value, scale, width, frames)
    }

    static func scrollingFrame(_ text: String, size: PanelSize, font: ArtworkFont, color: UIColor, phase: Double) throws -> PixelFrame {
        guard phase.isFinite, (0...1).contains(phase) else { throw BackpackError.invalid("Invalid text animation position.") }
        let plan = try scrollingPlan(text, size: size, font: font)
        let ink = try rgb(color)
        let x = size.width + 2 - Int((Double(size.width + plan.width + 4) * phase).rounded())
        if font == .pixel {
            var frame = PixelFrame.black(size)
            try paint(plan.text, into: &frame, x: x, y: (size.height - plan.scale * 7) / 2,
                scale: plan.scale, color: ink)
            return frame
        }
        return try MediaCodec.canvas(size) { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font.font(CGFloat(size.height) * 0.4), .foregroundColor: color
            ]
            let height = (plan.text as NSString).size(withAttributes: attributes).height
            (plan.text as NSString).draw(at: CGPoint(x: CGFloat(x), y: floor((CGFloat(size.height) - height) / 2)),
                withAttributes: attributes)
        }
    }

    static func animation(_ text: String, size: PanelSize, font: ArtworkFont, color: UIColor) throws -> [PixelFrame] {
        let plan = try scrollingPlan(text, size: size, font: font)
        return try (0..<plan.frames).map {
            try scrollingFrame(text, size: size, font: font, color: color, phase: Double($0) / Double(plan.frames - 1))
        }
    }
}
