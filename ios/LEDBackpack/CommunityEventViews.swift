import SwiftUI
import BackpackProtocol

@MainActor
struct CommunityEventsView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var session = CommunityFeatureSession()
    @State private var list = CatalogEventList.accessible
    @State private var events: [TimedCatalogEvent] = []
    @State private var offset = 0
    @State private var creating = false
    var body: some View {
        List {
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
    @State private var value: TimedCatalogEvent?
    @State private var editingEvent: CatalogEvent?
    @State private var planningEvent: CatalogEvent?
    @State private var chatSelection: ChatScreenSelection?
    private var editing: Bool { editingEvent != nil || planningEvent != nil }
    @State private var target = ""
    @State private var action = CommunityFeatureClient.OrganizerAction.invite
    @State private var pending: Confirmation?
    @State private var notice: String?
    private struct Confirmation {
        let title, message: String
        let scope: UUID
        let work: @MainActor (CommunityFeatureClient) async throws -> Void
    }
    var body: some View {
        Form {
            if community.config?.eventsEnabled == true && community.signedIn && !session.denied &&
                session.client?.accountID == community.user?.id {
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if session.busy { ProgressView() }
                if let value {
                    let event = value.event
                    Section(event.title) {
                        Text(event.description)
                        Text(event.startsAtISO).font(.caption)
                        Text("Until \(event.endsAtISO) / \(event.timezone)").font(.caption)
                        Text("Status: \(event.status.rawValue)")
                        if event.rsvpStatus == .going { EventCountdownView(value: value) }
                        LabeledContent("Your RSVP", value: event.rsvpStatus?.rawValue ?? "None")
                        LabeledContent("Visibility", value: event.visibility)
                        LabeledContent("Capacity", value: String(event.capacity))
                        Text("Venue: \(event.location.label)")
                        Text("\(event.location.latitude), \(event.location.longitude) / radius \(event.location.radiusMeters)m").font(.caption)
                        Text("Fixed organizer venue; this view does not access device GPS.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("RSVP") {
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
                            if community.config?.messagingEnabled == true, organizer.id != community.user?.id {
                                Button("Private question to \(organizer.displayName)") {
                                    chatSelection = ChatScreenSelection(context: .direct(peer: organizer.id, event: event.id), title: "Private organizer question")
                                }
                            }
                        }
                    }
                    if community.config?.messagingEnabled == true, community.config?.eventChatsEnabled == true {
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
                            Button("Edit / reschedule event") { editingEvent = event }
                            if event.access.canManageRoute, event.route != nil, event.badges != nil {
                                Button("Plan venue route & checkpoints") { planningEvent = event }
                                    .disabled(community.config?.eventsEnabled != true)
                            }
                            TextField("Target account UUID", text: $target).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Picker("Action", selection: $action) {
                                ForEach(CommunityFeatureClient.OrganizerAction.allCases.filter {
                                    event.access.role == .owner || [.invite, .revokeInvite].contains($0)
                                }) { Text($0.label).tag($0) }
                            }
                            Button("Review organizer action") { organize(event) }
                            Text("Revoking an invitation can leave a going member's access intact. Explicit participant removal is separate. Co-organizers are event-scoped, not account admins.")
                                .font(.caption).foregroundStyle(.secondary)
                            if event.access.role == .owner {
                                Button("Cancel event", role: .destructive) {
                                    confirm("Cancel event", "Cancel this event at revision \(event.revision)?") { client in _ = try await client.cancelEvent(event) }
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
        .modernScene().navigationTitle("Event")
        .navigationDestination(item: $chatSelection) { item in CommunityConversationView(context: item.context, title: item.title) }
        .task(id: "\(community.accountRevision):\(community.user?.id.uuidString ?? ""):\(community.config?.eventsEnabled == true)") {
            value = nil; pending = nil; notice = nil; session.bind(community)
            editingEvent = nil
            planningEvent = nil
            guard community.config?.eventsEnabled == true else { return }
            load()
        }
        .task(id: "\(phase):\(community.accountRevision):\(community.config?.eventsEnabled == true)") {
            guard phase == .active, community.config?.eventsEnabled == true, community.signedIn else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !editing && !session.busy && !session.denied && pending == nil { load() }
            }
        }
        .onChange(of: session.denied) { _, denied in if denied { value = nil; editingEvent = nil; planningEvent = nil; pending = nil } }
        .onDisappear { if !editing { session.clear(); value = nil }; pending = nil; target = "" }
        .sheet(item: $editingEvent, onDismiss: load) { original in
            CommunityEventEditor(original: original) { editingEvent = nil }
        }
        .sheet(item: $planningEvent, onDismiss: load) { original in
            EventRoutePlannerView(original: original) { planningEvent = nil }
        }
        .alert("Confirm event action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending) { value in
                Button(value.title) { session.run(expected: value.scope, value.work, success: load) }
                Button("Cancel", role: .cancel) {}
            } message: { Text($0.message) }
    }
    private func load() {
        session.run { client in
            let event: CatalogEvent
            do { event = try await client.event(id) }
            catch let error as CommunityFailure where error.status == 404 {
                value = nil; editingEvent = nil; planningEvent = nil
                throw error
            }
            try session.checked(client); value = try TimedCatalogEvent(event)
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
            try session.checked(client); value = try TimedCatalogEvent(updated)
        }
    }
    private func organize(_ event: CatalogEvent) {
        let selected = action, text = target
        confirm(selected.label,
            "Apply \(selected.label.lowercased()) to \(text)? Ownership transfer grants event-owner control. Changes use revision \(event.revision); conflicts require a refresh.") { client in
                guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw BackpackError.invalid("Enter a target account UUID.")
                }
                try await client.organize(event, target: id, action: selected)
                try session.checked(client)
                notice = selected == .revokeInvite ? "Invitation revoked. A going member may retain access; participant removal is separate." : "Organizer action confirmed."
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
    @State private var confirming = false
    @State private var scope: UUID?
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
                    Picker("Visibility", selection: $visibility) { Text("Private").tag("private"); Text("Public").tag("public") }
                    Stepper("Capacity \(capacity)", value: $capacity, in: 1...10000)
                    Picker("Event timezone", selection: $zone) {
                        ForEach(Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    if let timezone = TimeZone(identifier: zone) {
                        DatePicker("Starts", selection: Binding(get: { start }, set: { start = $0; startEdited = true })).environment(\.timeZone, timezone)
                        DatePicker("Ends", selection: Binding(get: { end }, set: { end = $0; endEdited = true })).environment(\.timeZone, timezone)
                    }
                    Section("Fixed organizer-authored venue") {
                        FixedVenueMapEditor(venue: $venue, enabled: community.config?.eventsEnabled == true)
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
                        scope = session.client?.instanceID; confirming = true
                    }.disabled(session.busy || !venueConfirmed || venue == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            }
            .onChange(of: community.accountRevision) { _, value in if initialRevision != value { session.clear(); dismiss() } }
            .onChange(of: community.user?.id) { _, value in if initialAccount != value { session.clear(); dismiss() } }
            .onDisappear { session.clear() }
            .confirmationDialog("Save this event?", isPresented: $confirming) {
                Button(original == nil ? "Create event" : "Save revision-checked update") {
                    session.run(expected: scope, { client in
                        guard venueConfirmed, let venue else {
                            throw BackpackError.invalid("Choose and review a fixed venue in the map/place controls.")
                        }
                        let input = CatalogEventInput(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                            startsAtISO: !startEdited ? (original?.startsAtISO ?? CatalogEventTime.wire(start)) : CatalogEventTime.wire(start),
                            endsAtISO: !endEdited ? (original?.endsAtISO ?? CatalogEventTime.wire(end)) : CatalogEventTime.wire(end),
                            timezone: zone, visibility: visibility, capacity: capacity,
                            location: venue, expectedRevision: original?.revision,
                            kind: community.config?.eventTemplatesEnabled == true ? kind : nil)
                        _ = try await client.saveEvent(input, original: original)
                    }, success: { dismiss(); saved() })
                }
            } message: { Text("Private is the default. Public events expose their fixed venue/details. No RSVP, discovery, GPS or global admin role is granted by saving.") }
        }
    }
}
