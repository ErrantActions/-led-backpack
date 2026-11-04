import SwiftUI
import BackpackProtocol

@MainActor
struct PlaylistCollection: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var runner: PlaylistRunner
    @State private var creating = false
    @State private var editing: SavedPlaylist?
    @State private var repeating = true
    var body: some View {
        List {
            if runner.running {
                Section {
                    Label(runner.status, systemImage: "play.circle.fill")
                    Button("Stop and restore", role: .destructive) { app.run { await runner.stop() } }
                }
            }
            Section {
                if library.state.playlists.isEmpty {
                    ContentUnavailableView("Build a rotation", systemImage: "rectangle.stack",
                        description: Text("Choose stored backpack GIFs, then set the order and timing."))
                }
                ForEach(library.state.playlists) { playlist in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(playlist.name).font(.headline)
                        Text("\(playlist.slots.count) stored GIFs").font(.caption).foregroundStyle(.secondary)
                        Menu("Playback and timing", systemImage: "play.circle") {
                            Button("Loop on backpack") { app.run { try await panel.play(list: playlist.slots) } }
                                .disabled(!app.link.connected || panel.busy || panel.hasDisplayOwner)
                            Button("Timed sequence") { app.run { try await runner.start(playlist, repeatPlaylist: repeating) } }
                                .disabled(!app.link.connected || panel.busy || panel.hasDisplayOwner)
                            Button("Edit timing") { editing = playlist }
                            Button("Remove playlist", role: .destructive) { app.run { try library.removePlaylist(playlist.id) } }
                        }
                    }.padding(.vertical, 6)
                }
            }
            Section {
                Toggle("Repeat timed sequences", isOn: $repeating)
                Text("Stored loops can continue without the app. Timed sequences require the foreground and stop/restore on background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .modernScene().navigationTitle("Playlists")
        .toolbar { Button("New playlist", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) { NewPlaylist() }
        .sheet(item: $editing) { PlaylistTimingEditor($0) }
    }
}

@MainActor
private struct NewPlaylist: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var slots: [Int] = []
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Playlist name", text: $name) }
                Section("Tap GIF slots in playback order") {
                    if panel.slots.isEmpty { Text("Connect and refresh backpack storage to choose GIFs.") }
                    ForEach(panel.slots.filter(\.occupied)) { slot in
                        Button {
                            if slots.contains(slot.id) { slots.removeAll { $0 == slot.id } }
                            else { slots.append(slot.id) }
                        } label: {
                            HStack {
                                Label("Slot \(slot.id)", systemImage: "photo")
                                Spacer()
                                if let index = slots.firstIndex(of: slot.id) { Text("\(index + 1)").bold() }
                            }
                        }
                    }
                }
                Button("Save playlist") {
                    app.run { try library.savePlaylist(name: name, slots: slots); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || slots.isEmpty)
            }.modernScene().navigationTitle("New playlist")
                .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
