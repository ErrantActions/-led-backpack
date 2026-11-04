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
        TabView(selection: $app.selectedTab) {
            LibraryView().tabItem { Label("Library", systemImage: "photo.on.rectangle") }.tag(AppTab.library)
            DeviceView().tabItem { Label("Backpack", systemImage: "backpack") }.tag(AppTab.backpack)
            CreateView().tabItem { Label("Create", systemImage: "paintbrush.pointed") }.tag(AppTab.create)
            LiveView().tabItem { Label("Live", systemImage: "waveform.path") }.tag(AppTab.live)
        }
        .tint(Aurora.mint)
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
    @State private var settings = false

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: link.connected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .font(.title2).foregroundStyle(Aurora.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.connected ? "Connected to your canvas" : "Ready when you are.").font(.headline)
                    Text(link.state).font(.caption).foregroundStyle(.secondary)
                }
            }
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
                Button { app.run { try link.scan() } } label: {
                    HStack { Text("Scan for backpacks"); Spacer(); Image(systemName: "arrow.right") }
                }.buttonStyle(AuroraPrimaryButton()).accessibilityLabel("Scan for backpacks")
                DisclosureGroup("Discovery options") { Toggle("Show all BLE devices", isOn: $link.showAll) }
                ForEach(link.nearby) { item in
                    Button { app.run { try await app.connect(item.id) } } label: {
                        HStack { Text(item.name); Spacer(); Text("\(item.rssi) dBm").foregroundStyle(.secondary) }
                    }
                }
            }
            Text("Keep the backpack powered on. Disconnect the original app or another phone before scanning.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).glassPanel()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                connectionSection
                if !link.connected {
                    BackpackHero(connected: link.connected,
                        size: panel.size.map { "\($0.width) x \($0.height) / STOCK FIRMWARE" } ?? "INDEPENDENT LED CONTROL")
                }
                if link.connected {
                    BackpackMonitor()
                    VStack(alignment: .leading, spacing: 16) { QuickScenes() }.padding(20).glassPanel()
                    displayControls
                    storage
                }
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup("Panel password and compatibility") {
                        VStack(alignment: .leading, spacing: 16) {
                            SecureField("Existing panel password", text: $panel.password).textFieldStyle(.roundedBorder)
                            Toggle("Legacy identity request", isOn: $panel.legacyInit)
                            Toggle("Remember on this iPhone", isOn: $panel.rememberPassword)
                            Button("Authenticate / refresh") {
                                app.run { try await panel.refresh(); try app.rememberPassword() }
                            }.disabled(!link.connected || panel.busy || panel.hasDisplayOwner)
                        }.padding(.top, 16)
                    }
                }.padding(20).glassPanel()
                if link.connected {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup("Change backpack lock") {
                        VStack(alignment: .leading, spacing: 16) {
                            SecureField("New panel password", text: $newPassword).textFieldStyle(.roundedBorder)
                            Button("Change panel password") { disablePassword = false; confirmPassword = true }
                            Button("Disable panel password", role: .destructive) { disablePassword = true; confirmPassword = true }
                            Text("Changing this affects the backpack, not an app account. There is no cloud password recovery. Save your password securely.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 16)
                    }
                }.padding(20).glassPanel().disabled(panel.busy || panel.hasDisplayOwner)
                }
                }
                .padding(20).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }.modernScene()
            .navigationTitle("LED Backpack").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Settings", systemImage: "gearshape") { settings = true } }
            .sheet(isPresented: $settings) { SettingsView() }
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

    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dial it in.").font(.title2.weight(.bold))
            HStack {
                Button("Panel on") { app.run { try await panel.power(true) } }
                Spacer()
                Button("Panel off") { app.run { try await panel.power(false) } }
            }.buttonStyle(.bordered)
            HStack {
                Text("Brightness").font(.subheadline)
                Spacer()
                Text("\(Int(brightness)) / 15").font(.title3.monospaced()).foregroundStyle(Aurora.mint)
            }
            Slider(value: $brightness, in: 0...15, step: 1) { Text("Brightness") }
            Button("Apply brightness \(Int(brightness))") { app.run { try await panel.brightness(Int(brightness)) } }
            Divider().overlay(.white.opacity(0.06))
            Picker("Rotation", selection: $rotation) {
                ForEach(0..<4) { Text("\($0 * 90) degrees").tag($0) }
            }.pickerStyle(.menu)
            Button("Apply rotation") { app.run { try await panel.rotate(rotation) } }
        }.padding(20).glassPanel().disabled(panel.busy || panel.hasDisplayOwner)
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On your backpack").font(.title3.weight(.semibold))
            Text("\(panel.slots.filter(\.occupied).count) / 60 slots occupied").font(.caption).foregroundStyle(.secondary)
            if let progress = panel.progress { ProgressView(value: progress) }
            ForEach(panel.slots) { slot in
                HStack {
                    Label("Slot \(slot.id)", systemImage: slot.occupied ? "photo.fill" : "square.dashed")
                    Spacer()
                    Text(slot.occupied ? "Occupied" : "Empty").font(.caption).foregroundStyle(.secondary)
                    if slot.occupied {
                        Button("Play") { app.run { try await panel.play(slot: slot.id) } }
                        Button(role: .destructive) {
                            selectedDelete = slot.id; showingDelete = true
                        } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                    }
                }.buttonStyle(.borderless)
            }
        }.padding(20).glassPanel().disabled(panel.busy || panel.hasDisplayOwner)
    }
}

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var runner: PlaylistRunner
    @EnvironmentObject private var community: CommunityController
    @StateObject private var cloud = CloudLibraryStore()
    @State private var scope = LibraryScope.all
    @State private var cloudSelection: CommunityCloudItem?
    @State private var showAccount = false
    @State private var libraryVisible = false
    @State private var pendingCloudSave: SavedMedia?
    @State private var settingsSheet = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var importIsVideo = false
    @State private var photoEditorReady = false
    @State private var pendingVideo: ImportedVideo?
    @State private var video: ImportedVideo?
    @State private var videoImporting = false
    @State private var importing = false
    @State private var editor = false
    @State private var editorData: Data?
    @State private var attribution: Attribution?
    @State private var editorCategory: String?
    @State private var editorName = "My artwork"
    @State private var openEditorAfterGallery = false
    @State private var organizing: SavedMedia?
    @State private var sharing: SavedMedia?
    @State private var libraryQuery = ""
    @State private var selectedCategory = ""
    @State private var favoritesOnly = false
    @State private var gallery = false
    @State private var communityGallery = false
    @State private var selected: SavedMedia?
    @State private var targetSlot = 12
    @State private var uploading = false
    @State private var deletion = false
    @State private var previewData: Data?
    @State private var previewTitle = "Artwork"
    @State private var exporting = false
    @State private var exportDocument: BinaryDocument?
    @State private var useDwell = false
    @State private var dwell = 10

    var body: some View {
        NavigationStack { mediaActions }
    }

    private var filteredMedia: [SavedMedia] {
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.state.media.filter { item in
            (scope != .cloud || cloud.connectedItem(item, origin: community.origin, owner: community.user?.id) != nil) &&
            (!favoritesOnly || item.isFavorite) &&
            (selectedCategory.isEmpty || item.categoryName == selectedCategory) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) ||
                item.categoryName.localizedCaseInsensitiveContains(query))
        }
    }

    private var categoryChoices: [String] {
        let remote = cloud.items.map { CommunityCategory(rawValue: $0.item.category)?.label ?? $0.item.category }
        return Array(Set((library.mediaCategories + remote + ["Uncategorized", selectedCategory]).filter { !$0.isEmpty })).sorted()
    }

    private var libraryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AuroraHeading(eyebrow: "Your collection", title: "Your world.", accent: "On repeat.")
                libraryHeader
                libraryArtwork
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { collectionLinks }
                    VStack(spacing: 12) { collectionLinks }
                }
            }
            .padding(20).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }
        .modernScene().navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $libraryQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search your artwork")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showAccount = true } label: { Image(systemName: community.signedIn ? "person.crop.circle.fill" : "person.crop.circle") }
                    .accessibilityLabel("Catalog account")
            }
            ToolbarItem(placement: .topBarTrailing) { importMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Category", selection: $selectedCategory) {
                        Text("All categories").tag("")
                        ForEach(categoryChoices, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Favorites only", isOn: $favoritesOnly)
                    Button("Settings") { settingsSheet = true }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel("Filter library")
            }
        }
        .task(id: community.accountRevision) { await cloud.refresh(community) }
        .onChange(of: community.accountRevision) { _, _ in cloudSelection = nil }
        .refreshable { await cloud.refresh(community) }
        .navigationDestination(isPresented: $showAccount) { CommunityAccountView() }
        .onAppear {
            libraryVisible = true
            resumeCloudSave()
        }
        .onDisappear { libraryVisible = false }
        .onChange(of: showAccount) { _, value in if !value { resumeCloudSave() } }
    }

    @ViewBuilder
    private var collectionLinks: some View {
        NavigationLink { PlaylistCollection() } label: {
            Label("Playlists", systemImage: "rectangle.stack").frame(maxWidth: .infinity, minHeight: 44).padding(12).glassPanel(radius: 20)
        }
        NavigationLink { ScenesView() } label: {
            Label("Scenes", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, minHeight: 44).padding(12).glassPanel(radius: 20)
        }
    }

    private func resumeCloudSave() {
        guard libraryVisible, !showAccount, let pending = pendingCloudSave else { return }
        pendingCloudSave = nil
        if community.signedIn { sharing = pending }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            LibraryScopeControl(selection: $scope)
            Button { communityGallery = true } label: {
                HStack {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text("Discover GIFs")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
            }.buttonStyle(AuroraPrimaryButton())
            HStack {
                Text("Find your next favorite.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { gallery = true } label: { Label("Commons", systemImage: "globe") }.font(.caption.weight(.semibold))
            }
            if !community.signedIn {
                Text("Browse and save GIFs freely. Sign in only when you want cloud storage or community actions.")
                    .font(.caption).foregroundStyle(.secondary)
                if scope == .cloud { Button("Sign in for your cloud library") { showAccount = true } }
            }
            if videoImporting { ProgressView("Importing artwork...") }
        }
    }

    private var libraryArtwork: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("In your rotation").font(.title3.weight(.semibold))
                Spacer()
                Image(systemName: "square.grid.2x2").foregroundStyle(Aurora.lavender).accessibilityHidden(true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(filteredMedia) { item in
                    let connected = cloud.connectedItem(item, origin: community.origin, owner: community.user?.id)
                    LibraryMediaRow(item: item, cloudStatus: connected?.visibility) { action in handle(action, item: item) }
                }
                if scope != .device {
                    ForEach(filteredCloud) { item in CloudArtworkRow(cloud: item) { cloudSelection = item } }
                }
            }
            if scope != .device {
                if cloud.loading { ProgressView("Updating cloud library...") }
                if cloud.nextPage != nil {
                    Button("Load more cloud artwork") { Task { await cloud.loadMore(community) } }.disabled(cloud.loading)
                }
                if let failure = cloud.failure {
                    Label(failure, systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
                    Button("Retry cloud refresh") { Task { await cloud.refresh(community) } }
                }
            }
            if filteredMedia.isEmpty && (scope == .device || filteredCloud.isEmpty) && !cloud.loading {
                ContentUnavailableView("Make this space yours", systemImage: "photo.on.rectangle.angled",
                    description: Text("Discover a GIF or use + to import artwork. Local copies are always available offline."))
            }
        }
    }

    private var filteredCloud: [CommunityCloudItem] {
        guard !favoritesOnly else { return [] }
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return cloud.cloudOnly(local: library.state.media, origin: community.origin, owner: community.user?.id).filter {
            (selectedCategory.isEmpty || CommunityCategory(rawValue: $0.item.category)?.label == selectedCategory ||
                $0.item.category == selectedCategory) &&
            (query.isEmpty || $0.item.title.localizedCaseInsensitiveContains(query) || $0.item.category.localizedCaseInsensitiveContains(query))
        }
    }

    private var importMenu: some View {
        Menu {
            Button("Photo or GIF") { importIsVideo = false; showingPhotos = true }
            Button("Image or GIF file") { importIsVideo = false; importing = true }
            Button("Video from Photos") { importIsVideo = true; showingPhotos = true }
            Button("Video file to GIF") { importIsVideo = true; importing = true }
        } label: { Image(systemName: "plus") }.accessibilityLabel("Add artwork").disabled(videoImporting)
    }

    private var importingContent: some View {
        videoImports
            .photosPicker(isPresented: $showingPhotos, selection: $selectedPhoto,
                matching: importIsVideo ? .videos : .images, preferredItemEncoding: .current)
            .onChange(of: showingPhotos) { _, visible in if !visible { presentImportedArtwork() } }
            .onChange(of: importing) { _, visible in if !visible { presentImportedArtwork() } }
            .onChange(of: selectedPhoto) { _, item in
                guard let item, !videoImporting else { return }
                let isVideo = importIsVideo
                videoImporting = true
                Task {
                    defer { videoImporting = false; selectedPhoto = nil }
                    do {
                        if isVideo {
                            guard let imported = try await item.loadTransferable(type: ImportedVideo.self) else {
                                throw BackpackError.invalid("Could not import the selected video.")
                            }
                            pendingVideo = imported
                        } else {
                            guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                                throw BackpackError.invalid("Could not load the selected photo or GIF.")
                            }
                            prepareImportedImage(data, name: "Imported photo")
                        }
                        presentImportedArtwork()
                    } catch { panel.report(error) }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: importIsVideo ? [.movie, .video] : [.image, .gif]) { result in
                do {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else { throw BackpackError.invalid("File access denied.") }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if importIsVideo {
                        pendingVideo = try ImportedVideo.copy(url)
                    } else {
                        let data = try Data(contentsOf: url)
                        guard !data.isEmpty else { throw BackpackError.invalid("The selected image or GIF is empty.") }
                        prepareImportedImage(data, name: url.deletingPathExtension().lastPathComponent)
                    }
                    presentImportedArtwork()
                } catch {
                    if (error as NSError).domain != NSCocoaErrorDomain || (error as NSError).code != NSUserCancelledError {
                        panel.report(error)
                    }
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

    private func prepareImportedImage(_ data: Data, name: String) {
        editorData = data; attribution = nil; editorCategory = nil; editorName = name
        photoEditorReady = true
    }

    private func presentImportedArtwork() {
        guard !showingPhotos, !importing else { return }
        if let imported = pendingVideo {
            pendingVideo = nil; video = imported
        } else if photoEditorReady {
            photoEditorReady = false; editor = true
        }
    }

    private var videoImports: some View {
        libraryList
            .sheet(item: $video) { imported in
                VideoGIFEditor(video: imported)
                    .onDisappear {
                        do { try imported.remove() }
                        catch { panel.report(error) }
                    }
            }
    }

    private var mediaActions: some View {
        importingContent
            .sheet(isPresented: $communityGallery, onDismiss: {
                if openEditorAfterGallery { openEditorAfterGallery = false; editor = true }
            }) {
                CommunityGallery { data, credit, category, title in
                    editorData = data; attribution = credit; editorCategory = category; editorName = title
                    openEditorAfterGallery = true; communityGallery = false
                }
            }
            .sheet(isPresented: $settingsSheet) { SettingsView() }
            .sheet(item: $cloudSelection, onDismiss: { Task { await cloud.refresh(community) } }) { CloudArtworkDetail(cloud: $0) }
            .sheet(item: $organizing) { MediaOrganizer(item: $0) }
            .sheet(item: $sharing, onDismiss: { Task { await cloud.refresh(community) } }) { CommunityUploadView(item: $0) }
            .sheet(isPresented: Binding(get: { previewData != nil }, set: { if !$0 { previewData = nil } })) {
                NavigationStack {
                    if let data = previewData {
                        AnimatedPreview(data: data).navigationTitle(previewTitle)
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
        case .preview: app.run { previewTitle = item.name; previewData = try library.data(item) }
        case .edit:
            app.run {
                editorData = try library.data(item)
                attribution = item.attribution; editorCategory = item.category
                editorName = "\(item.name) edited"; editor = true
            }
        case .send: selected = item; uploading = true
        case .share:
            if !community.signedIn { pendingCloudSave = item; showAccount = true }
            else if let connected = cloud.connectedItem(item, origin: community.origin, owner: community.user?.id) {
                cloudSelection = connected
            } else { sharing = item }
        case .export:
            app.run { exportDocument = BinaryDocument(data: try library.data(item)); exporting = true }
        case .organize: organizing = item
        case .delete: selected = item; deletion = true
        }
    }
}
