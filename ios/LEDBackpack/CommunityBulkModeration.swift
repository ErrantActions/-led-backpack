import SwiftUI
import CryptoKit
import BackpackProtocol

struct CommunityBulkRequest: Encodable {
    let ids: [UUID]
    let action, reason, confirmation: String
    private enum CodingKeys: String, CodingKey { case ids, action, reason, confirmation }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ids.map { $0.uuidString.lowercased() }, forKey: .ids)
        try values.encode(action, forKey: .action)
        try values.encode(reason, forKey: .reason)
        try values.encode(confirmation, forKey: .confirmation)
    }
    func validate() throws {
        guard (1...100).contains(ids.count), Set(ids).count == ids.count,
              ["delete", "quarantine"].contains(action), confirmation == action.uppercased(),
              (1...1000).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) else {
            throw BackpackError.invalid("Select 1…100 distinct community GIFs, provide a reason, and type the exact action confirmation.")
        }
    }
}
struct CommunityBulkReceipt: Decodable {
    let action: String
    let affected: Int
    let ids: [UUID]
    let cleanupPending: Int
    func validate(_ request: CommunityBulkRequest) throws {
        guard action == request.action, affected == request.ids.count, Set(ids) == Set(request.ids),
              ids.count == request.ids.count,
              cleanupPending == (action == "delete" ? affected : 0) else {
            throw BackpackError.invalid("Bulk action receipt differs from the exact selected IDs. Reconcile, do not repeat.")
        }
    }
}

