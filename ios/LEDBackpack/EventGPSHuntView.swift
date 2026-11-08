import SwiftUI
import BackpackProtocol

@MainActor
struct EventGPSHuntView: View {
    let eventID: UUID
    @StateObject private var model: NativeEventSocialStore
    init(eventID: UUID) {
        self.eventID = eventID
        _model = StateObject(wrappedValue: NativeEventSocialStore(eventID: eventID, surface: .collection))
    }
    var body: some View { EventGPSHuntContent(eventID: eventID, model: model) }
}
@MainActor
private struct EventGPSHuntContent: View {
    let eventID: UUID
    @ObservedObject var model: NativeEventSocialStore
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var gps: ForegroundCheckpointLocation
    @Environment(\.scenePhase) private var phase
    @State private var checkpointID: UUID?
    @State private var gpsConsent = false
    @State private var joinConsent = false
    @State private var cooperativeConsent = false
    @State private var stationary = false
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var confirming: UUID?
    @State private var manualReview = false
    @State private var epoch = UUID()
    @State private var work: Task<Void, Never>?
    private var targets: [EventRouteCheckpoint] {
        guard let event = model.event, let collection = model.collection else { return [] }
        return collection.remainingTargets(event: event)
    }
    private var selected: EventRouteCheckpoint? { targets.first { $0.id == checkpointID } }
    private var expectedScope: ForegroundLocationScope? {
        guard let event = model.event, let participation = event.participationRevision, let selected else { return nil }
        return .init(accountRevision: community.accountRevision, eventID: event.id, eventRevision: event.revision,
            participationRevision: participation, checkpointID: selected.id)
    }
    var body: some View {
        List {
            intro
            consentSection
            gameplay
            if let failure = failure ?? model.failure { Text(failure).foregroundStyle(.orange) }
            if let notice { Text(notice).font(.caption) }
            if busy || model.busy { ProgressView() }
            Section {
                if gps.sensing { Button("Stop GPS", role: .destructive) { stopGPS() } }
                FeatureDetails("Event tools & privacy") {
                    NavigationLink("Event & route") { CommunityEventDetailView(id: eventID) }
                    NavigationLink("Manual hunt & cooperative settings") { EventSocialView(eventID: eventID, surface: .collection) }
                    NavigationLink("Nearby games") { GPSGamesView() }
                    Button("Reload hunt") { stopGPS(); checkpointID = nil; model.bind(community); model.load() }.disabled(busy || model.busy)
                    Button("Leave hunt", role: .destructive) { stopGPS(); model.withdraw() }.disabled(model.busy)
                    Text("GPS is a broad local hint, not certified arrival or precise peer tagging. Coordinates and samples are not uploaded or saved.")
                    Text("Fresh fixes need full accuracy within25m and10s dwell. Bluetooth/NI require separate peer consent and do not track backpacks.")
                    Text("Private self-reports do not publish progress. Cooperative contribution is a separate choice; no other-player counts are shown.")
                }
            }
        }.navigationTitle("GPS checkpoint hunt").modernScene()
        .task(id: community.accountRevision) { stopGPS(); checkpointID = nil; model.bind(community); model.load() }
        .task(id: "\(phase):\(community.accountRevision)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if gps.sensing && !busy && !model.busy { await revalidateSensing() }
            }
        }
        .onChange(of: checkpointID) { _, _ in stopGPS(); stationary = false; manualReview = false; if !model.busy { confirming = nil } }
        .onChange(of: targets.map(\.id)) { _, ids in if let checkpointID, !ids.contains(checkpointID) { self.checkpointID = nil } }
        .onChange(of: gpsConsent) { _, value in if !value { stopGPS() } }
        .onChange(of: model.busy) { _, value in
            if !value, confirming != nil {
                notice = model.failure == nil && model.lastCollectedCheckpointID == confirming ?
                    "Selected private self-report acknowledged and current hunt reloaded. Not GPS-certified attendance; no public progress was submitted." :
                    "Confirmation outcome not verified. Reload your private hunt before another deliberate action; no automatic retry."
                confirming = nil
            }
        }
        .onChange(of: model.needsReload) { _, value in if value { gps.stop("Current hunt context requires reload") } }
        .onChange(of: phase) { _, value in if value != .active { manualReview = false; stopGPS(); model.clear(); checkpointID = nil } }
        .onDisappear { manualReview = false; stopGPS(); model.clear() }
        .confirmationDialog("Manually self-report this selected target privately?", isPresented: $manualReview) {
            if let event = model.event, let collection = model.collection, let selected {
                Button("Self-report \(selected.title) — no GPS proof") { confirmGPS(event, collection: collection, requiresHint: false) }
            }
        } message: { Text("This is your deliberate private self-report, not a verified GPS/Bluetooth arrival. No coordinates or public progress are uploaded. Your existing cooperative opt-in, if any, remains unchanged.") }
    }
    private var intro: some View {
        Section {
            Text(model.event?.title ?? "Checkpoint hunt").font(.title2.bold())
            Text("Choose a target. Stay still. Confirm privately.").font(.subheadline).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var consentSection: some View {
        if let collection = model.collection {
            Section(collection.ownEnabled ? "Your progress" : "Join this hunt") {
                HStack {
                    Text("\(collection.ownCollectedTargetCount) / \(collection.plan.checkpointIds.count)").font(.title.bold()).foregroundStyle(Aurora.mint)
                    Spacer()
                    StatusPill(title: collection.ownCompleted ? "Targets complete" : "Private progress", symbol: "flag")
                }
                ProgressView(value: Double(collection.ownCollectedTargetCount), total: Double(max(1, collection.plan.checkpointIds.count)))
                if collection.cooperativeReached { Label("Cooperative goal reached", systemImage: "checkmark.circle").font(.caption) }
                if !collection.ownEnabled {
                    Text("Your claims stay private. GPS is not attendance proof.").font(.caption)
                    Toggle("Join private hunt", isOn: $joinConsent)
                    Toggle("Include my completion in the cooperative goal", isOn: $cooperativeConsent)
                    Button("Join hunt") {
                        model.consent = joinConsent; model.cooperativeConsent = cooperativeConsent
                        model.joinCollection(); joinConsent = false; cooperativeConsent = false
                    }.buttonStyle(AuroraPrimaryButton()).disabled(!joinConsent || model.busy || !collection.plan.enabled)
                }
            }
        }
    }
    @ViewBuilder private var gameplay: some View {
        if let collection = model.collection, collection.ownEnabled, let event = model.event {
            Section("Target") {
                Picker("Choose target", selection: $checkpointID) {
                    Text("Choose target").tag(Optional<UUID>.none)
                    ForEach(targets) { Text($0.title).tag(Optional($0.id)) }
                }.disabled(busy || model.busy)
                if checkpointID == nil && !targets.isEmpty {
                    Button("Choose next target") {
                        guard let next = targets.first else { failure = "Remaining targets changed. Reload the current hunt."; return }
                        checkpointID = next.id
                        notice = "Selected \(next.title). GPS and private confirmation still need your separate explicit choices."
                    }.disabled(busy || model.busy || model.needsReload || phase != .active)
                }
                if targets.isEmpty { Text("No remaining targets. Reload the hunt.").font(.caption) }
                Toggle("Use foreground GPS for this target", isOn: $gpsConsent)
                    .disabled(busy || model.busy || selected == nil)
                Button("Allow location") { gps.requestWhenInUse(consent: gpsConsent) }
                    .disabled(!gpsConsent || phase != .active)
                if !gps.sensing && !hasCurrentHint {
                Button("Start GPS · 60 seconds") { startGPS(event, collection: collection) }
                    .buttonStyle(AuroraPrimaryButton())
                    .disabled(!gpsConsent || selected == nil || busy || model.busy || model.needsReload)
                }
                StatusPill(title: gps.eligibility.rawValue, symbol: gps.sensing ? "location.fill" : "location.slash")
                FeatureDetails("GPS status") { Text(gps.status) }
                if let remaining = gps.dwellRemaining, gps.sensing, gps.eligibility == .dwelling {
                    Text("Stay still · about \(Int(ceil(remaining))) seconds of fresh fixes remaining")
                        .font(.caption)
                }
                Toggle("I am stopped and can safely confirm", isOn: $stationary)
                if hasCurrentHint {
                Button("Confirm target privately") { confirmGPS(event, collection: collection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!stationary || busy || model.busy || model.needsReload || !hasCurrentHint)
                }
                Button("Confirm manually · no GPS proof") { manualReview = true }
                    .disabled(!stationary || selected == nil || busy || model.busy || model.needsReload)
                Text("Private self-report only. Nothing starts or publishes automatically.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var hasCurrentHint: Bool {
        guard let scope = expectedScope, let hint = gps.hint else { return false }
        return (try? hint.require(scope, uptime: ProcessInfo.processInfo.systemUptime)) != nil
    }
    private func stopGPS() {
        epoch = UUID(); work?.cancel(); work = nil; busy = false; gpsConsent = false
        gps.stop("GPS game stopped — no automatic restart")
    }
    private func fresh(_ event: CatalogEvent, collection: NativeEventCollection) async throws -> (CatalogEvent, NativeEventCollection, CatalogEventClock) {
        guard let client = model.client else { throw BackpackError.invalid("Reload the current hunt account first.") }
        let context = try NativeEventSocialContext(event)
        let current = try await client.currentSocialEvent(context, surface: .collection)
        let clock = try CatalogEventClock(serverTime: current.serverTime)
        let snapshot = try await client.eventCollection(current)
        try snapshot.plan.validate(event: current)
        guard snapshot.ownEnabled, snapshot.revision == collection.revision,
              snapshot.optinRevision == collection.optinRevision, snapshot.plan == collection.plan else {
            throw BackpackError.invalid("Hunt plan or current own opt-in changed. Stop and reload; no stale GPS confirmation.")
        }
        return (current,snapshot,clock)
    }
    private func startGPS(_ event: CatalogEvent, collection: NativeEventCollection) {
        guard let checkpoint = selected, gpsConsent, !busy else { return }
        let stamp = UUID(); epoch = stamp; busy = true; failure = nil
        gps.stop("Checking current hunt before GPS start")
        work = Task {
            defer { if epoch == stamp { busy = false } }
            do {
                let (current,snapshot,clock) = try await fresh(event, collection: collection)
                guard epoch == stamp, phase == .active, gpsConsent, checkpointID == checkpoint.id,
                      snapshot.permitsManualCollection(checkpoint.id, event: current) else { throw CancellationError() }
                try gps.start(event: current, checkpoint: checkpoint, accountRevision: community.accountRevision,
                    consent: gpsConsent, foreground: phase == .active, capability: model.client?.collectionsAvailable == true,
                    eventClock: clock)
            } catch { if epoch == stamp && !Task.isCancelled { handleFailure(error) } }
        }
    }
    private func confirmGPS(_ event: CatalogEvent, collection: NativeEventCollection, requiresHint: Bool = true) {
        guard !busy, stationary, let checkpoint = selected, let expected = expectedScope else {
            failure = "Choose the current target and confirm you can safely make a private self-report."; return
        }
        let hintID = gps.hint?.id
        if requiresHint && hintID == nil { failure = "Current GPS eligibility is unavailable; use the explicitly labelled manual fallback."; return }
        let stamp = UUID(); epoch = stamp; busy = true; failure = nil
        work = Task {
            defer { if epoch == stamp { busy = false } }
            do {
                let (current,snapshot,_) = try await fresh(event, collection: collection)
                guard epoch == stamp, phase == .active, stationary, checkpointID == checkpoint.id,
                      snapshot.permitsManualCollection(checkpoint.id, event: current) else { throw CancellationError() }
                if requiresHint {
                    guard gps.hint?.id == hintID else { throw BackpackError.invalid("GPS hint changed; review eligibility or use manual fallback.") }
                    _ = try gps.consumeHint(expected)
                }
                gps.stop(requiresHint ? "Local target hint consumed — awaiting explicit private claim receipt" :
                    "GPS off — deliberate manual self-report, no location proof")
                gpsConsent = false; confirming = checkpoint.id; model.consent = true
                model.collect(checkpoint.id)
                guard model.busy else {
                    confirming = nil
                    throw BackpackError.invalid(model.failure ?? "Private collection request did not start; reload current hunt.")
                }
                notice = requiresHint ? "Private confirmation requested; this is a self-report, not a GPS proof or public progress post." :
                    "Manual private self-report requested for the selected target; no GPS/Bluetooth proof or public progress post."
            } catch { if epoch == stamp && !Task.isCancelled { handleFailure(error) } }
        }
    }
    private func revalidateSensing() async {
        let stamp = epoch
        guard let event = model.event, let collection = model.collection else { stopGPS(); return }
        do {
            let (current,snapshot,_) = try await fresh(event, collection: collection)
            if let checkpointID, !snapshot.permitsManualCollection(checkpointID, event: current) {
                throw BackpackError.invalid("This target was already collected or is no longer permitted. Reload the remaining hunt.")
            }
        }
        catch { if epoch == stamp { handleFailure(error) } }
    }
    private func handleFailure(_ error: Error) {
        stopGPS()
        if let failure = error as? CommunityFailure, [401,403,404,410].contains(failure.status) { model.clear(); checkpointID = nil }
        if let failure = error as? NativeEventSocialContextFailure {
            switch failure {
            case .denied, .unavailable: model.clear(); checkpointID = nil
            case .changed: break
            }
        }
        failure = error.localizedDescription
    }
}
