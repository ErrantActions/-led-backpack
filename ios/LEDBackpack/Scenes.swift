import SwiftUI
import BackpackProtocol

enum SavedSceneContent: Codable, Equatable {
    case live(mode: LiveMode, theme: LiveTheme, message: String)
    case playlist(panel: String, slots: [Int], durations: [Double]?, repeatPlaylist: Bool)

    var summary: String {
        switch self {
        case .live(let mode, _, _): return mode.rawValue
        case .playlist(_, let slots, let durations, _):
            return "\(slots.count) slots / \(durations == nil ? "stored loop" : "foreground timing")"
        }
    }
}

struct SavedScene: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var brightness: Int
    var content: SavedSceneContent

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              (0...15).contains(brightness) else {
            throw BackpackError.invalid("Scenes need a name up to 40 characters and brightness from 0 to 15.")
        }
        switch content {
        case .live(let mode, let theme, let message):
            try theme.validate()
            guard message.count <= 80,
                  mode != .message || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackpackError.invalid("A scrolling-message scene needs 1 to 80 characters.")
            }
        case .playlist(let panel, let slots, let durations, let repeatPlaylist):
            guard !panel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !slots.isEmpty, slots.count <= 60, slots.allSatisfy({ (0..<60).contains($0) }) else {
                throw BackpackError.invalid("Playlist scenes need a backpack and 1 to 60 valid slots.")
            }
            if let durations {
                guard durations.count == slots.count,
                      durations.allSatisfy({ $0.isFinite && (1...3600).contains($0) }) else {
                    throw BackpackError.invalid("Scene durations must match the slots and be 1...3600 seconds.")
                }
            } else if !repeatPlaylist {
                throw BackpackError.invalid("Stored playback loops on the backpack. Use foreground timing for a single pass.")
            }
        }
    }
}

@MainActor
struct QuickScenes: View {
    @EnvironmentObject private var library: LocalLibrary
    var body: some View {
        Section("One-tap scenes") {
            ForEach(Array((library.state.scenes ?? []).prefix(3))) { scene in
                SceneLaunchRow(scene: scene)
            }
            NavigationLink {
                ScenesView()
            } label: {
                Label("Manage scenes", systemImage: "square.stack.3d.up")
            }
        }
    }
}

@MainActor
private struct SceneLaunchRow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var link: BluetoothLink
    @EnvironmentObject private var panel: PanelController
    let scene: SavedScene
    var body: some View {
        Button {
            app.run { try await app.applyScene(scene) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.name).foregroundStyle(.primary)
                    Text("\(scene.content.summary) / brightness \(scene.brightness)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if app.applyingSceneID == scene.id { ProgressView() }
            }
        }
        .disabled(!link.connected || panel.busy || app.applyingSceneID != nil)
        .accessibilityHint("Stops the current live or timed display and applies this saved scene.")
    }
}

@MainActor
struct ScenesView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @State private var creating = false
    @State private var editing: SavedScene?

    var body: some View {
        List {
            Section {
                Text("Your display, ready in one tap").font(.title2.bold())
                Text("Save a live screen or backpack playlist. No artwork is uploaded or replaced.").font(.subheadline).foregroundStyle(.secondary)
                Button("Create scene") { creating = true }.buttonStyle(AuroraPrimaryButton())
                if let status = app.sceneStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Saved scenes") {
                if (library.state.scenes ?? []).isEmpty {
                    ContentUnavailableView("Your next display, one tap away", systemImage: "square.stack.3d.up",
                        description: Text("Create a scene using your saved live theme or a playlist."))
                }
                ForEach(library.state.scenes ?? []) { scene in
                    SceneLaunchRow(scene: scene)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { app.run { try library.deleteScene(scene.id) } }
                            Button("Edit") { editing = scene }.tint(.cyan)
                        }
                        .contextMenu {
                            Button("Edit scene") { editing = scene }
                            Button("Delete scene", role: .destructive) { app.run { try library.deleteScene(scene.id) } }
                        }
                }
            }
        }
        .modernScene().navigationTitle("Scenes")
        .toolbar { Button("Add scene", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) { SceneEditor() }
        .sheet(item: $editing) { SceneEditor(scene: $0) }
    }
}

