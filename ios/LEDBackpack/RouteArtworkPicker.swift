import SwiftUI
import BackpackProtocol

@MainActor
struct RouteArtworkPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: CommunityController
    let client: CommunityFeatureClient
    let event: CatalogEvent
    let choose: (RouteArtworkChoice?) -> Void
    @State private var community: [RouteArtworkChoice] = []
    @State private var exclusive: [RouteArtworkChoice] = []
    @State private var source = "community"
    @State private var query = ""
    @State private var page = 1
    @State private var total = 0
    @State private var busy = false
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
                        TextField("Search community GIFs", text: $query).submitLabel(.search).onSubmit { load(page: 1) }
                        Button("Search") { load(page: 1) }.disabled(busy)
                    }
                    if busy { ProgressView() }
                    if let failure { Text(failure).foregroundStyle(.orange); Button("Retry") { load(page: page) } }
                    let items = source == "community" ? community : exclusive
                    if items.isEmpty && !busy && failure == nil { Text("No eligible artwork in this selection. Unavailable references are never substituted.") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 12)], spacing: 12) {
                        ForEach(items) { choice in
                            Button {
                                do { try client.checkPlanner(); choose(choice); dismiss() }
                                catch { failure = error.localizedDescription }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    GIFThumbnail(key: "planner-art:\(client.instanceID):\(event.id):\(choice.id)", cache: false) {
                                        try await client.routeArtworkImage(choice, event: event)
                                    }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text(choice.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(source == "community" ? "Community" : "Event-exclusive").font(.caption2).foregroundStyle(Aurora.mint)
                                }.padding(12).glassPanel(radius: 20)
                            }.buttonStyle(.plain).disabled(busy)
                        }
                    }
                    if source == "community" {
                        HStack {
                            Button("Previous") { load(page: page - 1) }.disabled(page <= 1 || busy)
                            Spacer()
                            Text("Page \(page)").font(.caption)
                            Spacer()
                            Button("Next") { load(page: page + 1) }.disabled(page * 50 >= total || page >= 10000 || busy)
                        }
                    }
                    Button("No artwork / remove current assignment") { choose(nil); dismiss() }.disabled(busy)
                }.padding(20)
            }
            .modernScene().navigationTitle("Choose artwork")
            .toolbar { Button("Cancel") { dismiss() } }
            .task { load(page: 1) }
            .onChange(of: source) { _, _ in load(page: 1) }
            .onChange(of: account.config?.eventExclusiveRouteArtworkEnabled) { _, value in
                if value != true { exclusive = []; if source == "exclusive" { source = "community" } }
            }
            .onChange(of: account.config?.eventExclusiveGifsEnabled) { _, value in
                if value != true { exclusive = []; if source == "exclusive" { source = "community" } }
            }
            .onDisappear { operation?.cancel(); community = []; exclusive = [] }
        }
    }
    private func load(page requested: Int) {
        operation?.cancel(); let current = UUID(); stamp = current; busy = true; failure = nil
        let selected = source, text = query
        operation = Task {
            do {
                if selected == "community" {
                    let result = try await client.routeCatalog(query: text, page: requested)
                    try Task.checkCancellation(); try client.checkPlanner()
                    guard stamp == current else { return }
                    community = result.items.filter(\.eligible).map {
                        RouteArtworkChoice(reference: .community($0.item.id), title: $0.item.title, previewURL: $0.item.previewUrl)
                    }
                    page = result.page; total = result.total
                } else {
                    let result = try await client.routeExclusives(event)
                    try Task.checkCancellation(); try client.checkPlanner()
                    guard stamp == current else { return }
                    exclusive = result.map { RouteArtworkChoice(reference: .exclusive($0.id), title: $0.title, previewURL: $0.previewUrl) }
                }
            } catch {
                guard stamp == current, !Task.isCancelled else { return }
                failure = error.localizedDescription
                if let error = error as? CommunityFailure, [401, 403, 404].contains(error.status) {
                    community = []; exclusive = []
                }
            }
            if stamp == current { busy = false }
        }
    }
}
