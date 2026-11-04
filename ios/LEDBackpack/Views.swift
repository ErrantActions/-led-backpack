import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit
import BackpackProtocol

struct BinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .json, .gif] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BackpackError.invalid("Could not read the file.")
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct AnimatedPreview: UIViewRepresentable {
    let data: Data
    final class Coordinator { var data: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.isScrollEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>body{margin:0;background:#000}img{width:100%;height:100vh;object-fit:contain;image-rendering:pixelated}</style>
        <img alt="Local animation preview" src="data:image/gif;base64,\(data.base64EncodedString())">
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var panel: PanelController
    var body: some View {
        TabView {
            DeviceView().tabItem { Label("Backpack", systemImage: "backpack") }
            LibraryView().tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            StudioView().tabItem { Label("Studio", systemImage: "paintbrush.pointed") }
            LiveView().tabItem { Label("Live", systemImage: "waveform.path") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .disabled(app.applyingSceneID != nil)
        .alert("LED Backpack", isPresented: Binding(get: { panel.errorMessage != nil },
            set: { if !$0 { panel.errorMessage = nil } })) {
            Button("OK") { panel.errorMessage = nil }
        } message: { Text(panel.errorMessage ?? "") }
    }
}

@MainActor
struct DeviceView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var link: BluetoothLink
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var live: LiveEngine
    @State private var brightness = 8.0
    @State private var rotation = 0
    @State private var newPassword = ""
    @State private var confirmPassword = false
    @State private var disablePassword = false
    @State private var selectedDelete: Int?
    @State private var showingDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    BackpackHero(connected: link.connected,
                        size: panel.size.map { "\($0.width) x \($0.height) / STOCK FIRMWARE" } ?? "INDEPENDENT LED CONTROL")
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                Section {
                    BackpackMonitor().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                QuickScenes()
                Section {
                    Label(link.state, systemImage: link.connected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(link.connected ? .green : .secondary)
                    if let identity = panel.identity {
                        LabeledContent("Model", value: identity.model)
                        LabeledContent("Firmware", value: identity.firmware)
                    }
                    if let size = panel.size { LabeledContent("Panel", value: "\(size.width) x \(size.height)") }
                    if link.connected {
                        Button("Refresh status") { app.run { try await panel.refresh() } }.disabled(panel.busy || panel.hasDisplayOwner)
                        Button("Disconnect", role: .destructive) {
                            app.run { await live.stop(); await app.playlist.stop(); link.disconnect() }
                        }
                    } else {
                        Toggle("Show all BLE devices", isOn: $link.showAll)
                        Button("Scan for backpacks") { app.run { try link.scan() } }
                        ForEach(link.nearby) { item in
                            Button {
                                app.run { try await app.connect(item.id) }
                            } label: {
                                HStack { Text(item.name); Spacer(); Text("\(item.rssi) dBm").foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: { Text("Connection") } footer: {
                    Text("Use the backpack's power brick. Disconnect other phone/Windows clients first. No pairing or vendor account is normally required.")
                }
                Section("Panel authentication") {
                    SecureField("Existing panel password", text: $panel.password)
                    Toggle("Legacy identity request", isOn: $panel.legacyInit)
                    Toggle("Remember on this iPhone", isOn: $panel.rememberPassword)
                    Button("Authenticate / refresh") {
                        app.run {
                            try await panel.refresh()
                            try app.rememberPassword()
                        }
                    }.disabled(!link.connected || panel.busy || panel.hasDisplayOwner)
                }
                Section("Display controls") {
                    HStack {
                        Button("Panel on") { app.run { try await panel.power(true) } }
                        Spacer()
                        Button("Panel off") { app.run { try await panel.power(false) } }
                    }.buttonStyle(.bordered)
                    Slider(value: $brightness, in: 0...15, step: 1) { Text("Brightness") }
                    Button("Apply brightness \(Int(brightness))") { app.run { try await panel.brightness(Int(brightness)) } }
                    Picker("Rotation", selection: $rotation) {
                        ForEach(0..<4) { Text("\($0 * 90) degrees").tag($0) }
                    }
                    Button("Apply rotation") { app.run { try await panel.rotate(rotation) } }
                }.disabled(!link.connected || panel.busy || panel.hasDisplayOwner)
                Section {
                    SecureField("New panel password", text: $newPassword)
                    Button("Change panel password") { disablePassword = false; confirmPassword = true }
                    Button("Disable panel password", role: .destructive) { disablePassword = true; confirmPassword = true }
                } header: { Text("Panel lock") } footer: {
                    Text("Changing this affects the backpack, not an app account. There is no cloud password recovery. Save your password securely.")
                }.disabled(!link.connected || panel.busy || panel.hasDisplayOwner)
                Section("Storage: \(panel.slots.filter(\.occupied).count)/60 occupied") {
                    if let progress = panel.progress { ProgressView(value: progress) }
                    ForEach(panel.slots) { slot in
                        HStack {
                            Label("Slot \(slot.id)", systemImage: slot.occupied ? "photo.fill" : "square.dashed")
                            Spacer()
                            Text(slot.occupied ? "Occupied" : "Empty").foregroundStyle(.secondary)
                            if slot.occupied {
                                Button("Play") { app.run { try await panel.play(slot: slot.id) } }
                                Button(role: .destructive) {
                                    selectedDelete = slot.id; showingDelete = true
                                } label: { Image(systemName: "trash") }
                            }
                        }.buttonStyle(.borderless)
                    }
                }.disabled(!link.connected || panel.busy || panel.hasDisplayOwner)
            }.modernScene()
            .navigationTitle("LED Backpack")
            .confirmationDialog(disablePassword ? "Disable the panel password?" : "Change the panel password?", isPresented: $confirmPassword) {
                Button("Apply to backpack", role: .destructive) {
                    app.run {
                        try await panel.configurePassword(newPassword, disable: disablePassword)
                        try app.rememberPassword()
                        newPassword = ""
                    }
                }
            }
            .confirmationDialog("Permanently delete stored artwork?", isPresented: $showingDelete) {
                Button("Delete slot \(selectedDelete ?? 0)", role: .destructive) {
                    if let slot = selectedDelete { app.run { try await panel.delete(slot: slot) } }
                }
            } message: { Text("There is no firmware-level backup/readback of stored artwork. This cannot be undone.") }
        }
    }
}

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var runner: PlaylistRunner
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importing = false
    @State private var editor = false
    @State private var editorData: Data?
    @State private var attribution: Attribution?
    @State private var editorCategory: String?
    @State private var editorName = "My artwork"
    @State private var openEditorAfterGallery = false
    @State private var organizing: SavedMedia?
    @State private var libraryQuery = ""
    @State private var selectedCategory = ""
    @State private var favoritesOnly = false
    @State private var gallery = false
    @State private var selected: SavedMedia?
    @State private var targetSlot = 12
    @State private var uploading = false
    @State private var deletion = false
    @State private var previewData: Data?
    @State private var exporting = false
    @State private var exportDocument: BinaryDocument?
    @State private var playlistName = ""
    @State private var playlistSlots = ""
    @State private var editingPlaylist: SavedPlaylist?
    @State private var repeatPlaylist = true
    @State private var useDwell = false
    @State private var dwell = 10

    var body: some View {
        NavigationStack { mediaActions }
    }

    private var filteredMedia: [SavedMedia] {
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.state.media.filter { item in
            (!favoritesOnly || item.isFavorite) &&
            (selectedCategory.isEmpty || item.categoryName == selectedCategory) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) ||
                item.categoryName.localizedCaseInsensitiveContains(query))
        }
    }

    private var categoryChoices: [String] {
        Array(Set((library.mediaCategories + ["Uncategorized", selectedCategory]).filter { !$0.isEmpty })).sorted()
    }

    private var libraryList: some View {
        List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        StatusPill(title: "YOUR COLLECTION", symbol: "square.stack.3d.up")
                        Text("Small screen.\nBig energy.").font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1)
                        Text("Make a little room for a lot of personality.").foregroundStyle(.secondary)
                    }.padding(22).glassPanel()
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section("Add artwork") {
                    PhotosPicker("Choose photo or GIF", selection: $selectedPhoto, matching: .images)
                    Button("Import image / animated GIF file") { importing = true }
                    Button("Search licensed GIFs") { gallery = true }
                }
                Section("Browse your collection") {
                    TextField("Search saved artwork", text: $libraryQuery)
                    Picker("Category", selection: $selectedCategory) {
                        Text("All categories").tag("")
                        ForEach(categoryChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Favorites only", isOn: $favoritesOnly)
                }
                Section("Local media (\(filteredMedia.count))") {
                    ForEach(filteredMedia) { item in
                        LibraryMediaRow(item: item) { action in handle(action, item: item) }
                    }
                    if filteredMedia.isEmpty {
                        Text(library.state.media.isEmpty ? "Save artwork from the editor or GIF search." : "No artwork matches these filters.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Local playlists") {
                    Toggle("Repeat app-driven sequence", isOn: $repeatPlaylist)
                    if runner.running {
                        Text(runner.status)
                        Button("Stop timed sequence & restore", role: .destructive) { app.run { await runner.stop() } }
                    }
                    TextField("Playlist name", text: $playlistName)
                    TextField("Slot IDs, e.g. 2,4,7", text: $playlistSlots).keyboardType(.numbersAndPunctuation)
                    Button("Save playlist") {
                        app.run {
                            let tokens = playlistSlots.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            let ids = tokens.compactMap(Int.init)
                            guard ids.count == tokens.count else { throw BackpackError.invalid("Use comma-separated slot numbers.") }
                            try library.savePlaylist(name: playlistName, slots: ids)
                            playlistName = ""; playlistSlots = ""
                        }
                    }
                    ForEach(library.state.playlists) { playlist in
                        VStack(alignment: .leading) {
                            Text(playlist.name).font(.headline)
                            Text(playlist.slots.map(String.init).joined(separator: ", ")).font(.caption)
                            Menu("Playlist actions") {
                                Button("Loop on backpack") { app.run { try await panel.play(list: playlist.slots) } }
                                    .disabled(!app.link.connected || panel.busy || panel.hasDisplayOwner)
                                Button("Timed sequence") { app.run { try await runner.start(playlist, repeatPlaylist: repeatPlaylist) } }
                                    .disabled(!app.link.connected || panel.busy || panel.hasDisplayOwner)
                                Button("Timing") { editingPlaylist = playlist }
                                Button("Remove list", role: .destructive) {
                                    app.run { try library.removePlaylist(playlist.id) }
                                }
                                Text("Loop on backpack uses stored GIF/program timing and can continue without the app. Timed sequence uses per-item app durations, requires the foreground, and stops/restores when backgrounded. Edit order by saving a new slot list.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
        }.modernScene().navigationTitle("Library")
    }

    private var importingContent: some View {
        libraryList
            .onChange(of: selectedPhoto) { _, item in
                app.run {
                    guard let item, let data = try await item.loadTransferable(type: Data.self) else {
                        throw BackpackError.invalid("Could not load the selected photo.")
                    }
                    editorData = data; attribution = nil; editorCategory = nil; editorName = "Imported photo"; editor = true
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .gif]) { result in
                app.run {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else { throw BackpackError.invalid("File access denied.") }
                    defer { url.stopAccessingSecurityScopedResource() }
                    editorData = try Data(contentsOf: url); attribution = nil; editorCategory = nil
                    editorName = url.deletingPathExtension().lastPathComponent; editor = true
                }
            }
            .sheet(isPresented: $editor) {
                if let data = editorData {
                    MediaEditor(data: data, attribution: attribution, category: editorCategory, initialName: editorName)
                }
            }
            .sheet(isPresented: $gallery, onDismiss: {
                if openEditorAfterGallery { openEditorAfterGallery = false; editor = true }
            }) {
                GIFGallery { data, credit, category, title in
                    editorData = data; attribution = credit; editorCategory = category
                    editorName = title
                    openEditorAfterGallery = true
                    gallery = false
                }
            }
    }

    private var mediaActions: some View {
        importingContent
            .sheet(item: $editingPlaylist) { PlaylistTimingEditor($0) }
            .sheet(item: $organizing) { MediaOrganizer(item: $0) }
            .sheet(isPresented: Binding(get: { previewData != nil }, set: { if !$0 { previewData = nil } })) {
                NavigationStack {
                    if let data = previewData {
                        AnimatedPreview(data: data).navigationTitle("Local preview")
                            .toolbar { Button("Done") { previewData = nil } }
                    }
                }
            }
            .sheet(isPresented: $uploading) {
                NavigationStack {
                    Form {
                        Text(selected?.name ?? "Artwork")
                        Stepper("Target slot \(targetSlot)", value: $targetSlot, in: 0...59)
                        Toggle("Write program display duration with upload", isOn: $useDwell)
                        if useDwell { Stepper("Stored duration \(dwell)s", value: $dwell, in: 1...600) }
                        Text("Stored duration uses a recovered app command and still needs iPhone/device verification. Existing programs cannot be safely retimed without their original content.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Uploading begins by deleting the selected slot. Original artwork cannot be read back. Resize in Edit to match the connected panel first.")
                            .foregroundStyle(.orange)
                        Button("Confirm upload / replace", role: .destructive) {
                            guard let item = selected else { return }
                            uploading = false
                            app.run {
                                try await panel.upload(try library.data(item), slot: targetSlot,
                                    overwriteApproved: true, playSeconds: useDwell ? dwell : nil)
                                guard let key = panel.identity?.serial,
                                      let record = panel.slots.first(where: { $0.id == targetSlot }) else {
                                    throw BackpackError.invalid("Upload completed but preview association could not be recorded.")
                                }
                                try library.rememberSlot(panel: key, slot: targetSlot, identifier: record.identifier, mediaID: item.id)
                            }
                        }.disabled(!app.link.connected || panel.busy || panel.hasDisplayOwner)
                    }.navigationTitle("Upload confirmation").toolbar { Button("Cancel") { uploading = false } }
                }
            }
            .confirmationDialog("Delete this local media file?", isPresented: $deletion) {
                Button("Delete local copy", role: .destructive) {
                    if let item = selected { app.run { try library.delete(item) } }
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .gif, defaultFilename: "backpack-artwork") { result in
                if case .failure(let error) = result { panel.report(error) }
            }
    }

    private func handle(_ action: LibraryMediaRow.Action, item: SavedMedia) {
        switch action {
        case .preview: app.run { previewData = try library.data(item) }
        case .edit:
            app.run {
                editorData = try library.data(item)
                attribution = item.attribution; editorCategory = item.category
                editorName = "\(item.name) edited"; editor = true
            }
        case .send: selected = item; uploading = true
        case .export:
            app.run { exportDocument = BinaryDocument(data: try library.data(item)); exporting = true }
        case .organize: organizing = item
        case .delete: selected = item; deletion = true
        }
    }
}
