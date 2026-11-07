import SwiftUI
import BackpackProtocol

enum CommunityCategory: String, CaseIterable, Identifiable {
    case memes, motorcycle, animals, pixelArt = "pixel-art", reactions, other
    var id: String { rawValue }
    var label: String { self == .pixelArt ? "Pixel art" : rawValue.capitalized }
}

@MainActor
struct CommunityGallery: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let choose: (Data, Attribution, String?, String) -> Void
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var category = ""
    @State private var reload = UUID()
    @State private var items: [CommunityItem] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var failure: String?
    @StateObject private var selection = CommunitySelectionStore()
    @State private var showingQueue = false
    @State private var directSend: BackpackSendRequest?
    @State private var moreTask: Task<Void, Never>?
    @State private var sizes = NativeMatrixFilter()
    private struct Filter: Equatable {
        let server: URL?
        let user: UUID?
        let signedIn: Bool
        let revision: UUID
        let query: String
        let category: String
        let reload: UUID
        let sizes: NativeMatrixFilter
        let policy: UUID
    }
    private var filter: Filter {
        Filter(server: community.origin?.url, user: community.user?.id, signedIn: community.signedIn,
            revision: community.accountRevision, query: appliedQuery, category: category, reload: reload,
            sizes: sizes, policy: community.avatarPolicyRevision)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if community.origin == nil {
                        ContentUnavailableView("Connect your catalog", systemImage: "network",
                            description: Text("Add its deployed HTTPS URL. Offline and Commons features do not need an account."))
                        NavigationLink("Configure catalog") { CommunitySettingsView() }
                    } else {
                        controls
                        if let failure {
                            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Button("Refresh results") { reload = UUID() }
                            if community.signedIn {
                                Button("Continue browsing as a guest") {
                                    do { try community.forgetLocalSession(); reload = UUID() }
                                    catch { self.failure = error.localizedDescription }
                                }
                            }
                        }
                        results
                        if loading { ProgressView("Loading community GIFs...") }
                        if items.isEmpty && !loading && failure == nil {
                            ContentUnavailableView("No published matches", systemImage: "photo.on.rectangle",
                                description: Text("Try another category or search. Uploaded artwork appears publicly only after moderator approval."))
                        }
                        if items.count < min(total, 100), page < 10000 {
                            Button("Load more") {
                                guard !loading else { return }
                                loading = true
                                moreTask = Task { await load(reset: false) }
                            }.disabled(loading)
                        }
                        if items.count == 100 { Text("Showing the first 100 matches. Refine your search to narrow the results.").font(.caption) }
                    }
                }.padding(20)
            }
            .modernScene().navigationTitle("Community")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search GIFs")
            .onSubmit(of: .search) { appliedQuery = query; reload = UUID() }
            .toolbar { Button("Done") { dismiss() } }
            .task(id: filter) { moreTask?.cancel(); selection.invalidate(); await load(reset: true) }
            .onDisappear { moreTask?.cancel(); selection.cancel() }
            .onChange(of: phase) { _, state in if state != .active { selection.cancel() } }
            .safeAreaInset(edge: .bottom) {
                CommunitySelectionControls(store: selection, favorite: {
                    selection.apply(.favorite, items: items, community: community, library: library)
                }, send: {
                    do {
                        let chosen = try selection.selection.selected(from: items)
                        directSend = BackpackSendRequest(sources: chosen.map { .catalog($0) })
                    } catch { selection.report(error) }
                }, openQueue: { showingQueue = true })
            }
            .navigationDestination(isPresented: $showingQueue) { BatchTransferView() }
            .sheet(item: $directSend) { request in BackpackDirectSendView(request: request) }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("All GIFs") { category = "" }.buttonStyle(.bordered).tint(category.isEmpty ? .cyan : .gray)
                    ForEach(CommunityCategory.allCases) { value in
                        Button(value.label) { category = value.rawValue }
                            .buttonStyle(.bordered).tint(category == value.rawValue ? .cyan : .gray)
                    }
                }
            }
            HStack {
                Text("Find it. Save it. Make it yours.").font(.headline)
                Spacer()
                NavigationLink(community.signedIn ? "Account" : "Sign in") { CommunityAccountView() }
            }
            if let error = community.setupError { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("No account needed to preview or keep a local copy.").font(.caption).foregroundStyle(.secondary)
            NavigationLink { CommunityFavoritesView() } label: { Label("My Favorites", systemImage: "heart.fill") }
            Button("Advanced Send queue / manual slot review") { showingQueue = true }
            Text("Tap GIFs to select (up to20), then Favorite or Send to LED. No item page opens.").font(.caption)
            if community.config?.nativeSizeFiltersEnabled == true { NativeMatrixFilterControls(filter: $sizes) }
            else { Text("Exact multi-matrix filters are unavailable on this server.").font(.caption) }
        }
    }
    private var results: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            ForEach(items) { item in
                let animated = community.user?.mediaPreferences?.permitsAnimation(reducedMotion: reducedMotion, manual: false) ?? !reducedMotion
                let url = animated ? item.gifUrl : item.previewUrl
                let selected = selection.selection.ids.contains(item.id)
                Button { selection.toggle(item.id) } label: {
                    GIFThumbnail(key: url.absoluteString, cache: false, animationAllowed: animated) {
                        try await community.download(url)
                    }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            if selected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .cyan)
                                    .font(.title2).padding(8).accessibilityHidden(true)
                            }
                        }
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.cyan : .clear, lineWidth: 3) }
                }.buttonStyle(.plain)
                    .accessibilityLabel("Select community GIF")
                    .accessibilityIdentifier("community-gif-\(item.id.uuidString.lowercased())")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(selection.busy)
            }
        }
    }
    private func load(reset: Bool) async {
        guard community.origin != nil else { return }
        let stamp = filter
        if reset { items = []; page = 1; total = 0 }
        loading = true; failure = nil
        defer { if stamp == filter { loading = false } }
        do {
            let result = try await community.items(query: stamp.query, category: stamp.category, page: reset ? 1 : page + 1, sizes: stamp.sizes)
            try Task.checkCancellation()
            guard stamp == filter else { return }
            var ids = Set(items.map(\.id))
            items = Array((items + result.items.filter { ids.insert($0.id).inserted }).prefix(100))
            page = result.page; total = result.total
        } catch {
            guard stamp == filter, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

@MainActor
private struct CommunityDetail: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var panel: PanelController
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    let item: CommunityItem
    let choose: (Data, Attribution, String?, String) -> Void
    let blocked: (UUID) -> Void
    @State private var bytes: Data?
    @State private var failure: String?
    @State private var message: String?
    @State private var busy = false
    @State private var reason = ""
    @State private var retry = 0
    @State private var loadedURL: URL?
    @State private var loadedOrigin: CommunityOrigin?
    @State private var selectedFile: URL?
    @State private var loadedEpoch: UUID?
    @State private var loadedPolicy: UUID?
    @State private var integrity: NativeCatalogDownloadIntegrity?
    @State private var loadGeneration = UUID()
    @State private var loadedManifestEnabled: Bool?
    @State private var saved = false
    @State private var reporting = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let bytes { AnimatedPreview(data: bytes).frame(height: 280) }
                    else if failure == nil { ProgressView("Loading preview...") }
                    Text(item.title).font(.title2.bold())
                    Picker("Download exact recorded file", selection: Binding(get: { selectedFile ?? item.gifUrl }, set: { selectedFile = $0 })) {
                        ForEach(item.recordedFiles) { file in Text(file.label).tag(file.url) }
                    }
                    Text(integrity?.message ?? (community.config?.catalogDownloadManifestEnabled == true
                        ? "A current server manifest checksum is required before this download is accepted. No legacy fallback on manifest errors."
                        : "Checksum unavailable on this server. Legacy browsing/downloads have limited authorization, size and GIF decode checks only — not checksum verification."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(item.displayAttribution).font(.subheadline)
                    HStack {
                        CatalogContributorAvatar(item: item).frame(width: 56, height: 70)
                        Text(item.uploader.displayName)
                    }
                    Text(item.license == "original" ? "Original work: catalog download permission, not a general redistribution license." : item.license)
                        .font(.caption).foregroundStyle(.secondary)
                    if item.pageUrl.scheme == "https" { Link("Attribution and license page", destination: item.pageUrl) }
                    if let failure { Text(failure).foregroundStyle(.orange) }
                    if let message { Text(message).font(.caption) }
                    Button(saved ? "Saved on this iPhone" : "Save to my library") {
                        perform {
                            guard bytes != nil, let loadedURL, let loadedOrigin,
                                  loadedEpoch == community.accountRevision, loadedPolicy == community.avatarPolicyRevision,
                                  loadedManifestEnabled == (community.config?.catalogDownloadManifestEnabled == true),
                                  loadedURL == (selectedFile ?? item.gifUrl),
                                  !community.avatarPolicyChanging else {
                                throw BackpackError.invalid("Wait for the preview to load.")
                            }
                            let copy = try await currentCopy()
                            try library.saveCatalogGIF(copy.data, item: item, origin: loadedOrigin, accountID: nil, assetURL: loadedURL)
                            saved = true
                            integrity = copy.integrity
                            message = "Available offline in Library. " + copy.integrity.message
                        }
                    }.buttonStyle(.borderedProminent).disabled(bytes == nil || busy || saved)
                    Button("Customize a copy") {
                        perform {
                            let copy = try await currentCopy()
                            let category = CommunityCategory(rawValue: item.category)?.label ?? item.category
                            choose(copy.data, item.credit, category, item.title)
                        }
                    }.buttonStyle(.bordered).disabled(bytes == nil || busy)
                    Button("Reload preview") { retry += 1 }.disabled(busy)
                    moderation
                }.padding(20)
            }.modernScene().navigationTitle("Community GIF")
                .toolbar { Button("Back") { dismiss() } }
                .task(id: retry) { await loadPreview() }
                .onChange(of: community.accountRevision) { _, _ in invalidate() }
                .onChange(of: community.avatarPolicyRevision) { _, _ in invalidate() }
                .onChange(of: community.avatarPolicyChanging) { _, changing in if changing { invalidate() } }
                .onChange(of: community.config?.catalogDownloadManifestEnabled) { _, _ in invalidate() }
                .onChange(of: selectedFile) { _, _ in invalidate() }
                .onDisappear { loadGeneration = UUID(); bytes = nil; integrity = nil }
                .sheet(isPresented: $reporting) { reportComposer }
        }
    }
    private func loadPreview() async {
        let generation = UUID(); loadGeneration = generation
        bytes = nil; integrity = nil; loadedURL = nil; loadedOrigin = nil; failure = nil; saved = false; message = nil
        do {
            guard let origin = community.origin else { throw BackpackError.invalid("No catalog is configured.") }
            let epoch = community.accountRevision, policy = community.avatarPolicyRevision
            let assetURL = selectedFile ?? item.gifUrl
            guard let file = item.recordedFiles.first(where: { $0.url == assetURL }) else { throw BackpackError.invalid("Select an actually recorded file.") }
            let manifestEnabled = community.config?.catalogDownloadManifestEnabled == true
            let result = try await community.downloadCatalogFile(itemID: item.id, file: file)
            try Task.checkCancellation()
            guard generation == loadGeneration, epoch == community.accountRevision, policy == community.avatarPolicyRevision,
                  assetURL == (selectedFile ?? item.gifUrl), manifestEnabled == (community.config?.catalogDownloadManifestEnabled == true) else { return }
            loadedURL = assetURL; loadedOrigin = origin; loadedEpoch = epoch; loadedPolicy = policy
            loadedManifestEnabled = manifestEnabled; integrity = result.integrity; bytes = result.data
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            failure = error.localizedDescription
        }
    }
    private func invalidate() { loadGeneration = UUID(); bytes = nil; integrity = nil; saved = false; retry += 1 }
    private func currentCopy() async throws -> NativeCatalogDownload {
        let generation = loadGeneration, epoch = community.accountRevision, policy = community.avatarPolicyRevision
        let url = selectedFile ?? item.gifUrl
        guard loadedEpoch == epoch, loadedPolicy == policy, loadedURL == url,
              let file = item.recordedFiles.first(where: { $0.url == url }) else {
            throw BackpackError.invalid("Reload this exact selection before saving/customizing.")
        }
        let result = try await community.downloadCatalogFile(itemID: item.id, file: file)
        try Task.checkCancellation()
        guard generation == loadGeneration, epoch == community.accountRevision, policy == community.avatarPolicyRevision,
              url == (selectedFile ?? item.gifUrl), !community.avatarPolicyChanging else {
            throw BackpackError.invalid("Selection or account changed before the local copy. Nothing was saved.")
        }
        return result
    }

    private var reportComposer: some View {
        NavigationStack {
            Form {
                TextField("Describe the concern", text: $reason, axis: .vertical)
                Button("Send report") {
                    perform {
                    try await community.report(item.id, reason: reason)
                    message = "Report sent to admins."; reporting = false; reason = ""
                    }
                }.disabled(busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                if let failure { Text(failure).foregroundStyle(.orange) }
            }.modernScene().navigationTitle("Report GIF")
                .toolbar { Button("Cancel") { reporting = false }.disabled(busy) }
        }
    }

    private var moderation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if community.signedIn {
                Button("Like this GIF") {
                    perform {
                        let count = try await community.like(item.id)
                        message = "\(count) likes."
                    }
                }
                Button("Report this GIF") { reporting = true }
                if let user = community.user, let uploaderID = item.uploader.id, user.id != uploaderID {
                    Button("Block this uploader", role: .destructive) {
                        perform {
                            try await community.block(uploaderID)
                            blocked(uploaderID); dismiss()
                        }
                    }
                }
            } else {
                NavigationLink("Sign in to like, report or block") { CommunityAccountView() }
            }
        }.disabled(busy)
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { failure = error.localizedDescription }
        }
    }
}
