import Foundation
import UIKit
import SwiftUI
import BackpackProtocol

enum PixelInk: String, Codable, Hashable, CaseIterable, Identifiable {
    case black, white, cyan, magenta, green, yellow, red, blue
    var id: String { rawValue }
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .white: return .white
        case .cyan: return .cyan
        case .magenta: return .magenta
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .blue: return .blue
        }
    }
    var color: Color { Color(uiColor: uiColor) }
}

enum LiveTypeface: String, Codable, Hashable, CaseIterable, Identifiable {
    case mono = "Monospaced", rounded = "Rounded", system = "System"
    var id: String { rawValue }
    func font(_ points: CGFloat) -> UIFont {
        switch self {
        case .mono: return .monospacedSystemFont(ofSize: points, weight: .bold)
        case .system: return .systemFont(ofSize: points, weight: .bold)
        case .rounded:
            let base = UIFont.systemFont(ofSize: points, weight: .bold)
            return UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: points)
        }
    }
}

enum LiveLayout: String, Codable, Hashable, CaseIterable, Identifiable {
    case centered = "Centered", stacked = "Stacked", left = "Left aligned"
    var id: String { rawValue }
}
enum LiveAnimation: String, Codable, Hashable, CaseIterable, Identifiable {
    case still = "Still", marquee = "Marquee", bounce = "Float", typewriter = "Typewriter"
    var id: String { rawValue }
}
enum LiveField: String, Codable, Hashable, CaseIterable, Identifiable {
    case automatic = "Screen label", clock = "Phone time", battery = "Phone battery"
    var id: String { rawValue }
}

struct LiveTheme: Codable, Equatable, Hashable {
    var foreground = PixelInk.cyan
    var background = PixelInk.black
    var typeface = LiveTypeface.mono
    var scale = 1.0
    var layout = LiveLayout.centered
    var topLabel = ""
    var bottomLabel = ""
    var showSecondary = true
    var secondaryField = LiveField.automatic
    var animation = LiveAnimation.still
    var animationSpeed = 1.0
    var refreshInterval = 0.3
    var inkEffect = InkEffect.solid
    var accent = PixelInk.magenta
    var colorSpeed = 1.0
    var gauge = GaugeStyle.none
    var gaugeMinimum = 0.0
    var gaugeMaximum = 100.0

    init() {}
    private enum CodingKeys: String, CodingKey {
        case foreground, background, typeface, scale, layout, topLabel, bottomLabel, showSecondary
        case secondaryField, animation, animationSpeed, refreshInterval, inkEffect, accent, colorSpeed
        case gauge, gaugeMinimum, gaugeMaximum
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try c.decodeIfPresent(PixelInk.self, forKey: .foreground) ?? .cyan
        background = try c.decodeIfPresent(PixelInk.self, forKey: .background) ?? .black
        typeface = try c.decodeIfPresent(LiveTypeface.self, forKey: .typeface) ?? .mono
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        layout = try c.decodeIfPresent(LiveLayout.self, forKey: .layout) ?? .centered
        topLabel = try c.decodeIfPresent(String.self, forKey: .topLabel) ?? ""
        bottomLabel = try c.decodeIfPresent(String.self, forKey: .bottomLabel) ?? ""
        showSecondary = try c.decodeIfPresent(Bool.self, forKey: .showSecondary) ?? true
        secondaryField = try c.decodeIfPresent(LiveField.self, forKey: .secondaryField) ?? .automatic
        animation = try c.decodeIfPresent(LiveAnimation.self, forKey: .animation) ?? .still
        animationSpeed = try c.decodeIfPresent(Double.self, forKey: .animationSpeed) ?? 1
        refreshInterval = try c.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 0.3
        inkEffect = try c.decodeIfPresent(InkEffect.self, forKey: .inkEffect) ?? .solid
        accent = try c.decodeIfPresent(PixelInk.self, forKey: .accent) ?? .magenta
        colorSpeed = try c.decodeIfPresent(Double.self, forKey: .colorSpeed) ?? 1
        gauge = try c.decodeIfPresent(GaugeStyle.self, forKey: .gauge) ?? .none
        gaugeMinimum = try c.decodeIfPresent(Double.self, forKey: .gaugeMinimum) ?? 0
        gaugeMaximum = try c.decodeIfPresent(Double.self, forKey: .gaugeMaximum) ?? 100
    }

