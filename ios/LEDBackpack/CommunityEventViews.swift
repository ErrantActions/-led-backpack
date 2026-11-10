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
                Label(event.access.invitationDeadline.label, systemImage: "envelope").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct CommunityEventsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var session = CommunityFeatureSession()
    @State private var list = CatalogEventList.accessible
    @State private var events: [TimedCatalogEvent] = []
    @State private var offset = 0
    @State private var creating = false
    @State private var createdEvent: CatalogEvent?
    @State private var showCreated = false
    @State private var search = ""
    private var available: Bool {
        community.config?.eventsEnabled == true && community.signedIn && !session.denied &&
            session.client?.accountID == community.user?.id
    }
    private var visibleEvents: [TimedCatalogEvent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? events : events.filter {
            $0.event.title.localizedCaseInsensitiveContains(query) || $0.event.location.label.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AuroraHeading(eyebrow: "Good plans. Great people.", title: "Show up.", accent: "Light it up.")
                    .auroraEntrance()
                if available {
                    Button { createdEvent = nil; showCreated = false; creating = true } label: {
                        Label("Create event", systemImage: "plus")
                    }.buttonStyle(AuroraPrimaryButton()).disabled(session.busy)
                        .accessibilityIdentifier("events-create")
                    Picker("Events", selection: $list) {
                        ForEach(CatalogEventList.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(session.busy)
                        .accessibilityIdentifier("events-filter")
                    if session.busy { ProgressView("Loading events") }
                    if let failure = session.failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                        count: horizontalSizeClass == .regular ? 2 : 1), spacing: 16) {
                        ForEach(visibleEvents) { value in
                            NavigationLink { CommunityEventDetailView(id: value.id) } label: {
                                EventInvitationCard(value: value)
                            }.buttonStyle(AuroraTileButton())
                                .accessibilityIdentifier("event-card-\(value.id.uuidString.lowercased())")
                        }
                    }
                    if visibleEvents.isEmpty && !session.busy && session.failure == nil {
                        ContentUnavailableView(search.isEmpty ? "No events yet" : "No matches on this page",
                            systemImage: search.isEmpty ? "calendar" : "magnifyingglass",
                            description: Text(search.isEmpty ? list.emptyMessage : "Try another name or load a different page."))
                    }
                    if offset > 0 || events.count == 50 {
                        HStack {
                            Button("Previous") { offset -= 50; load() }.disabled(offset == 0 || session.busy)
                            Spacer()
                            Text("Page \(offset / 50 + 1)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Next") { offset += 50; load() }.disabled(events.count < 50 || offset >= 100000 || session.busy)
                        }
                    }
                } else {
                    ContentUnavailableView(community.signedIn ? "Events unavailable" : "Sign in for events",
                        systemImage: "calendar",
                        description: Text(session.failure ?? (community.signedIn ? "Not enabled on this server." : "Find your people and make a plan.")))
                    if !community.signedIn { NavigationLink("Sign in") { CommunityAccountView() } }
                }
                if community.signedIn {
                    DisclosureGroup("Your event extras") {
                        NavigationLink("Private playlists & schedules") { OwnerPlaylistsView() }
                        NavigationLink("Guestbook receipts & withdrawals") { OwnedGuestbookPostsView() }
                    }.font(.subheadline)
                }
            }.padding(20).frame(maxWidth: 1080).frame(maxWidth: .infinity)
        }
        .modernScene().navigationTitle("Events")
        .searchable(text: $search, prompt: "Search loaded events")
        .toolbar {
            Button(action: load) { Label("Refresh events", systemImage: "arrow.clockwise") }
                .disabled(session.busy || !available)
        }
        .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.config?.eventsEnabled == true)") {
            createdEvent = nil; showCreated = false; events = []; offset = 0; search = ""; session.bind(community)
            if community.config?.eventsEnabled == true { load() }
        }
        .onChange(of: list) { _, _ in offset = 0; search = ""; load() }
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
        .sheet(isPresented: $creating, onDismiss: { load(); showCreated = createdEvent != nil }) {
            CommunityEventEditor(original: nil, created: { createdEvent = $0 }, saved: { creating = false })
        }
        .navigationDestination(isPresented: $showCreated) {
            if let createdEvent { CommunityEventDetailView(id: createdEvent.id, newlyCreated: true) }
        }
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
    var newlyCreated = false
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
    @State private var planExpanded = false
    private var available: Bool {
        community.config?.eventsEnabled == true && community.signedIn && !session.denied &&
            session.client?.accountID == community.user?.id
    }
    @State private var knownOwnRSVP = false
    private struct Confirmation {
        let title, message: String
        let scope: UUID
        let work: @MainActor (CommunityFeatureClient) async throws -> Void
    }
    private var eventForm: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            if available {
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if session.busy { ProgressView() }
                if value == nil && knownOwnRSVP {
                    Button("Withdraw my RSVP") {
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
                        Label("Event on hold", systemImage: "lock").font(.headline).foregroundStyle(Aurora.rose)
                        Text("Participation, media, progress and chat are unavailable.").font(.subheadline)
                        FeatureDetails("What happens next?") {
                            Text("Hosts can correct the event. Release requires fresh participation review and does not restore shared progress.")
                        }
                    }
                    if newlyCreated && event.access.canManage {
                        Label("Your event is ready", systemImage: "checkmark.circle.fill").foregroundStyle(Aurora.mint)
                        Text("Add photos, invite people or plan an activity below.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    EventInvitationPoster(title: event.title, kind: event.kind).auroraEntrance()
                        .accessibilityIdentifier("event-invitation")
                    VStack(alignment: .leading, spacing: 18) {
                        if event.moderation?.held != true { EventAuthorizedCoverView(event: event) }
                        EventScheduleView(event: event)
                        FeatureRowLabel(title: event.location.label, symbol: "mappin.and.ellipse", subtitle: "Meeting place")
                        if event.cancelled { StatusPill(title: "Cancelled", symbol: "calendar.badge.exclamationmark", color: Aurora.rose) }
                        if event.rsvpStatus == .going { EventCountdownView(value: loadedEvent) }
                        if event.rsvpStatus == .declined {
                            StatusPill(title: "Not going", symbol: "minus.circle", color: Aurora.supporting)
                        }
                        if !event.description.isEmpty {
                            DisclosureGroup("About this event") { Text(event.description).padding(.top, 8) }
                        }
                        FeatureDetails("Audience & access") {
                            LabeledContent("Visibility", value: event.visibility.capitalized)
                            LabeledContent("Time zone", value: event.timezone.replacingOccurrences(of: "_", with: " "))
                            LabeledContent("Capacity", value: String(event.capacity))
                            Text("Private links don't grant access. Public and unlisted details include the venue.")
                            if event.access.invited {
                                Text("Invitation expiry ends invitation access only. Going RSVP or organizer membership can remain.")
                            }
                        }
                        EventInvitationDeadlineView(event: event)
                    }.padding(18).background(AuroraSurface())
                    if event.requiresReconfirmation == true {
                        Label("Plans changed. Review the date, venue and route before confirming again.",
                            systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    DisclosureGroup(isExpanded: $planExpanded) {
                        if let route = event.route { FixedEventPlanPreview(event: event, route: route) }
                        else { Text("No route has been added.").font(.subheadline) }
                        FeatureDetails("Fixed venue coordinates") {
                            Text("\(event.location.latitude), \(event.location.longitude)")
                            Text("Radius: \(event.location.radiusMeters)m. Viewing does not use device GPS.")
                        }
                    } label: { Label("Venue & route", systemImage: "map") }
                        .padding(18).background(AuroraSurface())
                    if session.client?.progressDeadlinesEnabled(event) == true, event.moderation?.held != true, event.access.canViewProgress {
                        DisclosureGroup("Shared progress") {
                            NavigationLink("View, share or withdraw progress") { EventProgressView(eventID: event.id) }
                            NavigationLink("Local checkpoint hints") { EventLocalEligibilityView(eventID: event.id) }
                            FeatureDetails("Sharing & retention") {
                                Text("Sharing and GPS are separate opt-ins. This page does not enable either.")
                                Text("Shared checkpoints expire no later than event end + 24 hours, or earlier on withdrawal, cancellation, moderation or a shorter schedule. Extending an event does not extend a claim.")
                                Text("Expiry is a retention deadline, not proof of arrival. Private badges are separate.")
                            }
                        }.padding(18).background(AuroraSurface())
                    }
                    DisclosureGroup("Activities & extras") {
                        NavigationLink("Team colors") { EventSocialView(eventID: event.id, surface: .teams) }
                            .disabled(community.config?.eventTeamsEnabled != true || event.settings?.eventTeamsEnabled != true || event.moderation?.held == true)
                        NavigationLink("Checkpoint collection") { EventSocialView(eventID: event.id, surface: .collection) }
                            .disabled(community.config?.eventCollectionsEnabled != true || event.settings?.eventCollectionsEnabled != true || event.moderation?.held == true)
                        NavigationLink("GPS checkpoint hunt") { EventGPSHuntView(eventID: event.id) }
                            .disabled(community.config?.eventCollectionsEnabled != true || event.settings?.eventCollectionsEnabled != true || event.route?.published != true || event.moderation?.held == true)
                        NavigationLink("Guestbook") { EventSocialView(eventID: event.id, surface: .guestbook) }
                            .disabled(community.config?.eventGuestbookAvailable != true || event.settings?.eventGuestbookAvailable != true || event.moderation?.held == true)
                        NavigationLink("Display plan") { EventSocialView(eventID: event.id, surface: .display) }
                            .disabled(community.config?.eventDisplayPlanningEnabled != true || event.settings?.eventDisplayPlanningEnabled != true || event.moderation?.held == true)
                        NavigationLink("Your private recap") { EventSocialView(eventID: event.id, surface: .recap) }
                            .disabled(community.config?.eventRecapsEnabled != true || event.settings?.eventRecapsEnabled != true || event.access.canViewRecap != true || event.moderation?.held == true)
                        if event.settings?.accountAwardsEnabled == true, event.moderation?.held != true {
                            NavigationLink("Collect an event badge") { EventAwardCollectionView(eventID: event.id) }
                        }
                        Text("Each activity asks for its own consent. Unavailable options are disabled.").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).background(AuroraSurface())
                    DisclosureGroup("Hosts") {
                        ForEach(event.organizers) { organizer in
                            LabeledContent(organizer.displayName, value: organizer.eventRole.rawValue)
                            if community.config?.messagingEnabled == true, organizer.id != community.user?.id, event.moderation?.held != true {
                                Button("Message \(organizer.displayName)") {
                                    chatSelection = ChatScreenSelection(context: .direct(peer: organizer.id, event: event.id), title: "Private organizer question")
                                }
                            }
                        }
                    }.padding(18).background(AuroraSurface())
                    if community.config?.messagingEnabled == true, community.config?.eventChatsEnabled == true, event.moderation?.held != true {
                            Button {
                                session.run({ client in
                                    let room = try await client.openEventRoom(event.id)
                                    try session.checked(client)
                                    chatSelection = ChatScreenSelection(context: .room(room.id), title: room.title)
                                })
                            } label: {
                                FeatureRowLabel(title: "Event chat", symbol: "bubble.left.and.bubble.right",
                                    subtitle: "Join the group conversation")
                                    .padding(18).background(AuroraSurface())
                            }.buttonStyle(AuroraTileButton()).disabled(session.busy || event.cancelled || event.requiresReconfirmation == true ||
                                (event.access.role == nil && event.rsvpStatus != .going))
                    }
                    if event.moderation?.held != true {
                        NavigationLink { EventGalleryView(eventID: event.id, organizer: false) } label: {
                            FeatureRowLabel(title: "Photos", symbol: "photo.on.rectangle",
                                subtitle: "Event gallery").padding(18).background(AuroraSurface())
                        }.buttonStyle(AuroraTileButton())
                    }
                    if event.access.canManage && !event.cancelled {
                        DisclosureGroup("Host tools") {
                            if event.moderation?.held != true {
                                NavigationLink("People & invitations") { EventRosterView(eventID: event.id) }
                                NavigationLink("Add photos & cover") { EventGalleryView(eventID: event.id, organizer: true) }
                            }
                            if event.access.role == .owner {
                                NavigationLink("Co-hosts & ownership") {
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
                            Button("Edit event") { editingEvent = event }
                            if event.access.canManageRoute, event.route != nil, event.badges != nil {
                                Button("Add or edit a route") { planningEvent = event }
                                    .disabled(community.config?.eventsEnabled != true)
                            }
                            DisclosureGroup("Invite or manage access") {
                            TextField("Account ID", text: $target).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Picker("Action", selection: $action) {
                                ForEach(CommunityFeatureClient.OrganizerAction.allCases.filter {
                                    [.invite, .revokeInvite, .removeParticipant].contains($0) &&
                                        (event.access.role == .owner || [.invite, .revokeInvite].contains($0))
                                }) { Text($0.label).tag($0) }
                            }
                            if session.client?.eventReportsAvailable == true, event.settings?.eventReportsEnabled == true {
                                NavigationLink("Report event") { EventReportComposerView(event: event) }
                            }
                            if action == .invite, session.client?.invitationDeadlinesEnabled(event) == true {
                                Toggle("Custom invitation expiry", isOn: $customInviteDeadline)
                                if customInviteDeadline {
                                    DatePicker("Invitation deadline (UTC)", selection: $inviteDeadline, displayedComponents: [.date, .hourAndMinute])
                                        .environment(\.timeZone, .gmt)
                                    Text("Within 30 days. Changing expiry invalidates the old invitation notice.").font(.caption)
                                } else {
                                    Text("New invitations last 7 days. Resending keeps the current expiry.").font(.caption)
                                }
                            }
                            Button("Review organizer action") { organize(event) }
                            Text("Revoking an invite does not remove a going participant. Removal is a separate action.")
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if event.access.role == .owner {
                                Button("Cancel event", role: .destructive) {
                                    confirm("Cancel event", "Cancel this event at revision \(event.revision)?") { client in
                                        let cancelled = try await client.cancelEvent(event)
                                        try session.checked(client); value = try TimedCatalogEvent(cancelled)
                                    }
                                }
                            }
                        }.padding(18).background(AuroraSurface()).disabled(session.busy)
                    }
                    if let origin = community.origin {
                        ShareLink(item: origin.url.appendingPathComponent("events").appendingPathComponent(event.id.uuidString.lowercased())) {
                            Label("Share invitation", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        if event.visibility == "private" { Text("A private link doesn't grant access.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } else {
                ContentUnavailableView("Event unavailable", systemImage: "calendar",
                    description: Text(session.failure ?? "Sign in and refresh current access."))
            }
          }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if available, let event = value?.event { rsvpBar(event) }
        }
    }
    private func rsvpBar(_ event: CatalogEvent) -> some View {
        VStack(spacing: 8) {
            if event.cancelled {
                Label("Event cancelled", systemImage: "calendar.badge.exclamationmark").foregroundStyle(Aurora.rose)
            } else if event.moderation?.held == true {
                Label("Event on hold", systemImage: "lock").foregroundStyle(Aurora.rose)
            } else if event.rsvpStatus == .going && event.requiresReconfirmation != true {
                Label("You're going", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Aurora.mint)
            } else {
                Button(event.requiresReconfirmation == true ? "Review & confirm" : "I'm going") { rsvp(event, status: .going) }
                    .buttonStyle(AuroraPrimaryButton())
                    .disabled(session.busy || !event.access.canRsvp || event.cancelled || event.moderation?.held == true)
                    .accessibilityIdentifier("event-rsvp")
                if !event.access.canRsvp {
                    Text("RSVP isn't available right now.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if event.rsvpStatus != nil || event.access.member {
                Button("Can't make it", role: .destructive) { rsvp(event, status: .declined) }
                    .font(.subheadline).frame(minHeight: 44).disabled(session.busy)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity)
        .background(Aurora.surface)
    }
    private var eventLifecycle: some View {
        eventForm
        .modernScene().navigationTitle("Event")
        .toolbar {
            Button(action: load) { Label("Refresh event", systemImage: "arrow.clockwise") }.disabled(session.busy || !available)
        }
        .onChange(of: value?.event.requiresReconfirmation, initial: true) { _, review in
            if review == true { planExpanded = true }
        }
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
        confirm(status == .going ? "Join this event?" : "Leave this event?",
            status == .going ? "Confirm \(event.title)'s date, venue and route. GPS and progress sharing are separate choices." :
                "Withdraw your RSVP for \(event.title)?") { client in
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
    var created: ((CatalogEvent) -> Void)? = nil
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
    init(original: CatalogEvent?, created: ((CatalogEvent) -> Void)? = nil, saved: @escaping () -> Void) {
        self.original = original; self.created = created; self.saved = saved
    }
    var body: some View {
        NavigationStack { editorLifecycle }
    }
    private var essentialsForm: some View {
            ScrollView {
              VStack(alignment: .leading, spacing: 22) {
                if community.config?.eventsEnabled == true && !session.denied &&
                    session.client?.accountID == community.user?.id {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("What's the plan?", systemImage: "sparkles").font(.headline)
                        TextField("Give your event a name", text: $title)
                            .font(.title3.weight(.semibold)).textInputAutocapitalization(.sentences)
                            .accessibilityIdentifier("event-title")
                    }.padding(18).background(AuroraSurface())
                    VStack(alignment: .leading, spacing: 14) {
                        Label("When", systemImage: "calendar").font(.headline)
                        if let timezone = TimeZone(identifier: zone) {
                            DatePicker("Starts", selection: Binding(get: { start }, set: { start = $0; startEdited = true }))
                                .environment(\.timeZone, timezone)
                            DatePicker("Ends", selection: Binding(get: { end }, set: { end = $0; endEdited = true }))
                                .environment(\.timeZone, timezone)
                        }
                        DisclosureGroup("Time zone: \(zone.replacingOccurrences(of: "_", with: " "))") {
                            Picker("Time zone", selection: $zone) {
                                ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])).sorted(), id: \.self) {
                                    Text($0.replacingOccurrences(of: "_", with: " ")).tag($0)
                                }
                            }.pickerStyle(.menu)
                        }.font(.subheadline)
                        if original == nil {
                            Toggle("Confirm these times", isOn: Binding(get: { startEdited && endEdited },
                                set: { startEdited = $0; endEdited = $0 }))
                                .accessibilityIdentifier("event-confirm-times")
                        }
                    }.padding(18).background(AuroraSurface())
                    if let acknowledgement { Text(acknowledgement).foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Where", systemImage: "mappin.and.ellipse").font(.headline)
                        FixedVenueMapEditor(venue: $venue, enabled: community.config?.eventsEnabled == true && editingAuthorized && !requiresReload)
                        Toggle("Confirm this venue", isOn: $venueConfirmed).disabled(venue == nil)
                            .accessibilityIdentifier("event-confirm-venue")
                    }.padding(18).background(AuroraSurface())
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Who can see it?", systemImage: "person.2").font(.headline)
                        Picker("Visibility", selection: $visibility) {
                            Text("Private").tag("private"); Text("Public").tag("public")
                            if community.config?.unlistedEventsEnabled == true &&
                                (original == nil || original?.settings?.unlistedEventsEnabled == true) {
                                Text("Link only").tag("unlisted")
                            } else if original?.visibility == "unlisted" { Text("Link only").tag("unlisted") }
                        }
                        .pickerStyle(.segmented).accessibilityIdentifier("event-visibility")
                        Text(visibility == "private" ? "Invited people and members only." :
                            visibility == "unlisted" ? "Anyone with the link can see the details and venue." :
                                "Anyone can see the details and venue.")
                            .font(.caption).foregroundStyle(.secondary)
                        if visibility == "unlisted" && original?.visibility != "unlisted" {
                            Toggle("I agree to share details and venue by link", isOn: $unlistedConsent)
                        }
                    }.padding(18).background(AuroraSurface())
                    DisclosureGroup("Add details") {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("What should people know? (optional)", text: $description, axis: .vertical)
                                .lineLimit(3...8)
                            Stepper("Capacity: \(capacity)", value: $capacity, in: 1...10000)
                            if community.config?.eventTemplatesEnabled == true {
                                Picker("Event type", selection: $kind) {
                                    Text("Meetup").tag("meetup"); Text("Group ride").tag("group-ride")
                                }
                            }
                            Text("Photos, routes and activities come next.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    .padding(18).background(AuroraSurface())
                    if let failure = session.failure {
                        Text(failure).foregroundStyle(.orange)
                        if requiresReload { Text("Your draft is kept. Close and reopen the current event before saving.").font(.caption) }
                    }
                    if session.busy { ProgressView() }
                } else { Text(session.failure ?? "Events are unavailable.") }
              }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let reviewIssue { Text(reviewIssue).font(.caption).foregroundStyle(.secondary) }
                    Button(original == nil ? "Preview invitation" : "Review changes") {
                        do {
                            guard let input = definitionInput, let client = session.client else { throw BackpackError.invalid("Choose explicit times, venue and current access first.") }
                            review = try NativeEventDefinitionReview(input: input, original: original, scope: client.instanceID)
                        } catch { session.run { _ in throw error } }
                    }.buttonStyle(AuroraPrimaryButton())
                        .disabled(session.busy || !editingAuthorized || requiresReload || reviewIssue != nil)
                        .accessibilityIdentifier("event-preview-invitation")
                    Button("Cancel", role: .cancel) { dismiss() }
                        .frame(minHeight: 44).disabled(session.busy)
                        .accessibilityIdentifier("event-create-cancel")
                }.padding(.horizontal, 20).padding(.vertical, 12).background(Aurora.surface)
            }
    }
    private var initializedEditor: some View {
            essentialsForm
            .modernScene().navigationTitle(original == nil ? "Create event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(session.busy)
            .task {
                guard !loaded else { return }
                loaded = true; initialRevision = community.accountRevision; initialAccount = community.user?.id; session.bind(community)
                if original == nil { zone = TimeZone.current.identifier }
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
    }
    private var editorLifecycle: some View {
            initializedEditor
            .onChange(of: community.accountRevision) { _, value in if initialRevision != value { session.clear(); dismiss() } }
            .onChange(of: community.user?.id) { _, value in if initialAccount != value { session.clear(); dismiss() } }
            .onChange(of: inputFingerprint) { _, _ in review = nil }
            .onChange(of: venueConfirmed) { _, _ in review = nil }
            .onChange(of: venue?.latitude) { _, _ in venueConfirmed = false }
            .onChange(of: venue?.longitude) { _, _ in venueConfirmed = false }
            .onChange(of: venue?.radiusMeters) { _, _ in venueConfirmed = false }
            .onChange(of: venue?.label) { _, _ in venueConfirmed = false }
            .onChange(of: community.config?.eventsEnabled) { _, enabled in if enabled != true { review = nil; venue = nil; session.clear(); dismiss() } }
            .onChange(of: community.config?.unlistedEventsEnabled) { _, _ in review = nil; unlistedConsent = false }
            .onChange(of: session.denied) { _, denied in if denied { review = nil; venue = nil; dismiss() } }
            .task(id: "\(community.accountRevision):\(original?.id.uuidString ?? "")") {
                await monitorOwnerAccess()
            }
            .onDisappear { if review == nil { session.clear() } }
            .sheet(item: $review) { captured in
                EventDefinitionReviewView(captured: captured, busy: session.busy, back: { review = nil }) {
                    guard captured.matches(definitionInput), venueConfirmed else { review = nil; return }
                    session.run(expected: captured.scope) { client in
                        do {
                            let stored = try await client.saveEvent(captured.input, original: original)
                            try session.checked(client)
                            let unchanged = captured.matches(definitionInput)
                            review = nil
                            if unchanged { if original == nil { created?(stored) }; dismiss(); saved() }
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
    private func monitorOwnerAccess() async {
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
    private var reviewIssue: String? {
        EventCreationReadiness.issue(input: definitionInput, startChosen: original != nil || startEdited,
            endChosen: original != nil || endEdited, venueConfirmed: venueConfirmed, existingVisibility: original?.visibility)
    }
    private var inputFingerprint: Data? {
        guard let input = definitionInput else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(input)
    }
}
