import SwiftUI
import UniformTypeIdentifiers
import os
import BackpackProtocol

struct ChatScreenSelection: Identifiable, Hashable {
    let id = UUID()
    let context: ChatConversation
    let title: String
}
@MainActor
struct CommunityMessagesView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var friends: [SocialPerson] = []
    @State private var recent: [RecentChatContact] = []
    @State private var rooms: [NativeChatRoom] = []
    @State private var invitations: [NativeChatInvitation] = []
    @State private var unifiedEntries: [NativeChatInboxEntry]?
    @State private var inboxCursors: [String?] = [nil]
    @State private var composePage = 1
    @State private var composeMore = false
    @State private var page = 1
    @State private var hasMore = false
    @State private var selection: ChatScreenSelection?
    @State private var creating = false
    @State private var composing = false
    @State private var query = ""
    @State private var filter = NativeChatInboxFilter.chats
    @State private var pendingInvite: NativeChatInvitation?
    @State private var inviteScope: UUID?
    private var filteredRecent: [RecentChatContact] {
        recent.filter { filter.matches($0.profile.displayName,
            context: $0.eventId == nil ? "Direct message" : "Private organizer question", query: query) }
    }
    private var filteredRooms: [NativeChatRoom] {
        rooms.filter { filter.matches($0.title, context: $0.kind == "event" ? "Event-wide chat" : "Group chat", query: query) }
    }
    private var inboxEntries: [NativeChatInboxEntry] {
        if let unifiedEntries {
            return unifiedEntries.filter { entry in
                switch entry {
                case .direct(let contact):
                    return filter == .chats && filter.matches(contact.profile.displayName,
                        context: contact.eventId == nil ? "Direct message" : "Private organizer question", query: query)
                case .room(let room):
                    return filter != .requests && filter.matches(room.title,
                        context: room.kind == "event" ? "Event-wide chat" : "Group chat", query: query)
                }
            }
        }
        let contacts = filter == .chats ? filteredRecent.map(NativeChatInboxEntry.direct) : []
        let groups = filter != .requests ? filteredRooms.map(NativeChatInboxEntry.room) : []
        return (contacts + groups).sorted(by: NativeChatInboxEntry.newestFirst)
    }
    var body: some View {
        GeometryReader { geometry in
            let split = presentsSplit(geometry)
            HStack(spacing: 0) {
                inbox.frame(maxWidth: split ? 340 : .infinity)
                if split {
                    Divider()
                    if let selection {
                        CommunityConversationView(context: selection.context, title: selection.title, embedded: true)
                            .id(selection.context).frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationDestination(item: Binding(get: { split ? nil : selection }, set: { if !split { selection = $0 } })) { item in
                CommunityConversationView(context: item.context, title: item.title).id(item.context)
            }
        }
        .navigationTitle("Messages").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New message", systemImage: "square.and.pencil") { composing = true }
                    if community.config?.groupChatsEnabled == true {
                        Button("Create group", systemImage: "person.3") { creating = true }
                    }
                } label: { Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("New conversation")
                    .disabled(session.busy || session.denied || session.client == nil || community.config?.messagingEnabled != true)
            }
        }
        .task(id: "\(community.accountRevision):\(community.chatAccessRevision):\(community.user?.role ?? ""):\(community.config?.messagingEnabled == true):\(community.config?.chatMessageRequestsEnabled == true):\(community.config?.groupChatsEnabled == true):\(community.config?.eventChatsEnabled == true)") {
            clear(); selection = nil; page = 1; session.clear()
            guard phase == .active else { return }
            session.bind(community)
            if community.config?.messagingEnabled == true { load() }
        }
        .onChange(of: phase) { _, value in
            if value == .active { session.bind(community); if community.config?.messagingEnabled == true { load() } }
            else { session.clear(); clear() }
        }
        .onChange(of: session.denied) { _, denied in if denied { clear(); selection = nil } }
        .onChange(of: community.accountRevision) { _, _ in clear(); selection = nil; NativeChatDraftStore.shared.invalidate() }
        .onChange(of: community.chatAccessRevision) { _, _ in clear(); selection = nil; session.clear(); NativeChatDraftStore.shared.invalidate() }
        .onChange(of: community.config?.chatInboxEnabled) { _, _ in
            clear(); page = 1; selection = nil; session.bind(community)
            if phase == .active, community.config?.messagingEnabled == true { load() }
        }
        .onDisappear { session.clear(); clear() }
        .sheet(isPresented: $creating, onDismiss: load) { NativeGroupCreateView() }
        .sheet(isPresented: $composing) {
            NavigationStack {
                List {
                    if session.busy { ProgressView() }
                    if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                    ForEach(friends) { person in
                        Button {
                            composing = false
                            selection = ChatScreenSelection(context: .direct(peer: person.id, event: nil), title: person.displayName)
                        } label: { contactRow(person, subtitle: "Direct message") }
                            .buttonStyle(.plain)
                    }
                    if !session.busy, session.failure == nil, friends.isEmpty {
                        Text("Connect with a friend to start a conversation.").foregroundStyle(.secondary)
                    }
                    if composePage > 1 || composeMore {
                        HStack {
                            Button("Previous") { composePage -= 1; loadComposeFriends() }.disabled(composePage <= 1 || session.busy)
                            Spacer()
                            Button("Next") { composePage += 1; loadComposeFriends() }.disabled(!composeMore || session.busy)
                        }
                    }
                }
                .task { composePage = 1; loadComposeFriends() }
                .modernScene().navigationTitle("New message")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { composing = false } } }
                .safeAreaInset(edge: .bottom) {
                    Button("Cancel", role: .cancel) { composing = false }
                        .frame(maxWidth: .infinity).padding().background(.bar)
                }
            }
        }
        .confirmationDialog("Respond to group invitation?", isPresented: Binding(get: { pendingInvite != nil },
            set: { if !$0 { pendingInvite = nil } })) {
                if let invite = pendingInvite {
                    Button("Accept displayed history choice") { respond(invite, accept: true) }
                    Button("Decline", role: .destructive) { respond(invite, accept: false) }
                }
            } message: { Text("Uses the displayed invitation and history choice.") }
    }
    private func presentsSplit(_ geometry: GeometryProxy) -> Bool {
        guard geometry.size.width >= 760 else { return false }
        if #available(iOS 27.1, *) { return geometry.reservedRegions(kind: .division).isEmpty }
        return true
    }
    private var inbox: some View {
        List {
            if community.config?.messagingEnabled == true && !session.denied {
                if session.busy { ProgressView() }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                Picker("Conversations", selection: $filter) {
                    ForEach(NativeChatInboxFilter.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).listRowBackground(Color.clear)
                ForEach(inboxEntries) { entry in
                    switch entry {
                    case .direct(let contact):
                        Button {
                            selection = ChatScreenSelection(context: .direct(peer: contact.profile.id, event: contact.eventId),
                                title: contact.profile.displayName)
                        } label: {
                            contactRow(contact.profile, subtitle: contact.eventId == nil ? "Direct message" : "Private organizer question",
                                timestamp: contact.lastMessageCreatedAt)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat-contact-\(contact.profile.id.uuidString.lowercased())-\(contact.eventId?.uuidString.lowercased() ?? "direct")")
                    case .room(let room):
                        Button { selection = ChatScreenSelection(context: .room(room.id), title: room.title) } label: {
                            HStack(spacing: 12) {
                                NativeChatAvatar(title: room.title, group: true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(room.title).font(.headline)
                                    Text(room.archived ? "Archived" : room.kind == "event" ? "Event-wide chat" : "Group chat")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(Date(timeIntervalSince1970: room.updatedAt / 1000), style: .relative)
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if room.unread > 0 {
                                        Text("\(room.unread)").font(.caption.bold()).foregroundStyle(Aurora.onAction)
                                            .padding(7).background(Aurora.mint, in: Capsule())
                                            .accessibilityLabel("\(room.unread) unread messages")
                                }
                                }
                            }.padding(.vertical, 6).frame(minHeight: 64).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("chat-room-\(room.id.uuidString.lowercased())")
                    }
                }
                if filter == .requests {
                    if community.config?.chatMessageRequestsEnabled == true {
                        NavigationLink("Message requests") { CommunityMessageRequestsView() }
                    }
                    ForEach(invitations.filter { filter.matches($0.title, context: "Group invitation", query: query) }) { invite in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(invite.title, systemImage: "person.3").font(.headline)
                            Text("Invited by \(invite.inviter.displayName)").font(.caption)
                            Text(invite.shareHistory ? "Retained earlier messages are shared." :
                                "Earlier messages are not shared.").font(.caption).foregroundStyle(.secondary)
                            Button("Review invitation") { pendingInvite = invite; inviteScope = session.client?.instanceID }
                        }
                    }
                }
                if community.config?.deviceRecoveryEnabled == true,
                   community.config?.connectedDeviceRegistrationVersion == 2 {
                    NavigationLink("Found-device messages") { DeviceRecoveryInboxView() }
                }
                if page > 1 || hasMore { HStack {
                    Button("Previous") { page -= 1; load() }.disabled(page <= 1 || session.busy)
                    Spacer()
                    Button("Next") { page += 1; load() }.disabled(!hasMore || session.busy)
                } }
                if !session.busy && session.failure == nil && !hasMore && recent.isEmpty && rooms.isEmpty && invitations.isEmpty {
                    ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Connect with a friend to start chatting."))
                }
                if !session.busy, session.failure == nil, hasMore, recent.isEmpty, rooms.isEmpty, invitations.isEmpty {
                    Text("No accessible conversations on this page. Continue to the next page.").foregroundStyle(.secondary)
                }
                if !session.busy && session.failure == nil && !query.isEmpty && filter != .requests &&
                    filteredRooms.isEmpty && (filter == .groups || filteredRecent.isEmpty) {
                    ContentUnavailableView.search(text: query)
                }
                if !query.isEmpty { Text("Searches loaded conversation names and contexts.").font(.caption).foregroundStyle(.secondary) }
            } else { Text(session.failure ?? "Messaging is unavailable until this server advertises configured support.") }
        }
        .listStyle(.plain).modernScene()
        .searchable(text: $query, prompt: "Find a conversation")
        .disabled(session.denied || community.config?.messagingEnabled != true)
        .refreshable { load() }
    }
    private func contactRow(_ person: SocialPerson, subtitle: String, timestamp: Double? = nil) -> some View {
        HStack(spacing: 12) {
            if let client = session.client {
                CommunityProfileAvatar(person: person, client: client).frame(width: 48, height: 48)
            } else { NativeChatAvatar(title: person.displayName) }
            VStack(alignment: .leading, spacing: 4) {
                Text(person.displayName).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let timestamp {
                Text(Date(timeIntervalSince1970: timestamp / 1000), style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6).frame(minHeight: 64).contentShape(Rectangle())
    }
    private func respond(_ invite: NativeChatInvitation, accept: Bool) {
        session.run(expected: inviteScope, { try await $0.respondChatInvite(invite, accept: accept) },
            success: { pendingInvite = nil; load() })
    }
    private func load() {
        let requested = page
        session.run { client in
            if client.chatInboxEnabled {
                guard inboxCursors.indices.contains(requested - 1) else {
                    throw BackpackError.invalid("Reload the inbox before requesting this page.")
                }
                let result = try await client.chatInbox(after: inboxCursors[requested - 1])
                try session.checked(client)
                recent = result.entries.compactMap(\.contact); rooms = result.entries.compactMap(\.chat)
                invitations = result.entries.compactMap(\.invitation)
                unifiedEntries = result.entries.compactMap { entry in
                    if let contact = entry.contact { return .direct(contact) }
                    if let room = entry.chat { return .room(room) }
                    return nil
                }
                inboxCursors = Array(inboxCursors.prefix(requested))
                if let next = result.nextAfter { inboxCursors.append(next) }
                hasMore = result.hasMore
                return
            }
            let contacts = try await client.recentChats(page: requested)
            let chats = client.groupsEnabled || client.eventChatsEnabled ? try await client.rooms(page: requested) : nil
            let invites = client.groupsEnabled ? try await client.chatInvitations(page: requested) : nil
            try session.checked(client)
            recent = contacts.conversations; rooms = chats?.chats ?? []; invitations = invites?.invitations ?? []; unifiedEntries = nil
            hasMore = contacts.conversations.count == 24 || chats?.hasMore == true || invites?.hasMore == true
        }
    }
    private func loadComposeFriends() {
        let requested = composePage
        session.run { client in
            let result = try await client.friends(page: requested)
            try session.checked(client)
            friends = result.friends; composeMore = result.friends.count == 50
        }
    }
    private func clear() {
        friends = []; recent = []; rooms = []; invitations = []; unifiedEntries = nil; inboxCursors = [nil]
        pendingInvite = nil; composing = false; creating = false; query = ""; composePage = 1; composeMore = false
    }
}

@MainActor
struct CommunityConversationView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let context: ChatConversation
    let title: String
    var embedded = false
    @State private var draftScope: NativeChatDraftScope?
    @State private var messages: [NativeChatMessage] = []
    @State private var room: NativeChatRoom?
    @State private var directCursor: DirectChatCursor?
    @State private var roomCursor: Int?
    @State private var more = false
    @State private var viewToken: String?
    @State private var text = ""
    @State private var attachment: ChatAttachmentDraft?
    @State private var pin: ChatPin?
    @State private var intent: ChatSendIntent?
    @State private var outbox: NativeChatOutboxRecord?
    @State private var outboxFailure: String?
    @State private var newQuestionsAllowed = false
    @State private var contactPreference: NativeMessageRequestPreference?
    @State private var canManageOwnContact = false
    @State private var importing = false
    @State private var importScope: UUID?
    @State private var deleting: NativeChatMessage?
    @State private var deleteScope: UUID?
    @State private var liveStatus = "Connecting"
    @State private var liveFailure: String?
    @State private var liveRevision = UUID()
    @State private var revoked = false
    @State private var shareTyping = false
    @State private var typing: [ChatTypingPage.Peer] = []
    @State private var typingTask: Task<Void, Never>?
    @State private var typingExpiryTask: Task<Void, Never>?
    @State private var typingWasShared = false
    @State private var typingClient = UUID()
    @State private var roomInfo = false
    @State private var privacyDetails = false
    @State private var choosingPin = false
    @State private var choosingReference = false
    @State private var reporting: NativeChatMessage?
    @State private var reference: ChatReferenceSelection?
    @State private var referencePolicyStale = false
    @State private var referencesVerified = false
    private var conversationContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if revoked || session.denied || community.config?.messagingEnabled != true || phase != .active {
                    ContentUnavailableView("Conversation unavailable", systemImage: "lock.bubble",
                        description: Text(session.failure ?? "Refresh to check access."))
                } else {
                    HStack(spacing: 12) {
                        NativeChatAvatar(title: room?.title ?? title, group: isRoom)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversationSubtitle).font(.subheadline.weight(.semibold))
                            Text(liveStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.bottom, 12)
                    if let outboxFailure { Text(outboxFailure).foregroundStyle(.orange) }
                    if let liveFailure { Text(liveFailure).font(.caption).foregroundStyle(.orange) }
                    if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                    if more { Button("Load older messages") { load(older: true) }.disabled(session.busy) }
                    ForEach(community.avatarPolicyChanging ? [] : messages) { message in
                        NativeChatBubble(message: message, mine: message.senderId == community.user?.id, client: session.client,
                            referenceEpoch: viewToken ?? "", referencesVerified: referencesVerified, showSender: isRoom,
                            incident: session.client?.chatReportsEnabled == true && message.senderId != community.user?.id ? { reporting = message } : nil) {
                            deleting = message; deleteScope = session.client?.instanceID
                        }
                    }
                    if messages.isEmpty && !session.busy && session.failure == nil {
                        Text("No messages yet. Say hello.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    if !typing.isEmpty { Text("\(typing.map(\.displayName).joined(separator: ", ")) typing...").font(.caption).foregroundStyle(Aurora.lavender) }
                }
            }.padding(16)
        }.defaultScrollAnchor(.bottom)
        .refreshable { revoked = false; liveFailure = nil; liveRevision = UUID(); load(older: false) }
    }
    private var isRoom: Bool { if case .room = context { return true }; return false }
    private var conversationSubtitle: String {
        if let room { return room.archived ? "Archived chat" : room.kind == "event" ? "Event-wide chat" : "Group chat" }
        if case .direct(_, let event) = context, event != nil { return "Private organizer question" }
        return "Direct message"
    }
    private var conversationLifecycle: some View {
        conversationContent
        .modernScene().navigationTitle(revoked || session.denied || phase != .active || embedded ? "Messages" : room?.title ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let client = session.client, client.chatNotificationPreferencesEnabled {
                        NavigationLink("Notifications", destination: ConversationNotificationView(context: context))
                    }
                    if let room { Button("Members & room info") { roomInfo = true }.disabled(session.busy || room.archived) }
                    Button("Refresh") { revoked = false; liveFailure = nil; liveRevision = UUID(); load(older: false) }
                    Button("Privacy & history", systemImage: "info.circle") { privacyDetails = true }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Conversation actions").disabled(revoked || session.denied || session.client == nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !revoked, !session.denied, community.config?.messagingEnabled == true, let client = session.client {
                composer(client)
            }
        }
        .task(id: "\(community.accountRevision):\(community.chatAccessRevision):\(community.user?.role ?? ""):\(phase):\(community.config?.messagingEnabled == true):\(community.config?.chatMessageRequestsEnabled == true):\(community.config?.chatPlaylistReferencesEnabled == true):\(community.config?.chatReferencesEnabled == true):\(community.config?.chatMediaEnabled == true):\(community.config?.chatPinsEnabled == true):\(community.config?.directMessageRetentionDays.map(String.init) ?? "missing"):\(community.config?.directMessageRecovery ?? "missing")") {
            clear(preservingDraft: true); session.clear()
            guard phase == .active, community.config?.messagingEnabled == true else { return }
            session.bind(community); restoreDraft(); load(older: false)
        }
        .task(id: "\(session.client?.instanceID.uuidString ?? ""):\(phase):\(community.config?.messagingEnabled == true):\(community.config?.liveChatEnabled == true):\(liveRevision)") {
            guard phase == .active, community.config?.messagingEnabled == true, let client = session.client else { return }
            if client.chatLiveEnabled {
                while !Task.isCancelled && !revoked {
                    do {
                        liveStatus = "Connecting live hints..."
                        for try await hint in try client.chatHints(context) {
                            try session.checked(client)
                            if hint == .revoked { clear(); revoked = true; return }
                            if hint == .ready { liveStatus = "Live connected" }
                            if hint == .typing { try await refreshTyping(client) }
                            else if !session.busy { load(older: false) }
                        }
                        liveStatus = "Reconnecting; rechecking current history..."
                        if !session.busy { load(older: false) }
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        if Task.isCancelled { return }
                        liveStatus = "Live unavailable; explicit access refresh required."
                        if let error = error as? CommunityFailure, [401, 403, 404, 409].contains(error.status) { clear(); revoked = true }
                        liveFailure = error.localizedDescription
                        return
                    }
                }
            } else {
                liveStatus = "Periodic refresh (live hints unavailable)"
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    if !session.busy && !revoked { load(older: false) }
                }
            }
        }
        .onChange(of: text) { _, _ in scheduleTyping() }
        .onChange(of: community.config?.chatHistoryValidationEnabled) { _, _ in
            clear(preservingDraft: true); session.clear()
            if phase == .active, community.config?.messagingEnabled == true {
                session.bind(community); restoreDraft(); load(older: false)
            }
        }
        .task(id: "reference:\(phase):\(community.accountRevision):\(community.config?.chatReferencesEnabled == true):\(community.avatarPolicyChanging)") {
            guard phase == .active, community.config?.chatReferencesEnabled == true, !community.avatarPolicyChanging else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if !session.busy && !revoked { load(older: false, reconcile: true) }
            }
        }
        .onChange(of: community.avatarPolicyChanging) { _, changing in
            if changing { stopTyping(); clear(); session.clear() }
            else if phase == .active { session.bind(community); load(older: false) }
        }
        .onChange(of: community.avatarPolicyRevision) { _, _ in
            stopTyping(); clear(); session.clear()
            if phase == .active, !community.avatarPolicyChanging { session.bind(community); load(older: false) }
        }
        .onChange(of: shareTyping) { _, _ in scheduleTyping() }
        .onChange(of: phase) { _, state in
            if state != .active { stopTyping(); clear(preservingDraft: true); session.clear() }
            else if !session.busy && !revoked { load(older: false, reconcile: true) }
        }
        .onChange(of: community.accountRevision) { _, _ in stopTyping(); clear(); session.clear(); dismiss() }
        .onChange(of: community.chatAccessRevision) { _, _ in stopTyping(); clear(); session.clear(); dismiss() }
        .onChange(of: community.config?.groupChatsEnabled) { _, _ in stopTyping(); clear(); session.clear(); if phase == .active { session.bind(community); load(older: false) } }
        .onChange(of: community.config?.eventChatsEnabled) { _, _ in stopTyping(); clear(); session.clear(); if phase == .active { session.bind(community); load(older: false) } }
        .onChange(of: session.denied) { _, denied in if denied { clear(); revoked = true } }
        .onDisappear { stopTyping(); clear(preservingDraft: true); session.clear() }
    }
    var body: some View {
        conversationLifecycle
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .gif]) { result in
            session.run(expected: importScope, { client in
                let bytes = try PhoneDisplayFileReader.read(result.get())
                let draft = try await client.uploadChatMedia(bytes, context: context)
                try session.checked(client); attachment = draft
            })
        }
        .sheet(isPresented: $roomInfo) { if let room, let client = session.client { NativeRoomInfoView(initial: room, client: client) } }
        .sheet(isPresented: $choosingPin) { ChatFixedPinPicker { pin = $0; choosingPin = false } }
        .sheet(isPresented: $choosingReference) {
            if let client = session.client { ChatReferencePicker(client: client, context: context) { reference = $0; choosingReference = false } }
        }
        .sheet(item: $reporting) { message in MessageIncidentComposeView(message: message, context: context) }
        .sheet(isPresented: $privacyDetails) {
            NavigationStack {
                List {
                    Text("Server-encrypted, not end-to-end encrypted.")
                    Text("Saved on the server does not mean delivered or read by the recipient.")
                    Text("Only authorized retained history is available for 30 days. Deleted messages, lost keys and private libraries cannot be restored.")
                    Text("Room history follows its invitation choice. Screenshots and downloaded copies cannot be recalled.")
                    FeatureDetails("Retry records") {
                        Text("Minimal sender/client-ID receipts last at most 60 days. They are not recipient read receipts.")
                    }
                }.modernScene().navigationTitle("Privacy & history")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { privacyDetails = false } } }
                    .safeAreaInset(edge: .bottom) {
                        Button("Done") { privacyDetails = false }
                            .frame(maxWidth: .infinity).padding().background(.bar)
                    }
            }
        }
        .confirmationDialog("Delete your sent message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let message = deleting {
                Button("Delete for both accounts", role: .destructive) {
                    session.run(expected: deleteScope, { try await $0.deleteChatMessage(message, context: context) },
                        success: { messages.removeAll { $0.id == message.id }; deleting = nil })
                }
            }
        } message: { Text("This removes server message/media access, not screenshots or downloaded copies.") }
    }
    private func composer(_ client: CommunityFeatureClient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let attachment {
                PrivateChatImage(item: attachment.attachment, client: client).frame(height: 150)
                Text("Private unsent attachment; not shared until Send.").font(.caption)
                Button("Discard unsent attachment", role: .destructive) {
                    session.run({ try await $0.discardChatAttachment(attachment.attachment.id) }, success: { self.attachment = nil })
                }.disabled(session.busy || intent != nil)
            }
            if let pin { Text("Fixed place: \(pin.label)").font(.caption); Button("Remove unsent place") { self.pin = nil }.disabled(intent != nil) }
            if let reference {
                Label(reference.kind == "event" ? "Current event reference attached" : reference.kind == "playlist" ? "Published snapshot reference attached" : "Community GIF reference attached", systemImage: "link")
                if reference.inviteRecipient == true {
                    Text("Send will also invite the actual direct recipient and may renew a withdrawn invitation. It will not RSVP.").font(.caption).foregroundStyle(.orange)
                }
                Button("Remove unsent reference") { self.reference = nil }.disabled(intent != nil)
            }
            if case .direct(_, let event) = context, event != nil {
                if !newQuestionsAllowed { Text("New visitor questions are disabled or unverified. Retained history, exact existing retries and organizer replies remain separate.").font(.caption) }
                if canManageOwnContact {
                    Button("Load my organizer question settings") {
                        session.run { client in
                            guard let event else { throw BackpackError.invalid("Missing event context.") }
                            let value = try await client.organizerContact(event)
                            try session.checked(client); contactPreference = value
                        }
                    }.disabled(session.busy)
                }
                if let contactPreference {
                    Button(contactPreference.enabled ? "Stop new visitor questions to me" : "Enable new visitor questions to me") {
                        session.run { client in
                            guard case .direct(_, let eventID) = context, let eventID else { throw BackpackError.invalid("Missing event context.") }
                            let value = try await client.saveOrganizerContact(eventID, original: contactPreference, enabled: !contactPreference.enabled)
                            try session.checked(client); self.contactPreference = value
                        }
                    }.disabled(session.busy)
                }
            }
            if room?.canSend == false { Text("Read-only chat").font(.caption).foregroundStyle(.secondary) }
            if let outbox {
                Text(outbox.state == .uncertain ? "Send outcome unknown" : outbox.state == .acknowledged ? "Saved on server" : "Send stopped").font(.headline)
                if outbox.state == .uncertain {
                    Button("Retry same message") { retryOutbox(outbox) }.disabled(session.busy)
                    Button("Clear pending message", role: .destructive) {
                        var abandoned = outbox; abandoned.state = .abandoned; abandoned.acknowledgedMessageID = nil
                        do { try NativeChatOutbox.save(abandoned); dismissAcknowledgedOutbox(abandoned) }
                        catch { outboxFailure = error.localizedDescription }
                    }.disabled(session.busy)
                } else {
                    Button("Clear send record") { dismissAcknowledgedOutbox(outbox) }.disabled(session.busy)
                }
                Text("Clearing this record does not recall a message.").font(.caption)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    if client.chatMediaEnabled { Button("Image or GIF") { importScope = client.instanceID; importing = true }.disabled(intent != nil || outbox != nil || attachment != nil) }
                    if client.chatPinsEnabled { Button("Fixed place") { choosingPin = true }.disabled(intent != nil || outbox != nil) }
                    if client.chatReferencesEnabled { Button("GIF, event or playlist") { choosingReference = true }.disabled(intent != nil || outbox != nil) }
                    if client.chatLiveEnabled { Toggle("Share typing indicator", isOn: $shareTyping) }
                } label: { Image(systemName: "plus").font(.title3).frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Add to message").disabled(session.busy || room?.canSend == false)
                TextField("Message", text: $text, axis: .vertical).lineLimit(1...6)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Aurora.lavender.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
                    .disabled(intent != nil || outbox != nil || room?.canSend == false)
                    .accessibilityIdentifier("chat-message-input")
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.headline.bold()).frame(width: 44, height: 44)
                        .foregroundStyle(Aurora.onAction).background(Aurora.mint, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Send message").accessibilityIdentifier("chat-send-message")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.busy || outbox != nil || !newQuestionsAllowed ||
                        text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 4000 ||
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil && pin == nil && reference == nil)
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 4000 {
                Text("Shorten your message to 4,000 UTF-16 units.").font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Send details") {
                Button("Check saved send state", action: restoreOutbox).disabled(session.busy)
                if let outbox {
                    Text("State: \(outbox.state.rawValue). Retry before \(outbox.retryBefore.formatted()).").font(.caption)
                }
                Text("Retries keep the exact message ID and content. Server acceptance is not recipient delivery.")
                    .font(.caption)
            }
            if session.busy { ProgressView() }
        }.padding(12).background(AuroraSurface(radius: 22))
    }
    private func send() {
        let capturedText = text, capturedAttachment = attachment?.attachment.id
        let capturedPin = pin, capturedReference = reference
        session.run({ client in
            guard !referencePolicyStale else { throw BackpackError.invalid("Media policy changed. Discard the captured failed intent and reselect current references explicitly.") }
            guard newQuestionsAllowed else { throw BackpackError.invalid("Current new-message permission is unavailable.") }
            guard try NativeChatOutbox.load(origin: client.origin.url.absoluteString, account: client.accountID, context: context) == nil else {
                throw BackpackError.invalid("Inspect and reconcile the existing private outbox before creating another intent.")
            }
            if intent == nil { intent = try ChatSendIntent(context: context, text: capturedText, attachmentID: capturedAttachment, pin: capturedPin, reference: capturedReference) }
            guard let intent else { throw BackpackError.invalid("Prepare a valid send intent.") }
            let record = try NativeChatOutboxRecord(account: client.accountID, origin: client.origin.url.absoluteString,
                context: context, clientID: intent.clientMessageID, bytes: intent.data, consent: true)
            try NativeChatOutbox.save(record); outbox = record
            do {
                let result = try await client.submitOutbox(record)
                try session.checked(client); outbox = result
                try NativeChatOutbox.archiveTerminal(result); outbox = nil
            } catch {
                try session.checked(client); messages = []; referencesVerified = false; newQuestionsAllowed = false
                restoreOutbox(); throw error
            }
        }, success: { discardStoredDraft(); intent = nil; text = ""; attachment = nil; pin = nil; reference = nil; referencePolicyStale = false; stopTyping(); load(older: false) })
    }
    private func restoreOutbox() {
        guard let client = session.client else { return }
        do {
            try client.check(.messaging)
            outbox = try NativeChatOutbox.load(origin: client.origin.url.absoluteString, account: client.accountID, context: context)
            if let outbox, outbox.state == .acknowledged, intent == nil {
                try NativeChatOutbox.archiveTerminal(outbox)
                self.outbox = nil
            }
            outboxFailure = nil
        } catch { outboxFailure = error.localizedDescription }
    }
    private func retryOutbox(_ record: NativeChatOutboxRecord) {
        messages = []; referencesVerified = false
        session.run { client in
            do {
                let result = try await client.submitOutbox(record)
                try session.checked(client); outbox = result; intent = nil; text = ""; reference = nil; pin = nil; attachment = nil
                try NativeChatOutbox.archiveTerminal(result); outbox = nil
            } catch {
                try session.checked(client); restoreOutbox(); throw error
            }
        } success: { load(older: false) }
    }
    private func dismissAcknowledgedOutbox(_ record: NativeChatOutboxRecord) {
        do {
            try NativeChatOutbox.archiveTerminal(record)
            outbox = nil; intent = nil; text = ""; reference = nil; pin = nil; attachment = nil
        } catch { outboxFailure = error.localizedDescription }
    }
    private func load(older: Bool, reconcile: Bool = false) {
        session.run { client in
            do {
                let rows: [NativeChatMessage]
                switch context {
                case .direct(let peer, let event):
                    let permission = try await client.organizerChatPermission(peer: peer, eventID: event)
                    let result = try await client.directHistory(peer: peer, event: event, before: older ? directCursor : nil)
                    try session.checked(client)
                    newQuestionsAllowed = permission.newMessagesAllowed; canManageOwnContact = permission.canManageOwnContact
                    if !canManageOwnContact { contactPreference = nil }
                    if reconcile, result.unchanged == true, !messages.isEmpty {
                        messages.removeAll { !NativeChatRetention.retained(createdAtMilliseconds: $0.createdAt, now: Date()) }
                        referencesVerified = true; restoreOutbox()
                        return
                    }
                    rows = result.messages
                    let currentToken = client.chatHistoryValidationEnabled ? result.historyScopeToken ?? result.viewToken : result.viewToken
                    let tokenChanged = currentToken != nil && currentToken != viewToken
                    if !reconcile || tokenChanged { directCursor = result.nextBefore; more = result.hasMore }
                    if let token = currentToken { if tokenChanged { messages = [] }; viewToken = token }
                    if !older && !reconcile { messages = [] }
                case .room(let id):
                    let result = try await client.roomHistory(id, before: older ? roomCursor : nil)
                    try session.checked(client)
                    if reconcile, result.unchanged == true, !messages.isEmpty {
                        messages.removeAll { !NativeChatRetention.retained(createdAtMilliseconds: $0.createdAt, now: Date()) }
                        referencesVerified = true; restoreOutbox()
                        return
                    }
                    let tokenChanged = viewToken != result.viewToken
                    if tokenChanged { messages = [] }
                    if !older && !reconcile { messages = [] }
                    viewToken = result.viewToken; room = result.chat
                    newQuestionsAllowed = result.chat.canSend
                    if !reconcile || tokenChanged { roomCursor = result.nextBefore; more = result.hasMore }
                    rows = result.messages
                    if !older, phase == .active, let visible = rows.compactMap(\.sequence).max(), visible > result.readSequence {
                        try await client.markRoomRead(id, sequence: visible)
                    }
                }
                try session.checked(client)
                if reconcile {
                    if case .direct = context {
                        messages.removeAll { !NativeChatRetention.retained(createdAtMilliseconds: $0.createdAt, now: Date()) }
                    }
                    if let oldest = rows.map(\.createdAt).min() {
                        let authorized = Set(rows.map(\.id))
                        messages.removeAll { $0.createdAt >= oldest && !authorized.contains($0.id) }
                    } else { messages = [] }
                    for row in rows { if let index = messages.firstIndex(where: { $0.id == row.id }) { messages[index] = row } }
                }
                var ids = Set(messages.map(\.id))
                messages += rows.filter { ids.insert($0.id).inserted }
                messages.sort { ($0.sequence.map(Double.init) ?? $0.createdAt) < ($1.sequence.map(Double.init) ?? $1.createdAt) }
                referencesVerified = true
                restoreOutbox()
            } catch let error as CommunityFailure where [401, 403, 404, 409].contains(error.status) {
                clear(); revoked = true
                throw error
            } catch {
                messages = []; referencesVerified = false; newQuestionsAllowed = false
                throw error
            }
        }
    }
    private func refreshTyping(_ client: CommunityFeatureClient) async throws {
        let page = try await client.typing(context)
        try session.checked(client); typingExpiryTask?.cancel()
        typing = page.typing.filter { $0.expiresInMs > 0 }
        let clock = ContinuousClock()
        let deadlines = typing.map { (id: $0.id, expiry: clock.now.advanced(by: .milliseconds(min(6000, $0.expiresInMs)))) }
        typingExpiryTask = Task {
            do {
                for item in deadlines.sorted(by: { $0.expiry < $1.expiry }) {
                    try await clock.sleep(until: item.expiry)
                    try session.checked(client)
                    typing.removeAll { $0.id == item.id }
                }
            } catch {
                if !Task.isCancelled { typing = []; liveFailure = "Typing unavailable: \(error.localizedDescription)" }
            }
        }
    }
    private func scheduleTyping() {
        typingTask?.cancel()
        guard phase == .active, !revoked, !session.denied, let client = session.client, client.chatLiveEnabled else { return }
        let active = shareTyping && !text.isEmpty && newQuestionsAllowed && room?.canSend != false
        guard active || typingWasShared else { return }
        typingTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(500)); try session.checked(client)
                try await client.setTyping(context, clientID: typingClient, active: active)
                try session.checked(client); typingWasShared = active
            }
            catch { if !Task.isCancelled { liveFailure = "Typing update failed: \(error.localizedDescription)" } }
        }
    }
    private func stopTyping() {
        typingTask?.cancel(); typingExpiryTask?.cancel(); typing = []; typingWasShared = false
        // The server's bounded typing TTL expires it; background/access loss never starts another request.
    }
    private func restoreDraft() {
        guard let client = session.client else { return }
        let scope = NativeChatDraftScope(origin: client.origin.url.absoluteString, account: client.accountID,
            accountRevision: community.accountRevision, accessRevision: community.chatAccessRevision)
        draftScope = scope
        if let saved = NativeChatDraftStore.shared.restore(scope: scope, context: context) {
            text = saved.text; attachment = saved.attachment; pin = saved.pin; reference = saved.reference
        }
    }
    private func discardStoredDraft() {
        if let draftScope { NativeChatDraftStore.shared.remove(scope: draftScope, context: context) }
    }
    private func clear(preservingDraft: Bool = false) {
        if preservingDraft, let draftScope, !revoked, !session.denied,
           community.config?.messagingEnabled == true, community.user?.id == draftScope.account,
           community.origin?.url.absoluteString == draftScope.origin,
           community.accountRevision == draftScope.accountRevision, community.chatAccessRevision == draftScope.accessRevision,
           intent == nil, outbox == nil {
            let saved = NativeChatDraft(text: text, attachment: attachment, pin: pin, reference: reference)
            if !NativeChatDraftStore.shared.save(saved, scope: draftScope, context: context) {
                Logger(subsystem: "com.errantactions.ledbackpack", category: "Messages").debug("Ignoring a draft from an expired session scope.")
            }
        } else { discardStoredDraft() }
        messages = []; room = nil; text = ""; intent = nil; outbox = nil; outboxFailure = nil; newQuestionsAllowed = false
        contactPreference = nil; canManageOwnContact = false; attachment = nil; pin = nil; reference = nil; referencePolicyStale = false
        referencesVerified = false; choosingReference = false; choosingPin = false; importing = false; deleting = nil; reporting = nil
        roomInfo = false; privacyDetails = false; draftScope = nil; stopTyping(); viewToken = nil; revoked = false; directCursor = nil; roomCursor = nil; more = false
    }
}

