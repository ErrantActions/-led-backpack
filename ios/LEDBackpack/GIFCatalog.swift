import SwiftUI
import BackpackProtocol

@MainActor
final class GIFCatalog: ObservableObject {
    @Published private(set) var results: [GIFResult] = []
    @Published private(set) var loading = false
    @Published private(set) var searched = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var nextOffset: Int?
    @Published private(set) var excludedCount = 0
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var query = ""
    private var topic = GIFTopic.pixelArt
    private var active = true
    private var failedRequest: (offset: Int, append: Bool)?
    private var revisions: [Int: UUID] = [:]
    private var started = false
    private let fetch: @MainActor (String, GIFTopic, Int) async throws -> GIFSearchPage

    init(fetch: @escaping @MainActor (String, GIFTopic, Int) async throws -> GIFSearchPage = { text, topic, offset in
        try await CommonsSearch.search(text, topic: topic, offset: offset)
    }) {
        self.fetch = fetch
    }

    func search(_ text: String, topic: GIFTopic) {
        task?.cancel()
        query = text; self.topic = topic
        active = true; started = true; revisions = [:]; failedRequest = nil
        results = []; nextOffset = nil; excludedCount = 0; notice = nil; searched = false
        load(offset: 0, append: false)
    }

    func loadMore() {
        guard active, !loading, errorMessage == nil, let nextOffset else { return }
        load(offset: nextOffset, append: true)
    }
    func nearEnd(_ id: Int) {
        guard results.suffix(4).contains(where: { $0.id == id }) else { return }
        loadMore()
    }
    func retry() {
        guard active, !loading, let failedRequest else { return }
        load(offset: failedRequest.offset, append: failedRequest.append)
    }
    func resume() {
        active = true
        if started && !searched && !loading && errorMessage == nil { load(offset: 0, append: false) }
    }
    func thumbnailKey(_ item: GIFResult) -> String {
        "commons:\(item.id):\(revisions[item.id]?.uuidString ?? "original"):\(item.previewURL.absoluteString)"
    }

    func cancel() {
        active = false
        task?.cancel()
        task = nil
        requestID = UUID()
        loading = false
    }

    private func load(offset: Int, append: Bool) {
        let id = UUID()
        requestID = id
        let text = query, selected = topic
        loading = true; errorMessage = nil; failedRequest = nil
        task = Task {
            defer { if requestID == id { loading = false; task = nil } }
            do {
                try Task.checkCancellation()
                let page = try await fetch(text, selected, offset)
                try Task.checkCancellation()
                guard requestID == id else { return }
                if let next = page.nextOffset, next <= offset { throw BackpackError.invalid("The GIF catalog returned a repeated page cursor.") }
                var merged = append ? results : []
                var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) })
                var added = 0
                for item in page.items {
                    if let index = indices[item.id] { merged[index] = item }
                    else if merged.count < 100 { indices[item.id] = merged.count; merged.append(item); added += 1 }
                    revisions[item.id] = UUID()
                }
                results = merged
                guard page.nextOffset == nil || merged.count == 100 || added > 0 else {
                    throw BackpackError.invalid("The catalog returned no new GIFs. Retry this page or refine the search.")
                }
                nextOffset = results.count < 100 ? page.nextOffset : nil
                excludedCount += page.excludedCount
                notice = page.notice
                searched = true
            } catch {
                guard requestID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                failedRequest = (offset, append)
                searched = true
            }
        }
    }
}

