import SwiftUI
import BackpackProtocol

struct CommunityBlockedUser: Decodable, Identifiable {
    let id: UUID
    let displayName: String
}

extension CommunityController {
    func blockedUsers() async throws -> [CommunityBlockedUser] {
        guard signedIn else { throw BackpackError.invalid("Sign in to manage blocked accounts.") }
        let revision = accountRevision
        let result = try await request("blocks")
        try Task.checkCancellation()
        guard accountRevision == revision, signedIn else {
            throw BackpackError.invalid("Discarded blocked accounts after the signed-in account changed.")
        }
        struct Result: Decodable { let users: [CommunityBlockedUser] }
        let users = try JSONDecoder().decode(Result.self, from: result.data).users
        guard Set(users.map(\.id)).count == users.count else { throw BackpackError.invalid("The server returned duplicate blocked-account IDs.") }
        return users
    }

    func unblock(_ id: UUID, revision: UUID, server: CommunityOrigin) async throws {
        guard signedIn, accountRevision == revision, origin == server else {
            throw BackpackError.invalid("Your account or server changed. Refresh blocked accounts before unblocking.")
        }
        let response = try await request("blocks/\(id.uuidString.lowercased())", method: "DELETE")
        guard accountRevision == revision, origin == server, signedIn else {
            throw BackpackError.invalid("The account changed during unblocking. Refresh the current account.")
        }
        _ = try JSONDecoder().decode(CommunityMessage.self, from: response.data)
    }
}

@MainActor
struct CommunityBlocksView: View {
    @EnvironmentObject private var community: CommunityController
    @State private var users: [CommunityBlockedUser] = []
    @State private var busy = false
    @State private var failure: String?
    @State private var pending: Selection?
    @State private var operation: Task<Void, Never>?
    private struct Selection {
        let user: CommunityBlockedUser
        let revision: UUID
        let origin: CommunityOrigin
    }
    var body: some View {
        List {
            if !community.signedIn {
                Text("Sign in to manage blocked accounts.")
            } else {
                if busy { ProgressView("Updating blocked accounts...") }
                if let failure { Text(failure).foregroundStyle(.orange) }
                ForEach(users) { user in
                    HStack {
                        Text(user.displayName)
                        Spacer()
                        Button("Unblock") {
                            if let origin = community.origin {
                                pending = Selection(user: user, revision: community.accountRevision, origin: origin)
                            }
                        }.disabled(busy)
                    }
                }
                if users.isEmpty && !busy && failure == nil { Text("No blocked accounts.") }
                Button("Refresh blocked accounts") {
                    operation?.cancel(); operation = Task { await load() }
                }.disabled(busy)
                Text("Unblocking allows this uploader's community GIFs to appear again. It does not change any private or local files. Refresh after an interrupted request before retrying.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .modernScene().navigationTitle("Blocked accounts")
        .task(id: community.accountRevision) { users = []; pending = nil; await load() }
        .onChange(of: community.accountRevision) { _, _ in operation?.cancel(); pending = nil; users = [] }
        .onDisappear { operation?.cancel(); users = []; pending = nil }
        .alert("Unblock this account?", isPresented: Binding(get: { pending != nil },
            set: { if !$0 { pending = nil } }), presenting: pending) { value in
                Button("Unblock") {
                    operation?.cancel()
                    operation = Task {
                        busy = true; failure = nil
                        do {
                            try await community.unblock(value.user.id, revision: value.revision, server: value.origin)
                            try Task.checkCancellation()
                            users.removeAll { $0.id == value.user.id }
                        } catch {
                            if !Task.isCancelled, community.accountRevision == value.revision, community.origin == value.origin {
                                failure = error.localizedDescription
                                if let error = error as? CommunityFailure, [401, 403].contains(error.status) { users = [] }
                            }
                        }
                        if community.accountRevision == value.revision { busy = false }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Show community GIFs from \($0.user.displayName) again?") }
    }
    private func load() async {
        let stamp = community.accountRevision
        busy = true; failure = nil
        defer { if community.accountRevision == stamp { busy = false } }
        do {
            let result = try await community.blockedUsers()
            try Task.checkCancellation()
            guard community.accountRevision == stamp else { return }
            users = result
        } catch {
            guard !Task.isCancelled, community.accountRevision == stamp else { return }
            failure = error.localizedDescription
            if let error = error as? CommunityFailure, [401, 403].contains(error.status) { users = [] }
        }
    }
}