@MainActor
private struct NativeChatAvatar: View {
    let title: String
    var group = false
    var body: some View {
        Text(title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.subheadline.bold()).foregroundStyle(Aurora.onAction)
            .frame(width: 48, height: 48)
            .background(Aurora.spectrum, in: RoundedRectangle(cornerRadius: group ? 16 : 24))
            .accessibilityHidden(true)
    }
}

@MainActor
private struct PrivateChatImage: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.accessibilityReduceMotion) private var reduced
    let item: PrivateChatAttachment
    let client: CommunityFeatureClient
    @State private var manual = false
    var body: some View {
        let animate = community.user?.mediaPreferences?.permitsAnimation(reducedMotion: reduced, manual: manual) ?? (!reduced || manual)
        VStack {
            GIFThumbnail(key: "private-chat:\(client.instanceID):\(item.id):\(animate):\(community.avatarPolicyRevision)", cache: false) {
                try await client.privateChatMedia(item, animated: item.animated && animate)
            }.clipShape(RoundedRectangle(cornerRadius: 16))
            if item.animated && (reduced || community.user?.mediaPreferences?.animationsEnabled == false || community.user?.mediaPreferences?.dataSaving == true) {
                Button(manual ? "Pause GIF" : "Play GIF") { manual.toggle() }.font(.caption)
            }
        }.onChange(of: community.user?.mediaPreferences) { _, _ in manual = false }
            .onChange(of: community.accountRevision) { _, _ in manual = false }
    }
}

