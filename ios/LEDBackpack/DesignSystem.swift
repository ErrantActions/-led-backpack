import SwiftUI
import UIKit

enum Aurora {
    private static func adaptive(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    static let background = adaptive(0x06090E, 0xF6F7F9)
    static let surface = adaptive(0x141725, 0xFFFFFF)
    static let raised = adaptive(0x252239, 0xE9EEF4)
    static let ink = adaptive(0xF4F7FB, 0x14212D)
    static let supporting = adaptive(0xC5C6E4, 0x47586C)
    static let mint = adaptive(0x9EFFE6, 0x006B58)
    static let lavender = adaptive(0xBDB8FF, 0x5744A5)
    static let rose = adaptive(0xFFA3D9, 0x8B275F)
    static let onAction = adaptive(0x09201E, 0xFFFFFF)
    static let mintSurface = adaptive(0x14352F, 0xE3F8EF)
    static let lavenderSurface = adaptive(0x292142, 0xF0ECFF)
    static let roseSurface = adaptive(0x381D32, 0xFDEAF4)
    static let spectrum = LinearGradient(colors: [mint, lavender, rose], startPoint: .leading, endPoint: .trailing)

    // Illustrations retain the original spectrum on their own opaque ink canvas.
    static let pixelMint = Color(red: 158 / 255, green: 1, blue: 230 / 255)
    static let pixelLavender = Color(red: 189 / 255, green: 184 / 255, blue: 1)
    static let pixelRose = Color(red: 1, green: 163 / 255, blue: 217 / 255)
    static let pixelInk = Color(red: 6 / 255, green: 9 / 255, blue: 14 / 255)

    static func featureSurface(for tint: Color) -> Color {
        if tint == lavender { return lavenderSurface }
        if tint == rose { return roseSurface }
        return mintSurface
    }
}

@MainActor
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        ZStack {
            Aurora.background
            if !opaque && contrast != .increased {
                GeometryReader { proxy in
                    Ellipse().fill(Aurora.mint.opacity(0.08))
                        .frame(width: proxy.size.width, height: proxy.size.height * 0.65)
                        .blur(radius: 85).offset(x: -proxy.size.width * 0.45, y: -100)
                    Ellipse().fill(Aurora.lavender.opacity(0.09))
                        .frame(width: proxy.size.width, height: proxy.size.height * 0.7)
                        .blur(radius: 100).offset(x: proxy.size.width * 0.35, y: proxy.size.height * 0.3)
                }
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

@MainActor
struct AuroraSurface: View {
    var radius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Aurora.surface)
            if !opaque && contrast != .increased {
                shape.fill(LinearGradient(colors: [Aurora.lavender.opacity(0.045), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            shape.strokeBorder(Aurora.supporting.opacity(contrast == .increased ? 0.65 : 0.18),
                lineWidth: contrast == .increased ? 1.5 : 1)
        }.accessibilityHidden(true)
    }
}

@MainActor
struct AuroraPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 20).padding(12)
            .foregroundStyle(Aurora.onAction)
            .background(Aurora.mint, in: RoundedRectangle(cornerRadius: 14))
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion && scenePhase == .active ? 0.97 : 1)
            .animation(!reduceMotion && scenePhase == .active ? .easeOut(duration: 0.18) : nil,
                value: configuration.isPressed)
    }
}

@MainActor
struct AuroraTileButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion && scenePhase == .active ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(!reduceMotion && scenePhase == .active ? .easeOut(duration: 0.18) : nil,
                value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

@MainActor
struct AuroraHeading: View {
    let eyebrow: String
    let title: String
    let accent: String
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased()).font(.caption.weight(.semibold)).tracking(1.5)
                .foregroundStyle(Aurora.supporting)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).foregroundStyle(Aurora.ink)
                if contrast == .increased {
                    Text(accent).foregroundStyle(Aurora.mint)
                } else {
                    Text(accent).foregroundStyle(Aurora.spectrum)
                }
            }
            .font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-0.7)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        }.accessibilityElement(children: .combine)
    }
}

private struct AuroraMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct AuroraViewportKey: EnvironmentKey {
    static let defaultValue = CGRect.zero
}

