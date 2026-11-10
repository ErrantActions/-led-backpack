import SwiftUI
import BackpackProtocol

@MainActor
struct NativeGroupCreateView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    @State private var title = ""
    @State private var friends: [SocialPerson] = []
    @State private var chosen = Set<UUID>()
    @State private var shareHistory = false
    @State private var page = 1
    @State private var confirm = false
    @State private var captured: (String, [UUID], Bool, UUID)?
    var body: some View {
        NavigationStack {
            Form {
                Section("Group") { TextField("Group title", text: $title); Toggle("Share retained earlier history with invitees", isOn: $shareHistory) }
                Section("Invite accepted friends") {
                    if friends.isEmpty && !session.busy && session.failure == nil {
                        Text("No friends on this page. Connect with friends before inviting them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(friends) { friend in
                        Toggle(friend.displayName, isOn: Binding(get: { chosen.contains(friend.id) }, set: {
                            if $0 { chosen.insert(friend.id) } else { chosen.remove(friend.id) }
                        }))
                    }
                    HStack {
                        Button("Previous") { page -= 1; load() }.disabled(page <= 1)
                        Spacer(); Button("Next") { page += 1; load() }.disabled(friends.count < 50)
                    }
                    Text("Up to 29 invitees. Each must accept. Sharing history defaults off and never shares other chats or private organizer questions.").font(.caption)
                }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if session.busy { ProgressView("Working with group choices…") }
                Button("Review & create") {
                    guard let client = session.client else { return }
                    captured = (title, Array(chosen), shareHistory, client.instanceID); confirm = true
                }.buttonStyle(AuroraPrimaryButton()).disabled(session.busy || session.denied || chosen.count > 29)
            }.disabled(session.busy)
            .modernScene().navigationTitle("New group")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(session.busy) } }
            .safeAreaInset(edge: .bottom) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .frame(maxWidth: .infinity).padding().background(.bar).disabled(session.busy)
            }
            .interactiveDismissDisabled(session.busy)
            .task { session.bind(community); load() }
            .onChange(of: community.accountRevision) { _, _ in session.clear(); chosen = []; friends = []; captured = nil; dismiss() }
            .onDisappear { session.clear() }
            .confirmationDialog("Create the captured group?", isPresented: $confirm) {
                if let value = captured {
                    Button("Create & send invitations") {
                        session.run(expected: value.3, { _ = try await $0.createRoom(title: value.0, invitees: value.1, shareHistory: value.2) },
                            success: { dismiss() })
                    }
                }
            } message: { Text(captured?.2 == true ? "Invitations deliberately include retained room history." : "Invitees start after acceptance; earlier history stays unavailable.") }
        }
    }
    private func load() {
        session.run { client in let value = try await client.friends(page: page); try session.checked(client); friends = value.friends }
    }
}