    static func standard(for mode: LiveMode) -> LiveTheme {
        var theme = LiveTheme()
        if mode == .music || mode == .message { theme.animation = .marquee }
        return theme
    }

    func validate() throws {
        guard foreground != background else { throw BackpackError.invalid("Ink and background must be different colors.") }
        guard scale.isFinite, (0.5...1.5).contains(scale),
              animationSpeed.isFinite, (0.5...3).contains(animationSpeed),
              refreshInterval.isFinite, (0.2...2).contains(refreshInterval),
              colorSpeed.isFinite, (0.2...3).contains(colorSpeed),
              gaugeMinimum.isFinite, gaugeMaximum.isFinite, gaugeMinimum < gaugeMaximum,
              abs(gaugeMinimum) <= 10000, abs(gaugeMaximum) <= 10000,
              topLabel.count <= 24, bottomLabel.count <= 24 else {
            throw BackpackError.invalid("Theme has invalid type size, timing, or labels.")
        }
    }

    static func builtins(for mode: LiveMode) -> [(name: String, theme: LiveTheme)] {
        let standard = standard(for: mode)
        var arcade = standard
        arcade.foreground = .magenta; arcade.typeface = .rounded; arcade.scale = 1.15
        arcade.animation = .bounce; arcade.layout = .stacked
        var terminal = standard
        terminal.foreground = .green; terminal.animation = .typewriter
        var quiet = standard
        quiet.foreground = .white; quiet.scale = 0.8; quiet.animation = .still
        return [("Night ride", standard), ("Arcade", arcade), ("Terminal", terminal), ("Quiet", quiet)]
    }
}

struct LivePreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var mode: String
    var theme: LiveTheme
}

