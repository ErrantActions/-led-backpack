import SwiftUI
import BackpackProtocol

struct CommunityCloudItem: Decodable, Identifiable {
    let item: CommunityItem
    let visibility: String
    let status: String
    let moderationReason: String
    let aiState: String
    let aiError: String?
    let contentRevision: String?
    let syncRevision: String?
    var id: UUID { item.id }
    init(from decoder: Decoder) throws {
        item = try CommunityItem(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        visibility = try values.decode(String.self, forKey: .visibility)
        status = try values.decode(String.self, forKey: .status)
        moderationReason = try values.decode(String.self, forKey: .moderationReason)
        aiState = try values.decode(String.self, forKey: .aiState)
        aiError = try values.decodeIfPresent(String.self, forKey: .aiError)
        contentRevision = try values.decodeIfPresent(String.self, forKey: .contentRevision)
        syncRevision = try values.decodeIfPresent(String.self, forKey: .syncRevision)
    }
    private enum CodingKeys: String, CodingKey { case visibility, status, moderationReason, aiState, aiError, contentRevision, syncRevision }
}

private struct LibraryDeltaPage: Decodable {
    let accountId: UUID
    let snapshot: String
    let items: [CommunityCloudItem]
    let removed: [UUID]
    let order: [UUID]
    let nextPage: Int?
    let page: Int
    let limit: Int
    let total: Int
}

struct CommunityCloudPage: Decodable {
    let items: [CommunityCloudItem]
    let page: Int?
    let limit: Int?
    let total: Int?
    var nextPage: Int? {
        guard let page, let limit, let total, (1..<10000).contains(page), (1...100).contains(limit),
              total >= 0, page * limit < total else { return nil }
        return page + 1
    }
}

@MainActor
final class CloudLibraryStore: ObservableObject {
    @Published private(set) var items: [CommunityCloudItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var nextPage: Int?
    private var revision: UUID?
    private var ownerID: UUID?
    private var server: CommunityOrigin?
    private var operation = UUID()
    private var moreTask: Task<Void, Never>?
    private var moreTicket = UUID()
    private var active = true
    private var contentRevisions: [UUID: UUID] = [:]
    private var failedPage: Int?
    private var pageLimit: Int?
    private var deltaComplete = false

    func clear() {
        cancel()
        items = []; failure = nil; loading = false; revision = nil; ownerID = nil; server = nil; nextPage = nil
        contentRevisions = [:]; failedPage = nil; pageLimit = nil; deltaComplete = false
    }
    func cancel() {
        active = false; operation = UUID(); moreTicket = UUID(); moreTask?.cancel(); moreTask = nil; loading = false
    }
    func resume() { active = true }
    func thumbnailKey(_ item: CommunityCloudItem) -> String {
        "owned:\(item.id):\(item.contentRevision ?? contentRevisions[item.id]?.uuidString ?? "original")"
    }
    func nearEnd(_ id: UUID, community: CommunityController, library: LocalLibrary? = nil, visible: [UUID]? = nil) {
        guard active, !loading, failure == nil, moreTask == nil, nextPage != nil,
              items.contains(where: { $0.id == id }), (visible ?? items.map(\.id)).suffix(4).contains(id) else { return }
        let ticket = UUID(); moreTicket = ticket
        moreTask = Task {
            defer { if moreTicket == ticket { moreTask = nil } }
            await loadMore(community, library: library)
        }
    }
    func retry(_ community: CommunityController, library: LocalLibrary? = nil) async {
        if let failedPage, failedPage > 1, nextPage != nil { await loadMore(community, library: library) }
        else { await refresh(community, library: library) }
    }
    private func merge(_ incoming: [CommunityCloudItem]) -> Int {
        var indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        var added = 0
        for item in incoming where item.status != "deleted" {
            if let index = indices[item.id] { items[index] = item }
            else { indices[item.id] = items.count; items.append(item); added += 1 }
            contentRevisions[item.id] = UUID()
        }
        return added
    }

    func refresh(_ community: CommunityController, library: LocalLibrary? = nil) async {
        let current = community.accountRevision
        if revision != current { clear(); revision = current }
        guard community.signedIn else { clear(); return }
        guard !loading else { return }
        active = true
        let ticket = UUID(); operation = ticket
        var requestedPage = 1
        loading = true; failure = nil
        defer {
            if revision == current && operation == ticket {
                if community.accountRevision != current { clear() }
                else { loading = false }
            }
        }
        do {
            if library != nil && community.config == nil { try await community.loadConfig() }
            if community.user == nil { try await community.refreshUser() }
            if community.config?.libraryDeltaSyncEnabled == true {
                do {
                    try await refreshDelta(community, current: current, ticket: ticket)
                    if let library { try await downloadMissing(community, library: library, revision: current, ticket: ticket) }
                    return
                } catch let error as CommunityFailure where error.code == "library_sync_limit" {
                    deltaComplete = false
                }
            }
            let result = try await community.cloudPage(page: 1)
            try Task.checkCancellation()
            guard community.accountRevision == current, revision == current, operation == ticket, active, community.signedIn else { return }
            guard result.page == nil || result.page == 1 else { throw BackpackError.invalid("The owned library returned the wrong first page.") }
            items = []; contentRevisions = [:]; deltaComplete = false
            _ = merge(result.items)
            pageLimit = result.limit
            nextPage = result.nextPage
            ownerID = community.user?.id; server = community.origin
            if let library {
                while let page = nextPage {
                    requestedPage = page
                    let result = try await community.cloudPage(page: page)
                    try Task.checkCancellation()
                    guard community.accountRevision == current, revision == current, operation == ticket, active, community.signedIn else { return }
                    guard result.page == page, result.limit == pageLimit else { throw BackpackError.invalid("The owned library returned a different page or page size.") }
                    let added = merge(result.items)
                    guard result.nextPage == nil || added > 0 else {
                        throw BackpackError.invalid("Cloud pagination repeated artwork. Retry synchronization.")
                    }
                    nextPage = result.nextPage
                }
                try await downloadMissing(community, library: library, revision: current, ticket: ticket)
            }
        } catch {
            guard !Task.isCancelled, community.accountRevision == current, revision == current, operation == ticket, active else { return }
            failure = error.localizedDescription
            failedPage = requestedPage
        }
    }

    private func refreshDelta(_ community: CommunityController, current: UUID, ticket: UUID) async throws {
        guard let owner = community.user?.id, let origin = community.origin else {
            throw BackpackError.invalid("Sign in before synchronizing owned artwork.")
        }
        struct Entry: Encodable { let id: String; let revision: String }
        struct Input: Encodable { let baseline: [Entry]; let page: Int; let snapshot: String? }
        let sameScope = deltaComplete && ownerID == owner && server == origin
        let baseline = sameScope ? items.compactMap { item in
            item.syncRevision.map { Entry(id: item.id.uuidString.lowercased(), revision: $0) }
        } : []
        guard baseline.count <= 10000 else { throw BackpackError.invalid("Owned library exceeds the change-only manifest budget.") }
        for attempt in 0..<3 {
            do {
                var staged = sameScope ? Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) : [:]
                var snapshot: String?
                var order: [UUID] = []
                var total: Int?
                var seen = Set<UUID>()
                for page in 1...100 {
                    let body = try JSONEncoder().encode(Input(baseline: baseline, page: page, snapshot: snapshot))
                    let response = try await community.request("me/items/changes", method: "POST", body: body,
                        expectedAccountRevision: current, expectedAccountID: owner)
                    try Task.checkCancellation()
                    guard community.accountRevision == current, revision == current, operation == ticket,
                          active, community.signedIn, community.origin == origin, community.user?.id == owner else {
                        throw CancellationError()
                    }
                    let delta = try JSONDecoder().decode(LibraryDeltaPage.self, from: response.data)
                    guard delta.accountId == owner, delta.page == page, delta.limit == 100, delta.items.count <= 100,
                          (0...10000).contains(delta.total), snapshot == nil || snapshot == delta.snapshot,
                          total == nil || total == delta.total,
                          delta.nextPage == nil || delta.nextPage == page + 1 else {
                        throw BackpackError.invalid("Owned library returned an inconsistent change snapshot.")
                    }
                    if page == 1 {
                        snapshot = delta.snapshot; total = delta.total; order = delta.order
                        guard order.count == delta.total, Set(order).count == order.count,
                              delta.removed.count <= baseline.count else { throw BackpackError.invalid("Invalid owned library manifest.") }
                        for id in delta.removed { staged.removeValue(forKey: id) }
                    } else if !delta.removed.isEmpty || !delta.order.isEmpty {
                        throw BackpackError.invalid("Owned library repeated its change manifest.")
                    }
                    for item in delta.items {
                        guard item.status != "deleted", let syncRevision = item.syncRevision,
                              syncRevision.count == 64, syncRevision.allSatisfy({ $0.isHexDigit }),
                              seen.insert(item.id).inserted else { throw BackpackError.invalid("Invalid owned library change.") }
                        staged[item.id] = item
                    }
                    if delta.nextPage == nil {
                        guard Set(staged.keys) == Set(order) else { throw BackpackError.invalid("Incomplete owned library changes.") }
                        items = try order.map { id in
                            guard let item = staged[id] else { throw BackpackError.invalid("Missing owned artwork.") }
                            return item
                        }
                        ownerID = owner; server = origin; nextPage = nil; pageLimit = nil
                        contentRevisions = [:]; failedPage = nil; deltaComplete = true
                        return
                    }
                    guard !delta.items.isEmpty else { throw BackpackError.invalid("Owned library changes made no progress.") }
                }
                throw BackpackError.invalid("Owned library changes exceed their pagination budget.")
            } catch let error as CommunityFailure where error.code == "library_snapshot_changed" && attempt < 2 { continue }
        }
        throw BackpackError.invalid("Owned library changes could not be completed.")
    }

