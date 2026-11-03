import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import BackpackProtocol

@MainActor
struct StudioView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    @State private var text = "HELLO"
    @State private var name = "My text"
    @State private var animate = false
    @State private var ink: Color = .cyan
    @State private var pixels = PixelFrame.black(PanelSize(width: 64, height: 64))
    @State private var undo: [PixelFrame] = []
    @State private var redo: [PixelFrame] = []
    @State private var eraser = false
    @State private var gestureStarted = false
    @State private var drawingPreview: UIImage?
    @State private var textPreview: UIImage?
    private var size: PanelSize { panel.size ?? PanelSize(width: 64, height: 64) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Message", text: $text)
                    TextField("Saved name", text: $name)
                    ColorPicker("Ink", selection: $ink, supportsOpacity: false)
                    Toggle("Animated horizontal marquee", isOn: $animate)
                    if let textPreview { Image(uiImage: textPreview).interpolation(.none).resizable().scaledToFit().frame(height: 150) }
                    Button("Preview text") {
                        app.run { textPreview = try MediaCodec.text(String(text.prefix(80)), size: size, color: UIColor(ink)).image() }
                    }
                    Button("Save text as GIF") {
                        app.run {
                            guard !text.isEmpty, text.count <= 80 else { throw BackpackError.invalid("Enter 1 to 80 characters.") }
                            let frames: [PixelFrame]
                            if animate {
                                frames = try (0..<40).map { index in
                                    try MediaCodec.marquee(text, subtitle: "", size: size,
                                        color: UIColor(ink), phase: Double(index) / 40)
                                }
                            } else { frames = [try MediaCodec.text(text, size: size, color: UIColor(ink))] }
                            try library.add(name: name, data: MediaCodec.encode(frames,
                                delays: Array(repeating: animate ? 0.1 : 1, count: frames.count)))
                        }
                    }
                }
                Section("Pixel drawing") {
                    Text("Canvas: \(pixels.size.width) x \(pixels.size.height). Selected panel: \(size.width) x \(size.height).")
                        .font(.caption)
                    if let drawingPreview {
                        GeometryReader { geometry in
                            Image(uiImage: drawingPreview).interpolation(.none).resizable()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                    if !gestureStarted {
                                        undo.append(pixels)
                                        if undo.count > 30 { undo.removeFirst() }
                                        redo = []; gestureStarted = true
                                    }
                                    let x = min(pixels.size.width - 1, max(0, Int(value.location.x / max(1, geometry.size.width) * Double(pixels.size.width))))
                                    let y = min(pixels.size.height - 1, max(0, Int(value.location.y / max(1, geometry.size.height) * Double(pixels.size.height))))
                                    let color = eraser ? UIColor.black : UIColor(ink)
                                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
                                    let offset = (y * pixels.size.width + x) * 3
                                    pixels.rgb[offset] = UInt8(max(0, min(255, Int(r * 255))))
                                    pixels.rgb[offset + 1] = UInt8(max(0, min(255, Int(g * 255))))
                                    pixels.rgb[offset + 2] = UInt8(max(0, min(255, Int(b * 255))))
                                    updateDrawing()
                                }.onEnded { _ in gestureStarted = false })
                        }.aspectRatio(CGFloat(pixels.size.width) / CGFloat(pixels.size.height), contentMode: .fit)
                    }
                    Toggle("Eraser", isOn: $eraser)
                    HStack {
                        Button("Undo") {
                            if let old = undo.popLast() { redo.append(pixels); pixels = old; updateDrawing() }
                        }.disabled(undo.isEmpty)
                        Button("Redo") {
                            if let next = redo.popLast() { undo.append(pixels); pixels = next; updateDrawing() }
                        }.disabled(redo.isEmpty)
                        Button("New canvas") {
                            undo.append(pixels); redo = []; pixels = .black(size); updateDrawing()
                        }
                    }.buttonStyle(.bordered)
                    Button("Save drawing as GIF") {
                        app.run { try library.add(name: "Drawing", data: MediaCodec.encode([pixels], delays: [1])) }
                    }
                }
            }.modernScene().navigationTitle("Studio")
            .task { updateDrawing() }
        }
    }

    private func updateDrawing() {
        do { drawingPreview = try pixels.image() } catch { panel.report(error) }
    }
}