@MainActor
extension MediaCodec {
    static func styled(_ text: String, subtitle: String, size: PanelSize, theme: LiveTheme,
        phase: Double, field: String? = nil, requiredStatus: Bool = false, gaugeValue: Double? = nil) throws -> PixelFrame {
        try theme.validate()
        guard phase.isFinite, phase >= 0 else { throw BackpackError.invalid("Invalid theme animation phase.") }
        let template = try canvas(size) { context in
            let w = CGFloat(size.width), h = CGFloat(size.height)
            context.setFillColor(theme.background.uiColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let hasGauge = !requiredStatus && gaugeValue?.isFinite == true && theme.gauge != .none
            if hasGauge, let value = gaugeValue {
                let amount = max(0, min(1, (value - theme.gaugeMinimum) / (theme.gaugeMaximum - theme.gaugeMinimum)))
                context.setFillColor(theme.foreground.uiColor.cgColor)
                context.setStrokeColor(theme.foreground.uiColor.cgColor)
                if theme.gauge == .bar {
                    context.fill(CGRect(x: w * 0.1, y: h * 0.69, width: w * 0.8 * CGFloat(amount), height: max(1, h * 0.045)))
                } else if amount > 0 {
                    let path = UIBezierPath(arcCenter: CGPoint(x: w / 2, y: h * 0.43),
                        radius: min(w, h) * 0.36, startAngle: .pi * 0.75,
                        endAngle: .pi * 0.75 + .pi * 1.5 * CGFloat(amount), clockwise: true)
                    context.setLineWidth(max(1, h * 0.045))
                    context.addPath(path.cgPath); context.strokePath()
                }
            }
            let safePhase = phase.truncatingRemainder(dividingBy: 1)
            let message: String
            if theme.animation == .typewriter && !requiredStatus {
                let count = min(text.count, max(1, Int(safePhase * Double(text.count + 8))))
                message = String(text.prefix(count))
            } else { message = text }
            let scrolling = theme.animation == .marquee && !requiredStatus
            let base = scrolling ? h * 0.4 : min(h * (hasGauge ? 0.36 : 0.48), w * 1.5 / CGFloat(max(1, message.count)))
            var points = max(5, min(h * 0.75, base * (requiredStatus ? 1 : theme.scale)))
            if requiredStatus {
                while points > 3 && (message as NSString).size(withAttributes: [.font: theme.typeface.font(points)]).width > w - 4 {
                    points -= 0.5
                }
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: theme.typeface.font(points), .foregroundColor: theme.foreground.uiColor
            ]
            let bounds = (message as NSString).size(withAttributes: attrs)
            let layout = requiredStatus ? LiveLayout.centered : theme.layout
            var x = layout == .left ? CGFloat(2) : (w - bounds.width) / 2
            let y = layout == .stacked ? h * 0.18 : (h - bounds.height) / 2 - h * 0.08
            if scrolling { x = w - CGFloat(safePhase) * (w + bounds.width) }
            if theme.animation == .bounce && !requiredStatus {
                x += CGFloat(sin(safePhase * .pi * 2)) * w * 0.1
            }
            (message as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            var labelPoints = max(5, h * 0.12)
            if requiredStatus {
                while labelPoints > 3 && (subtitle as NSString).size(withAttributes: [.font: theme.typeface.font(labelPoints)]).width > w - 2 {
                    labelPoints -= 0.5
                }
            }
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: theme.typeface.font(labelPoints), .foregroundColor: theme.foreground.uiColor
            ]
            if !theme.topLabel.isEmpty && !requiredStatus {
                let topBounds = (theme.topLabel as NSString).size(withAttributes: labelAttrs)
                (theme.topLabel as NSString).draw(at: CGPoint(x: layout == .left ? 2 : (w - topBounds.width) / 2, y: 1),
                    withAttributes: labelAttrs)
            }
            if theme.showSecondary || requiredStatus {
                let label = requiredStatus ? subtitle
                    : field ?? (theme.bottomLabel.isEmpty ? subtitle : theme.bottomLabel)
                let labelBounds = (label as NSString).size(withAttributes: labelAttrs)
                (label as NSString).draw(at: CGPoint(x: layout == .left ? 2 : (w - labelBounds.width) / 2, y: h * 0.8),
                    withAttributes: labelAttrs)
            }
        }
        var inkTheme = theme
        if requiredStatus { inkTheme.inkEffect = .solid }
        return InkPainter.apply(template, theme: inkTheme, phase: max(0, phase))
    }

    static func demo(mode: LiveMode, size: PanelSize, theme: LiveTheme, phase: Double = 0.35) throws -> PixelFrame {
        try theme.validate()
        if mode == .eyes {
            return try canvas(size) { context in
                let w = CGFloat(size.width), h = CGFloat(size.height)
                context.setFillColor(theme.background.uiColor.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                context.setFillColor(theme.foreground.uiColor.cgColor)
                context.fill(CGRect(x: w * 0.18, y: h * 0.35, width: w * 0.2, height: h * 0.25))
                context.fill(CGRect(x: w * 0.62, y: h * 0.35, width: w * 0.2, height: h * 0.25))
            }
        }
        let value: String
        let subtitle: String
        switch mode {
        case .speed: value = "42"; subtitle = "MPH"
        case .weather: value = "21C"; subtitle = "CLEAR"
        case .music: value = "YOUR SONG"; subtitle = "ARTIST"
        case .motion: value = "12"; subtitle = "PHONE ROLL"
        case .clock: value = "9:41"; subtitle = ""
        case .compass: value = "180"; subtitle = "PHONE DEG"
        case .battery: value = "87"; subtitle = "PHONE BAT"
        case .message: value = "HELLO WORLD"; subtitle = ""
        case .loading: value = "..."; subtitle = "LOADING RIDER"
        case .eyes: value = ""; subtitle = ""
        }
        let field = theme.secondaryField == .clock ? "9:41" : theme.secondaryField == .battery ? "PHONE 87%" : nil
        return try styled(value, subtitle: subtitle, size: size, theme: theme, phase: phase,
            field: field, gaugeValue: Double(value.replacingOccurrences(of: "C", with: "")))
    }
}
