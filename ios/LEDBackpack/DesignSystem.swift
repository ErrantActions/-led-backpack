import SwiftUI

enum Aurora {
    static let mint = Color(red: 0.62, green: 1, blue: 0.9)
    static let lavender = Color(red: 0.74, green: 0.72, blue: 1)
    static let rose = Color(red: 1, green: 0.64, blue: 0.85)
    static let spectrum = LinearGradient(colors: [mint, lavender, rose], startPoint: .leading, endPoint: .trailing)
}

@MainActor
struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.035, blue: 0.055)
            GeometryReader { proxy in
                Ellipse().fill(Aurora.mint.opacity(0.04))
                    .frame(width: proxy.size.width, height: proxy.size.height * 0.65)
                    .blur(radius: 85).offset(x: -proxy.size.width * 0.45, y: -100)
                Ellipse().fill(Aurora.lavender.opacity(0.04))
                    .frame(width: proxy.size.width, height: proxy.size.height * 0.7)
                    .blur(radius: 100).offset(x: proxy.size.width * 0.35, y: proxy.size.height * 0.3)
                Ellipse().fill(Aurora.rose.opacity(0.015)).frame(width: 240, height: 300)
                    .blur(radius: 80).offset(x: -60, y: proxy.size.height * 0.65)
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

@MainActor
struct AuroraSurface: View {
    var radius: CGFloat = 26
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if opaque {
                shape.fill(Color(red: 0.08, green: 0.095, blue: 0.14))
            } else {
                shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                shape.fill(LinearGradient(colors: [.white.opacity(0.065), .white.opacity(0.01)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            shape.strokeBorder(LinearGradient(
                colors: [.white.opacity(contrast == .increased ? 0.55 : 0.22), .white.opacity(0.04), Aurora.lavender.opacity(0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct AuroraPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 20).padding(12)
            .foregroundStyle(Color(red: 0.045, green: 0.15, blue: 0.14))
            .background(LinearGradient(colors: [Aurora.mint, Color(red: 0.62, green: 0.94, blue: 0.94)],
                startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

@MainActor
struct AuroraHeading: View {
    let eyebrow: String
    let title: String
    let accent: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow.uppercased()).font(.caption2.weight(.semibold)).tracking(2.5)
                .foregroundStyle(Aurora.mint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).foregroundStyle(.primary)
                Text(accent).foregroundStyle(Aurora.spectrum)
            }
            .font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1.3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }
}

@MainActor
extension View {
    func glassPanel(radius: CGFloat = 26) -> some View {
        background(AuroraSurface(radius: radius))
    }
    func modernScene() -> some View {
        scrollContentBackground(.hidden)
            .background(AuroraBackground())
            .listRowSpacing(6)
            .tint(Aurora.mint)
    }
}

@MainActor
struct FeatureCardLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint = Aurora.mint
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .glassPanel(radius: 20)
            .accessibilityElement(children: .combine)
    }
}

@MainActor
struct FeatureRowLabel: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var tint = Aurora.mint
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.frame(minHeight: 44)
    }
}

@MainActor
struct FeatureDetails<Content: View>: View {
    var title = "Details"
    private let content: Content
    init(_ title: String = "Details", @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
        } label: {
            Label(title, systemImage: "info.circle").font(.subheadline)
        }
    }
}

@MainActor
struct StatusPill: View {
    let title: String
    var symbol = "sparkles"
    var color = Aurora.mint
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            .foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 8)
            .background(color.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.18)))
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
                        with: .color(bright ? (x < 11 ? Aurora.mint : Aurora.rose) : .white.opacity(0.055)))
                }
            }
        }.aspectRatio(1, contentMode: .fit).accessibilityLabel("Original cyan and pink pixel wave")
    }
}

@MainActor
struct BackpackHero: View {
    let connected: Bool
    let size: String
    var body: some View {
        HStack(spacing: 18) {
            PixelArtwork().frame(width: 80, height: 80).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your backpack").font(.title2.bold())
                StatusPill(title: connected ? "Connected" : "Not connected", symbol: "backpack")
                Text(size).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(20)
    }
}