@MainActor
struct NativeRoomInfoView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    let client: CommunityFeatureClient
    @State private var room: NativeChatRoom
    @State private var members: [NativeChatMember] = []
    @State private var friends: [SocialPerson] = []
    @State private var memberPage = 1
    @State private var friendPage = 1
    @State private var hasMoreMembers = false
    @State private var title = ""
    @State private var shareHistory = false
    @State private var failure: String?
    @State private var busy = false
    @State private var needsReview = false
    @State private var pending: Action?
    @State private var task: Task<Void, Never>?
    struct Action {
        let room: NativeChatRoom
        let name: String
        let target: UUID?
        let title: String
        let shareHistory: Bool
    }
    init(initial: NativeChatRoom, client: CommunityFeatureClient) { self.client = client; _room = State(initialValue: initial) }
    private var canManage: Bool { room.kind == "group" && room.canManage && room.ownerId == client.accountID && !room.archived && !needsReview }
    var body: some View {
        NavigationStack {
            Form {
                if let failure { Text(failure).foregroundStyle(.orange) }
                if busy { ProgressView("Updating room…") }
                Section("Current room") {
                    Text(room.title)
                    Text(room.kind == "event" ? "Event-wide membership is tied to current event eligibility, not private questions." : "Room ownership does not grant catalog administration or private-library access.").font(.caption)
                    Button("Refresh current access", action: load)
                }
                Section("Members") {
                    ForEach(members) { member in
                        HStack {
                            Text(member.displayName); Spacer()
                            if member.owner { Text("Owner").font(.caption) }
                            else if canManage && member.available {
                                Menu("Manage") {
                                    Button("Remove member", role: .destructive) { capture("remove", member.id) }
                                    if member.state == "joined" { Button("Transfer ownership") { capture("transfer", member.id) } }
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Previous") { memberPage -= 1; load() }.disabled(memberPage <= 1)
                        Spacer(); Button("Next") { memberPage += 1; load() }.disabled(!hasMoreMembers)
                    }
                }
                if canManage {
                    Section("Owner controls") {
                        TextField("New group title", text: $title)
                        Button("Review title change") { capture("title") }
                        Toggle("Share retained history with new invitee", isOn: $shareHistory)
                        ForEach(friends) { friend in Button("Invite \(friend.displayName)") { capture("invite", friend.id) } }
                        HStack {
                            Button("Previous friends") { friendPage -= 1; load() }.disabled(friendPage <= 1)
                            Spacer(); Button("Next friends") { friendPage += 1; load() }.disabled(friends.count < 50)
                        }
                        Button("Delete group & server history", role: .destructive) { capture("delete") }
                    }
                } else if room.ownerId != client.accountID { Button("Leave room", role: .destructive) { capture("leave") } }
            }
            .disabled(busy).modernScene().navigationTitle("Room information")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .safeAreaInset(edge: .bottom) {
                Button("Done") { dismiss() }
                    .frame(maxWidth: .infinity).padding().background(.bar).disabled(busy)
            }
            .interactiveDismissDisabled(busy)
            .task { load() }
            .onDisappear { task?.cancel(); members = []; friends = []; pending = nil }
            .onChange(of: community.accountRevision) { _, _ in task?.cancel(); members = []; friends = []; pending = nil; dismiss() }
            .confirmationDialog("Confirm captured room change?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let action = pending { Button("Confirm \(action.name)", role: action.name == "delete" || action.name == "remove" || action.name == "leave" ? .destructive : nil) { perform(action) } }
            } message: { Text("This uses the displayed room revision. A conflict preserves your choices and requires refreshing/reviewing, never automatic rebase. Leaving does not withdraw event RSVP.") }
        }
    }
    private func capture(_ name: String, _ target: UUID? = nil) { pending = Action(room: room, name: name, target: target, title: title, shareHistory: shareHistory) }
    private func load() {
        needsReview = true
        run {
            let current = try await client.room(room.id)
            let roster = try await client.roomMembers(current, page: memberPage)
            guard roster.revision == current.revision else { throw BackpackError.invalid("Room changed while fetching the roster. Refresh and review again.") }
            let peers = current.canManage && current.ownerId == client.accountID ? try await client.friends(page: friendPage).friends : []
            try client.check(.messaging)
            room = current; members = roster.members; friends = peers; hasMoreMembers = roster.hasMore; needsReview = false
        }
    }
    private func perform(_ action: Action) {
        run({
            if action.name == "leave" { try await client.leaveRoom(action.room.id) }
            else if action.name == "title" { try await client.editRoom(action.room, title: action.title) }
            else { try await client.manageRoom(action.room, target: action.target, action: action.name, shareHistory: action.shareHistory) }
            try client.check(.messaging)
        }, success: {
            pending = nil
            if ["leave", "delete"].contains(action.name) { dismiss() }
            else { load() }
        })
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void, success: @escaping @MainActor () -> Void = {}) {
        guard !busy else { return }
        busy = true; failure = nil
        task = Task {
            do { try await operation(); try Task.checkCancellation(); busy = false; success() }
            catch {
                if Task.isCancelled { return }
                busy = false; failure = error.localizedDescription
                if let value = error as? CommunityFailure, [401, 403, 404, 409].contains(value.status) {
                    members = []; friends = []; needsReview = true
                }
            }
        }
    }
}