@MainActor
private struct NativeChatBubble: View {
    let message: NativeChatMessage
    let mine: Bool
    let client: CommunityFeatureClient?
    let referenceEpoch: String
    let referencesVerified: Bool
    var showSender = false
    let incident: (() -> Void)?
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var entered = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 32) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
            if showSender, !mine { Text(message.senderName ?? "Contact").font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 8) {
            if !message.text.isEmpty {
                Text(message.text).textSelection(.enabled).foregroundStyle(mine ? Aurora.onAction : Aurora.ink)
            }
            if let attachment = message.attachment, let client { PrivateChatImage(item: attachment, client: client).frame(height: 200) }
            if let pin = message.pin { ChatFixedPinCard(pin: pin).padding(8).glassPanel(radius: 14) }
            if let reference = message.reference, let client {
                if referencesVerified {
                    ChatReferenceCardView(card: reference, client: client, reconciliationEpoch: referenceEpoch)
                        .padding(8).glassPanel(radius: 14).id("\(reference.fingerprint):\(referenceEpoch)")
                } else { Label("Shared content unavailable until access is reverified", systemImage: "rectangle.slash").foregroundStyle(.secondary) }
            }
            }.padding(14)
                .background(mine ? Aurora.mint.opacity(0.96) : Aurora.lavender.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(Date(timeIntervalSince1970: message.createdAt / 1000), format: .dateTime.hour().minute())
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if !mine { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .opacity(entered || reducedMotion ? 1 : 0)
        .offset(y: entered || reducedMotion ? 0 : 6)
        .onAppear { withAnimation(reducedMotion ? nil : .easeOut(duration: 0.22)) { entered = true } }
        .contextMenu {
            if mine { Button("Delete your message", systemImage: "trash", role: .destructive, action: delete) }
            if !mine, let incident { Button("Report message", systemImage: "flag", action: incident) }
        }
        .accessibilityAction(named: Text("Delete your message")) { if mine { delete() } }
        .accessibilityAction(named: Text("Report message")) { if !mine { incident?() } }
    }
}
