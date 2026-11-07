import SwiftUI
import BackpackProtocol

struct CommunitySelection {
    static let maximum = 20
    private(set) var ids: [UUID] = []
    mutating func toggle(_ id: UUID) throws {
        if ids.contains(id) { ids.removeAll { $0 == id }; return }
        guard ids.count < Self.maximum else { throw BackpackError.invalid("Select up to20 GIFs per action.") }
        ids.append(id)
    }
    mutating func clear() { ids = [] }
    mutating func remove(_ id: UUID) { ids.removeAll { $0 == id } }
    func selected(from items: [CommunityItem]) throws -> [CommunityItem] {
        guard Set(items.map(\.id)).count == items.count else { throw BackpackError.invalid("The current gallery contains duplicate identities; reload before selecting.") }
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id,$0) })
        return try ids.map {
            guard let item = lookup[$0] else { throw BackpackError.invalid("Selected GIF is no longer on the current authorized page. Clear/reselect explicitly.") }
            return item
        }
    }
}
enum CommunitySelectionAction: Equatable { case favorite, send }

@MainActor
final class CommunitySelectionStore: ObservableObject {
    @Published private(set) var selection = CommunitySelection()
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var message: String?
    @Published private(set) var completed = 0
    @Published private(set) var queueReady = false
    private var epoch = UUID()
    private var task: Task<Void, Never>?
    func toggle(_ id: UUID) {
        guard !busy else { return }
        do { try selection.toggle(id); failure = nil; message = nil }
        catch { failure = error.localizedDescription }
    }
    func clear() { guard !busy else { return }; selection.clear(); failure = nil; message = nil }
    func invalidate() {
        epoch = UUID(); task?.cancel(); task = nil; busy = false; selection.clear()
        queueReady = false; failure = nil; message = nil; completed = 0
    }
    func cancel() {
        guard busy else { return }
        epoch = UUID(); task?.cancel(); task = nil; busy = false
        message = "Stopped. \(completed) copies already \(queueReady ? "queued" : "favorited"); unprocessed selections remain. No LED slots were written."
    }
    func apply(_ action: CommunitySelectionAction, items: [CommunityItem], community: CommunityController, library: LocalLibrary) {
        guard !busy else { return }
        let chosen: [CommunityItem]
        do {
            chosen = try selection.selected(from: items)
            guard !chosen.isEmpty else { throw BackpackError.invalid("Select at least one GIF.") }
            if action == .send {
                guard (library.state.transferQueue?.count ?? 0) + chosen.count <= 60 else { throw BackpackError.invalid("The send queue holds60 GIFs. Remove queued entries or select fewer.") }
            }
        } catch { failure = error.localizedDescription; return }
        guard let origin = community.origin else { failure = "Configure the catalog before selecting community GIFs."; return }
        let account = community.accountRevision, policy = community.avatarPolicyRevision
        let stamp = UUID(); epoch = stamp; busy = true; failure = nil; message = nil; completed = 0; queueReady = false
        task = Task {
            defer { if epoch == stamp { busy = false } }
            do {
                var byteCount = 0
                for item in chosen {
                    try Task.checkCancellation()
                    guard epoch == stamp, community.origin == origin, community.accountRevision == account,
                          community.avatarPolicyRevision == policy, !community.avatarPolicyChanging else { throw CancellationError() }
                    guard let original = item.recordedFiles.first(where: \.original) else { throw BackpackError.invalid("Original file descriptor unavailable; no source reconstruction.") }
                    let copy = try await community.downloadCatalogFile(itemID: item.id, file: original)
                    try Task.checkCancellation()
                    guard epoch == stamp, community.origin == origin, community.accountRevision == account,
                          community.avatarPolicyRevision == policy, !community.avatarPolicyChanging else { throw CancellationError() }
                    byteCount += copy.data.count
                    guard byteCount <= 50_000_000 else { throw BackpackError.invalid("This selection exceeds50 MB; processed copies are retained, select the remainder in a smaller batch.") }
                    _ = try library.saveCatalogGIF(copy.data, item: item, origin: origin, accountID: nil,
                        assetURL: original.url, favorite: action == .favorite, queued: action == .send)
                    completed += 1; selection.remove(item.id)
                    if action == .send { queueReady = true }
                    message = "\(completed)/\(chosen.count) \(action == .favorite ? "added to local Favorites" : "saved and added to Send queue")."
                    await Task.yield()
                }
                message = action == .favorite ? "\(completed) GIFs added to your local Favorites. Credits retained; no public likes/cloud upload." :
                    "\(completed) GIFs queued. Review panel/slots and confirm in Send queue before any LED write."
            } catch {
                if epoch == stamp {
                    failure = "\(error.localizedDescription) \(completed) copies already \(action == .favorite ? "favorited" : "queued"); unprocessed selections remain. No automatic retry or LED slot writes."
                }
            }
        }
    }
}
