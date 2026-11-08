import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit
import BackpackProtocol
import Combine

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
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var vault: CloudVaultStore
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var targets: DisplayTargetSelection
    @EnvironmentObject private var apple: NativeApplePushCoordinator
    @Environment(\.scenePhase) private var phase
    var body: some View {
        TabView(selection: $app.selectedTab) {
            LibraryView().tabItem { Label("Library", systemImage: "photo.on.rectangle") }.tag(AppTab.library)
            SocialTabView().tabItem { Label("Social", systemImage: "person.2") }.tag(AppTab.social)
            DeviceView().tabItem { Label("Backpack", systemImage: "backpack") }.tag(AppTab.backpack)
            CreateView().tabItem { Label("Create", systemImage: "paintbrush.pointed") }.tag(AppTab.create)
            LiveView().tabItem { Label("Live", systemImage: "waveform.path") }.tag(AppTab.live)
        }
        .tint(Aurora.mint)
        .task(id: "\(community.accountRevision)-\(phase)") {
            guard phase == .active else { return }
            await vault.bind(community)
            vault.requestSynchronization(library)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                if community.signedIn && (!vault.available || vault.state == nil) { await vault.bind(community) }
                vault.requestSynchronization(library)
            }
        }
        .onReceive(library.$state.dropFirst().debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in
            if phase == .active { vault.requestSynchronization(library) }
        }
        .onChange(of: phase) { _, value in if value != .active { vault.stopWork() } }
        .disabled(app.applyingSceneID != nil)
        .alert("LED Backpack", isPresented: Binding(get: { panel.errorMessage != nil },
            set: { if !$0 { panel.errorMessage = nil } })) {
            Button("OK") { panel.errorMessage = nil }
        } message: { Text(panel.errorMessage ?? "") }
        .fullScreenCover(isPresented: Binding(get: { phone.presented }, set: { if !$0 { phone.dismiss() } })) {
            PhoneDisplayView()
        }
        .onChange(of: targets.target) { _, target in if target == .hardware { phone.dismiss() } }
        .sheet(isPresented: Binding(get: { apple.destination != nil && !phone.presented }, set: { if !$0 { apple.clearDestination() } })) {
            if let destination = apple.destination {
                NavigationStack {
                    NativePushDestinationView(destination: destination)
                        .toolbar { Button("Done") { apple.clearDestination() } }
                }
            }
        }
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
                    app.run { await app.batch.stop(); await app.drawing.stop(); await live.stop(); await app.playlist.stop(); link.disconnect() }
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
                    DisclosureGroup("Display settings") { displayControls }
                    BackpackStorageView()
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

}

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var runner: PlaylistRunner
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var vault: CloudVaultStore
    @EnvironmentObject private var phone: PhoneDisplayController
    @EnvironmentObject private var targets: DisplayTargetSelection
    @StateObject private var cloud = CloudLibraryStore()
    @State private var cloudSelection: CommunityCloudItem?
    @State private var showAccount = false
    @State private var libraryVisible = false
    @State private var pendingCloudSave: SavedMedia?
    @State private var privateCloudSettings = false
    @State private var foreignCopy: SavedMedia?
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
            (!favoritesOnly || item.isFavorite) &&
            (selectedCategory.isEmpty || item.categoryName == selectedCategory) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) ||
                item.categoryName.localizedCaseInsensitiveContains(query))
        }
    }

    private var categoryChoices: [String] {
        let remote = vault.available ? Array(vault.categories.values) :
            cloud.items.map { CommunityCategory(rawValue: $0.item.category)?.label ?? $0.item.category }
        return Array(Set((library.mediaCategories + remote + ["Uncategorized", selectedCategory]).filter { !$0.isEmpty })).sorted()
    }

    private var libraryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your GIFs").font(.title2.bold())
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
        .task(id: community.accountRevision) { await cloud.refresh(community, library: library) }
        .onChange(of: community.accountRevision) { _, _ in cloudSelection = nil }
        .refreshable {
            if vault.available {
                vault.requestSynchronization(library)
            } else { await cloud.refresh(community, library: library) }
        }
        .navigationDestination(isPresented: $showAccount) { CommunityAccountView() }
        .onAppear {
            cloud.resume()
            libraryVisible = true
            resumeCloudSave()
        }
        .onDisappear { cloud.cancel(); libraryVisible = false }
        .onChange(of: showAccount) { _, value in if !value { resumeCloudSave() } }
    }

    @ViewBuilder
    private var collectionLinks: some View {
        NavigationLink { BatchTransferView() } label: {
            Label("Send queue (\(library.state.transferQueue?.count ?? 0))", systemImage: "square.stack.3d.up")
                .frame(maxWidth: .infinity, minHeight: 44).padding(12).glassPanel(radius: 20)
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Picker("Display target", selection: $targets.target) {
                ForEach(NativeDisplayTarget.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            StatusPill(title: targets.target == .phone ? "Phone · offline" :
                app.link.connected ? "Backpack connected" : "Connect backpack to send",
                symbol: targets.target == .phone ? "iphone" : "backpack")
            if targets.target == .hardware, let id = targets.hardwareArtworkID,
               let media = library.state.media.first(where: { $0.id == id }) {
                Text("Selected: \(media.name)").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink { CloudVaultSettingsView() } label: {
                Label(vault.busy ? "Syncing" : vault.failure != nil ? "Sync needs attention" :
                    vault.syncing ? (vault.locked ? "Unlock to sync" : "Cloud sync on") : "Cloud sync off",
                    systemImage: vault.failure != nil ? "icloud.slash" : "icloud")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.accessibilityLabel("Library sync settings")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button { communityGallery = true } label: {
                    FeatureCardLabel(title: "Discover", subtitle: "Community GIFs", symbol: "sparkle.magnifyingglass", compact: true)
                }.accessibilityLabel("Discover GIFs")
                NavigationLink { PhoneDisplayLibraryView() } label: {
                    FeatureCardLabel(title: "Play", subtitle: "On your phone", symbol: "play.fill", tint: Aurora.lavender, compact: true)
                }.accessibilityLabel("Phone display")
                NavigationLink { GPSGamesView() } label: {
                    FeatureCardLabel(title: "Games", subtitle: "Explore & swap", symbol: "gamecontroller", tint: Aurora.rose, compact: true)
                }.accessibilityLabel("GPS & nearby games")
            }.buttonStyle(.plain)
            FeatureDetails("More sources & target details") {
                Button { gallery = true } label: { Label("Commons", systemImage: "globe") }
                Text("Changing targets does not send artwork. Backpack transfers still require confirmation; phone playback is local.")
            }
            if videoImporting { ProgressView("Importing artwork...") }
        }
    }

    private var libraryArtwork: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Collection").font(.headline)
                Spacer()
                Image(systemName: "square.grid.2x2").foregroundStyle(Aurora.lavender).accessibilityHidden(true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(filteredMedia) { item in
                    LibraryMediaRow(item: item) { action in handle(action, item: item) }
                }
                if vault.available {
                    ForEach(filteredVault) { item in CloudVaultArtworkRow(item: item) }
                } else {
                    ForEach(filteredCloud) { item in
                        CloudArtworkRow(cloud: item, open: { cloudSelection = item }, previewKey: cloud.thumbnailKey(item))
                            .onAppear { cloud.nearEnd(item.id, community: community, library: library, visible: filteredCloud.map(\.id)) }
                    }
                }
            }
                if vault.available && !vault.syncing { Text("Private cloud is paused on this device. Local files are unchanged.").font(.caption) }
                if vault.available {
                    if vault.busy { ProgressView("Updating private cloud…") }
                    if let failure = vault.failure {
                        Text(failure).foregroundStyle(.orange).font(.caption)
                        Button("Retry sync") { vault.requestSynchronization(library) }
                            .disabled(!vault.syncing || vault.locked || vault.busy)
                    }
                } else if cloud.loading { ProgressView("Updating cloud library...") }
                if !vault.available, let failure = cloud.failure {
                    Label(failure, systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
                    Button("Retry sync") { Task { await cloud.retry(community, library: library) } }
                }
            if filteredMedia.isEmpty && (vault.available ? filteredVault.isEmpty : filteredCloud.isEmpty) && !cloud.loading {
                ContentUnavailableView("Make this space yours", systemImage: "photo.on.rectangle.angled",
                    description: Text("Discover a GIF or use + to import artwork. Local copies are always available offline."))
            }
        }
    }

    private var filteredVault: [CloudVaultItem] {
        guard !favoritesOnly else { return [] }
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return vault.cloudOnly(local: library.state.media).filter {
            (selectedCategory.isEmpty || vault.categories[$0.id] == selectedCategory) &&
            (query.isEmpty || (vault.titles[$0.id] ?? "").localizedCaseInsensitiveContains(query) ||
                (vault.categories[$0.id] ?? "").localizedCaseInsensitiveContains(query))
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
            .sheet(isPresented: $privateCloudSettings) {
                NavigationStack {
                    CloudVaultSettingsView().toolbar { Button("Done") { privateCloudSettings = false } }
                }
            }
            .confirmationDialog("Create an independent private-cloud copy? Other-account associations and deleted/reset cloud libraries will not be restored.", isPresented: Binding(
                get: { foreignCopy != nil }, set: { if !$0 { foreignCopy = nil } })) {
                Button("Back up independent copy") {
                    guard let item = foreignCopy else { return }
                    foreignCopy = nil
                    vault.run { try await vault.synchronize(library, selected: [item.id], allowForeignCopies: true) }
                }
            }
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
        case .send: targets.stageHardware(item.id); selected = item; uploading = true
        case .phone:
            targets.target = .phone; phone.cancelPendingSelection()
            Task {
                do { try await phone.showLocalFile(library.phoneOriginalURL(item), mediaID: item.id) }
                catch { if !Task.isCancelled { phone.report(error) } }
            }
        case .enqueue: app.run { try library.enqueue([item.id]) }
        case .share:
            if !community.signedIn { pendingCloudSave = item; showAccount = true }
            else if let connected = cloud.connectedItem(item, origin: community.origin, owner: community.user?.id) {
                cloudSelection = connected
            } else { sharing = item }
        case .cloud:
            if !vault.syncing || vault.locked { privateCloudSettings = true }
            else {
                do {
                    if try vault.requiresExplicitCopy(item) { foreignCopy = item }
                    else { vault.run { try await vault.synchronize(library, selected: [item.id]) } }
                } catch { panel.report(error) }
            }
        case .export:
            app.run { exportDocument = BinaryDocument(data: try library.data(item)); exporting = true }
        case .organize: organizing = item
        case .delete: selected = item; deletion = true
        }
    }
}
