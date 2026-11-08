import SwiftUI
import BackpackProtocol

@MainActor
struct RouteArtworkPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: CommunityController
    let client: CommunityFeatureClient
    let event: CatalogEvent
    let choose: (RouteArtworkChoice?) -> Void
    @StateObject private var catalog = CommunityGalleryStore()
    private var community: [RouteArtworkChoice] {
        catalog.items.map { RouteArtworkChoice(reference: .community($0.id), title: $0.title, previewURL: $0.previewUrl) }
    }
    @State private var exclusive: [RouteArtworkChoice] = []
    @State private var source = "community"
    @State private var query = ""
    @State private var exclusiveBusy = false
    private var busy: Bool { exclusiveBusy || catalog.loading }
    @State private var failure: String?
    @State private var operation: Task<Void, Never>?
    @State private var stamp = UUID()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusPill(title: "NAMED ARTWORK", symbol: "photo.on.rectangle")
                    Picker("Artwork source", selection: $source) {
                        Text("Community / public").tag("community")
                        if client.exclusiveRouteEnabled(event) { Text("This event / exclusive").tag("exclusive") }
                    }.pickerStyle(.segmented)
                    Text(source == "community" ? "Only eligible approved, non-mature general community GIFs." :
                        "Protected ready artwork from this event only. Assignment never publishes a community copy.")
                        .font(.caption).foregroundStyle(.secondary)
                    if source == "community" {
                        TextField("Search community GIFs", text: $query).submitLabel(.search).onSubmit { load() }
                        Button("Search") { load() }.disabled(busy)
                    }
                    if busy { ProgressView() }
                    if let failure = failure ?? catalog.failure {
                        Text(failure).foregroundStyle(.orange)
                        Button("Retry") { if source == "community" { catalog.retry() } else { load() } }
                    }
                    let items = source == "community" ? community : exclusive
                    if items.isEmpty && !busy && failure == nil { Text("No eligible artwork in this selection. Unavailable references are never substituted.") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 12)], spacing: 12) {
                        ForEach(items) { choice in
                            Button {
                                do { try client.checkPlanner(); choose(choice); dismiss() }
                                catch { failure = error.localizedDescription }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    GIFThumbnail(key: previewKey(choice), cache: false) {
                                        try await client.routeArtworkImage(choice, event: event)
                                    }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text(choice.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(source == "community" ? "Community" : "Event-exclusive").font(.caption2).foregroundStyle(Aurora.mint)
                                }.padding(12).glassPanel(radius: 20)
                            }.buttonStyle(.plain).disabled(busy)
                                .onAppear { if source == "community", case .community(let id) = choice.reference { catalog.nearEnd(id) } }
                        }
                    }
                    if source == "community", !busy, catalog.failure == nil, !items.isEmpty {
                        Text(items.count == 100 ? "Showing 100 matches. Refine your search." : catalog.nextPage == nil ? "You're all caught up" : "")
                            .font(.caption)
                    }
                    Button("No artwork / remove current assignment") { choose(nil); dismiss() }.disabled(busy)
                }.padding(20)
            }
            .modernScene().navigationTitle("Choose artwork")
            .toolbar { Button("Cancel") { dismiss() } }
            .task { load() }
            .onChange(of: source) { _, _ in load() }
            .onChange(of: account.accountRevision) { _, _ in catalog.cancel(); exclusive = []; dismiss() }
            .onChange(of: account.config?.eventExclusiveRouteArtworkEnabled) { _, value in
                if value != true { exclusive = []; if source == "exclusive" { source = "community" } }
            }
            .onChange(of: account.config?.eventExclusiveGifsEnabled) { _, value in
                if value != true { exclusive = []; if source == "exclusive" { source = "community" } }
            }
            .onDisappear { operation?.cancel(); catalog.cancel(); exclusive = [] }
        }
    }
    private func previewKey(_ choice: RouteArtworkChoice) -> String {
        if case .community(let id) = choice.reference, let item = catalog.items.first(where: { $0.id == id }) {
            return catalog.thumbnailKey(item, url: choice.previewURL)
        }
        return "planner-art:\(client.instanceID):\(event.id):\(choice.id)"
    }
    private func load() {
        operation?.cancel(); catalog.cancel(); let current = UUID(); stamp = current; exclusiveBusy = false; failure = nil
        let selected = source, text = query
        if selected == "community" {
            catalog.search(valid: { stamp == current && source == selected && account.accountRevision == client.revision }, fetch: { page in
                let result = try await client.routeCatalog(query: text, page: page)
                try client.checkPlanner()
                return CommunityPage(items: result.items.filter(\.eligible).map(\.item), page: result.page, limit: result.limit, total: result.total)
            })
            return
        }
        exclusiveBusy = true
        operation = Task {
            do {
                    let result = try await client.routeExclusives(event)
                    try Task.checkCancellation(); try client.checkPlanner()
                    guard stamp == current else { return }
                    exclusive = result.map { RouteArtworkChoice(reference: .exclusive($0.id), title: $0.title, previewURL: $0.previewUrl) }
            } catch {
                guard stamp == current, !Task.isCancelled else { return }
                failure = error.localizedDescription
                if let error = error as? CommunityFailure, [401, 403, 404].contains(error.status) {
                    exclusive = []
                }
            }
            if stamp == current { exclusiveBusy = false }
        }
    }
}