    func loadMore(_ community: CommunityController, library: LocalLibrary? = nil) async {
        guard active, !loading, let page = nextPage, revision == community.accountRevision, community.signedIn else { return }
        let current = community.accountRevision
        let ticket = UUID(); operation = ticket
        loading = true; failure = nil
        defer {
            if revision == current && operation == ticket {
                if community.accountRevision != current { clear() }
                else { loading = false }
            }
        }
        do {
            let result = try await community.cloudPage(page: page)
            try Task.checkCancellation()
            guard revision == current, community.accountRevision == current, operation == ticket, active else { return }
            guard result.page == page, result.limit == pageLimit else { throw BackpackError.invalid("The owned library returned a different page or page size.") }
            let added = merge(result.items)
            guard result.nextPage == nil || added > 0 else { throw BackpackError.invalid("Cloud pagination repeated the same items. Retry or refine the library.") }
            nextPage = result.nextPage
            if let library { try await downloadMissing(community, library: library, revision: current, ticket: ticket) }
        } catch {
            guard !Task.isCancelled, revision == current, community.accountRevision == current, operation == ticket, active else { return }
            failure = error.localizedDescription
            failedPage = page
        }
    }

    private func downloadMissing(_ community: CommunityController, library: LocalLibrary, revision: UUID, ticket: UUID) async throws {
        guard let origin = server, let owner = ownerID else {
            throw BackpackError.invalid("Sign in before synchronizing owned artwork.")
        }
        // Protocol 1 owns reconciliation when enabled; never bypass its pause or unlock gates.
        guard let config = community.config else { throw BackpackError.invalid("Load cloud capabilities before synchronization.") }
        guard config.cloudLibraryEncryptionEnabled != true else { return }
        for cloud in cloudOnly(local: library.state.media, origin: origin, owner: owner) {
            guard operation == ticket, active else { throw CancellationError() }
            let bytes = try await community.download(cloud.item.gifUrl)
            try Task.checkCancellation()
            guard operation == ticket, active, community.accountRevision == revision, community.signedIn,
                  community.origin == origin, community.user?.id == owner else {
                throw BackpackError.invalid("Cloud account changed; downloaded artwork was discarded.")
            }
            _ = try library.saveCatalogGIF(bytes, item: cloud.item, origin: origin, accountID: owner, assetURL: cloud.item.gifUrl)
        }
    }

