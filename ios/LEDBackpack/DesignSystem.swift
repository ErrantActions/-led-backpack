import SwiftUI

@MainActor
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.07)
            GeometryReader { proxy in
                Ellipse().fill(.cyan.opacity(0.13)).frame(width: proxy.size.width * 0.9, height: 330)
                    .blur(radius: 90).offset(x: -proxy.size.width * 0.2, y: -160)
                Ellipse().fill(.purple.opacity(0.16)).frame(width: proxy.size.width, height: 450)
                    .blur(radius: 110).offset(x: proxy.size.width * 0.3, y: 250)
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

@MainActor
private struct GlassPanel: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @ViewBuilder func body(content: Content) -> some View {
        if opaque {
            content.background(Color(red: 0.09, green: 0.11, blue: 0.17), in: RoundedRectangle(cornerRadius: radius))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: radius))
            } else {
                content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            }
            #else
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            #endif
        }
    }
}

@MainActor
extension View {
    func glassPanel(radius: CGFloat = 26) -> some View { modifier(GlassPanel(radius: radius)) }
    func modernScene() -> some View {
        scrollContentBackground(.hidden)
            .background(AuroraBackground())
            .listRowSpacing(12)
            .tint(.cyan)
    }
}

@MainActor
struct StatusPill: View {
    let title: String
    var symbol = "sparkles"
    var color = Color.cyan
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            .foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 8)
            .glassPanel(radius: 20)
    }
}

@MainActor
struct PixelArtwork: View {
    var body: some View {
        Canvas { context, size in
            let columns = 22, rows = 22
            let cell = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
            for y in 0..<rows {
                for x in 0..<columns {
                    let wave = sin(Double(x) * 0.32) * 4 + 11
                    let distance = abs(Double(y) - wave)
                    let bright = distance < 1.4
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell * 0.68, height: cell * 0.68)
                    context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.16),
                        with: .color(bright ? (x < 11 ? .cyan : .pink) : .white.opacity(0.045)))
                }
            }
        }.aspectRatio(1, contentMode: .fit).accessibilityLabel("Original cyan and pink pixel wave")
    }
}

@MainActor
struct BackpackHero: View {
    let connected: Bool
    let size: String
    private var copy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Make your\npixels move.").font(.system(.title2, design: .rounded, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Live data.\nInfinite personality.").font(.caption).foregroundStyle(.secondary)
            Text(size).font(.caption2.monospaced()).foregroundStyle(.cyan)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                StatusPill(title: connected ? "LINKED & READY" : "YOUR NEXT CANVAS",
                    symbol: connected ? "dot.radiowaves.left.and.right" : "sparkles",
                    color: connected ? .mint : .cyan)
                Spacer()
                Image(systemName: "backpack.fill").font(.title2).foregroundStyle(.white.opacity(0.7))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    copy.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    PixelArtwork().frame(width: 84, height: 84)
                }
                VStack(alignment: .leading, spacing: 16) {
                    copy
                    PixelArtwork().frame(width: 84, height: 84)
                }
            }
        }.padding(24).glassPanel()
    }
}
