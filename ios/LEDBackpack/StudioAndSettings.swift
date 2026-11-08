import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import BackpackProtocol

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
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Live canvas").font(.title2.bold())
                            Spacer()
                            StatusPill(title: live.mode == nil ? "Preview" : "Live",
                                symbol: live.mode == nil ? "sparkles" : "dot.radiowaves.left.and.right")
                        }
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 24) {
                                controls.frame(minWidth: 280, maxWidth: 370)
                                VStack(spacing: 20) {
                                    previewCard
                                    DisclosureGroup("Presets") { presetRail }
                                }.frame(maxWidth: .infinity)
                            }
                        } else {
                            previewCard
                            controls
                            DisclosureGroup("Presets") { presetRail }
                        }
                        backgroundNote
                    }
                    .padding(24).frame(maxWidth: 1300, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.background(AuroraBackground()).tint(Aurora.mint)
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
            Text("Choose a mode").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 10)], spacing: 10) {
                ForEach(LiveMode.allCases) { mode in
                    Button { selected = mode } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: symbol(for: mode)).font(.title3)
                            Text(mode.rawValue).font(.caption.weight(.semibold)).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                            .padding(12)
                            .background(selected == mode ? Aurora.mint.opacity(0.09) : Color.white.opacity(0.025),
                                in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected == mode ? Aurora.mint.opacity(0.4) : .white.opacity(0.08)))
                    }.buttonStyle(.plain).foregroundStyle(selected == mode ? Aurora.mint : .primary)
                        .accessibilityAddTraits(selected == mode ? .isSelected : [])
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
                    .buttonStyle(AuroraPrimaryButton())
                    .disabled(starting || !app.link.connected || panel.busy || panel.hasDisplayOwner || panel.size == nil)
            } else {
                Button("Stop & restore playback", role: .destructive) { app.run { await live.stop() } }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var presetRail: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Text("Use controls only while stationary. A lost connection can prevent playback restoration.")
                .foregroundStyle(.orange)
            FeatureDetails("Sensors & background limits") {
            Text("An explicitly started GPS session can continue with Always location and Background GPS enabled. Other screens refresh on allowed callbacks; iOS suspension or force-quit can stop updates.")
            Text("Weather is opportunistic, marked STALE after five minutes and NO DATA after fifteen. Stop attempts playback restoration; a lost connection can prevent it. Operate controls only while stationary.")
            LabeledContent("Location", value: sensors.authorization == .authorizedAlways ? "Always" : "Check permission")
            }
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
    @Environment(\.dismiss) private var dismiss
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
                            preferences.communityURL = library.state.preferences.communityURL
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
                        Section("Community") {
                            NavigationLink("Catalog server and account") { CommunitySettingsView() }
                        }
                    }
                    Button("Import / merge backup") { importer = true }
                    Text("Includes local GIFs, attribution, playlists and preferences, including the optional catalog URL. Import merges media/playlists without overwriting existing files or applying connection permissions. Passwords, catalog sessions, deletion receipts and location history are not exported. A backup does not read artwork out of the backpack.")
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
            .toolbar { Button("Done") { dismiss() } }
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
