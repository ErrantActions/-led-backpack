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
    @Environment(\.dismiss) private var dismiss
    let choose: (Data, Attribution, String?, String) -> Void
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var category = "memes"
    @State private var reload = UUID()
    @State private var items: [CommunityItem] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var selected: CommunityItem?
    @State private var moreTask: Task<Void, Never>?
    private struct Filter: Equatable {
        let server: URL?
        let user: UUID?
        let signedIn: Bool
        let query: String
        let category: String
        let reload: UUID
    }
    private var filter: Filter {
        Filter(server: community.origin?.url, user: community.user?.id, signedIn: community.signedIn,
            query: appliedQuery, category: category, reload: reload)
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
            .toolbar { Button("Done") { dismiss() } }
            .task(id: filter) { moreTask?.cancel(); await load(reset: true) }
            .onDisappear { moreTask?.cancel() }
            .sheet(item: $selected) { item in
                CommunityDetail(item: item, choose: choose) { id in
                    items.removeAll { $0.uploader.id == id }
                }
            }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search community GIFs", text: $query).textFieldStyle(.roundedBorder)
                .submitLabel(.search).onSubmit { appliedQuery = query; reload = UUID() }
            Picker("Category", selection: $category) {
                Text("All categories").tag("")
                ForEach(CommunityCategory.allCases) { Text($0.label).tag($0.rawValue) }
            }
            HStack {
                Button("Search") { appliedQuery = query; reload = UUID() }.buttonStyle(.borderedProminent)
                Spacer()
                NavigationLink(community.signedIn ? "Account" : "Sign in / register") { CommunityAccountView() }
            }
            if let error = community.setupError { Text(error).font(.caption).foregroundStyle(.orange) }
            if let url = community.origin?.url {
                if community.signedIn { NavigationLink("My uploads") { CommunityUploadsView() } }
                Link("Open moderation portal", destination: url)
                Text("Share from Library > Actions > Share to community. The web portal has its own sign-in. Download permission alone does not grant permission to re-upload someone else's work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var results: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            ForEach(items) { item in
                Button { selected = item } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        GIFThumbnail(key: item.previewUrl.absoluteString, cache: false) {
                            try await community.download(item.previewUrl)
                        }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                        Text("\(item.width) x \(item.height) / \(item.frameCount) frames")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
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
            let result = try await community.items(query: stamp.query, category: stamp.category, page: reset ? 1 : page + 1)
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let bytes { AnimatedPreview(data: bytes).frame(height: 280) }
                    else if failure == nil { ProgressView("Loading preview...") }
                    Text(item.title).font(.title2.bold())
                    Text(item.displayAttribution).font(.subheadline)
                    Text(item.license == "original" ? "Original work: catalog download permission, not a general redistribution license." : item.license)
                        .font(.caption).foregroundStyle(.secondary)
                    if item.pageUrl.scheme == "https" { Link("Attribution and license page", destination: item.pageUrl) }
                    if let failure { Text(failure).foregroundStyle(.orange) }
                    if let message { Text(message).font(.caption) }
                    Button("Edit and save locally") {
                        if let bytes {
                            let category = CommunityCategory(rawValue: item.category)?.label ?? item.category
                            choose(bytes, item.credit, category, item.title)
                        }
                    }.buttonStyle(.borderedProminent).disabled(bytes == nil || busy)
                    Button("Reload preview") { retry += 1 }.disabled(busy)
                    moderation
                }.padding(20)
            }.modernScene().navigationTitle("Community GIF")
                .toolbar { Button("Back") { dismiss() } }
                .task(id: retry) {
                    bytes = nil; failure = nil
                    do {
                        let target = panel.size ?? PanelSize(width: 64, height: 64)
                        let variant = item.variants.first { $0.width == target.width && $0.height == target.height }
                        let data = try await community.download(variant?.url ?? item.gifUrl)
                        try Task.checkCancellation()
                        try GIFPreviewDecoder.validateOriginal(data)
                        bytes = data
                    } catch {
                        guard !Task.isCancelled else { return }
                        failure = error.localizedDescription
                    }
                }
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
                TextField("Report concern (4-1000 characters)", text: $reason, axis: .vertical)
                Button("Send report") { perform { try await community.report(item.id, reason: reason); message = "Report sent to moderators." } }
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                if let user = community.user, user.id != item.uploader.id {
                    Button("Block this uploader", role: .destructive) {
                        perform {
                            try await community.block(item.uploader.id)
                            blocked(item.uploader.id); dismiss()
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