    func cloudOnly(local: [SavedMedia], origin: CommunityOrigin?, owner: UUID?) -> [CommunityCloudItem] {
        guard let origin, let owner, origin == server, owner == ownerID else { return [] }
        let linked = Set(local.compactMap { media -> UUID? in
            guard let source = media.cloudSource, source.server == origin.url.absoluteString,
                  source.accountID == owner else { return nil }
            return source.itemID
        })
        return items.filter { !linked.contains($0.id) }
    }

    func connectedItem(_ media: SavedMedia, origin: CommunityOrigin?, owner: UUID?) -> CommunityCloudItem? {
        guard let origin, let owner, origin == server, owner == ownerID, let source = media.cloudSource,
              source.server == origin.url.absoluteString, source.accountID == owner else { return nil }
        return items.first { $0.id == source.itemID }
    }
}

@MainActor
struct CloudArtworkRow: View {
    @EnvironmentObject private var community: CommunityController
    let cloud: CommunityCloudItem
    let open: () -> Void
    var previewKey: String? = nil
    var body: some View {
        Button(action: open) {
            GIFThumbnail(key: previewKey ?? cloud.item.previewUrl.absoluteString, cache: false) {
                try await community.download(cloud.item.previewUrl)
            }.aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(.plain).accessibilityLabel("Preview \(cloud.item.title)")
    }
}

@MainActor
struct CloudArtworkDetail: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var library: LocalLibrary
    @Environment(\.dismiss) private var dismiss
    let cloud: CommunityCloudItem
    @State private var bytes: Data?
    @State private var loadedOrigin: CommunityOrigin?
    @State private var loadedOwner: UUID?
    @State private var failure: String?
    @State private var saved = false
    @State private var retry = 0
    @State private var sharing = false
    @State private var deleting = false
    @State private var busy = false
    @State private var shared = false
    @State private var directSend: BackpackSendRequest?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let bytes { AnimatedPreview(data: bytes).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 22)) }
                    else if failure == nil { ProgressView("Opening cloud GIF...").frame(maxWidth: .infinity, minHeight: 180) }
                    Label(cloud.visibility == "private" ? "Private cloud library" : "Community / \(cloud.status)",
                        systemImage: cloud.visibility == "private" ? "lock.icloud" : "person.2")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(cloud.item.displayAttribution).font(.caption).foregroundStyle(.secondary)
                    Button("Send & Play directly from cloud") { directSend = BackpackSendRequest(sources: [.legacyCloud(cloud)]) }
                        .buttonStyle(AuroraPrimaryButton()).disabled(bytes == nil || busy)
                    if cloud.visibility == "private" && !shared {
                        Button("Share with the community") { sharing = true }.disabled(busy)
                    }
                    if shared { Label("Submitted for community review", systemImage: "checkmark.circle").font(.caption) }
                    if community.user?.role == "admin" {
                        Button("Delete cloud copy", role: .destructive) { deleting = true }.disabled(busy)
                    }
                    if busy { ProgressView() }
                    if !cloud.moderationReason.isEmpty { Text(cloud.moderationReason).font(.caption) }
                    if let failure {
                        Text(failure).foregroundStyle(.orange)
                        Button("Try again") { retry += 1 }
                    }
                }.padding(24)
            }
            .modernScene().navigationTitle("Cloud artwork")
            .toolbar { Button("Done") { dismiss() }.disabled(busy) }
            .safeAreaInset(edge: .bottom) {
                Button("Done") { dismiss() }
                    .frame(maxWidth: .infinity).padding().background(.bar).disabled(busy)
            }
            .interactiveDismissDisabled(busy)
            .task(id: retry) {
                bytes = nil; loadedOrigin = nil; loadedOwner = nil; failure = nil
                do {
                    let revision = community.accountRevision
                    if community.user == nil { try await community.refreshUser() }
                    guard let owner = community.user?.id, let origin = community.origin else {
                        throw BackpackError.invalid("Sign in to open your private cloud library.")
                    }
                    let data = try await community.download(cloud.item.gifUrl)
                    try Task.checkCancellation()
                    guard community.accountRevision == revision else { throw BackpackError.invalid("The cloud account changed.") }
                    try GIFPreviewDecoder.validateOriginal(data)
                    loadedOrigin = origin; loadedOwner = owner; bytes = data
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
            .onChange(of: community.accountRevision) { _, _ in bytes = nil; dismiss() }
            .onDisappear { bytes = nil; loadedOwner = nil; loadedOrigin = nil }
            .sheet(item: $directSend) { request in BackpackDirectSendView(request: request) }
            .confirmationDialog("Share this GIF for review? This confirms your right to publish and permits the server's optional AI review. It does not publish until approved.", isPresented: $sharing) {
                Button("I have sharing rights; submit") {
                    guard !busy else { return }
                    busy = true; failure = nil
                    Task {
                        defer { busy = false }
                        do { _ = try await community.submitUpload(cloud.id, sharingAttested: true); shared = true }
                        catch { failure = error.localizedDescription }
                    }
                }
            }
            .confirmationDialog("Delete only this cloud copy? Local copies are not erased.", isPresented: $deleting) {
                Button("Delete cloud copy", role: .destructive) {
                    guard !busy else { return }
                    busy = true; failure = nil
                    Task {
                        defer { busy = false }
                        do { try await community.deleteUpload(cloud.id); dismiss() }
                        catch { failure = error.localizedDescription }
                    }
                }
            }
        }
    }
}
