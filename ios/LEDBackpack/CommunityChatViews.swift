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
    @State private var page = 1
    @State private var hasMore = false
    @State private var selection: ChatScreenSelection?
    @State private var creating = false
    @State private var pendingInvite: NativeChatInvitation?
    @State private var inviteScope: UUID?
    private var newConversationContacts: [SocialPerson] {
        let existing = Set(recent.filter { $0.eventId == nil }.map { $0.profile.id })
        return friends.filter { !existing.contains($0.id) }
    }
    var body: some View {
        List {
            if community.config?.messagingEnabled == true && !session.denied {
                if session.busy { ProgressView() }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if community.config?.chatMessageRequestsEnabled == true {
                    NavigationLink("Non-friend message requests / stop") { CommunityMessageRequestsView() }
                }
                if community.config?.deviceRecoveryEnabled == true {
                    NavigationLink("Found-device messages") { DeviceRecoveryInboxView() }
                }
                Section("Recent conversations") {
                    ForEach(recent) { contact in
                        Button {
                            selection = ChatScreenSelection(context: .direct(peer: contact.profile.id, event: contact.eventId),
                                title: contact.eventId == nil ? contact.profile.displayName : "Private organizer question")
                        } label: {
                            HStack {
                                Text(contact.profile.displayName)
                                Spacer()
                                if contact.eventId != nil { Text("Private event question").font(.caption) }
                            }
                        }
                        if !newConversationContacts.isEmpty {
                            Section("Start a conversation") {
                                ForEach(newConversationContacts) { person in
                                    Button(person.displayName) { selection = ChatScreenSelection(context: .direct(peer: person.id, event: nil), title: person.displayName) }
                                }
                            }
                        }
                    }
                }
                Section("Groups & event-wide chats") {
                    ForEach(rooms) { room in
                        Button { selection = ChatScreenSelection(context: .room(room.id), title: room.title) } label: {
                            HStack { Text(room.title); Spacer(); Text(room.kind == "event" ? "Event-wide" : "Group").font(.caption)
                                if room.unread > 0 { Text("\(room.unread)").font(.caption.bold()).foregroundStyle(Aurora.mint) } }
                        }
                    }
                    if community.config?.groupChatsEnabled == true { Button("Create group") { creating = true } }
                    FeatureDetails("Event chats") { Text("Join event-wide chats from an eligible event. Organizer questions stay private.") }
                }
                Section("Group invitations") {
                    ForEach(invitations) { invite in
                        VStack(alignment: .leading) {
                            Text(invite.title).font(.headline)
                            Text("From \(invite.inviter.displayName)").font(.caption)
                            Text(invite.shareHistory ? "The owner shares this room's retained earlier messages and attachments." :
                                "You start from acceptance; earlier room history is not shared.").font(.caption)
                            Button("Review invitation") { pendingInvite = invite; inviteScope = session.client?.instanceID }
                        }
                    }
                }
                if page > 1 || hasMore { HStack {
                    Button("Previous") { page -= 1; load() }.disabled(page <= 1 || session.busy)
                    Spacer()
                    Button("Next") { page += 1; load() }.disabled(!hasMore || session.busy)
                } }
                if !session.busy && session.failure == nil && friends.isEmpty && recent.isEmpty && rooms.isEmpty && invitations.isEmpty {
                    ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Connect with a friend to start chatting."))
                }
                Button("Refresh", action: load).disabled(session.busy)
            } else { Text(session.failure ?? "Messaging is unavailable until this server advertises configured support.") }
        }
        .modernScene().navigationTitle("Messages").buttonStyle(.borderless)
        .task(id: "\(community.accountRevision):\(community.chatAccessRevision):\(community.user?.role ?? ""):\(community.config?.messagingEnabled == true):\(community.config?.chatMessageRequestsEnabled == true):\(phase)") {
            clear(); selection = nil; page = 1; session.clear()
            guard phase == .active else { return }
            session.bind(community)
            if community.config?.messagingEnabled == true { load() }
        }
        .onChange(of: session.denied) { _, denied in if denied { clear() } }
        .onChange(of: community.accountRevision) { _, _ in clear(); selection = nil }
        .onChange(of: community.chatAccessRevision) { _, _ in clear(); selection = nil; session.clear() }
        .onDisappear { session.clear(); clear() }
        .navigationDestination(item: $selection) { item in CommunityConversationView(context: item.context, title: item.title) }
        .sheet(isPresented: $creating, onDismiss: load) { NativeGroupCreateView() }
        .confirmationDialog("Respond to group invitation?", isPresented: Binding(get: { pendingInvite != nil },
            set: { if !$0 { pendingInvite = nil } })) {
                if let invite = pendingInvite {
                    Button("Accept displayed history choice") { respond(invite, accept: true) }
                    Button("Decline", role: .destructive) { respond(invite, accept: false) }
                }
            } message: { Text("Acceptance uses the invitation's displayed revision. You cannot override the owner's history choice.") }
    }
    private func respond(_ invite: NativeChatInvitation, accept: Bool) {
        session.run(expected: inviteScope, { try await $0.respondChatInvite(invite, accept: accept) },
            success: { pendingInvite = nil; load() })
    }
    private func load() {
        let requested = page
        session.run { client in
            let contacts = try await client.recentChats(page: requested)
            let peers = community.config?.socialEnabled == true ? try await client.friends(page: requested).friends : []
            let chats = client.groupsEnabled || client.eventChatsEnabled ? try await client.rooms(page: requested) : nil
            let invites = client.groupsEnabled ? try await client.chatInvitations(page: requested) : nil
            try session.checked(client)
            recent = contacts.conversations; friends = peers; rooms = chats?.chats ?? []; invitations = invites?.invitations ?? []
            hasMore = contacts.conversations.count == 24 || peers.count == 50 || chats?.hasMore == true || invites?.hasMore == true
        }
    }
    private func clear() { friends = []; recent = []; rooms = []; invitations = []; pendingInvite = nil }
}

