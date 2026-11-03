import SwiftUI

@MainActor
struct BackpackMonitor: View {
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var link: BluetoothLink
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Now on backpack", systemImage: "display").font(.headline)
                Spacer()
                Text(link.connected ? "EXPECTED OUTPUT" : "OFFLINE").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let image = panel.monitorImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 18))
            } else if let data = panel.monitorGIF {
                AnimatedPreview(data: data).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                ContentUnavailableView("No readable pixels", systemImage: "eye.slash",
                    description: Text("Live frames sent by this app and its cached uploads can be previewed here."))
            }
            Text(panel.monitorCaption).font(.caption).foregroundStyle(.secondary)
            Text("No device screen-stream/readback command has been found. GIF phase, unknown stored artwork, and changes made elsewhere may not match this preview.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20).glassPanel()
    }
}

@MainActor
struct PlaylistTimingEditor: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SavedPlaylist
    @State private var durations: [Double]
    init(_ playlist: SavedPlaylist) {
        _draft = State(initialValue: playlist)
        _durations = State(initialValue: playlist.durations ?? Array(repeating: 10, count: playlist.slots.count))
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $draft.name)
                Section("App-driven duration per GIF") {
                    ForEach(Array(draft.slots.enumerated()), id: \.offset) { entry in
                        Stepper("Slot \(entry.element): \(Int(durations[entry.offset]))s",
                            value: Binding(get: { durations[entry.offset] }, set: { durations[entry.offset] = $0 }),
                            in: 1...3600, step: 1)
                    }
                }
                Text("These durations apply to the foreground timed sequence. The backpack's autonomous loop uses timing already stored with its GIFs/programs; changing this list does not rewrite device storage.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save timings") {
                    app.run { draft.durations = durations; try library.updatePlaylist(draft); dismiss() }
                }.buttonStyle(.borderedProminent)
            }.modernScene().navigationTitle("Playlist timing")
                .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
