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
    var body: some View {
        List {
            if community.config?.messagingEnabled == true && !session.denied {
                if session.busy { ProgressView() }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                Section("Friends") {
                    ForEach(friends) { person in
                        Button(person.displayName) { selection = ChatScreenSelection(context: .direct(peer: person.id, event: nil), title: person.displayName) }
                    }
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
                    Text("Event-wide rooms are separate from private organizer questions. Open an eligible event to explicitly join its room.")
                        .font(.caption).foregroundStyle(.secondary)
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
                HStack {
                    Button("Previous") { page -= 1; load() }.disabled(page <= 1 || session.busy)
                    Spacer()
                    Button("Next") { page += 1; load() }.disabled(!hasMore || session.busy)
                }
                Button("Refresh", action: load).disabled(session.busy)
            } else { Text(session.failure ?? "Messaging is unavailable until this server advertises configured support.") }
        }
        .modernScene().navigationTitle("Messages")
        .task(id: "\(community.accountRevision):\(community.config?.messagingEnabled == true)") {
            clear(); page = 1; session.bind(community)
            if community.config?.messagingEnabled == true { load() }
        }
        .onChange(of: session.denied) { _, denied in if denied { clear() } }
        .onChange(of: community.accountRevision) { _, _ in clear(); selection = nil }
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
    @State private var reference: ChatReferenceSelection?
    @State private var referencePolicyStale = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if revoked || session.denied || community.config?.messagingEnabled != true {
                    Text(session.failure ?? "Conversation access is unavailable. Recheck access; private media never falls back to public URLs.")
                } else {
                    Text(liveStatus).font(.caption).foregroundStyle(.secondary)
                    if let liveFailure { Text(liveFailure).font(.caption).foregroundStyle(.orange) }
                    if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                    if more { Button("Load older messages") { load(older: true) }.disabled(session.busy) }
                    ForEach(community.avatarPolicyChanging ? [] : messages) { message in
                        NativeChatBubble(message: message, mine: message.senderId == community.user?.id, client: session.client, referenceEpoch: viewToken ?? "") {
                            deleting = message; deleteScope = session.client?.instanceID
                        }
                    }
                    if !typing.isEmpty { Text("\(typing.map(\.displayName).joined(separator: ", ")) typing...").font(.caption) }
                    if let client = session.client {
                        composer(client)
                    }
                    if let room { Button("Room information / members") { roomInfo = true }.disabled(session.busy || room.archived) }
                    Button("Recheck conversation access") { revoked = false; liveFailure = nil; liveRevision = UUID(); load(older: false) }.disabled(session.busy)
                    DisclosureGroup("Privacy & history") {
                        Text("Messages are stored with server-managed encryption, not end-to-end encryption. Room history follows the owner's invitation choice. Event-wide rooms never include private organizer questions. Deletion cannot recall recipients' screenshots or saved copies.")
                            .font(.caption)
                    }
                }
            }.padding(20)
        }
        .modernScene().navigationTitle(revoked || session.denied ? "Messages" : room?.title ?? title)
        .task(id: community.accountRevision) {
            clear(); session.bind(community); load(older: false)
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
            if changing { messages = []; choosingReference = false; reference = nil; referencePolicyStale = intent?.reference != nil }
            else if !session.busy { load(older: false) }
        }
        .onChange(of: shareTyping) { _, _ in scheduleTyping() }
        .onChange(of: phase) { _, state in if state != .active { stopTyping() } }
        .onChange(of: community.accountRevision) { _, _ in stopTyping(); clear(); session.clear(); dismiss() }
        .onChange(of: session.denied) { _, denied in if denied { clear(); revoked = true } }
        .onDisappear { stopTyping(); session.clear(); clear() }
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
                Label(reference.kind == "event" ? "Current event reference attached" : "Community GIF reference attached", systemImage: "link")
                Button("Remove unsent reference") { self.reference = nil }.disabled(intent != nil)
            }
            TextField("Message", text: $text, axis: .vertical).lineLimit(1...6).disabled(intent != nil)
            HStack {
                if client.chatMediaEnabled { Button("Attach image / GIF") { importScope = client.instanceID; importing = true }.disabled(intent != nil || attachment != nil) }
                if client.chatPinsEnabled { Button("Fixed place") { choosingPin = true }.disabled(intent != nil) }
                if client.chatReferencesEnabled { Button("Share GIF / event") { choosingReference = true }.disabled(intent != nil) }
                Spacer()
                Button(intent == nil ? "Send" : "Retry exact send") { send() }.buttonStyle(.borderedProminent)
            }
            if intent != nil {
                Button("Discard failed send intent", role: .destructive) { intent = nil; referencePolicyStale = false }
                Text("A failed connection may have accepted the message. Retry retains the same ID/bytes; check history before starting a different intent.").font(.caption)
            }
            if client.chatLiveEnabled { Toggle("Share ephemeral typing indicator", isOn: $shareTyping) }
            if session.busy { ProgressView() }
        }.padding(16).glassPanel().disabled(session.busy || room?.canSend == false)
    }
    private func send() {
        session.run({ client in
            guard !referencePolicyStale else { throw BackpackError.invalid("Media policy changed. Discard the captured failed intent and reselect current references explicitly.") }
            if intent == nil { intent = try ChatSendIntent(context: context, text: text, attachmentID: attachment?.attachment.id, pin: pin, reference: reference) }
            guard let intent else { throw BackpackError.invalid("Prepare a valid send intent.") }
            _ = try await client.sendChat(intent)
        }, success: { intent = nil; text = ""; attachment = nil; pin = nil; reference = nil; referencePolicyStale = false; stopTyping(); load(older: false) })
    }
    private func load(older: Bool, reconcile: Bool = false) {
        session.run { client in
            do {
                let rows: [NativeChatMessage]
                switch context {
                case .direct(let peer, let event):
                    let result = try await client.directHistory(peer: peer, event: event, before: older ? directCursor : nil)
                    try session.checked(client)
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
                    if !reconcile || tokenChanged { roomCursor = result.nextBefore; more = result.hasMore }
                    rows = result.messages
                    if !older, phase == .active, let visible = rows.compactMap(\.sequence).max(), visible > result.readSequence {
                        try await client.markRoomRead(id, sequence: visible)
                    }
                }
                try session.checked(client)
                if reconcile {
                    for row in rows { if let index = messages.firstIndex(where: { $0.id == row.id }) { messages[index] = row } }
                }
                var ids = Set(messages.map(\.id))
                messages += rows.filter { ids.insert($0.id).inserted }
                messages.sort { ($0.sequence.map(Double.init) ?? $0.createdAt) < ($1.sequence.map(Double.init) ?? $1.createdAt) }
            } catch let error as CommunityFailure where [401, 403, 404].contains(error.status) {
                clear(); revoked = true
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
        guard shareTyping, let client = session.client, client.chatLiveEnabled else { return }
        Task {
            do { try await client.setTyping(context, clientID: typingClient, active: false) }
            catch { Logger(subsystem: "com.errantactions.ledbackpack", category: "chat-lifecycle").error("Typing cleanup failed; memory-only indicator expires after its bounded TTL.") }
        }
    }
    private func clear() { messages = []; room = nil; text = ""; intent = nil; attachment = nil; pin = nil; reference = nil; referencePolicyStale = false; choosingReference = false; typing = []; viewToken = nil; revoked = false }
}

@MainActor
private struct PrivateChatImage: View {
    @Environment(\.accessibilityReduceMotion) private var reduced
    let item: PrivateChatAttachment
    let client: CommunityFeatureClient
    @State private var manual = false
    var body: some View {
        VStack {
            GIFThumbnail(key: "private-chat:\(client.instanceID):\(item.id):\(manual):\(reduced)", cache: false) {
                try await client.privateChatMedia(item, animated: item.animated && (!reduced || manual))
            }.clipShape(RoundedRectangle(cornerRadius: 16))
            if reduced && item.animated { Button(manual ? "Pause GIF" : "Play GIF") { manual.toggle() }.font(.caption) }
        }
    }
}

@MainActor
private struct NativeChatBubble: View {
    let message: NativeChatMessage
    let mine: Bool
    let client: CommunityFeatureClient?
    let referenceEpoch: String
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
                ChatReferenceCardView(card: reference, client: client, reconciliationEpoch: referenceEpoch).id("\(reference.fingerprint):\(referenceEpoch)")
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading).glassPanel(radius: 22)
        .overlay(alignment: .topTrailing) {
            if mine && (hover || selected) { Button(action: delete) { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("Delete your message") }
        }
        .onHover { hover = $0 }.onTapGesture { selected.toggle() }
        .accessibilityAction(named: Text("Delete your message")) { if mine { delete() } }
    }
}
