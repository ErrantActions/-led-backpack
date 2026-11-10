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
    @State private var failure: String?
    var body: some View {
        List {
            Button("New playlist", systemImage: "plus") { creating = true }
                .buttonStyle(AuroraPrimaryButton())
            if let failure { Text(failure).foregroundStyle(.orange) }
            if panel.busy { ProgressView("Updating backpack playback") }
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
                        Menu("Play & edit", systemImage: "play.circle") {
                            Button("Loop on backpack") {
                                app.run {
                                    do {
                                        try playlist.validateForDevice(serial: panel.identity?.serial, inventory: panel.slots)
                                        try await panel.play(list: playlist.slots)
                                        failure = nil
                                    } catch { failure = error.localizedDescription; throw error }
                                }
                            }
                                .disabled(!app.link.connected || panel.busy || panel.hasDisplayOwner)
                            Button("Timed sequence") {
                                app.run {
                                    do { try await runner.start(playlist, repeatPlaylist: repeating); failure = nil }
                                    catch { failure = error.localizedDescription; throw error }
                                }
                            }
                                .disabled(!app.link.connected || panel.busy || panel.hasDisplayOwner)
                            Button("Edit order and timing") { editing = playlist }
                            Button("Remove list, keep artwork", role: .destructive) {
                                app.run {
                                    do { try library.removePlaylist(playlist.id); failure = nil }
                                    catch { failure = error.localizedDescription; throw error }
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                }
            }
            DisclosureGroup("Timed playback options") {
                Toggle("Repeat timed sequences", isOn: $repeating)
                Text("Stored loops can continue without the app. Timed sequences require the foreground and stop/restore on background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .modernScene().navigationTitle("Playlists")
        .toolbar { Button("New playlist", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) { PlaylistEditor() }
        .sheet(item: $editing) { PlaylistEditor(playlist: $0) }
    }
}

@MainActor
private struct PlaylistEditor: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @Environment(\.dismiss) private var dismiss
    let playlist: SavedPlaylist?
    @State private var name = ""
    @State private var draft = PlaylistDraft()
    @State private var serial: String?
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var failure: String?
    init(playlist: SavedPlaylist? = nil) { self.playlist = playlist }
    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Playlist name", text: $name)
                    Text(serial.map { "Backpack: \($0)" } ?? "Legacy/unbound playlist: verify the connected backpack before playback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Playback order") {
                    EditButton()
                    Text("Edit to reorder or remove entries. This does not delete stored artwork.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($draft.entries) { $entry in
                        VStack(alignment: .leading) {
                            Text("Slot \(entry.slot)")
                            Stepper("Foreground sequence: \(Int(entry.seconds))s", value: $entry.seconds,
                                in: 1...3600, step: 1)
                        }
                    }
                    .onMove { offsets, target in
                        do { try draft.move(offsets, to: target) } catch { failure = error.localizedDescription; panel.report(error) }
                    }
                    .onDelete { offsets in
                        do { try draft.remove(offsets) } catch { failure = error.localizedDescription; panel.report(error) }
                    }
                }
                Section("Append stored artwork") {
                    Text("Tap repeatedly to use a slot more than once. Up to 60 entries.")
                        .font(.caption)
                    if panel.inventoryDeviceID == nil { Text("Connect and refresh backpack storage to add GIFs.") }
                    if serial == nil || serial == panel.identity?.serial {
                        ForEach(panel.slots.filter(\.occupied)) { slot in
                            Button {
                                do { try draft.append(slot.id) } catch { failure = error.localizedDescription; panel.report(error) }
                            } label: {
                                HStack {
                                    StoredSlotThumbnail(slot: slot).frame(width: 48, height: 48)
                                    Text("Add slot \(slot.id)")
                                }
                            }.disabled(draft.entries.count >= 60 || panel.inventoryDeviceID != panel.link.selectedID || panel.inventoryDeviceID == nil)
                        }
                    } else { Text("Connect this playlist's backpack to add slots.") }
                }
                InteractionExplanation("Backpack loop uses stored GIF durations, not these foreground timing values. Editing the list does not overwrite artwork.", details: "Loop on backpack sends the ordered slot list once and continues without the phone. The per-entry seconds above are for foreground timed sequences only. Autonomous dwell uses each GIF/program's already stored duration; editing this list never silently overwrites backpack artwork.")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure { Text(failure).foregroundStyle(.orange) }
                Button("Save playlist") {
                    app.run {
                        do {
                            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            let ids = draft.entries.map(\.slot), durations = draft.entries.map(\.seconds)
                            if var existing = playlist {
                                existing.name = title; existing.slots = ids; existing.durations = durations; existing.panelSerial = serial
                                try library.updatePlaylist(existing)
                            } else { try library.savePlaylist(name: title, slots: ids, durations: durations, panelSerial: serial) }
                            dismiss()
                        } catch { failure = error.localizedDescription; throw error }
                    }
                }.buttonStyle(AuroraPrimaryButton())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.entries.isEmpty || loadFailed)
            }.modernScene().navigationTitle(playlist == nil ? "New playlist" : "Edit playlist")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                }
                .safeAreaInset(edge: .bottom) {
                    Button("Cancel") { dismiss() }
                        .frame(maxWidth: .infinity, minHeight: 44).padding(8).background(.regularMaterial)
                }
                .task {
                    guard !loaded else { return }
                    loaded = true
                    serial = playlist?.panelSerial ?? (panel.link.connected && panel.inventoryDeviceID != nil &&
                        panel.inventoryDeviceID == panel.link.selectedID ? panel.identity?.serial : nil)
                    if let playlist {
                        name = playlist.name
                        do { draft = try PlaylistDraft(playlist) }
                        catch { loadFailed = true; failure = error.localizedDescription; panel.report(error) }
                    }
                }
        }
    }
}