@MainActor
struct CommunityConversationView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let context: ChatConversation
    let title: String
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
    @State private var typingClient = UUID()
    @State private var roomInfo = false
    @State private var choosingPin = false
    @State private var choosingReference = false
    @State private var reporting: NativeChatMessage?
    @State private var reference: ChatReferenceSelection?
    @State private var referencePolicyStale = false
    @State private var referencesVerified = false
    private var conversationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if revoked || session.denied || community.config?.messagingEnabled != true {
                    Text(session.failure ?? "Conversation access is unavailable. Recheck access; private media never falls back to public URLs.")
                } else {
                    Text(liveStatus).font(.caption).foregroundStyle(.secondary)
                    if let outboxFailure { Text(outboxFailure).foregroundStyle(.orange) }
                    if let liveFailure { Text(liveFailure).font(.caption).foregroundStyle(.orange) }
                    if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                    if more { Button("Load older messages") { load(older: true) }.disabled(session.busy) }
                    ForEach(community.avatarPolicyChanging ? [] : messages) { message in
                        NativeChatBubble(message: message, mine: message.senderId == community.user?.id, client: session.client,
                            referenceEpoch: viewToken ?? "", referencesVerified: referencesVerified,
                            incident: session.client?.chatReportsEnabled == true && message.senderId != community.user?.id ? { reporting = message } : nil) {
                            deleting = message; deleteScope = session.client?.instanceID
                        }
                    }
                    if !typing.isEmpty { Text("\(typing.map(\.displayName).joined(separator: ", ")) typing...").font(.caption) }
                    if let client = session.client {
                        if client.chatNotificationPreferencesEnabled {
                            NavigationLink("Alerts for this conversation") { ConversationNotificationView(context: context) }
                        }
                    }
                    if let room { Button("Room information / members") { roomInfo = true }.disabled(session.busy || room.archived) }
                    Button("Refresh conversation") { revoked = false; liveFailure = nil; liveRevision = UUID(); load(older: false) }.disabled(session.busy)
                    DisclosureGroup("Privacy & history") {
                        Text("Messages use server-managed encryption, not E2EE. Direct/organizer recovery reloads only authorized history less than 30 days old with the same server messaging key. Deleted/expired messages, lost keys and private libraries cannot be restored. Minimal sender/client-ID receipts last at most 60 days, not forever. Room history follows its invitation choice. Screenshots cannot be recalled.")
                            .font(.caption)
                    }
                }
            }.padding(20)
        }.defaultScrollAnchor(.bottom)
    }
    private var conversationLifecycle: some View {
        conversationContent
        .modernScene().navigationTitle(revoked || session.denied ? "Messages" : room?.title ?? title)
        .safeAreaInset(edge: .bottom) {
            if !revoked, !session.denied, community.config?.messagingEnabled == true, let client = session.client {
                composer(client)
            }
        }
        .task(id: "\(community.accountRevision):\(community.chatAccessRevision):\(community.user?.role ?? ""):\(phase):\(community.config?.messagingEnabled == true):\(community.config?.chatMessageRequestsEnabled == true):\(community.config?.chatPlaylistReferencesEnabled == true):\(community.config?.chatReferencesEnabled == true):\(community.config?.chatMediaEnabled == true):\(community.config?.chatPinsEnabled == true):\(community.config?.directMessageRetentionDays.map(String.init) ?? "missing"):\(community.config?.directMessageRecovery ?? "missing")") {
            clear(); session.clear()
            guard phase == .active, community.config?.messagingEnabled == true else { return }
            session.bind(community); load(older: false)
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
            if state != .active { stopTyping(); session.clear(); clear() }
            else if !session.busy && !revoked { load(older: false, reconcile: true) }
        }
        .onChange(of: community.accountRevision) { _, _ in stopTyping(); clear(); session.clear(); dismiss() }
        .onChange(of: community.chatAccessRevision) { _, _ in stopTyping(); clear(); session.clear(); dismiss() }
        .onChange(of: community.config?.groupChatsEnabled) { _, _ in stopTyping(); clear(); session.clear(); if phase == .active { session.bind(community); load(older: false) } }
        .onChange(of: community.config?.eventChatsEnabled) { _, _ in stopTyping(); clear(); session.clear(); if phase == .active { session.bind(community); load(older: false) } }
        .onChange(of: session.denied) { _, denied in if denied { clear(); revoked = true } }
        .onDisappear { stopTyping(); session.clear(); clear() }
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
            if let outbox {
                Text(outbox.state == .uncertain ? "Delivery uncertain" : outbox.state == .acknowledged ? "Delivered" : "Delivery stopped").font(.headline)
                if outbox.state == .uncertain {
                    Button("Retry same message") { retryOutbox(outbox) }.disabled(session.busy)
                    Button("Clear pending message", role: .destructive) {
                        var abandoned = outbox; abandoned.state = .abandoned; abandoned.acknowledgedMessageID = nil
                        do { try NativeChatOutbox.save(abandoned); dismissAcknowledgedOutbox(abandoned) }
                        catch { outboxFailure = error.localizedDescription }
                    }.disabled(session.busy)
                } else {
                    Button("Clear delivery record") { dismissAcknowledgedOutbox(outbox) }.disabled(session.busy)
                }
                Text("Clearing local delivery state does not recall a message already received.").font(.caption)
            }
            TextField("Message", text: $text, axis: .vertical).lineLimit(1...6).disabled(intent != nil || outbox != nil)
            HStack {
                Menu {
                    if client.chatMediaEnabled { Button("Image or GIF") { importScope = client.instanceID; importing = true }.disabled(intent != nil || attachment != nil) }
                    if client.chatPinsEnabled { Button("Fixed place") { choosingPin = true }.disabled(intent != nil) }
                    if client.chatReferencesEnabled { Button("GIF, event or playlist") { choosingReference = true }.disabled(intent != nil || outbox != nil) }
                    if client.chatLiveEnabled { Toggle("Share typing indicator", isOn: $shareTyping) }
                } label: { Label("Add", systemImage: "plus.circle").frame(minWidth: 44, minHeight: 44) }
                .disabled(session.busy)
                Spacer()
                Button("Send") { send() }.buttonStyle(.borderedProminent)
                    .disabled(session.busy || outbox != nil || !newQuestionsAllowed ||
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil && pin == nil && reference == nil)
            }
            DisclosureGroup("Delivery details") {
                Button("Check saved delivery state", action: restoreOutbox).disabled(session.busy)
                if let outbox {
                    Text("State: \(outbox.state.rawValue). Retry before \(outbox.retryBefore.formatted()).").font(.caption)
                }
                Text("Retries keep the original ID and exact content. Similar text in history is not a delivery receipt.")
                    .font(.caption)
            }
            if session.busy { ProgressView() }
        }.padding(16).glassPanel().disabled(room?.canSend == false)
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
        }, success: { intent = nil; text = ""; attachment = nil; pin = nil; reference = nil; referencePolicyStale = false; stopTyping(); load(older: false) })
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
                    rows = result.messages
                    let tokenChanged = result.viewToken != nil && result.viewToken != viewToken
                    if !reconcile || tokenChanged { directCursor = result.nextBefore; more = result.hasMore }
                    if let token = result.viewToken { if tokenChanged { messages = [] }; viewToken = token }
                    if !older && !reconcile { messages = [] }
                case .room(let id):
                    let result = try await client.roomHistory(id, before: older ? roomCursor : nil)
                    try session.checked(client)
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
        try session.checked(client); typing = page.typing.filter { $0.expiresInMs > 0 }
    }
    private func scheduleTyping() {
        typingTask?.cancel()
        guard phase == .active, let client = session.client, client.chatLiveEnabled else { return }
        let active = shareTyping && !text.isEmpty
        typingTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)); try await client.setTyping(context, clientID: typingClient, active: active) }
            catch { if !Task.isCancelled { liveFailure = "Typing update failed: \(error.localizedDescription)" } }
        }
    }
    private func stopTyping() {
        typingTask?.cancel(); typing = []
        // The server's bounded typing TTL expires it; background/access loss never starts another request.
    }
    private func clear() { messages = []; room = nil; text = ""; intent = nil; outbox = nil; outboxFailure = nil; newQuestionsAllowed = false; contactPreference = nil; canManageOwnContact = false; attachment = nil; pin = nil; reference = nil; referencePolicyStale = false; referencesVerified = false; choosingReference = false; choosingPin = false; importing = false; deleting = nil; reporting = nil; typing = []; viewToken = nil; revoked = false; directCursor = nil; roomCursor = nil; more = false }
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
    let incident: (() -> Void)?
    let delete: () -> Void
    @State private var hover = false
    @State private var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mine ? "You" : message.senderName ?? "Contact").font(.caption).foregroundStyle(.secondary)
            if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
            if let attachment = message.attachment, let client { PrivateChatImage(item: attachment, client: client).frame(height: 200) }
            if let pin = message.pin { ChatFixedPinCard(pin: pin) }
            if let reference = message.reference, let client {
                if referencesVerified {
                    ChatReferenceCardView(card: reference, client: client, reconciliationEpoch: referenceEpoch).id("\(reference.fingerprint):\(referenceEpoch)")
                } else { Label("Shared content unavailable until access is reverified", systemImage: "rectangle.slash").foregroundStyle(.secondary) }
            }
            if !mine, let incident { Button("Explain an incident", action: incident).font(.caption) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading).glassPanel(radius: 22)
        .overlay(alignment: .topTrailing) {
            if mine && (hover || selected) { Button(action: delete) { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("Delete your message") }
        }
        .onHover { hover = $0 }.onTapGesture { selected.toggle() }
        .accessibilityAction(named: Text("Delete your message")) { if mine { delete() } }
    }
}