@MainActor
struct GIFGallery: View {
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let choose: (Data, Attribution, String?, String) -> Void
    @StateObject private var catalog = GIFCatalog()
    @State private var query = ""
    @State private var topic = GIFTopic.pixelArt
    @State private var selected: GIFResult?
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchControls
                    if let error = catalog.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Retry") { catalog.retry() }
                    }
                    if let notice = catalog.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    resultsGrid
                    if catalog.loading { ProgressView("Finding GIFs...").frame(maxWidth: .infinity) }
                    if catalog.searched && catalog.results.isEmpty && !catalog.loading && catalog.errorMessage == nil {
                        ContentUnavailableView("No matching GIFs on this page", systemImage: "magnifyingglass",
                            description: Text("Try fewer words or another category."))
                    }
                    if catalog.nextOffset == nil && !catalog.results.isEmpty && catalog.results.count < 100 && !catalog.loading && catalog.errorMessage == nil {
                        Text("You're all caught up").font(.caption).foregroundStyle(.secondary)
                    }
                    if catalog.results.count == 100 { Text("Showing the first 100 matches. Refine your search for more specific results.").font(.caption) }
                    FeatureDetails("Source & reuse") {
                    if catalog.excludedCount > 0 {
                        Text("\(catalog.excludedCount) files omitted because of missing license metadata, unsupported dimensions/format or the 5 MB size limit.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    catalogNotes
                    }
                }.padding(20)
            }
            .modernScene().navigationTitle("Find GIFs")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search licensed GIFs")
            .onSubmit(of: .search) { search() }
            .safeAreaInset(edge: .bottom) {
                Button("Done") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                    .padding(8).background(Aurora.surface)
            }
            .task { if !catalog.searched && catalog.errorMessage == nil { search() } else { catalog.resume() } }
            .onChange(of: topic) { _, _ in search() }
            .onDisappear { catalog.cancel() }
            .onChange(of: phase) { _, state in if state == .active { catalog.resume() } else { catalog.cancel() } }
            .sheet(item: $selected) { GIFDetails(item: $0, category: topic.libraryCategory, choose: choose) }
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(GIFTopic.allCases) { choice in
                        Button(choice.rawValue) { topic = choice }
                            .buttonStyle(.bordered).tint(topic == choice ? .cyan : .gray)
                    }
                }
            }
            Text("Licensed GIFs from Commons.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(catalog.results) { item in
                Button { selected = item } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        GIFThumbnail(key: catalog.thumbnailKey(item)) {
                            try await HTTP.fetch(item.previewURL, maxBytes: 2_000_000)
                        }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityLabel("Preview \(item.title)")
                    .accessibilityValue("\(item.width) x \(item.height), \(item.attribution.license)")
                    .onAppear { catalog.nearEnd(item.id) }
            }
        }
    }

    private var catalogNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not every GIF is animated. Source, author and license stay with saved artwork; review reuse requirements before sending or sharing.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Commons reuse guidance", destination: URL(string: "https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia")!)
            Link("Browse GIPHY externally", destination: URL(string: "https://giphy.com")!)
        }
    }

    private func search() { catalog.search(query, topic: topic) }
}

@MainActor
private struct GIFDetails: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var link: BluetoothLink
    @Environment(\.dismiss) private var dismiss
    let item: GIFResult
    let category: String?
    let choose: (Data, Attribution, String?, String) -> Void
    @State private var data: Data?
    @State private var failure: String?
    @State private var retry = 0
    @State private var frameCount: Int?
    @State private var saved = false
    private var canEdit: Bool { data != nil && frameCount.map { $0 <= 120 } == true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let data { AnimatedPreview(data: data).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 18)) }
                    else if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Retry download") { retry += 1 }
                    } else { ProgressView("Loading full preview...").frame(maxWidth: .infinity, minHeight: 180) }
                    FeatureDetails("File details") {
                    Text("\(item.width) x \(item.height) / \(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))")
                    if let category { Label(category, systemImage: "folder") }
                    }
                    if let frameCount {
                        Text("\(frameCount) frame(s)").font(.caption).foregroundStyle(.secondary)
                        if frameCount > 120 {
                            Text("This animation can be previewed, but has more than the editor's 120-frame limit. Choose a shorter GIF to import.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text("\(item.attribution.author)\n\(item.attribution.license)").font(.subheadline)
                    Link("Review source and license", destination: item.page)
                    Button(saved ? "Saved on this iPhone" : "Save to my library") {
                        do {
                            guard let data else { throw BackpackError.invalid("Wait for the GIF download to finish.") }
                            try GIFPreviewDecoder.validateOriginal(data)
                            try library.add(name: item.title, data: data, attribution: item.attribution, category: category)
                            saved = true
                        } catch { failure = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(!canEdit || saved)
                    Button("Customize a copy") {
                        do {
                            guard let data else { throw BackpackError.invalid("Wait for the GIF download to finish.") }
                            try GIFPreviewDecoder.validateOriginal(data)
                            choose(data, item.attribution, category, item.title)
                        } catch {
                            failure = error.localizedDescription
                            link.note("GIF import unavailable: \(error.localizedDescription)")
                        }
                    }.buttonStyle(.bordered).disabled(!canEdit)
                    Text("Credits stay with the copy. The backpack is unchanged.").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .modernScene().navigationTitle("GIF preview")
            .safeAreaInset(edge: .bottom) {
                Button("Back") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                    .padding(8).background(Aurora.surface)
            }
            .task(id: retry) {
                data = nil; frameCount = nil; failure = nil
                do {
                    let bytes = try await HTTP.fetch(item.url, maxBytes: 5_000_000)
                    try Task.checkCancellation()
                    frameCount = try GIFPreviewDecoder.originalFrameCount(bytes)
                    data = bytes
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                    link.note("GIF download failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
