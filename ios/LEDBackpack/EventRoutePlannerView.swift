import SwiftUI
import MapKit
import BackpackProtocol

private enum PlannerTapMode: String, CaseIterable, Identifiable {
    case select = "Move selected point", start = "Set start gate", checkpoint = "Drop checkpoint on route"
    case finish = "Set finish gate", shape = "Add draggable route handle", geometry = "Manual guide point", radius = "Set selected circle edge"
    var id: String { rawValue }
}
private enum PlannerArtworkTarget: Identifiable {
    case checkpoint(UUID), reward(UUID)
    var id: String {
        switch self { case .checkpoint(let id): return "checkpoint:\(id)"; case .reward(let id): return "reward:\(id)" }
    }
}

@MainActor
struct EventRoutePlannerView: View {
    @StateObject private var store = EventRoutePlannerStore()
    let original: CatalogEvent
    let saved: () -> Void
    var body: some View { EventRoutePlannerContent(store: store, session: store.session, original: original, saved: saved) }
}

@MainActor
private struct EventRoutePlannerContent: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @ObservedObject var store: EventRoutePlannerStore
    @ObservedObject var session: CommunityFeatureSession
    let original: CatalogEvent
    let saved: () -> Void
    @State private var imagery = false
    @State private var mode = PlannerTapMode.select
    @State private var selected = ""
    @State private var fit = UUID()
    @State private var localFailure: String?
    @State private var artworkTarget: PlannerArtworkTarget?
    @State private var saveReview: NativeEventRouteReview?
    @State private var discardReview = false
    @State private var reloadRevision = 0
    @State private var reviewingServer: CatalogEvent?
    @State private var loaded = false
    @State private var numericLatitude = ""
    @State private var numericLongitude = ""
    @StateObject private var road = EventRoadRouteStore()
    @State private var roadMode = EventRoadMode.driving
    @State private var endpointChoice: EventCheckpointKind?
    @State private var offRouteCheckpoints: Set<UUID> = []
    private var endpoints: [EventCoordinate] {
        guard let draft = store.draft else { return [] }
        return [draft.checkpoints.first(where: { $0.kind == .start })?.point,
                draft.checkpoints.first(where: { $0.kind == .finish })?.point].compactMap { $0 }
    }
    private var editable: Bool { !store.readOnly && !store.conflict && !store.saving && !session.denied }
    private var structureEditable: Bool { editable && !store.structureLocked }
    private var routeFingerprint: Data? {
        guard let draft = store.draft else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(draft.body.normalized())
    }
    private var pins: [OrganizerMapPin] {
        guard let draft = store.draft else { return [] }
        let venue = draft.original.location
        return [OrganizerMapPin(id: "venue", title: venue.label, symbol: "V",
            point: EventCoordinate(latitude: venue.latitude, longitude: venue.longitude), radius: venue.radiusMeters, draggable: false)]
            + draft.checkpoints.map { OrganizerMapPin(id: "c:\($0.id)", title: $0.title,
                symbol: $0.kind == .start ? "S" : $0.kind == .finish ? "F" : String($0.order + 1),
                point: $0.point, radius: $0.radiusMeters, draggable: structureEditable) }
            + (road.result == nil ? draft.geometry.enumerated().map { index, value in
                OrganizerMapPin(id: "g:\(value.id)", title: "Guide point \(index + 1)", symbol: "R",
                    point: value.point, radius: 0, draggable: structureEditable)
            } : [])
            + road.waypoints.enumerated().map { index, value in
                OrganizerMapPin(id: "via:\(value.id)", title: "Drag route handle \(index + 1)", symbol: "↔",
                    point: value.point, radius: 0, draggable: structureEditable && !road.busy)
            }
    }
    var body: some View {
        NavigationStack { presentedPlanner }
    }
    private var plannerScroll: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AuroraHeading(eyebrow: "Organizer studio", title: "Shape the", accent: "experience.")
                    if let draft = store.draft, !session.denied, community.config?.eventsEnabled == true {
                        overview(draft)
                        if let failure = session.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                        if let failure = localFailure, failure != session.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                        if session.busy { ProgressView(store.saving ? "Saving captured revision..." : "Checking event/artwork...") }
                        if store.readOnly { Label("Owner permission is unavailable. Saves are stopped.", systemImage: "lock").foregroundStyle(.orange) }
                        if store.conflict {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("The server event changed. Your draft is retained.", systemImage: "exclamationmark.triangle")
                                if let latest = store.latest {
                                    Text("Observed server revision \(latest.revision), \(latest.route?.checkpoints.count ?? 0) checkpoints; draft revision \(draft.original.revision).")
                                        .font(.caption)
                                    Text("Current server event: \(latest.title), \(latest.location.label), \(latest.startsAtISO). Nothing in your draft is rebased automatically.")
                                        .font(.caption)
                                }
                                Button("Fetch current server plan for review") { store.refreshPermission() }.disabled(session.busy)
                                Button("Inspect server plan without discarding") { reviewingServer = store.latest }.disabled(store.latest == nil)
                                Button("Discard draft and load reviewed server version") {
                                    reloadRevision = store.latest?.revision ?? 0; discardReview = true
                                }.disabled(store.latest == nil)
                            }.padding(16).glassPanel()
                        }
                        if store.structureLocked {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Shared progress locks fixed checkpoint details and guide geometry. Artwork/finish rewards may still be repaired.")
                                Button("Restore captured fixed geometry, keep artwork/rewards") {
                                    do {
                                        guard editable, var value = store.draft else { throw BackpackError.invalid("Review current owner access before restoring fixed geometry.") }
                                        try value.restoreFixedGeometryKeepingArtwork(); store.draft = value; localFailure = nil; fit = UUID()
                                    }
                                    catch { localFailure = error.localizedDescription }
                                }.disabled(!editable)
                            }.font(.caption).padding(16).glassPanel()
                        }
                        mapPanel(draft)
                        DisclosureGroup("Advanced numeric fixed points (optional)") {
                            Text("Numeric fixed points (no maps/search needed)").font(.headline)
                            TextField("Explicit decimal latitude", text: $numericLatitude).keyboardType(.numbersAndPunctuation)
                            TextField("Explicit decimal longitude", text: $numericLongitude).keyboardType(.numbersAndPunctuation)
                            HStack {
                                Button("Add start") { addNumeric(.start) }
                                Button("Add intermediate") { addNumeric(.checkpoint) }
                                Button("Add finish") { addNumeric(.finish) }
                            }
                            Button("Move selected stage / guide to typed coordinates") {
                                do { move(selected, try NativeEventFixedPointInput.parse(latitude: numericLatitude, longitude: numericLongitude)) }
                                catch { localFailure = error.localizedDescription }
                            }
                            Button("Add typed guide point") {
                                edit(structural: true) {
                                    guard $0.geometry.count < 200 else { throw BackpackError.invalid("Use at most 200 guide points.") }
                                    $0.geometry.append(EventGeometryPoint(point: try NativeEventFixedPointInput.parse(latitude: numericLatitude, longitude: numericLongitude)))
                                }
                            }
                        }.padding(16).glassPanel().disabled(!structureEditable)
                        checkpointPanel(draft)
                        DisclosureGroup("Advanced manual route geometry") { geometryPanel(draft) }
                        rewardsPanel(draft)
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Publish checkpoint plan", isOn: Binding(get: { store.draft?.published ?? false },
                                set: { value in edit(structural: true) { $0.published = value } })).disabled(!structureEditable)
                            InteractionExplanation("Publish needs start first and finish last. Organizer lines are not navigation or a safe-route guarantee.", details: "Publishing requires exactly one start first and one finish last. Guide lines are organizer-authored, not navigation or a safe-routing promise. Claims/rewards remain self-reported, not certified attendance.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Review and save route") {
                                do { saveReview = try NativeEventRouteReview(draft) } catch { localFailure = error.localizedDescription }
                            }.buttonStyle(AuroraPrimaryButton())
                                .disabled(!editable || session.busy || road.busy || road.needsRegeneration || !offRouteCheckpoints.isEmpty || store.loadingArtwork || (store.structureLocked && !draft.fixedGeometryMatchesOriginal))
                            Button("Refresh permissions / compare revision") { store.refreshPermission() }.disabled(session.busy)
                            Button("Refresh artwork availability") { store.resolveArtwork() }.disabled(session.busy)
                        }.padding(18).glassPanel()
                    } else { Text(session.failure ?? "This server/event has not enabled owner route planning.") }
                }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
    }
    private var configuredPlanner: some View {
            plannerScroll
            .modernScene().navigationTitle("Plan event")
            .toolbar { Button("Close") { dismiss() }.disabled(store.saving) }
            .interactiveDismissDisabled(store.saving)
            .task {
                guard !loaded else { return }
                loaded = true; store.bind(community, event: original)
            }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if saveReview == nil && !discardReview && reviewingServer == nil && !session.busy { store.refreshPermission() }
                }
            }
            .onChange(of: session.busy) { _, busy in if !busy { store.operationEnded() } }
            .onChange(of: session.denied) { _, denied in if denied { road.clear(); store.clear(); artworkTarget = nil; reviewingServer = nil; imagery = false } }
            .onChange(of: store.readOnly) { _, value in if value { road.clear(); artworkTarget = nil; reviewingServer = nil; imagery = false; saveReview = nil } }
            .onChange(of: store.conflict) { _, value in if value { road.cancel(); saveReview = nil; artworkTarget = nil } }
            .onChange(of: endpoints) { _, _ in
                let regenerate = road.result != nil || road.needsRegeneration
                road.endpointsChanged()
                if regenerate && imagery && phase == .active && structureEditable { generateRoadRoute() }
            }
            .onChange(of: store.draft?.checkpoints.map(\.id)) { _, ids in offRouteCheckpoints.formIntersection(Set(ids ?? [])) }
            .onChange(of: roadMode) { _, _ in road.endpointsChanged() }
            .onChange(of: imagery) { _, value in if !value { road.cancel(); endpointChoice = nil } }
            .onChange(of: phase) { _, value in if value != .active { road.cancel(); endpointChoice = nil; imagery = false; saveReview = nil } }
            .onChange(of: store.structureLocked) { _, locked in if locked { road.cancel(); endpointChoice = nil } }
            .onChange(of: session.failure) { _, value in if value != nil { saveReview = nil } }
            .onChange(of: routeFingerprint) { _, _ in saveReview = nil }
    }
    private var presentedPlanner: some View {
            configuredPlanner
            .onChange(of: community.accountRevision) { _, _ in road.clear(); store.clear(); dismiss() }
            .onChange(of: community.user?.id) { _, id in if id != session.client?.accountID { store.clear(); dismiss() } }
            .onChange(of: community.config?.eventsEnabled) { _, value in
                if value != true { artworkTarget = nil; store.clear(); imagery = false; dismiss() }
            }
            .onDisappear { road.cancel(); if artworkTarget == nil && reviewingServer == nil && saveReview == nil && endpointChoice == nil { store.clear() } }
            .sheet(isPresented: Binding(get: { endpointChoice != nil }, set: { if !$0 { endpointChoice = nil } })) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(endpointChoice == .start ? "Choose start location" : "Choose destination").font(.title2.bold())
                        Text("Only this typed place search is sent to Apple. No device location, account, event URL or participant position is supplied.").font(.caption)
                        OrganizerPlaceSearchView { place in
                            guard let kind = endpointChoice, structureEditable, imagery, phase == .active else { endpointChoice = nil; return }
                            edit(structural: true) { try $0.setEndpoint(kind, at: place.point, name: place.name) }
                            endpointChoice = nil; fit = UUID()
                        }
                        Spacer()
                    }.padding(20).navigationTitle("Find a place")
                        .toolbar { Button("Cancel") { endpointChoice = nil } }
                }
            }
            .sheet(item: $artworkTarget) { target in
                if let client = session.client, let event = store.draft?.original {
                    RouteArtworkPicker(client: client, event: event) { choice in
                        guard editable else { localFailure = "Review changed permissions/revision before choosing artwork."; artworkTarget = nil; return }
                        edit(structural: false) { draft in
                            switch target {
                            case .checkpoint(let id):
                                guard let index = draft.checkpoints.firstIndex(where: { $0.id == id }) else { throw BackpackError.invalid("Checkpoint was removed.") }
                                set(choice, checkpoint: &draft.checkpoints[index])
                            case .reward(let id):
                                guard let index = draft.rewards.firstIndex(where: { $0.id == id }) else { throw BackpackError.invalid("Reward was removed.") }
                                set(choice, reward: &draft.rewards[index])
                            }
                        }
                        if let choice { store.remember(choice) }; artworkTarget = nil
                    }
                }
            }
            .sheet(item: $reviewingServer) { event in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Server revision \(event.revision)").font(.headline)
                            Text(event.title).font(.title2.bold())
                            Text("\(event.startsAtISO) / \(event.timezone)").font(.caption)
                            if let route = event.route { FixedEventPlanPreview(event: event, route: route) }
                            Text("Your local draft is unchanged.").font(.caption).foregroundStyle(Aurora.mint)
                        }.padding(20)
                    }.modernScene().navigationTitle("Review server plan")
                        .toolbar { Button("Done") { reviewingServer = nil } }
                }
            }
            .sheet(item: $saveReview) { captured in
                EventRouteReviewView(captured: captured, back: { saveReview = nil }) {
                    guard editable, captured.matches(store.draft) else { saveReview = nil; return }
                    store.save(captured: captured) { saveReview = nil; dismiss(); saved() }
                }
            }
            .confirmationDialog("Discard local route edits?", isPresented: $discardReview) {
                Button("Reload reviewed revision \(reloadRevision)", role: .destructive) {
                    store.reloadDiscardingDraft(reviewedRevision: reloadRevision); fit = UUID()
                }
            } message: { Text("Only the version you reviewed is loaded. A newer unseen revision requires another review.") }
    }
    private func overview(_ draft: EventRouteDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusPill(title: "FIXED EVENT PLAN", symbol: "map")
            Text(draft.original.title).font(.title2.bold())
            Text("\(draft.original.startsAtISO) / \(draft.original.timezone)").font(.caption)
            Text("\(draft.original.visibility.capitalized) / \(draft.original.location.label)").font(.subheadline)
            Text("No participant pins, GPS collection, directions or location sharing. Venue changes are saved separately in event details; this route draft never silently rebases.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).glassPanel()
    }
    private func mapPanel(_ draft: EventRouteDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Apple Maps, place search and route directions", isOn: $imagery)
            InteractionExplanation("Apple receives map/search/routing coordinates, not account tokens, private event text, participant location or GPS tracks.", details: "Apple receives map viewports, typed place searches and chosen start/destination/shaping coordinates for directions. No account token, private event text, participant/device location or GPS track is supplied.")
                .font(.caption).foregroundStyle(.secondary)
            if imagery && phase == .active {
                roadControls(draft)
                Picker("Map action", selection: $mode) { ForEach(PlannerTapMode.allCases) { Text($0.rawValue).tag($0) } }
                    .disabled(!structureEditable || road.busy)
                OrganizerPlaceSearchView { place in apply(place.point) }.disabled(!structureEditable)
                OrganizerMap(pins: pins, geometry: road.result?.full ?? draft.geometry.map(\.point), editable: structureEditable && !road.busy,
                    fit: fit, reducedMotion: reducedMotion, tap: apply, moved: move, selected: { selected = $0 },
                    failed: { localFailure = $0 })
                    .frame(height: 390).clipShape(RoundedRectangle(cornerRadius: 24))
                Button("Show whole plan") { fit = UUID() }
                InteractionExplanation("Choose start and destination, then Generate route. Tap the line to add a checkpoint or drag a route handle to reshape it.", details: "Choose start and destination, Generate route, then choose Drop checkpoint and tap the blue line. To reshape: choose Add draggable route handle, tap the line and drag its handle to the road you want; the route recalculates. Start/finish pins can also be dragged. No latitude/longitude entry is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).glassPanel()
    }
    private func roadControls(_ draft: EventRouteDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { endpointChoice = .start } label: {
                    Label(draft.checkpoints.first(where: { $0.kind == .start })?.title ?? "Choose start location", systemImage: "mappin.circle")
                }
                Button { endpointChoice = .finish } label: {
                    Label(draft.checkpoints.first(where: { $0.kind == .finish })?.title ?? "Choose destination", systemImage: "flag.checkered")
                }
            }.buttonStyle(.bordered).disabled(!structureEditable || road.busy)
            Picker("Road route type", selection: $roadMode) {
                Text("Driving / group ride").tag(EventRoadMode.driving)
                Text("Walking / checkpoint game").tag(EventRoadMode.walking)
            }.disabled(!structureEditable || road.busy)
            Button(road.result == nil ? "Generate road route" : "Recalculate edited route") { generateRoadRoute() }
                .buttonStyle(.borderedProminent).disabled(!structureEditable || road.busy || endpoints.count != 2)
            if road.busy { ProgressView("Finding roads through your selected places"); Button("Cancel directions") { road.cancel() } }
            if let failure = road.failure { Text(failure).foregroundStyle(.orange) }
            if road.needsRegeneration { Text("Route edit is not yet applied. Recalculate before saving; the previous saved draft geometry remains intact.").font(.caption).foregroundStyle(.orange) }
            if let route = road.result {
                Text(String(format: "Route preview %.1f km · about %.0f minutes", route.meters / 1000, route.seconds / 60)).font(.caption)
                InteractionExplanation("Preview only, not navigation or attendance proof. Geometry is simplified; over-complex routes fail instead of truncating.", details: "Route preview only—not safe-routing certification, live navigation or a participant track. Saved geometry is simplified within10m and must fit the service's200-point limit; longer complex routes fail explicitly instead of truncating.").font(.caption)
                Button("Drop checkpoint pins along this route") { mode = .checkpoint }.disabled(road.busy || road.needsRegeneration)
                Button("Reshape route: tap line to add a draggable handle") { mode = .shape }.disabled(road.busy || road.needsRegeneration)
                ForEach(Array(road.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    HStack {
                        Text("Route handle \(index + 1): drag its ↔ pin to change roads").font(.caption)
                        Button("Remove") { road.removeShapingPoint(waypoint.id); generateRoadRoute() }.disabled(road.busy || !structureEditable)
                    }
                }
            }
            if !offRouteCheckpoints.isEmpty {
                Text("\(offRouteCheckpoints.count) checkpoint(s) are outside the recalculated route. Drag their pins onto the blue route or remove them before saving; they were not silently moved.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
    private func generateRoadRoute() {
        guard structureEditable, imagery, phase == .active, let draft = store.draft,
              let start = draft.checkpoints.first(where: { $0.kind == .start })?.point,
              let end = draft.checkpoints.first(where: { $0.kind == .finish })?.point else {
            localFailure = "Choose both start and destination with current owner access and explicit Maps consent."; return
        }
        let captured = routeFingerprint, account = community.accountRevision, revision = draft.original.revision
        road.generate(start: start, end: end, mode: roadMode, authorized: {
            guard structureEditable, imagery, phase == .active, community.accountRevision == account,
                  store.draft?.original.revision == revision, routeFingerprint == captured else {
                throw BackpackError.invalid("Route/account/permission changed during directions. Previous draft retained.")
            }
        }, apply: { route in
            guard var current = store.draft, structureEditable, routeFingerprint == captured else { throw CancellationError() }
            var offRoute: Set<UUID> = []
            for checkpoint in current.checkpoints where checkpoint.kind == .checkpoint {
                if try EventRoadGeometry.nearest(checkpoint.point, to: route.full).distance > 100 { offRoute.insert(checkpoint.id) }
            }
            current.geometry = route.saved.map { EventGeometryPoint(point: $0) }
            try current.body.validate()
            store.draft = current; offRouteCheckpoints = offRoute; fit = UUID(); localFailure = nil
            mode = .checkpoint; saveReview = nil
        })
    }
    private func checkpointPanel(_ draft: EventRouteDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Checkpoints (\(draft.checkpoints.count)/50)").font(.title3.bold())
            if draft.checkpoints.isEmpty { Text("Enable Maps, choose Add start/checkpoint/finish, then tap or search for a place.") }
            ForEach(draft.checkpoints) { checkpoint in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(checkpoint.order + 1) / \(checkpoint.kind.rawValue.capitalized)").font(.caption).foregroundStyle(Aurora.mint)
                    TextField("Checkpoint name", text: checkpointText(checkpoint.id)).disabled(!structureEditable)
                    if checkpoint.kind == .checkpoint, session.client?.eventOptionalCheckpointsAvailable == true,
                       draft.original.settings?.optionalCheckpointsEnabled == true {
                        Toggle("Optional stage — may be skipped", isOn: Binding(get: {
                            store.draft?.checkpoints.first(where: { $0.id == checkpoint.id })?.optional == true
                        }, set: { optional in
                            edit(structural: true) {
                                guard let index = $0.checkpoints.firstIndex(where: { $0.id == checkpoint.id }) else { throw BackpackError.invalid("Stage selection changed.") }
                                $0.checkpoints[index].optional = optional
                            }
                        })).disabled(!structureEditable)
                    } else if checkpoint.optional == true {
                        Text("Existing optional assignment retained; editing is not advertised by this server.").font(.caption)
                    }
                    Stepper("Radius \(Int(checkpoint.radiusMeters))m", value: checkpointRadius(checkpoint.id), in: 1...100000, step: 5)
                        .disabled(!structureEditable)
                    artworkButton(checkpoint.artwork, target: .checkpoint(checkpoint.id))
                    HStack {
                        Button("Select pin") { selected = "c:\(checkpoint.id)" }
                        if checkpoint.kind == .checkpoint {
                            Button("Earlier") { edit(structural: true) { try $0.moveCheckpoint(checkpoint.id, by: -1) } }
                            Button("Later") { edit(structural: true) { try $0.moveCheckpoint(checkpoint.id, by: 1) } }
                        }
                        Button("Remove", role: .destructive) { edit(structural: true) { $0.removeCheckpoint(checkpoint.id) } }
                    }.font(.caption).disabled(!structureEditable)
                    if selected == "c:\(checkpoint.id)" { nudgeControls(key: selected) }
                }.padding(14).glassPanel(radius: 18)
            }
        }
    }
    private func geometryPanel(_ draft: EventRouteDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planned guide shape (\(draft.geometry.count)/200)").font(.title3.bold())
            Text("These are authored guide lines, not turn-by-turn directions or a safety assessment.").font(.caption).foregroundStyle(.secondary)
            Button("Connect placed checkpoints with straight guide segments") {
                edit(structural: true) { value in value.geometry = value.checkpoints.map { EventGeometryPoint(point: $0.point) } }; fit = UUID()
            }.disabled(!structureEditable || draft.checkpoints.count < 2)
            ForEach(Array(draft.geometry.enumerated()), id: \.element.id) { index, value in
                HStack {
                    Text("Guide point \(index + 1)")
                    Spacer()
                    Button("Select") { selected = "g:\(value.id)" }
                    Button("Earlier") {
                        edit(structural: true) { draft in
                            guard let i = draft.geometry.firstIndex(where: { $0.id == value.id }), i > 0 else { throw BackpackError.invalid("No earlier guide position.") }
                            draft.geometry.swapAt(i, i - 1)
                        }
                    }.disabled(index == 0)
                    Button("Later") {
                        edit(structural: true) { draft in
                            guard let i = draft.geometry.firstIndex(where: { $0.id == value.id }), i + 1 < draft.geometry.count else { throw BackpackError.invalid("No later guide position.") }
                            draft.geometry.swapAt(i, i + 1)
                        }
                    }.disabled(index + 1 == draft.geometry.count)
                    Button("Remove", role: .destructive) { edit(structural: true) { $0.geometry.removeAll { $0.id == value.id } } }
                }.font(.caption).disabled(!structureEditable)
                if selected == "g:\(value.id)" { nudgeControls(key: selected) }
            }
        }.padding(18).glassPanel()
    }
    private func rewardsPanel(_ draft: EventRouteDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish rewards (\(draft.rewards.count)/10)").font(.title3.bold())
            Text("Optional rewards for this event's self-reported finish, not certified attendance.").font(.caption).foregroundStyle(.secondary)
            ForEach(draft.rewards) { reward in
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Reward name", text: rewardText(reward.id, description: false))
                    TextField("Description", text: rewardText(reward.id, description: true), axis: .vertical)
                    artworkButton(reward.artwork, target: .reward(reward.id))
                    Button("Remove reward", role: .destructive) { edit(structural: false) { $0.rewards.removeAll { $0.id == reward.id } } }
                }.padding(14).glassPanel(radius: 18)
            }
            Button("Add finish reward") {
                edit(structural: false) {
                    guard $0.rewards.count < 10 else { throw BackpackError.invalid("Use at most 10 finish rewards.") }
                    $0.rewards.append(EventRouteReward(title: "Finish reward", description: "Self-reported finish; not certified attendance."))
                }
            }.disabled(!editable || draft.rewards.count >= 10)
        }.disabled(!editable || session.busy)
    }
    private func artworkButton(_ reference: RouteArtworkReference?, target: PlannerArtworkTarget) -> some View {
        Button { artworkTarget = target } label: {
            Label(store.artworkLabel(reference), systemImage: reference == nil ? "photo.badge.plus" : "photo")
        }.disabled(!editable || session.busy)
    }
    private func edit(structural: Bool, _ work: (inout EventRouteDraft) throws -> Void) {
        do {
            guard editable, !structural || !store.structureLocked, var value = store.draft else {
                throw BackpackError.invalid("This draft cannot be changed until permissions/conflict/structure lock are reviewed.")
            }
            try work(&value); store.draft = value; localFailure = nil
        } catch { localFailure = error.localizedDescription }
    }
    private func addNumeric(_ kind: EventCheckpointKind) {
        edit(structural: true) {
            try $0.addCheckpoint(kind, at: NativeEventFixedPointInput.parse(latitude: numericLatitude, longitude: numericLongitude))
        }
    }
    private func apply(_ point: EventCoordinate) {
        if mode == .shape {
            do { try road.addShapingPoint(point); localFailure = nil }
            catch { localFailure = error.localizedDescription }
            return
        }
        edit(structural: true) { value in
            try point.validate()
            switch mode {
            case .start, .finish:
                try value.setEndpoint(mode == .start ? .start : .finish, at: point, name: nil)
            case .checkpoint:
                guard !road.needsRegeneration else { throw BackpackError.invalid("Recalculate the changed route before placing checkpoints.") }
                let projected = try EventRoadGeometry.nearest(point, to: road.result?.full ?? value.geometry.map(\.point))
                guard projected.distance <= 100 else { throw BackpackError.invalid("Tap the route itself to drop a checkpoint pin.") }
                try value.addCheckpoint(.checkpoint, at: projected.point)
            case .shape: break
            case .geometry:
                guard value.geometry.count < 200 else { throw BackpackError.invalid("Use at most 200 guide points.") }
                value.geometry.append(EventGeometryPoint(point: point))
            case .select:
                if !selected.isEmpty { try movePoint(selected, to: point, in: &value) }
            case .radius:
                guard let index = value.checkpoints.firstIndex(where: { "c:\($0.id)" == selected }) else {
                    throw BackpackError.invalid("Select a checkpoint pin before placing its circle edge.")
                }
                let center = value.checkpoints[index].point
                let radius = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude))
                    .distance(to: MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)))
                guard radius.isFinite, (1...100000).contains(radius) else { throw BackpackError.invalid("Choose a radius between 1m and 100km.") }
                value.checkpoints[index].radiusMeters = radius.rounded()
            }
        }
    }
    private func move(_ key: String, _ point: EventCoordinate) {
        if key.hasPrefix("via:"), let id = UUID(uuidString: String(key.dropFirst(4))) {
            do { try road.moveShapingPoint(id, to: point); generateRoadRoute() }
            catch { localFailure = error.localizedDescription }
            return
        }
        let endpoint = store.draft?.checkpoints.first(where: { "c:\($0.id)" == key })?.kind
        edit(structural: true) { value in
            let target: EventCoordinate
            if endpoint == .checkpoint {
                let projected = try EventRoadGeometry.nearest(point, to: road.result?.full ?? value.geometry.map(\.point))
                guard projected.distance <= 100 else { throw BackpackError.invalid("Drag a checkpoint onto the current route.") }
                target = projected.point
            } else { target = point }
            try movePoint(key, to: target, in: &value)
        }
        if endpoint == .checkpoint, localFailure == nil, let id = store.draft?.checkpoints.first(where: { "c:\($0.id)" == key })?.id {
            offRouteCheckpoints.remove(id)
        }
    }
    private func movePoint(_ key: String, to point: EventCoordinate, in value: inout EventRouteDraft) throws {
        try point.validate()
        if let index = value.checkpoints.firstIndex(where: { "c:\($0.id)" == key }) { value.checkpoints[index].point = point }
        else if let index = value.geometry.firstIndex(where: { "g:\($0.id)" == key }) { value.geometry[index].point = point }
        else { throw BackpackError.invalid("Select a checkpoint/guide pin. Edit the venue separately in event details.") }
    }
    private func nudgeControls(key: String) -> some View {
        HStack {
            ForEach(["North", "South", "West", "East"], id: \.self) { direction in
                Button(direction) {
                    edit(structural: true) { value in
                        guard let point = value.checkpoints.first(where: { "c:\($0.id)" == key })?.point ??
                            value.geometry.first(where: { "g:\($0.id)" == key })?.point else { throw BackpackError.invalid("Select a fixed point.") }
                        let delta = 10.0 / 111_320
                        let longitude = delta / max(0.01, cos(point.latitude * .pi / 180))
                        let changed = EventCoordinate(latitude: point.latitude + (direction == "North" ? delta : direction == "South" ? -delta : 0),
                            longitude: point.longitude + (direction == "East" ? longitude : direction == "West" ? -longitude : 0))
                        try movePoint(key, to: changed, in: &value)
                    }
                }.accessibilityLabel("Move selected fixed point about 10 meters \(direction.lowercased())")
            }
        }.font(.caption).disabled(!structureEditable)
    }
    private func checkpointText(_ id: UUID) -> Binding<String> {
        Binding(get: { store.draft?.checkpoints.first(where: { $0.id == id })?.title ?? "" }, set: { text in
            edit(structural: true) { value in
                guard let index = value.checkpoints.firstIndex(where: { $0.id == id }) else { throw BackpackError.invalid("Checkpoint was removed.") }
                value.checkpoints[index].title = text
            }
        })
    }
    private func checkpointRadius(_ id: UUID) -> Binding<Double> {
        Binding(get: { store.draft?.checkpoints.first(where: { $0.id == id })?.radiusMeters ?? 100 }, set: { radius in
            edit(structural: true) { value in
                guard let index = value.checkpoints.firstIndex(where: { $0.id == id }) else { throw BackpackError.invalid("Checkpoint was removed.") }
                value.checkpoints[index].radiusMeters = radius
            }
        })
    }
    private func rewardText(_ id: UUID, description: Bool) -> Binding<String> {
        Binding(get: {
            guard let item = store.draft?.rewards.first(where: { $0.id == id }) else { return "" }
            return description ? item.description : item.title
        }, set: { text in
            edit(structural: false) { value in
                guard let index = value.rewards.firstIndex(where: { $0.id == id }) else { throw BackpackError.invalid("Reward was removed.") }
                if description { value.rewards[index].description = text } else { value.rewards[index].title = text }
            }
        })
    }
    private func set(_ choice: RouteArtworkChoice?, checkpoint: inout EventRouteCheckpoint) {
        checkpoint.gifItemId = nil; checkpoint.exclusiveGifId = nil
        switch choice?.reference { case .some(.community(let id)): checkpoint.gifItemId = id; case .some(.exclusive(let id)): checkpoint.exclusiveGifId = id; case .none: break }
    }
    private func set(_ choice: RouteArtworkChoice?, reward: inout EventRouteReward) {
        reward.gifItemId = nil; reward.exclusiveGifId = nil
        switch choice?.reference { case .some(.community(let id)): reward.gifItemId = id; case .some(.exclusive(let id)): reward.exclusiveGifId = id; case .none: break }
    }
}
