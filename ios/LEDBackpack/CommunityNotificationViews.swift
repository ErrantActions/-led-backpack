import SwiftUI

@MainActor
struct CommunityNotificationSettingsView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = CommunityFeatureSession()
    @State private var original: NativeNotificationSettings?
    @State private var choices: NativeNotificationPreferences?
    @State private var captured: (NativeNotificationSettings, NativeNotificationPreferences, UUID)?
    @State private var confirm = false
    @State private var discard = false
    var body: some View {
        Form {
            if community.config?.notificationPreferencesEnabled == true, !session.denied, let choices {
                Section("Delivery channels") {
                    Toggle("Global notifications", isOn: binding(\.globalEnabled))
                    Toggle("In-app activity", isOn: binding(\.inAppEnabled))
                    Toggle("Apple push", isOn: binding(\.applePushEnabled))
                        .disabled(original?.applePushAvailable != true && !choices.applePushEnabled)
                    Text(original?.applePushAvailable == true ?
                        "Server availability is not OS permission, token registration or proof of delivery." :
                        "Apple push is unavailable. No OS permission, device registration or push activation is performed here.").font(.caption)
                }
                Section("Categories") {
                    ForEach(NativeNotificationPreferences.Category.allCases) { category in
                        Toggle(category.title, isOn: Binding(get: { self.choices?.categories[keyPath: category.keyPath] == true },
                            set: { self.choices?.categories[keyPath: category.keyPath] = $0 }))
                        .disabled(category == .eventReminders && community.config?.eventRemindersEnabled != true && !choices.categories.eventReminders)
                    }
                    InteractionExplanation("Reminders are off by default. Eligible reviewed events only; no RSVP, GPS, arrival or progress sharing.", details: "Event reminders default off. Opting in schedules only eligible reviewed events during their final hour; it never RSVPs, shares progress, records arrival or collects GPS. Material updates require fresh review.").font(.caption)
                }
                Button("Review & save") {
                    guard let original, let client = session.client, let choices = self.choices else { return }
                    captured = (original, choices, client.instanceID); confirm = true
                }.buttonStyle(AuroraPrimaryButton())
                Button("Discard choices & reload") { discard = true }
                Text("Delivery preferences do not stop messages, live connections, memberships or security requirements. Existing delivered history remains subject to current access.").font(.caption)
            } else { Text("Notification preferences unavailable until this server supports them.") }
            if session.busy { ProgressView() }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
        }.disabled(session.busy).modernScene().navigationTitle("Notification settings")
        .task(id: community.accountRevision) { clear(); session.bind(community); load() }
        .onChange(of: session.denied) { _, denied in if denied { clear() } }
        .onDisappear { session.clear(); clear() }
        .confirmationDialog("Save captured notification choices?", isPresented: $confirm) {
            if let value = captured {
                Button("Save displayed revision") {
                    session.run(expected: value.2, { client in
                        let result = try await client.saveNotificationSettings(value.0, choices: value.1)
                        try session.checked(client); original = result; choices = result.preferences; captured = nil
                    })
                }
            }
        } message: { Text("Conflicts preserve your choices. Reload/discard and explicitly review again; no automatic rebase.") }
        .confirmationDialog("Discard unsaved choices?", isPresented: $discard) { Button("Discard & reload", role: .destructive) { load() } }
    }
    private func binding(_ path: WritableKeyPath<NativeNotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { choices?[keyPath: path] == true }, set: { choices?[keyPath: path] = $0 })
    }
    private func load() {
        guard community.config?.notificationPreferencesEnabled == true else { return }
        session.run { client in let value = try await client.notificationSettings(); try session.checked(client); original = value; choices = value.preferences }
    }
    private func clear() { original = nil; choices = nil; captured = nil; confirm = false; discard = false }
}
@MainActor
struct CommunityActivityView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var notices: [NativeActivityNotice] = []
    @State private var page = 1
    @State private var total = 0
    @State private var pending: NativeActivityNotice?
    @State private var pendingScope: UUID?
    var body: some View {
        List {
            if community.config?.notificationsEnabled == true && !session.denied {
                if session.busy { ProgressView("Loading activity…") }
                if notices.isEmpty && !session.busy && session.failure == nil {
                    ContentUnavailableView("No activity", systemImage: "bell",
                        description: Text("Your currently authorized activity appears here."))
                }
                ForEach(notices) { notice in
                    VStack(alignment: .leading) {
                        Text(notice.type.title).font(.headline)
                        Text(notice.createdAtISO).font(.caption)
                        destination(notice)
                        if notice.readAtISO == nil {
                            Button("Mark read") { session.run({ try await $0.noticeAction(notice.id) }, success: load) }
                        }
                        Button("Dismiss", role: .destructive) { pending = notice; pendingScope = session.client?.instanceID }
                    }
                }
                HStack {
                    Button("Previous") { page -= 1; load() }.disabled(page <= 1)
                    Spacer(); Button("Next") { page += 1; load() }.disabled(page >= 200 || page * 24 >= total)
                }
                Button("Refresh current access", action: load)
                Button("Mark all authorized activity read") { session.run({ try await $0.noticeAction(nil) }, success: load) }
            } else { Text("Private activity unavailable.") }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
        }.disabled(session.busy).modernScene().navigationTitle("Activity")
        .task(id: community.accountRevision) { notices = []; page = 1; session.bind(community); load() }
        .onChange(of: session.denied) { _, denied in if denied { notices = []; pending = nil } }
        .task(id: "\(phase):\(community.accountRevision):\(community.config?.notificationsEnabled == true)") {
            guard phase == .active, community.config?.notificationsEnabled == true else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !session.busy && pending == nil { load() }
            }
        }
        .onChange(of: phase) { _, state in
            session.clear(); notices = []; pending = nil
            if state == .active { session.bind(community); load() }
        }
        .onChange(of: community.chatAccessRevision) { _, _ in session.clear(); notices = []; pending = nil; if phase == .active { session.bind(community); load() } }
        .onChange(of: community.config?.notificationsEnabled) { _, _ in session.clear(); notices = []; pending = nil; if phase == .active { session.bind(community); load() } }
        .onDisappear { session.clear(); notices = []; pending = nil }
        .confirmationDialog("Dismiss your activity notice?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let item = pending {
                Button("Dismiss", role: .destructive) { session.run(expected: pendingScope, { try await $0.noticeAction(item.id, remove: true) }, success: { pending = nil; load() }) }
            }
        }
    }
    @ViewBuilder private func destination(_ notice: NativeActivityNotice) -> some View {
        switch notice.type {
        case .eventInvite, .eventUpdated, .eventCancelled, .eventReminder:
            if let id = UUID(uuidString: String(notice.referenceId.prefix(36))), community.config?.eventsEnabled == true {
                NavigationLink("Review current authorized event notice") {
                    CommunityEventDetailView(id: id, noticeContext: EventNoticeContext(notice: notice, page: page))
                }
            }
        case .friendRequest, .friendAccepted:
            if community.config?.socialEnabled == true { NavigationLink("Review current friend requests") { CommunitySocialView() } }
        case .message:
            if community.config?.messagingEnabled == true {
                NavigationLink("Open authorized conversations / requests") { CommunityMessagesView() }
                if community.config?.chatMessageRequestsEnabled == true {
                    NavigationLink("Review current message requests") { CommunityMessageRequestsView() }
                }
                Text("This opaque activity ID is not a peer, room or accepted-thread grant.").font(.caption)
            }
        case .avatarReviewed:
            if community.config?.avatarsEnabled == true { NavigationLink("Review your avatar") { CommunityAvatarView() } }
        }
    }
    private func load() {
        guard community.config?.notificationsEnabled == true else { return }
        notices = []
        session.run { client in let value = try await client.notices(page: page); try session.checked(client); notices = value.notifications; total = value.total }
    }
}
