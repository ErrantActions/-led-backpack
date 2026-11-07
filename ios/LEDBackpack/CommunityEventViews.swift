import SwiftUI
import BackpackProtocol

struct EventNoticeContext {
    let notice: NativeActivityNotice
    let page: Int
}

@MainActor
struct EventInvitationDeadlineView: View {
    let event: CatalogEvent
    var body: some View {
        if event.access.invited && event.access.invitationDeadline != .unspecified {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.access.invitationDeadline.label).font(.caption)
                Text("Expiry ends invitation access only. Independent going RSVP or organizer membership can remain; expiry is not automatic RSVP, event end or participant removal.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct CommunityEventsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var list = CatalogEventList.accessible
    @State private var events: [TimedCatalogEvent] = []
    @State private var offset = 0
    @State private var creating = false
    var body: some View {
        List {
            if community.signedIn {
                Section("Own private source tools") {
                    NavigationLink("Private playlists / foreground schedules") { OwnerPlaylistsView() }
                    NavigationLink("My guestbook receipts / withdraw without event access") { OwnedGuestbookPostsView() }
                    Text("Each tool checks its own actual server capability. No source-only feature is assumed deployed.").font(.caption)
                }
            }
            if community.config?.eventsEnabled == true && community.signedIn && !session.denied &&
                session.client?.accountID == community.user?.id {
                Picker("Events", selection: $list) { ForEach(CatalogEventList.allCases) { Text($0.rawValue).tag($0) } }
                    .disabled(session.busy)
                if session.busy { ProgressView() }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                ForEach(events) { value in
                    NavigationLink { CommunityEventDetailView(id: value.id) } label: {
                        VStack(alignment: .leading) {
                            Text(value.event.title).font(.headline)
                            Text(value.event.location.label).font(.caption)
                            Text("\(value.event.startsAtISO) / \(value.event.timezone)").font(.caption)
                            if value.event.rsvpStatus == .going { EventCountdownView(value: value) }
                            else { Text(value.event.status.rawValue).font(.caption).foregroundStyle(.secondary) }
                            EventInvitationDeadlineView(event: value.event)
                        }
                    }
                }
                HStack {
                    Button("Previous") { offset -= 50; load() }.disabled(offset == 0 || session.busy)
                    Spacer()
                    Button("Next") { offset += 50; load() }.disabled(events.count < 50 || offset >= 100000 || session.busy)
                }
                Button("Refresh events", action: load).disabled(session.busy)
                Button("Create event") { creating = true }.disabled(session.busy)
                Text("Private event links do not grant an invitation. Venues are fixed organizer coordinates, not participant GPS.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(session.failure ?? "Events are not enabled by this server.") }
        }
        .modernScene().navigationTitle("Events")
        .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.config?.eventsEnabled == true)") {
            events = []; offset = 0; session.bind(community)
            if community.config?.eventsEnabled == true { load() }
        }
        .onChange(of: list) { _, _ in offset = 0; load() }
        .task(id: "\(events.map { $0.event.access.invitationDeadline.wireValue ?? "" }):\(phase)") {
            guard phase == .active else { return }
            do {
                var nearest: TimeInterval?
                for event in events where event.event.access.invited {
                    if let raw = event.event.access.invitationDeadline.wireValue {
                        let seconds = try CatalogEventTime.parse(raw).timeIntervalSince(event.clock.now())
                        if seconds > 0 { nearest = min(nearest ?? seconds, seconds) }
                    }
                }
                guard let nearest else { return }
                try await Task.sleep(for: .seconds(nearest)); try Task.checkCancellation()
                events = []; load()
            } catch { if !Task.isCancelled { session.run { _ in throw error } } }
        }
        .onChange(of: phase) { _, state in
            if state == .active { events = []; load() }
            else { events = [] }
        }
        .onChange(of: session.denied) { _, value in if value { events = []; creating = false } }
        .onDisappear { if !creating { session.clear(); events = [] } }
        .sheet(isPresented: $creating, onDismiss: load) { CommunityEventEditor(original: nil) { creating = false } }
    }
    private func load() {
        events = []
        let selection = list, page = offset
        session.run { client in
            let value = try await client.events(selection, offset: page)
            try session.checked(client)
            guard selection == list, page == offset else { return }
            events = try value.events.map(TimedCatalogEvent.init)
        }
    }
}

@MainActor
struct EventCountdownView: View {
    @Environment(\.scenePhase) private var phase
    let value: TimedCatalogEvent
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if phase == .active {
                countdown
            } else { Text(value.event.status.rawValue).font(.caption) }
        }
    }
    @ViewBuilder private var countdown: some View {
        switch Result(catching: { try value.label() }) {
        case .success(let label): Text(label).font(.subheadline.monospaced()).foregroundStyle(Aurora.mint)
        case .failure(let error): Text(error.localizedDescription).font(.caption).foregroundStyle(.orange)
        }
    }
}

