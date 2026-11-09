import SwiftUI
import BackpackProtocol

@MainActor
struct DeviceRecoveryInboxView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = AccountServiceSession()
    @State private var conversations: [DeviceRecoveryConversation] = []
    @State private var retry = UUID()
    private var context: String {
        "\(community.accountRevision):\(community.config?.deviceRecoveryEnabled == true):\(community.config?.unverifiedDeviceTagsEnabled == true):\(community.config?.connectedDeviceRegistrationEnabled == true):\(community.config?.connectedDeviceRegistrationVersion ?? 0):\(phase):\(retry)"
    }

    var body: some View {
        List {
            Text("Private conversations about returning a found backpack. No friendship is required.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(conversations) { conversation in
                NavigationLink {
                    DeviceRecoveryThreadView(id: conversation.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.peer.displayName).font(.headline)
                        Text(conversation.state == .accepted ? "Recovery conversation" :
                            conversation.role == .owner ? "Someone found your device" : "Waiting for a reply")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if conversations.isEmpty, !session.busy, session.failure == nil {
                ContentUnavailableView("No found-device messages", systemImage: "backpack",
                    description: Text("Enable finder contact for a backpack in My devices."))
            }
            if session.busy { ProgressView("Loading conversations…") }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            Button("Refresh") { retry = UUID() }.disabled(session.busy)
        }
        .modernScene().navigationTitle("Found-device messages")
        .task(id: context) {
            conversations = []; session.clear()
            guard phase == .active else { return }
            session.bind(community, .devices)
            load()
            while !Task.isCancelled, session.failure == nil {
                do { try await Task.sleep(for: .seconds(15)) }
                catch is CancellationError { return }
                catch { session.run { _ in throw error }; return }
                if !session.busy, session.failure == nil { load() }
            }
        }
        .onDisappear { session.clear(); conversations = [] }
    }

    private func load() {
        session.run { scope in
            var all: [DeviceRecoveryConversation] = []
            for page in 1...5 {
                let result = try await scope.recoveryConversations(page: page)
                try session.checked(scope)
                let next = all + result.conversations
                guard next.count <= 100, Set(next.map(\.id)).count == next.count else {
                    throw BackpackError.invalid("Recovery inbox changed or exceeded its limit. Refresh it.")
                }
                all = next
                if !result.hasMore { conversations = all; return nil }
            }
            throw BackpackError.invalid("Recovery inbox did not finish within its page limit.")
        }
    }
}

@MainActor
struct DeviceRecoveryThreadView: View {
    let id: UUID
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var panel: PanelController
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = DeviceRecoveryThreadStore()
    @StateObject private var actions = CommunityFeatureSession()
    @State private var retry = UUID()
    @State private var closing = false
    @State private var blocking = false
    @State private var reporting: DeviceRecoveryMessage?
    private var context: String {
        "\(community.accountRevision):\(community.avatarPolicyRevision):\(community.config?.deviceRecoveryEnabled == true):\(community.config?.connectedDeviceRegistrationVersion ?? 0):\(community.config?.unverifiedDeviceTagsEnabled == true):\(community.config?.connectedDeviceRegistrationEnabled == true):\(phase):\(retry)"
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.closed {
                        ContentUnavailableView("Conversation closed", systemImage: "checkmark.circle",
                            description: Text("Recovery access has ended."))
                    } else {
                        Text("Only for returning this backpack. This conversation expires after 30 days.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let conversation = store.conversation, conversation.state == .pending {
                            Text(conversation.role == .owner ?
                                "Reply to accept this recovery conversation. No friendship or other access is granted." :
                                "Your introduction was sent. You can reply when this person accepts.")
                                .font(.subheadline)
                        }
                        ForEach(store.messages) { message in
                            HStack {
                                if message.senderId == community.user?.id { Spacer(minLength: 32) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: message.text).textSelection(.enabled)
                                    Text(timestamp(message.createdAtISO)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(message.senderId == community.user?.id ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 16))
                                .contextMenu {
                                    if message.senderId != community.user?.id, community.config?.chatReportsEnabled == true {
                                        Button("Report message", systemImage: "flag") { reporting = message }
                                    }
                                }
                                if message.senderId != community.user?.id { Spacer(minLength: 32) }
                            }.id(message.id)
                        }
                        if store.busy { ProgressView() }
                        if let failure = store.failure { Text(failure).foregroundStyle(.orange) }
                        if let failure = store.draftFailure { Text("Draft not saved: \(failure)").foregroundStyle(.orange) }
                        if let failure = actions.failure { Text(failure).foregroundStyle(.orange) }
                        if let pending = store.pending {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(pending.state == .acknowledged ? "Delivery confirmed" : "Pending delivery")
                                    .font(.headline)
                                Text(verbatim: pending.text)
                                if pending.state == .uncertain {
                                    Button("Retry same reply") { Task { await store.send(retry: true) } }
                                }
                                Button("Clear local delivery record", role: .destructive) { store.discardPending() }
                                Text("Clearing does not recall a message already received.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.disabled(store.busy)
                        }
                        if let elsewhere = store.pendingElsewhere {
                            NavigationLink("Resolve pending reply in another conversation") { DeviceRecoveryThreadView(id: elsewhere) }
                        }
                        Button("Refresh") { retry = UUID() }.disabled(store.busy)
                    }
                }.padding().frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.messages.last?.id) { _, value in
                if let value, store.messages.last?.senderId == community.user?.id {
                    reader.scrollTo(value, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let conversation = store.conversation, !store.closed,
               conversation.state == .accepted || conversation.role == .owner && conversation.state == .pending,
               store.pending == nil {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Reply", text: $store.text, axis: .vertical)
                            .lineLimit(1...6).textFieldStyle(.roundedBorder)
                            .disabled(store.writing)
                            .accessibilityIdentifier("device-recovery-reply")
                        if store.text.utf16.count > 900 {
                            Text("\(store.text.utf16.count) / 1,000").font(.caption)
                                .foregroundStyle(store.text.utf16.count > 1000 ? Color.orange : Color.secondary)
                        }
                    }
                    Button("Send", systemImage: "arrow.up.circle.fill") { Task { await store.send() } }
                        .labelStyle(.iconOnly).font(.title2).frame(minWidth: 44, minHeight: 44)
                        .disabled(!store.canSend)
                        .accessibilityIdentifier("device-recovery-send")
                }.padding().background(.bar)
            }
        }
        .modernScene().navigationTitle(store.conversation?.peer.displayName ?? "Device recovery")
        .toolbar {
            if store.conversation != nil, !store.closed {
                Menu {
                    Button("Close conversation", role: .destructive) { closing = true }
                    Button("Block person", role: .destructive) { blocking = true }
                } label: { Label("Conversation actions", systemImage: "ellipsis.circle") }
                .disabled(store.busy || actions.busy)
            }
        }
        .task(id: context) {
            actions.clear(); reporting = nil; closing = false; blocking = false
            guard phase == .active else { saveAndClear(); return }
            actions.bind(community)
            await store.bind(community, id: id)
            while !Task.isCancelled, store.failure == nil, !store.closed {
                do { try await Task.sleep(for: .seconds(10)) }
                catch is CancellationError { return }
                catch { panel.report(error); return }
                if store.failure == nil { await store.refresh() }
            }
        }
        .onChange(of: store.text) { _, _ in store.saveDraft() }
        .onDisappear { saveAndClear(); actions.clear() }
        .confirmationDialog("Close this recovery conversation?", isPresented: $closing) {
            Button("Close conversation", role: .destructive) { Task { await store.close() } }
        } message: { Text("This ends recovery access. The old conversation cannot be reopened by enabling finder contact again.") }
        .confirmationDialog("Block this person?", isPresented: $blocking) {
            if let peer = store.conversation?.peer.id {
                Button("Block person", role: .destructive) {
                    actions.run({ try await $0.block(peer) }, success: { saveAndClear(); retry = UUID() })
                }
            }
        } message: { Text("Stops recovery contact and other account relationships. Unblocking does not restore them.") }
        .sheet(item: $reporting) { message in
            if let conversation = store.conversation {
                MessageIncidentComposeView(recoveryMessage: message, context: conversation)
            }
        }
    }
    private func saveAndClear() {
        do { try store.flushDraft() }
        catch { panel.report(error) }
        store.clear()
    }
    private func timestamp(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return "Time unavailable (\(value))"
        }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
