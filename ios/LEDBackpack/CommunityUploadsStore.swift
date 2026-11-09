import Foundation
import Combine
import BackpackProtocol

@MainActor
final class CommunityUploadsStore: ObservableObject {
    @Published private(set) var items: [CommunitySubmission] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var nextPage: Int?
    private var fetch: (@MainActor (Int) async throws -> CommunityUploadPage)?
    private var valid: @MainActor () -> Bool = { false }
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var failedPage: Int?
    private var pageLimit: Int?
    func search(valid: @escaping @MainActor () -> Bool, fetch: @escaping @MainActor (Int) async throws -> CommunityUploadPage) {
        cancel(); self.valid = valid; self.fetch = fetch
        items = []; failure = nil; nextPage = nil; pageLimit = nil; failedPage = nil
        load(1)
    }
    func nearEnd(_ id: UUID) {
        guard !loading, failure == nil, let nextPage, items.suffix(4).contains(where: { $0.id == id }) else { return }
        load(nextPage)
    }
    func retry() { if !loading, let failedPage { load(failedPage) } }
    func cancel() { work?.cancel(); work = nil; generation = UUID(); loading = false; valid = { false } }
    func update(_ item: CommunitySubmission) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    private func load(_ page: Int) {
        guard !loading, valid(), let fetch else { return }
        let ticket = UUID(); generation = ticket; loading = true; failure = nil; failedPage = nil
        work = Task {
            defer { if generation == ticket { loading = false; work = nil } }
            do {
                try Task.checkCancellation()
                let result = try await fetch(page)
                try Task.checkCancellation()
                guard generation == ticket, valid() else { return }
                guard result.page == page, (1...100).contains(result.limit), result.total >= result.items.count,
                      result.items.count <= result.limit, page < 10000,
                      pageLimit == nil || pageLimit == result.limit else {
                    throw BackpackError.invalid("Uploads returned an invalid page. Retry or change the filter.")
                }
                pageLimit = result.limit
                var indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
                var added = 0
                for item in result.items {
                    if let index = indices[item.id] { items[index] = item }
                    else if items.count < 100 { indices[item.id] = items.count; items.append(item); added += 1 }
                }
                let more = page * result.limit < result.total && items.count < 100
                guard !more || added > 0 else { throw BackpackError.invalid("Uploads returned no new items. Retry this page or refine the filter.") }
                nextPage = more ? page + 1 : nil
            } catch {
                guard generation == ticket, valid(), !Task.isCancelled else { return }
                failure = error.localizedDescription; failedPage = page
            }
        }
    }
}