extension AdminItem {
    var moderationSnapshot: Data {
        get throws {
            struct Snapshot: Encodable {
                let id: UUID
                let status, title, category, reason, aiState: String
                let tags: [String]
                let requiresReview, held, quarantined: Bool
                let version: Int?
                let original: String
                let width, height, frames: Int
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(Snapshot(id: id, status: status.rawValue, title: item.title,
                category: item.category, reason: moderationReason, aiState: aiState, tags: item.tags,
                requiresReview: requiresAdminReview, held: heldByReports, quarantined: quarantined,
                version: moderationVersion, original: item.gifUrl.absoluteString,
                width: item.width, height: item.height, frames: item.frameCount))
        }
    }
}

@MainActor
struct CommunityBulkModerationView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = AccountServiceSession()
    @State private var page: AdminItemsPage?
    @State private var number = 1
    @State private var status = "pending"
    @State private var selected: Set<UUID> = []
    @State private var action = "quarantine"
    @State private var reason = ""
    @State private var confirmation = ""
    @State private var pending: Captured?
    @State private var sizes = NativeMatrixFilter()
    private struct Captured {
        let request: CommunityBulkRequest
        let snapshots: [UUID: Data]
        let revision: UUID
    }
    var body: some View {
        Form {
            Text("Community-only moderation. Private/cloud artwork is excluded. Quarantine withdraws all public media and requires explicit manual safety approval in the existing item editor; AI cannot release it. Delete hides atomically and queues durable byte cleanup.")
                .font(.caption)
            if session.scope != nil {
                if community.config?.nativeSizeFiltersEnabled == true { NativeMatrixFilterControls(filter: $sizes) }
                Picker("Queue", selection: $status) {
                    Text("Pending").tag("pending"); Text("Approved").tag("approved")
                    Text("Rejected").tag("rejected"); Text("Quarantined").tag("quarantined")
                }
                if let page {
                    Section("Page \(number) — \(page.total) matches") {
                        if page.items.isEmpty { Text("No community items in this queue.") }
                        ForEach(page.items) { value in
                            Toggle(isOn: Binding(get: { selected.contains(value.id) }, set: {
                                if $0 { selected.insert(value.id) } else { selected.remove(value.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(value.item.title)
                                    Text("\(value.id.uuidString.lowercased()) · \(value.status.rawValue)\(value.quarantined ? " · quarantine" : "")")
                                        .font(.caption).textSelection(.enabled)
                                    if let version = value.moderationVersion { Text("Moderation revision \(version)").font(.caption) }
                                }
                            }
                        }
                        HStack {
                            Button("Previous") { number = max(1, number - 1); load() }.disabled(number == 1)
                            Button("Next") { number += 1; load() }.disabled(number * 24 >= page.total)
                        }
                    }
                    Section("Exact selected IDs (\(selected.count))") {
                        Picker("Action", selection: $action) { Text("Quarantine").tag("quarantine"); Text("Delete").tag("delete") }
                        TextField("Required moderation reason", text: $reason, axis: .vertical)
                        TextField("Type \(action.uppercased())", text: $confirmation).textInputAutocapitalization(.characters)
                        Text("Selection resets on paging/refresh. Current item state is checked before submission. This API has no client version-CAS field: the server atomically rejects missing/deleted/private IDs, but not every concurrent moderation edit. No version guarantee is invented.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Review captured \(action)", role: .destructive) {
                            session.run { scope in
                                let ids = selected.sorted { $0.uuidString < $1.uuidString }
                                let request = CommunityBulkRequest(ids: ids, action: action, reason: reason, confirmation: confirmation)
                                try request.validate()
                                var snapshots: [UUID: Data] = [:]
                                for id in ids {
                                    guard let item = page.items.first(where: { $0.id == id }) else { throw BackpackError.invalid("Selection is not on the current page.") }
                                    snapshots[id] = try item.moderationSnapshot
                                }
                                try session.checked(scope)
                                pending = Captured(request: request, snapshots: snapshots, revision: scope.revision)
                                return nil
                            }
                        }.disabled(selected.isEmpty)
                    }
                }
                Button("Reload queue / discard selection") { load() }
            } else { Text("Current admin bulk capability is unavailable. No action is enabled on production merely by this source.") }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let message = session.message { Text(message) }
        }.disabled(session.busy).navigationTitle("Bulk community moderation")
            .task(id: "\(community.accountRevision):\(community.user?.role ?? ""):\(community.config?.adminBulkModerationEnabled == true):\(community.avatarPolicyRevision)") {
                reset(); session.bind(community, .bulk, admin: true); load()
            }
            .onChange(of: status) { _, _ in number = 1; load() }
            .onChange(of: sizes) { _, _ in number = 1; load() }
            .onDisappear { session.clear(); reset() }
            .confirmationDialog("Apply the captured action to exactly these community IDs?", isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                    if let pending {
                        Button("\(pending.request.action.uppercased()) \(pending.request.ids.count) GIFs", role: .destructive) {
                            self.pending = nil
                            session.run { scope in
                                guard pending.revision == scope.revision else { throw BackpackError.invalid("Admin account changed.") }
                                try pending.request.validate()
                                let admin = try CommunityAdminClient(community)
                                for id in pending.request.ids {
                                    let current = try await admin.item(id)
                                    guard try current.moderationSnapshot == pending.snapshots[id] else {
                                        selected = []; throw BackpackError.invalid("Selected item state/version changed. Nothing was submitted; reload.")
                                    }
                                }
                                let result = try await scope.send(CommunityBulkReceipt.self, "admin/items/bulk",
                                    method: "POST", body: JSONEncoder().encode(pending.request))
                                try result.validate(pending.request); try session.checked(scope)
                                reset()
                                return "\(result.affected) items \(result.action == "delete" ? "hidden; cleanup queued" : "quarantined"). Reload the queue."
                            }
                        }
                    }
                } message: { Text(pending.map { $0.request.ids.map { $0.uuidString.lowercased() }.joined(separator: "\n") + "\nReason: " + $0.request.reason } ?? "") }
    }
    private func reset() { selected = []; pending = nil; page = nil; confirmation = ""; reason = "" }
    private func load() {
        reset()
        session.run { scope in
            let requestedPage = number, requestedStatus = status, requestedSizes = sizes
            guard (1...10000).contains(number), ["pending", "approved", "rejected", "quarantined"].contains(status) else { throw BackpackError.invalid("Invalid queue/page.") }
            if !sizes.sizes.isEmpty && community.config?.nativeSizeFiltersEnabled != true { throw BackpackError.invalid("Admin exact size filters are unavailable.") }
            let result = try await scope.send(AdminItemsPage.self, "admin/items", query: [
                URLQueryItem(name: "visibility", value: "shared"), URLQueryItem(name: "status", value: status),
                URLQueryItem(name: "page", value: String(number)), URLQueryItem(name: "limit", value: "24")] + (try sizes.query()))
            guard result.page == number, result.limit == 24, result.total >= 0, result.items.count <= 24,
                  Set(result.items.map(\.id)).count == result.items.count else { throw BackpackError.invalid("Invalid current community moderation page.") }
            try session.checked(scope)
            guard number == requestedPage, status == requestedStatus, sizes == requestedSizes else { throw BackpackError.invalid("Queue filters changed. Reload the current selection.") }
            page = result; return nil
        }
    }
}
