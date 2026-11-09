import Foundation
import Combine
import BackpackProtocol

@MainActor
final class CommunityGalleryStore: ObservableObject {
    @Published private(set) var items: [CommunityItem] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var nextPage: Int?
    @Published private(set) var total = 0
    private var revisions: [UUID: UUID] = [:]
    private var fetch: (@MainActor (Int) async throws -> CommunityPage)?
    private var valid: @MainActor () -> Bool = { false }
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var failedPage: Int?
    private var active = false
    private var pageLimit: Int?

    func search(valid: @escaping @MainActor () -> Bool, fetch: @escaping @MainActor (Int) async throws -> CommunityPage) {
        cancel()
        self.valid = valid; self.fetch = fetch; active = true
        items = []; revisions = [:]; nextPage = nil; total = 0; failure = nil; failedPage = nil; pageLimit = nil
        load(1)
    }
    func nearEnd(_ id: UUID) {
        guard active, valid(), !loading, failure == nil, let nextPage,
              items.suffix(4).contains(where: { $0.id == id }) else { return }
        load(nextPage)
    }
    func retry() {
        guard active, valid(), !loading, let failedPage else { return }
        load(failedPage)
    }
    func cancel() {
        active = false; work?.cancel(); work = nil; generation = UUID(); loading = false
    }
    func resume() {
        active = true
        if items.isEmpty && failure == nil && nextPage == nil { load(1) }
    }
    func thumbnailKey(_ item: CommunityItem, url: URL) -> String {
        "community:\(item.id):\(revisions[item.id]?.uuidString ?? "original"):\(url.absoluteString)"
    }
    private func load(_ page: Int) {
        guard active, valid(), !loading, let fetch else { return }
        let ticket = UUID(); generation = ticket; loading = true; failure = nil; failedPage = nil
        work = Task {
            defer { if generation == ticket { loading = false; work = nil } }
            do {
                try Task.checkCancellation()
                let result = try await fetch(page)
                try Task.checkCancellation()
                guard generation == ticket, active, valid() else { return }
                guard result.page == page, (1...100).contains(result.limit), result.total >= result.items.count,
                      result.items.count <= result.limit, page < 10000,
                      pageLimit == nil || pageLimit == result.limit else {
                    throw BackpackError.invalid("The gallery returned an invalid page. Retry or change the search.")
                }
                pageLimit = result.limit
                var merged = items, indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
                var added = 0
                for item in result.items {
                    if let index = indices[item.id] { merged[index] = item }
                    else if merged.count < 100 { indices[item.id] = merged.count; merged.append(item); added += 1 }
                    revisions[item.id] = UUID()
                }
                items = merged; total = result.total
                let more = page * result.limit < result.total && merged.count < 100
                guard !more || added > 0 else {
                    throw BackpackError.invalid("The gallery returned no new artwork. Retry this page or refine the search.")
                }
                nextPage = more ? page + 1 : nil
            } catch {
                guard generation == ticket, active, valid(), !Task.isCancelled else { return }
                failure = error.localizedDescription; failedPage = page
            }
        }
    }
}