@MainActor
struct CommunityEventDetailView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    let id: UUID
    var noticeContext: EventNoticeContext? = nil
    @State private var value: TimedCatalogEvent?
    @State private var editingEvent: CatalogEvent?
    @State private var planningEvent: CatalogEvent?
    @State private var chatSelection: ChatScreenSelection?
    private var editing: Bool { editingEvent != nil || planningEvent != nil }
    @State private var target = ""
    @State private var action = CommunityFeatureClient.OrganizerAction.invite
    @State private var pending: Confirmation?
    @State private var notice: String?
    @State private var customInviteDeadline = false
    @State private var inviteDeadline = Date().addingTimeInterval(7 * 86400)
    @State private var ownershipAccessLost = false
    @State private var knownOwnRSVP = false
    private struct Confirmation {
        let title, message: String
        let scope: UUID
        let work: @MainActor (CommunityFeatureClient) async throws -> Void
    }
    private var eventForm: some View {
        Form {
            if community.config?.eventsEnabled == true && community.signedIn && !session.denied &&
                session.client?.accountID == community.user?.id {
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if session.busy { ProgressView() }
                if value == nil && knownOwnRSVP {
                    Button("Explicitly decline known own RSVP (no event detail read)") {
                        session.run { client in
                            try await client.declineKnownEventRSVP(id); try session.checked(client)
                            knownOwnRSVP = false; value = nil; editingEvent = nil; planningEvent = nil; chatSelection = nil
                            notice = "Known RSVP declined. No current event content or membership was inferred."
                        }
                    }.disabled(session.busy)
                }
                if let loadedEvent = value {
                    let event = loadedEvent.event
                    if event.moderation?.held == true {
                        Label("Held: normal participation, progress, media and conversation access withdrawn.", systemImage: "lock")
                        Text("Organizers may correct the definition. Release requires fresh participation review and never restores shared progress.").font(.caption)
                    }
                    Section(event.title) {
                        if event.moderation?.held != true { EventAuthorizedCoverView(event: event) }
                        Text(event.description)
                        Text(event.startsAtISO).font(.caption)
                        Text("Until \(event.endsAtISO) / \(event.timezone)").font(.caption)
                        Text("Status: \(event.status.rawValue)")
                        if event.rsvpStatus == .going { EventCountdownView(value: loadedEvent) }
                        LabeledContent("Your RSVP", value: event.rsvpStatus?.rawValue ?? "None")
                        LabeledContent("Visibility", value: event.visibility)
                        LabeledContent("Capacity", value: String(event.capacity))
                        Text("Venue: \(event.location.label)")
                        Text("\(event.location.latitude), \(event.location.longitude) / radius \(event.location.radiusMeters)m").font(.caption)
                        Text("Fixed organizer venue; this view does not access device GPS.").font(.caption).foregroundStyle(.secondary)
                        EventInvitationDeadlineView(event: event)
                    }
                    if session.client?.progressDeadlinesEnabled(event) == true, event.moderation?.held != true, event.access.canViewProgress {
                        Section("Shared-progress retention policy") {
                            NavigationLink("Latest shared progress / claim / withdraw") { EventProgressView(eventID: event.id) }
                            NavigationLink("Foreground local checkpoint hint (opt in)") { EventLocalEligibilityView(eventID: event.id) }
                            Text("A deliberately shared latest checkpoint is retained no later than event end + 24 hours, or removed earlier by withdrawal, cancellation, moderation or a shortened schedule.")
                            Text("Extending the event does not extend an existing claim. Its returned expiresAtISO is a retention deadline, not an arrival/update timestamp.").font(.caption)
                            Text("Shared-progress expiry does not delete separately collected private badges. This screen does not collect/share a checkpoint, GPS or arrival proof.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Separate optional event choices") {
                        NavigationLink("Own team palette / organizer palette draft") { EventSocialView(eventID: event.id, surface: .teams) }
                            .disabled(community.config?.eventTeamsEnabled != true || event.settings?.eventTeamsEnabled != true || event.moderation?.held == true)
                        NavigationLink("Any-order hunt / separate cooperative consent") { EventSocialView(eventID: event.id, surface: .collection) }
                            .disabled(community.config?.eventCollectionsEnabled != true || event.settings?.eventCollectionsEnabled != true || event.moderation?.held == true)
                        NavigationLink("Consented guestbook / moderation") { EventSocialView(eventID: event.id, surface: .guestbook) }
                            .disabled(community.config?.eventGuestbookAvailable != true || event.settings?.eventGuestbookAvailable != true || event.moderation?.held == true)
                        NavigationLink("Show / rest-stop plan (paused source preview)") { EventSocialView(eventID: event.id, surface: .display) }
                            .disabled(community.config?.eventDisplayPlanningEnabled != true || event.settings?.eventDisplayPlanningEnabled != true || event.moderation?.held == true)
                        NavigationLink("Deliberately open only my private recap") { EventSocialView(eventID: event.id, surface: .recap) }
                            .disabled(community.config?.eventRecapsEnabled != true || event.settings?.eventRecapsEnabled != true || event.access.canViewRecap != true || event.moderation?.held == true)
                        Text("Disabled means this server/event/current account has not enabled the capability. These separate choices do not RSVP, publish progress, enable GPS or start phone/backpack playback.").font(.caption)
                    }
                    Section("RSVP") {
                        if event.settings?.accountAwardsEnabled == true, event.moderation?.held != true {
                            NavigationLink("Explicitly collect a private event badge") { EventAwardCollectionView(eventID: event.id) }
                        }
                        if event.requiresReconfirmation == true {
                            Label("Review the updated schedule, venue and route before reconfirming.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if let route = event.route {
                            Section("Review fixed plan") {
                                FixedEventPlanPreview(event: event, route: route)
                            }
                        }
                        Button(event.requiresReconfirmation == true ? "Confirm reviewed participation" : "I'm going") { rsvp(event, status: .going) }
                            .disabled(session.busy || !event.access.canRsvp || event.cancelled)
                        Button("Decline / leave") { rsvp(event, status: .declined) }
                            .disabled(session.busy || (event.rsvpStatus == nil && !event.access.member))
                        Text("An invitation does not RSVP automatically. Capacity and access are checked by the server.")
                            .font(.caption)
                        Text("Reconfirmation never republishes checkpoint progress. Sharing requires a separate explicit action.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Organizers") {
                        ForEach(event.organizers) { organizer in
                            LabeledContent(organizer.displayName, value: organizer.eventRole.rawValue)
                            if community.config?.messagingEnabled == true, organizer.id != community.user?.id, event.moderation?.held != true {
                                Button("Private question to \(organizer.displayName)") {
                                    chatSelection = ChatScreenSelection(context: .direct(peer: organizer.id, event: event.id), title: "Private organizer question")
                                }
                            }
                        }
                    }
                    if community.config?.messagingEnabled == true, community.config?.eventChatsEnabled == true, event.moderation?.held != true {
                        Section("Event-wide conversation") {
                            Button("Explicitly open / join event-wide chat") {
                                session.run({ client in
                                    let room = try await client.openEventRoom(event.id)
                                    try session.checked(client)
                                    chatSelection = ChatScreenSelection(context: .room(room.id), title: room.title)
                                })
                            }.disabled(session.busy || event.cancelled || event.requiresReconfirmation == true ||
                                (event.access.role == nil && event.rsvpStatus != .going))
                            Text("Separate from private organizer questions. Joining never RSVPs or shares progress. Current eligibility is checked by the server.").font(.caption)
                        }
                    }
                    if event.access.canManage && !event.cancelled {
                        Section("Organizer tools") {
                            if event.moderation?.held != true {
                                NavigationLink("Participants & current invitations") { EventRosterView(eventID: event.id) }
                                NavigationLink("Organizer image gallery") { EventGalleryView(eventID: event.id, organizer: true) }
                            }
                            if event.access.role == .owner {
                                NavigationLink("Named co-organizers / ownership / audit") {
                                    EventOwnerToolsView(eventID: event.id) { receipt in
                                        value = nil; editingEvent = nil; planningEvent = nil; pending = nil; chatSelection = nil
                                        ownershipAccessLost = receipt == nil
                                        if let receipt {
                                            do { value = try TimedCatalogEvent(receipt) }
                                            catch { session.run { _ in throw error } }
                                        }
                                    }
                                }
                            }
                            Button("Edit / reschedule event") { editingEvent = event }
                            if event.access.canManageRoute, event.route != nil, event.badges != nil {
                                Button("Plan venue route & checkpoints") { planningEvent = event }
                                    .disabled(community.config?.eventsEnabled != true)
                            }
                            TextField("Target account UUID", text: $target).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Picker("Action", selection: $action) {
                                ForEach(CommunityFeatureClient.OrganizerAction.allCases.filter {
                                    [.invite, .revokeInvite, .removeParticipant].contains($0) &&
                                        (event.access.role == .owner || [.invite, .revokeInvite].contains($0))
                                }) { Text($0.label).tag($0) }
                            }
                            if event.moderation?.held != true {
                                NavigationLink("Current authorized event gallery") { EventGalleryView(eventID: event.id, organizer: false) }
                            }
                            if session.client?.eventReportsAvailable == true, event.settings?.eventReportsEnabled == true {
                                NavigationLink("Deliberately report this event") { EventReportComposerView(event: event) }
                            }
                            if action == .invite, session.client?.invitationDeadlinesEnabled(event) == true {
                                Toggle("Explicitly set / change invitation deadline", isOn: $customInviteDeadline)
                                if customInviteDeadline {
                                    DatePicker("Invitation deadline (UTC)", selection: $inviteDeadline, displayedComponents: [.date, .hourAndMinute])
                                        .environment(\.timeZone, .gmt)
                                    Text("Future UTC, at most 30 days from server time. An explicit deadline changes the grant and invalidates its old notice.").font(.caption)
                                } else {
                                    Text("Omit deadline: new grants use the server's seven-day default; an active resend preserves the exact current expiry, including legacy no-expiry. No renewal is inferred.").font(.caption)
                                }
                            }
                            Button("Review organizer action") { organize(event) }
                            Text("Revoking an invitation can leave a going member's access intact. Explicit participant removal is separate. Co-organizers are event-scoped, not account admins.")
                                .font(.caption).foregroundStyle(.secondary)
                            if event.access.role == .owner {
                                Button("Cancel event", role: .destructive) {
                                    confirm("Cancel event", "Cancel this event at revision \(event.revision)?") { client in
                                        let cancelled = try await client.cancelEvent(event)
                                        try session.checked(client); value = try TimedCatalogEvent(cancelled)
                                    }
                                }
                            }
                        }.disabled(session.busy)
                    }
                    Button("Refresh event", action: load).disabled(session.busy)
                    if let origin = community.origin {
                        ShareLink("Share event link", item: origin.url.appendingPathComponent("events").appendingPathComponent(event.id.uuidString.lowercased()))
                        Text("Sharing a private link never grants event access.").font(.caption)
                    }
                }
            } else { Text(session.failure ?? "This event feature is unavailable.") }
        }
    }
    private var eventLifecycle: some View {
        eventForm
        .modernScene().navigationTitle("Event")
        .navigationDestination(item: $chatSelection) { item in CommunityConversationView(context: item.context, title: item.title) }
        .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.config?.eventsEnabled == true)") {
            value = nil; pending = nil; notice = nil; session.bind(community)
            knownOwnRSVP = false; ownershipAccessLost = false
            editingEvent = nil
            planningEvent = nil
            guard community.config?.eventsEnabled == true else { return }
            load()
        }
        .task(id: "\(phase):\(community.accountRevision):\(community.config?.eventsEnabled == true)") {
            guard phase == .active, community.config?.eventsEnabled == true, community.signedIn else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !editing && !session.busy && !session.denied && pending == nil && !ownershipAccessLost { load() }
            }
        }
        .onChange(of: session.denied) { _, denied in if denied { value = nil; editingEvent = nil; planningEvent = nil; pending = nil } }
        .task(id: "\(value?.event.id.uuidString ?? ""):\(value?.event.access.invitationDeadline.wireValue ?? ""):\(phase)") {
            guard phase == .active, let snapshot = value, snapshot.event.access.invited,
                  let raw = snapshot.event.access.invitationDeadline.wireValue else { return }
            do {
                let expiry = try CatalogEventTime.parse(raw)
                try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSince(snapshot.clock.now()))))
                try Task.checkCancellation()
                if (!EventDeadlinePolicy.retainsIndependentAccess(snapshot.event) && snapshot.event.visibility == "private") ||
                    noticeContext?.notice.type == .eventInvite {
                    value = nil; editingEvent = nil; planningEvent = nil; pending = nil
                }
                load()
            } catch { if !Task.isCancelled { session.run { _ in throw error } } }
        }
        .onChange(of: phase) { _, state in
            if state == .active && !editing { value = nil; pending = nil; load() }
        }
        .onDisappear { if !editing { session.clear(); value = nil }; pending = nil; target = "" }
    }
    var body: some View {
        eventLifecycle
        .sheet(item: $editingEvent, onDismiss: load) { original in
            CommunityEventEditor(original: original) { editingEvent = nil }
        }
        .sheet(item: $planningEvent, onDismiss: load) { original in
            EventRoutePlannerView(original: original) { planningEvent = nil }
        }
        .alert("Confirm event action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending) { value in
                Button(value.title) {
                    session.run(expected: value.scope, { client in
                        if let noticeContext { _ = try await client.verifyEventNotice(noticeContext.notice, page: noticeContext.page) }
                        try await value.work(client)
                    })
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text($0.message) }
    }
    private func load() {
        session.run { client in
            let event: CatalogEvent
            do {
                if let noticeContext {
                    guard try await client.verifyEventNotice(noticeContext.notice, page: noticeContext.page) == id else {
                        throw BackpackError.invalid("Event notice target changed.")
                    }
                }
                event = try await client.event(id)
            } catch {
                value = nil; editingEvent = nil; planningEvent = nil; pending = nil; chatSelection = nil
                throw error
            }
            try session.checked(client)
            if value?.event.revision != event.revision || value?.event.access.role != event.access.role ||
                value?.event.moderation != event.moderation {
                pending = nil; editingEvent = nil; planningEvent = nil; chatSelection = nil
            }
            ownershipAccessLost = false; knownOwnRSVP = event.rsvpStatus != nil; value = try TimedCatalogEvent(event)
        }
    }
    private func confirm(_ title: String, _ message: String, work: @escaping @MainActor (CommunityFeatureClient) async throws -> Void) {
        guard let client = session.client else {
            session.run { _ in throw BackpackError.invalid("Refresh event access before confirming an action.") }; return
        }
        pending = Confirmation(title: title, message: message, scope: client.instanceID, work: work)
    }
    private func rsvp(_ event: CatalogEvent, status: CatalogRSVP) {
        confirm(status == .going ? "Confirm reviewed event" : "Decline event",
            "Review \(event.title)'s schedule, venue and plan at participation revision \(event.participationRevision.map(String.init) ?? "legacy"). Reconfirmation does not share progress.") { client in
            let updated = try await client.rsvp(event, status: status)
            try session.checked(client)
            value = nil; pending = nil; editingEvent = nil; planningEvent = nil; chatSelection = nil
            knownOwnRSVP = status != .declined
            if let updated { value = try TimedCatalogEvent(updated) } else { ownershipAccessLost = true }
        }
    }
    private func organize(_ event: CatalogEvent) {
        let selected = action, text = target
        let expiry = selected == .invite && customInviteDeadline ? CatalogEventTime.wire(inviteDeadline) : nil
        let deadlineMessage = selected == .invite ?
            (expiry.map { " Explicitly set this grant's expiry to \($0); old grant notices will become stale." } ??
                " Omit expiry: preserve any active deadline/legacy no-expiry; only new grants default to seven days.") : ""
        confirm(selected.label,
            "Apply \(selected.label.lowercased()) to \(text)?\(deadlineMessage) Other revision-bound changes use revision \(event.revision); conflicts require a refresh.") { client in
                guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw BackpackError.invalid("Enter a target account UUID.")
                }
                if selected == .invite {
                    let receipt = try await client.invite(event, target: id, expiresAtISO: expiry,
                        serverNow: value?.clock.now())
                    try session.checked(client); notice = receipt.deadline.label
                } else {
                    try await client.organize(event, target: id, action: selected)
                }
                try session.checked(client)
                if selected != .invite {
                    notice = selected == .revokeInvite ? "Invitation revoked. Independent going/organizer membership may retain access; participant removal is separate." : "Organizer action confirmed."
                }
                load()
            }
    }
}