@MainActor
private struct SceneEditor: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var live: LiveEngine
    @Environment(\.dismiss) private var dismiss
    let scene: SavedScene?
    @State private var name: String
    @State private var brightness: Double
    @State private var isPlaylist = false
    @State private var mode = LiveMode.clock
    @State private var theme = LiveTheme.standard(for: .clock)
    @State private var message = ""
    @State private var playlistID: UUID?
    @State private var originalPlaylist: SavedPlaylist?
    @State private var originalPanel: String?
    @State private var timed = false
    @State private var repeatPlaylist = true

    init(scene: SavedScene? = nil) {
        self.scene = scene
        _name = State(initialValue: scene?.name ?? "")
        _brightness = State(initialValue: Double(scene?.brightness ?? 8))
        if let scene {
            switch scene.content {
            case .live(let mode, let theme, let message):
                _mode = State(initialValue: mode)
                _theme = State(initialValue: theme)
                _message = State(initialValue: message)
            case .playlist(let panel, let slots, let durations, let repeats):
                _isPlaylist = State(initialValue: true)
                _originalPlaylist = State(initialValue: SavedPlaylist(name: "Saved scene playlist", slots: slots, durations: durations))
                _originalPanel = State(initialValue: panel)
                _timed = State(initialValue: durations != nil)
                _repeatPlaylist = State(initialValue: repeats)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scene") {
                    TextField("Scene name", text: $name)
                    Stepper("Brightness: \(Int(brightness))", value: $brightness, in: 0...15, step: 1)
                    Toggle("Use a stored playlist", isOn: $isPlaylist)
                }
                if isPlaylist { playlistOptions } else { liveOptions }
                Section {
                    Text("Applying a scene stops the current live/timed session first. A failed operation may leave brightness changed; no artwork is overwritten.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let failure = panel.errorMessage { Text(failure).foregroundStyle(.orange) }
                    Button("Save scene", action: save).buttonStyle(AuroraPrimaryButton())
                }
            }
            .modernScene().navigationTitle(scene == nil ? "New scene" : "Edit scene")
            .safeAreaInset(edge: .bottom) { NativeFlowCancelFooter { dismiss() } }
            .toolbar { Button("Cancel") { dismiss() } }
            .onChange(of: mode) { _, selected in theme = library.theme(for: selected) }
            .task {
                if scene == nil {
                    theme = library.theme(for: mode)
                    message = String(live.message.prefix(80))
                    playlistID = library.state.playlists.first?.id
                }
            }
        }
    }

    private var liveOptions: some View {
        Section("Live display") {
            Picker("Screen", selection: $mode) {
                ForEach(LiveMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if mode == .message { TextField("Scrolling message", text: $message) }
            LabeledContent("Saved ink", value: theme.foreground.rawValue.capitalized)
            LabeledContent("Saved effect", value: theme.inkEffect.rawValue)
            Button("Copy current theme for this screen") { theme = library.theme(for: mode) }
            Text("Customize themes in Live first. A scene saves its own theme copy; later theme edits do not change it. Location, Music and sensor permissions still apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var playlistOptions: some View {
        Section("Playlist") {
            Picker("Source playlist", selection: $playlistID) {
                Text(originalPlaylist == nil ? "Choose a playlist" : "Keep saved scene playlist").tag(Optional<UUID>.none)
                ForEach(library.state.playlists) { playlist in
                    Text(playlist.name).tag(Optional(playlist.id))
                }
            }
            Toggle("Use foreground per-slot timing", isOn: $timed)
            if timed { Toggle("Repeat sequence", isOn: $repeatPlaylist) }
            Text(timed
                ? "Uses saved playlist durations, or 10 seconds per slot if none were set. Stops when the app enters the background."
                : "The backpack loops the slots using timing already stored on it, without needing the app to stay active.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Connect before selecting a new playlist. Scenes keep a copy of the slot list and bind it to that backpack; deleting the original playlist does not delete the scene.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        app.run {
            let content: SavedSceneContent
            if isPlaylist {
                let selected: SavedPlaylist
                let panelID: String
                if let playlistID {
                    guard let playlist = library.state.playlists.first(where: { $0.id == playlistID }) else {
                        throw BackpackError.invalid("The selected playlist was deleted. Choose another playlist.")
                    }
                    guard panel.link.connected, let serial = panel.identity?.serial else {
                        throw BackpackError.invalid("Connect to the backpack before saving a playlist scene.")
                    }
                    selected = playlist; panelID = serial
                } else {
                    guard let originalPlaylist, let originalPanel else {
                        throw BackpackError.invalid("Choose a playlist first.")
                    }
                    selected = originalPlaylist; panelID = originalPanel
                }
                let durations = timed ? selected.durations ?? Array(repeating: 10, count: selected.slots.count) : nil
                content = .playlist(panel: panelID, slots: selected.slots, durations: durations,
                    repeatPlaylist: timed ? repeatPlaylist : true)
            } else {
                content = .live(mode: mode, theme: theme, message: message)
            }
            var value = SavedScene(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                brightness: Int(brightness), content: content)
            if let scene { value.id = scene.id }
            try library.saveScene(value)
            dismiss()
        }
    }
}