@MainActor
struct LiveView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var live: LiveEngine
    @EnvironmentObject private var sensors: LiveSensors
    @EnvironmentObject private var library: LocalLibrary
    @State private var selected = LiveMode.speed
    @State private var starting = false
    @State private var themeEditor = false
    @State private var idlePreview: UIImage?
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your world,\nin pixels.").font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1)
                                Text("A live canvas with your signature.").foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            StatusPill(title: live.mode == nil ? "PREVIEW" : "ON AIR",
                                symbol: live.mode == nil ? "sparkles" : "dot.radiowaves.left.and.right",
                                color: live.mode == nil ? .cyan : .mint)
                        }
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 24) {
                                controls.frame(minWidth: 280, maxWidth: 370)
                                VStack(spacing: 20) {
                                    StatusPill(title: "EXPANDED LIVE STUDIO", symbol: "rectangle.split.2x1")
                                    previewCard
                                    presetRail
                                }.frame(maxWidth: .infinity)
                            }
                        } else {
                            previewCard
                            controls
                            presetRail
                        }
                        backgroundNote
                    }
                    .padding(24).frame(maxWidth: 1300, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.background(AuroraBackground())
            .navigationTitle("Live").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $themeEditor) { ThemeEditor(mode: selected, theme: library.theme(for: selected)) }
            .task(id: "\(selected.rawValue)-\(library.theme(for: selected))-\(panel.size?.width ?? 64)") { updatePreview() }
        }
    }

    private var previewCard: some View {
        VStack(spacing: 18) {
            HStack {
                Text(selected.rawValue.uppercased()).font(.caption.weight(.semibold)).tracking(2)
                Spacer()
                Text(live.mode == selected ? "LIVE PANEL" : "DEMO DATA").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let image = live.mode == selected ? live.preview : idlePreview {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxHeight: 420).background(.black, in: RoundedRectangle(cornerRadius: 22))
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            } else { PixelArtwork().frame(maxHeight: 260) }
            HStack {
                Text(live.mode == nil ? "Nothing is being sent to the backpack." : live.status)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { themeEditor = true } label: { Label("Customize", systemImage: "slider.horizontal.3") }
                    .font(.subheadline.weight(.semibold))
            }
        }.padding(22).glassPanel()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pick your signal").font(.title2.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 10)], spacing: 10) {
                ForEach(LiveMode.allCases) { mode in
                    Button { selected = mode } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: symbol(for: mode)).font(.title3)
                            Text(mode.rawValue).font(.caption.weight(.semibold)).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                            .padding(12)
                            .background(selected == mode ? Color.cyan.opacity(0.16) : Color.white.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected == mode ? .cyan : .white.opacity(0.08)))
                    }.buttonStyle(.plain).foregroundStyle(selected == mode ? .cyan : .primary)
                        .disabled(live.mode != nil)
                }
            }
            if selected == .message { TextField("Your message", text: $live.message).textFieldStyle(.roundedBorder) }
            if selected == .speed {
                Text(library.state.preferences.speedCapEnabled
                    ? "Display cap: \(library.state.preferences.speedCap) \(library.state.preferences.mph ? "mph" : "km/h"). Raw GPS is unchanged."
                    : "Speed cap is off. Configure it in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Stale GPS shows NO GPS. The optional slowdown display is experimental, not a brake sensor.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if selected == .music {
                Text("System Music metadata only, not universal access to other players.").font(.caption).foregroundStyle(.secondary)
            }
            if selected == .motion || selected == .compass {
                Text("Phone measurements, not validated motorcycle lean or heading.").font(.caption).foregroundStyle(.orange)
            }
            if live.mode == nil {
                Button {
                    starting = true
                    app.run {
                        defer { starting = false }
                        app.apply(library.state.preferences)
                        try await live.start(selected)
                    }
                } label: { Label("Go live", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(starting || !app.link.connected || panel.busy || panel.hasDisplayOwner || panel.size == nil)
            } else {
                Button("Stop & restore playback", role: .destructive) { app.run { await live.stop() } }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var presetRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Instant personality").font(.title3.weight(.bold))
                Spacer()
                Button("Make your own") { themeEditor = true }.font(.caption.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(LiveTheme.builtins(for: selected), id: \.name) { preset in
                        Button {
                            app.run {
                                try library.saveTheme(preset.theme, for: selected)
                                app.apply(library.state.preferences)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Circle().fill(preset.theme.foreground.color).frame(width: 20, height: 20)
                                Text(preset.name).font(.subheadline.weight(.semibold))
                                Text(preset.theme.typeface.rawValue).font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 120, alignment: .leading).padding(18).glassPanel(radius: 22)
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 4)
            }
        }
    }

    private var backgroundNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Designed to move with you", systemImage: "iphone.radiowaves.left.and.right").font(.headline)
            Text("An explicitly started GPS session can continue with Always location and Background GPS enabled. Other screens refresh on allowed callbacks; iOS suspension or force-quit can stop updates.")
            Text("Weather is opportunistic, marked STALE after five minutes and NO DATA after fifteen. Stop attempts playback restoration; a lost connection can prevent it. Operate controls only while stationary.")
            LabeledContent("Location", value: sensors.authorization == .authorizedAlways ? "Always" : "Check permission")
        }.font(.caption).foregroundStyle(.secondary).padding(20).glassPanel()
    }

    private func updatePreview() {
        app.run {
            let size = panel.size ?? PanelSize(width: 64, height: 64)
            idlePreview = try MediaCodec.demo(mode: selected, size: size, theme: library.theme(for: selected)).image()
        }
    }

    private func symbol(for mode: LiveMode) -> String {
        switch mode {
        case .speed: return "speedometer"
        case .weather: return "cloud.sun"
        case .music: return "music.note"
        case .motion: return "gyroscope"
        case .clock: return "clock"
        case .compass: return "location.north"
        case .battery: return "battery.100percent"
        case .eyes: return "eyes"
        case .message: return "text.bubble"
        case .loading: return "hourglass"
        }
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var link: BluetoothLink
    @EnvironmentObject private var live: LiveEngine
    @State private var preferences = Preferences()
    @State private var exporter = false
    @State private var document: BinaryDocument?
    @State private var exportName = "led-backpack-backup"
    @State private var importer = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Speed and units") {
                    Toggle("Miles per hour", isOn: $preferences.mph)
                    Toggle("Cap displayed speed", isOn: $preferences.speedCapEnabled)
                    if preferences.speedCapEnabled {
                        Stepper("Maximum: \(preferences.speedCap) \(preferences.mph ? "mph" : "km/h")", value: $preferences.speedCap, in: 1...250)
                    }
                    Text("The cap affects only numbers sent to the display. It does not alter GPS data, motion measurements, or braking detection. Changing units keeps the entered numeric cap; check it before saving.")
                        .font(.caption)
                    Toggle("Fahrenheit weather", isOn: $preferences.fahrenheit)
                    Toggle("Experimental slowdown indicator", isOn: $preferences.brakeDisplay)
                }
                Section("Connection and background") {
                    Toggle("Reconnect after link loss", isOn: $preferences.reconnect)
                    Toggle("Notify on unexpected disconnect", isOn: $preferences.disconnectAlerts)
                    Button("Allow notifications") {
                        app.run {
                            guard try await app.alerts.request() else { throw BackpackError.invalid("Notifications denied. Enable them in iOS Settings.") }
                        }
                    }
                    Toggle("Background GPS during live session", isOn: $preferences.backgroundLocation)
                    Button("Request Always location permission") { app.sensors.requestAlways() }
                    Button("Open iOS Settings") { openSettings() }
                    Text("Start GPS in the foreground. Restart a live session after changing background permission/settings. Location is not collected solely to keep unrelated screens running. Disconnect alerts require permission; OS/force-quit restrictions still apply.")
                        .font(.caption)
                    Button("Save preferences") {
                        app.run {
                            guard (1...250).contains(preferences.speedCap) else { throw BackpackError.invalid("Speed cap must be 1...250.") }
                            try library.savePreferences(preferences)
                            app.apply(preferences)
                        }
                    }
                }
                Section("Local backups") {
                    Button("Export library backup") {
                        app.run {
                            document = BinaryDocument(data: try library.backup()); exportName = "led-backpack-backup"; exporter = true
                        }
                    }
                    Button("Import / merge backup") { importer = true }
                    Text("Includes local GIFs, attribution, playlists and preferences. Import merges media/playlists without overwriting existing files or applying connection permissions. Passwords and location history are not exported. A backup does not read artwork out of the backpack.")
                        .font(.caption)
                }
                Section("Diagnostics") {
                    Button("Export connection log") {
                        app.run {
                            let value: [String: Any] = ["version": 1, "savedAt": Date().ISO8601Format(), "events": link.log]
                            document = BinaryDocument(data: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]))
                            exportName = "led-backpack-diagnostics"; exporter = true
                        }
                    }
                    Text("Logs may contain panel identity and raw status metadata. Password requests are redacted. Review exports before sharing.")
                        .font(.caption)
                    NavigationLink("View recent log") {
                        ScrollView {
                            Text(link.log.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).padding()
                        }.navigationTitle("Diagnostics")
                    }
                }
                Section("About") {
                    Text("LED Backpack • Independent stock-firmware controller")
                    Text("No vendor account, vendor cloud, firmware flashing, or arbitrary memory commands. iOS hardware compatibility and background behavior require on-device validation.")
                        .font(.caption)
                }
            }.modernScene().navigationTitle("Settings")
            .task { preferences = library.state.preferences }
            .fileExporter(isPresented: $exporter, document: document, contentType: .json, defaultFilename: exportName) { result in
                if case .failure(let error) = result { panel.report(error) }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.json]) { result in
                app.run {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else { throw BackpackError.invalid("Backup file access denied.") }
                    defer { url.stopAccessingSecurityScopedResource() }
                    try library.importBackup(Data(contentsOf: url))
                }
            }
        }
    }
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