extension EnvironmentValues {
    var auroraMotionEnabled: Bool {
        get { self[AuroraMotionEnabledKey.self] }
        set { self[AuroraMotionEnabledKey.self] = newValue }
    }
    var auroraViewport: CGRect {
        get { self[AuroraViewportKey.self] }
        set { self[AuroraViewportKey.self] = newValue }
    }
}

enum AuroraMotionPolicy {
    static func allowsAnimation(reduceMotion: Bool, paused: Bool, activeScene: Bool,
        activeDestination: Bool, appeared: Bool, frame: CGRect, viewport: CGRect) -> Bool {
        !reduceMotion && !paused && activeScene && activeDestination && appeared &&
            !frame.isEmpty && !viewport.isEmpty && frame.intersects(viewport)
    }
}

@MainActor
private struct AuroraScene: ViewModifier {
    @State private var viewport = CGRect.zero
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AuroraBackground())
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { viewport = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in viewport = frame }
                }.allowsHitTesting(false)
            }
            .environment(\.auroraViewport, viewport)
            .listRowSpacing(6)
            .tint(Aurora.mint)
            .toolbarBackground(opaque || contrast == .increased ?
                AnyShapeStyle(Aurora.surface) : AnyShapeStyle(.ultraThinMaterial), for: .navigationBar)
    }
}

@MainActor
private struct AuroraEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.auroraMotionEnabled) private var activeDestination
    @State private var entered = false
    func body(content: Content) -> some View {
        content
            .offset(y: !entered && !reduceMotion && scenePhase == .active && activeDestination ? 10 : 0)
            .transaction {
                if reduceMotion || scenePhase != .active || !activeDestination {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
            }
            .onAppear {
                guard !entered else { return }
                withAnimation(reduceMotion || scenePhase != .active || !activeDestination ? nil : .easeOut(duration: 0.6)) {
                    entered = true
                }
            }
    }
}

@MainActor
extension View {
    // Existing consumers keep their API; reading surfaces are now opaque, not stacked glass.
    func glassPanel(radius: CGFloat = 20) -> some View {
        background(AuroraSurface(radius: radius))
    }
    func modernScene() -> some View { modifier(AuroraScene()) }
    func auroraEntrance() -> some View { modifier(AuroraEntrance()) }
    func auroraMotionActive(_ active: Bool) -> some View { environment(\.auroraMotionEnabled, active) }
}

@MainActor
struct FeatureCardLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint = Aurora.mint
    var compact = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 12) {
            Image(systemName: symbol).font(compact ? .title3 : .title2).foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Aurora.surface, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            Text(title).font(compact ? .caption.weight(.semibold) : .headline).foregroundStyle(Aurora.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !compact {
                Text(subtitle).font(.subheadline).foregroundStyle(Aurora.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .padding(compact ? 12 : 16)
        .background(Aurora.featureSurface(for: tint), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(tint.opacity(contrast == .increased ? 0.7 : 0.2),
                    lineWidth: contrast == .increased ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
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
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 36, height: 36)
                .background(Aurora.featureSurface(for: tint), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Aurora.ink)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Aurora.supporting) }
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
            content
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                .buttonStyle(.borderless)
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
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            .foregroundStyle(color).padding(.horizontal, 12).padding(.vertical, 8)
            .background(Aurora.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(contrast == .increased ? 0.75 : 0.3)))
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum AuroraArtworkKind: Equatable {
    case wave, bloom, backpack
}

@MainActor
private struct AuroraPixelField: View {
    var kind: AuroraArtworkKind = .wave
    var phase: Double = 0
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            if kind == .backpack {
                let handle = CGRect(x: origin.x + side * 0.37, y: origin.y + side * 0.04,
                    width: side * 0.26, height: side * 0.23)
                context.stroke(Path(roundedRect: handle, cornerRadius: side * 0.08),
                    with: .color(Aurora.pixelLavender), lineWidth: side * 0.035)
                let bag = CGRect(x: origin.x + side * 0.18, y: origin.y + side * 0.18,
                    width: side * 0.64, height: side * 0.76)
                context.fill(Path(roundedRect: bag, cornerRadius: side * 0.13),
                    with: .color(Color(red: 20 / 255, green: 23 / 255, blue: 37 / 255)))
                context.stroke(Path(roundedRect: bag, cornerRadius: side * 0.13),
                    with: .color(Aurora.pixelLavender.opacity(0.75)), lineWidth: 1.5)
            }
            let columns = 30, rows = 30
            let cell = side / CGFloat(columns)
            for y in 0..<rows {
                for x in 0..<columns {
                    if kind == .backpack && !(7...22 ~= x && 10...24 ~= y) { continue }
                    let dx = Double(x) - 14.5, dy = Double(y) - 14.5
                    let first = sin(Double(x) * 0.25 + phase) * 5 + 13
                    let second = cos(Double(x) * 0.22 - phase) * 4 + 17
                    let distance = min(abs(Double(y) - first), abs(Double(y) - second))
                    let angle = atan2(dy, dx)
                    let bloomEdge = 8.5 + 2.8 * cos(6 * angle - phase * 0.4)
                    let bloomDistance = abs(hypot(dx, dy) - bloomEdge)
                    let bright = kind == .bloom ? bloomDistance < 1.8 : distance < 1.5
                    let color = x < 10 ? Aurora.pixelMint : (x < 20 ? Aurora.pixelLavender : Aurora.pixelRose)
                    let rect = CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell,
                        width: cell * 0.68, height: cell * 0.68)
                    context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.14),
                        with: .color(bright ? color : .white.opacity(0.065)))
                }
            }
        }
        .background(Aurora.pixelInk, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityHidden(true)
    }
}