@MainActor
struct CommunityEventEditor: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let original: CatalogEvent?
    let saved: () -> Void
    @State private var loaded = false
    @State private var title = ""
    @State private var description = ""
    @State private var start = Date().addingTimeInterval(86400)
    @State private var end = Date().addingTimeInterval(90000)
    @State private var zone = "UTC"
    @State private var visibility = "private"
    @State private var capacity = 50
    @State private var venue: CatalogEventLocation?
    @State private var kind = "meetup"
    @State private var startEdited = false
    @State private var endEdited = false
    @State private var venueConfirmed = false
    @State private var review: NativeEventDefinitionReview?
    @State private var unlistedConsent = false
    @State private var acknowledgement: String?
    @State private var requiresReload = false
    @State private var editingAuthorized = false
    @State private var initialRevision: UUID?
    @State private var initialAccount: UUID?
    var body: some View {
        NavigationStack {
            Form {
                if community.config?.eventsEnabled == true && !session.denied &&
                    session.client?.accountID == community.user?.id {
                    TextField("Event title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                    if community.config?.eventTemplatesEnabled == true {
                        Picker("Event type", selection: $kind) {
                            Text("Meetup").tag("meetup"); Text("Group ride").tag("group-ride")
                        }
                        Text("A type never creates a route or grants GPS permission. Place the actual plan separately.").font(.caption)
                    }
                    Picker("Visibility", selection: $visibility) {
                        Text("Private").tag("private"); Text("Public").tag("public")
                        if community.config?.unlistedEventsEnabled == true &&
                            (original == nil || original?.settings?.unlistedEventsEnabled == true) {
                            Text("Unlisted / link-readable").tag("unlisted")
                        } else if original?.visibility == "unlisted" { Text("Existing unlisted (new capability unavailable)").tag("unlisted") }
                    }
                    if visibility == "unlisted" && original?.visibility != "unlisted" {
                        Toggle("I consent to link-readable details and fixed venue", isOn: $unlistedConsent)
                    }
                    if visibility != "private" { Text("Public and unlisted links expose the venue; unlisted is not confidential.").font(.caption) }
                    Stepper("Capacity \(capacity)", value: $capacity, in: 1...10000)
                    Picker("Event timezone", selection: $zone) {
                        ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    if let timezone = TimeZone(identifier: zone) {
                        DatePicker("Starts", selection: Binding(get: { start }, set: { start = $0; startEdited = true })).environment(\.timeZone, timezone)
                        DatePicker("Ends", selection: Binding(get: { end }, set: { end = $0; endEdited = true })).environment(\.timeZone, timezone)
                    }
                    if original == nil {
                        Button("Explicitly choose displayed start time") { startEdited = true }
                        Button("Explicitly choose displayed end time") { endEdited = true }
                        Text("New schedules require deliberate start/end selection; displayed suggestions are never silently saved.").font(.caption)
                    }
                    if let acknowledgement { Text(acknowledgement).foregroundStyle(.orange) }
                    Section("Fixed organizer-authored venue") {
                        FixedVenueMapEditor(venue: $venue, enabled: community.config?.eventsEnabled == true && editingAuthorized && !requiresReload)
                        Toggle("I reviewed these fixed venue coordinates", isOn: $venueConfirmed)
                        Text("No device GPS or participant coordinates are requested. Changes may require going participants to review again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let failure = session.failure {
                        Text(failure).foregroundStyle(.orange)
                        Text("A revision conflict never overwrites this unsaved draft or retries automatically. Cancel to review the refreshed event, then reopen editing.")
                            .font(.caption)
                    }
                    if session.busy { ProgressView() }
                    Button(original == nil ? "Review new event" : "Review event update") {
                        do {
                            guard let input = definitionInput, let client = session.client else { throw BackpackError.invalid("Choose explicit times, venue and current access first.") }
                            review = try NativeEventDefinitionReview(input: input, original: original, scope: client.instanceID)
                        } catch { session.run { _ in throw error } }
                    }.disabled(session.busy || !editingAuthorized || requiresReload || !venueConfirmed || venue == nil ||
                        (original == nil && (!startEdited || !endEdited)) || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else { Text(session.failure ?? "Events are unavailable.") }
            }
            .modernScene().navigationTitle(original == nil ? "Create event" : "Edit event")
            .toolbar { Button("Cancel") { dismiss() }.disabled(session.busy) }
            .interactiveDismissDisabled(session.busy)
            .task {
                guard !loaded else { return }
                loaded = true; initialRevision = community.accountRevision; initialAccount = community.user?.id; session.bind(community)
                if let original {
                    title = original.title; description = original.description; zone = original.timezone
                    visibility = original.visibility; capacity = original.capacity; venue = original.location; kind = original.kind ?? "meetup"
                    do { start = try CatalogEventTime.parse(original.startsAtISO); end = try CatalogEventTime.parse(original.endsAtISO) }
                    catch { session.run { _ in throw error } }
                }
                session.run { client in
                    if let original {
                        let current = try await client.event(original.id)
                        guard current.access.canManage, current.access.role == original.access.role else {
                            throw CommunityFailure(status: 403, code: "event_access_changed", message: "Current organizer permission is required.")
                        }
                        guard current.revision == original.revision else {
                            requiresReload = true
                            throw CommunityFailure(status: 409, code: "event_revision_conflict", message: "Definition changed. Draft retained; explicitly reload before planning.")
                        }
                    }
                    try session.checked(client); editingAuthorized = true
                }
            }
            .onChange(of: community.accountRevision) { _, value in if initialRevision != value { session.clear(); dismiss() } }
            .onChange(of: community.user?.id) { _, value in if initialAccount != value { session.clear(); dismiss() } }
            .onChange(of: inputFingerprint) { _, _ in review = nil }
            .onChange(of: venueConfirmed) { _, _ in review = nil }
            .onChange(of: community.config?.eventsEnabled) { _, enabled in if enabled != true { review = nil; venue = nil; session.clear(); dismiss() } }
            .onChange(of: community.config?.unlistedEventsEnabled) { _, _ in review = nil; unlistedConsent = false }
            .onChange(of: session.denied) { _, denied in if denied { review = nil; venue = nil; dismiss() } }
            .task(id: "\(community.accountRevision):\(original?.id.uuidString ?? "")") {
                guard let original else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if !session.busy && !session.denied && !requiresReload {
                        session.run { client in
                            let current = try await client.event(original.id)
                            guard current.access.canManage, current.access.role == original.access.role else {
                                review = nil; editingAuthorized = false; venue = nil
                                throw CommunityFailure(status: 403, code: "event_access_changed", message: "Organizer access changed; clear private editing context.")
                            }
                            if current.revision != original.revision {
                                review = nil; requiresReload = true
                                throw CommunityFailure(status: 409, code: "event_revision_conflict", message: "Event changed; draft retained, review invalidated. Explicitly reload.")
                            }
                        }
                    }
                }
            }
            .onDisappear { if review == nil { session.clear() } }
            .sheet(item: $review) { captured in
                EventDefinitionReviewView(captured: captured, back: { review = nil }) {
                    guard captured.matches(definitionInput), venueConfirmed else { review = nil; return }
                    session.run(expected: captured.scope) { client in
                        do {
                            _ = try await client.saveEvent(captured.input, original: original)
                            try session.checked(client)
                            let unchanged = captured.matches(definitionInput)
                            review = nil
                            if unchanged { dismiss(); saved() }
                            else {
                                requiresReload = true
                                acknowledgement = "Captured save acknowledged. New edits remain local and were NOT saved or overwritten. Close, explicitly reload the event and review before another save."
                            }
                        } catch {
                            review = nil
                            if let failure = error as? CommunityFailure, failure.status == 409 { requiresReload = true }
                            throw error
                        }
                    }
                }
            }
        }
    }
    private var definitionInput: CatalogEventInput? {
        guard let venue, original != nil || (startEdited && endEdited) else { return nil }
        return CatalogEventInput(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            startsAtISO: !startEdited ? (original?.startsAtISO ?? CatalogEventTime.wire(start)) : CatalogEventTime.wire(start),
            endsAtISO: !endEdited ? (original?.endsAtISO ?? CatalogEventTime.wire(end)) : CatalogEventTime.wire(end),
            timezone: zone, visibility: visibility, capacity: capacity, location: venue, expectedRevision: original?.revision,
            kind: community.config?.eventTemplatesEnabled == true ? kind : nil,
            unlistedLinkConsent: visibility == "unlisted" && original?.visibility != "unlisted" && unlistedConsent ? true : nil)
    }
    private var inputFingerprint: Data? {
        guard let input = definitionInput else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(input)
    }
}
