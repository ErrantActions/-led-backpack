import SwiftUI
import BackpackProtocol

@MainActor
struct ThemeEditor: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: LiveMode
    @State private var draft: LiveTheme
    @State private var presetName = ""
    @State private var preview: UIImage?
    @State private var validation: String?

    init(mode: LiveMode, theme: LiveTheme) {
        self.mode = mode
        _draft = State(initialValue: theme)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width >= 760 {
                    HStack(spacing: 20) {
                        controls(showPreview: false).frame(minWidth: 300, maxWidth: 430)
                        ScrollView { previewCard.padding(24) }.frame(maxWidth: .infinity)
                    }
                } else { controls(showPreview: true) }
            }
            .background(AuroraBackground())
            .navigationTitle("Make it yours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: draft) {
                repeat {
                    updatePreview()
                    if validation != nil || (draft.animation == .still && draft.inkEffect == .solid) || reduceMotion { break }
                    do { try await Task.sleep(for: .seconds(draft.refreshInterval)) } catch { break }
                } while !Task.isCancelled
            }
        }
    }

    private func controls(showPreview: Bool) -> some View {
        Form {
            Section {
                if showPreview {
                    previewCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if let validation { Text(validation).foregroundStyle(.orange) }
            }
            Section("Your palette") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                    ForEach(PixelInk.allCases) { ink in
                        Button { draft.foreground = ink } label: {
                            Circle().fill(ink.color).frame(width: 25, height: 25)
                                .overlay(Circle().strokeBorder(.white.opacity(0.3)))
                                .frame(width: 44, height: 44)
                                .overlay(Circle().strokeBorder(draft.foreground == ink ? Aurora.mint : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel("\(ink.rawValue.capitalized) ink")
                            .accessibilityAddTraits(draft.foreground == ink ? .isSelected : [])
                    }
                }
                Picker("Background", selection: $draft.background) {
                    ForEach(PixelInk.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Ink effect", selection: $draft.inkEffect) { ForEach(InkEffect.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Secondary ink", selection: $draft.accent) { ForEach(PixelInk.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                Slider(value: $draft.colorSpeed, in: 0.2...3, step: 0.1) { Text("Color effect speed") }
                Text("Eight crisp LED colors. Ink and background must differ.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Typography and layout") {
                Picker("Typeface", selection: $draft.typeface) { ForEach(LiveTypeface.allCases) { Text($0.rawValue).tag($0) } }
                Slider(value: $draft.scale, in: 0.5...1.5, step: 0.05) { Text("Number / text size") }
                Text("Type scale: \(draft.scale, specifier: "%.2f")x").font(.caption.monospaced())
                Picker("Layout", selection: $draft.layout) { ForEach(LiveLayout.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Top label (up to 24 characters)", text: $draft.topLabel)
                TextField("Custom bottom label", text: $draft.bottomLabel)
                Toggle("Show secondary data", isOn: $draft.showSecondary)
                Picker("Secondary field", selection: $draft.secondaryField) { ForEach(LiveField.allCases) { Text($0.rawValue).tag($0) } }
                Text("Fields use existing phone data. NO GPS, stale weather and other critical statuses cannot be hidden or relabeled.").font(.caption)
            }
            Section("Motion") {
                Picker("Style", selection: Binding(get: { draft.animation }, set: { draft.animation = $0 })) {
                    ForEach(LiveAnimation.allCases) { Text($0.rawValue).tag($0) }
                }
                Slider(value: $draft.animationSpeed, in: 0.5...3, step: 0.1) { Text("Animation speed") }
                Text("Animation \(draft.animationSpeed, specifier: "%.1f")x").font(.caption)
                Slider(value: $draft.refreshInterval, in: 0.2...2, step: 0.1) { Text("Refresh interval") }
                Text("Target interval \(draft.refreshInterval, specifier: "%.1f")s; actual rate depends on BLE and iOS.").font(.caption)
                if mode == .eyes {
                    Text("Pixel eyes use the selected palette and refresh timing; text fonts, labels, and text animation styles apply to text-based screens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Gauge") {
                    Picker("Style", selection: $draft.gauge) { ForEach(GaugeStyle.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Minimum", value: $draft.gaugeMinimum, format: .number).keyboardType(.numbersAndPunctuation)
                    TextField("Maximum", value: $draft.gaugeMaximum, format: .number).keyboardType(.numbersAndPunctuation)
                    Text("Gauges use numeric screens only. The speed gauge uses the capped display value, not hidden uncapped GPS. Critical status messages replace the gauge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Starting points") {
                ForEach(LiveTheme.builtins(for: mode), id: \.name) { preset in
                    Button { draft = preset.theme } label: {
                        HStack {
                            Circle().fill(preset.theme.foreground.color).frame(width: 14, height: 14)
                            Text(preset.name)
                            Spacer()
                            Text(preset.theme.animation.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Your presets for \(mode.rawValue)") {
                TextField("Preset name", text: $presetName)
                Button("Save named preset") {
                    app.run { try library.savePreset(name: presetName, mode: mode, theme: draft); presetName = "" }
                }.disabled(validation != nil)
                ForEach((library.state.livePresets ?? []).filter { $0.mode == mode.rawValue }) { preset in
                    HStack {
                        Button(preset.name) { draft = preset.theme }
                        Spacer()
                        Button(role: .destructive) { app.run { try library.deletePreset(preset.id) } } label: { Image(systemName: "trash") }
                    }
                }
                Button("Apply to this live screen") {
                    app.run {
                        try library.saveTheme(draft, for: mode)
                        app.apply(library.state.preferences)
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent).disabled(validation != nil)
            }
        }.modernScene()
    }

    private var previewCard: some View {
        VStack(spacing: 16) {
            HStack {
                StatusPill(title: mode.rawValue.uppercased(), symbol: "slider.horizontal.3")
                Spacer()
                Text("PREVIEW ONLY").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let preview {
                Image(uiImage: preview).interpolation(.none).resizable().scaledToFit()
                    .frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 18))
            }
            Text("Sample data. Changes are not sent until you apply a theme and run a live screen.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).glassPanel()
    }

    private func updatePreview() {
        do {
            try draft.validate()
            let size = panel.size ?? PanelSize(width: 64, height: 64)
            let phase = reduceMotion ? 0.35 : Date().timeIntervalSince1970 * draft.animationSpeed / 8
            preview = try MediaCodec.demo(mode: mode, size: size, theme: draft, phase: phase).image()
            validation = nil
        } catch { validation = error.localizedDescription; preview = nil }
    }
}