@MainActor
struct PixelArtwork: View {
    var body: some View {
        AuroraPixelField().aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(false)
            .accessibilityLabel("Original mint, lavender and rose pixel waves")
    }
}

private struct AuroraArtworkFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@MainActor
struct AuroraHeroArtwork: View {
    var kind: AuroraArtworkKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.auroraMotionEnabled) private var activeDestination
    @Environment(\.auroraViewport) private var viewport
    @State private var paused = false
    @State private var appeared = false
    @State private var frame = CGRect.zero

    private var moving: Bool {
        AuroraMotionPolicy.allowsAnimation(reduceMotion: reduceMotion, paused: paused,
            activeScene: scenePhase == .active, activeDestination: activeDestination, appeared: appeared,
            frame: frame, viewport: viewport)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only explicit destination heroes own a clock, never cards or list cells.
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !moving)) { timeline in
                let phase = moving ? timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 24) / 24 * .pi * 2 : 0
                AuroraPixelField(kind: kind, phase: phase)
            }
            .frame(height: 180)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: AuroraArtworkFrameKey.self, value: proxy.frame(in: .global))
                }
            }
            .onPreferenceChange(AuroraArtworkFrameKey.self) { frame = $0 }
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text("Original pixel artwork").font(.caption).foregroundStyle(Aurora.supporting)
                Spacer(minLength: 0)
                Button {
                    paused.toggle()
                } label: {
                    Label(reduceMotion ? "Motion off" : (paused ? "Play motion" : "Pause motion"),
                        systemImage: paused || reduceMotion ? "play" : "pause")
                        .font(.caption.weight(.semibold)).frame(minHeight: 44)
                }
                .disabled(reduceMotion)
                .accessibilityLabel(reduceMotion ? "Motion off: Reduce Motion is enabled" :
                    (paused ? "Play decorative motion" : "Pause decorative motion"))
                .accessibilityIdentifier("aurora-hero-motion")
            }
        }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
    }
}

@MainActor
struct BackpackHero: View {
    let connected: Bool
    let size: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuroraHeading(eyebrow: "Your backpack", title: "Carry your", accent: "creativity.")
                .auroraEntrance()
            AuroraHeroArtwork(kind: .backpack)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    connectionStatus
                    Text(size).font(.caption.monospaced()).foregroundStyle(Aurora.supporting)
                }
                VStack(alignment: .leading, spacing: 8) {
                    connectionStatus
                    Text(size).font(.caption.monospaced()).foregroundStyle(Aurora.supporting)
                }
            }
        }
    }
    private var connectionStatus: some View {
        StatusPill(title: connected ? "Connected" : "Not connected", symbol: "backpack",
            color: connected ? Aurora.mint : Aurora.supporting)
    }
}
