import SwiftUI
import Combine
import BackpackProtocol

@MainActor
final class NativeEventSocialStore: ObservableObject {
    let eventID: UUID
    let surface: NativeEventSocialSurface
    @Published private(set) var event: CatalogEvent?
    @Published private(set) var teams: NativeEventTeams?
    @Published private(set) var collection: NativeEventCollection?
    @Published private(set) var display: NativeEventDisplay?
    @Published private(set) var preferences: NativeGuestbookPreferences?
    @Published private(set) var guestbook: NativeGuestbookPage?
    @Published private(set) var recap: NativeEventRecap?
    @Published private(set) var gallery: [NativeEventImage] = []
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var needsReload = false
    @Published private(set) var preview: NativeEventPlanPreview?
    @Published var teamDraft: [NativeEventTeam] = []
    @Published var collectionDraft = NativeCollectionPlan()
    @Published var displayDraft = NativeDisplayPlan()
    @Published var guestDraft = NativeGuestbookDraft()
    @Published var guestbookEnabled = false
    @Published var consent = false
    @Published var cooperativeConsent = false
    @Published var teamID: UUID?
    @Published var manualCheckpointID: UUID?
    @Published var page = 1
    private(set) var client: CommunityFeatureClient?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var submission: NativeGuestbookSubmission?
    @Published private(set) var submissionPending = false
    @Published private(set) var submissionConflict = false
    @Published private(set) var withdrawalRevision: Int?
    init(eventID: UUID, surface: NativeEventSocialSurface) { self.eventID = eventID; self.surface = surface }
    func bind(_ community: CommunityController) {
        clear()
        do { client = try CommunityFeatureClient(community) }
        catch { failure = error.localizedDescription }
    }
    func clear() {
        operation?.cancel(); operation = nil; generation = UUID(); client = nil; busy = false; failure = nil
        eraseContent(); withdrawalRevision = nil; page = 1
    }
    private func eraseContent() {
        event = nil; teams = nil; collection = nil; display = nil; preferences = nil; guestbook = nil; recap = nil
        teamDraft = []; collectionDraft = .init(); displayDraft = .init(); gallery = []
        guestDraft = .init(); submission = nil; submissionPending = false; submissionConflict = false
        consent = false; cooperativeConsent = false; teamID = nil; preview = nil
        manualCheckpointID = nil
        needsReload = true
    }
    func stopPreview() { preview = nil }
    func invalidateConsent() { consent = false; cooperativeConsent = false; preview = nil }
    private func work(_ body: @escaping @MainActor (CommunityFeatureClient, UUID) async throws -> Void) {
        guard let client, !busy else { return }
        operation?.cancel(); let ticket = UUID(); generation = ticket; busy = true; failure = nil
        operation = Task {
            do {
                try client.checkEventSurface(surface)
                try await body(client, ticket); try accept(client, ticket)
                busy = false
            } catch {
                guard generation == ticket, !Task.isCancelled else { return }
                busy = false; preview = nil; consent = false; cooperativeConsent = false
                guestDraft.consent = false; needsReload = true
                if let failure = error as? CommunityFailure, failure.status == 409 { submissionConflict = submissionPending }
                if let failure = error as? CommunityFailure, [401, 403, 404, 410].contains(failure.status) {
                    eraseContent()
                }
                if let failure = error as? NativeEventSocialContextFailure {
                    switch failure {
                    case .denied, .unavailable: eraseContent()
                    case .changed: submissionConflict = submissionPending
                    }
                }
                failure = error.localizedDescription
            }
        }
    }
    func accept(_ client: CommunityFeatureClient, _ ticket: UUID) throws {
        try Task.checkCancellation(); try client.checkEventSurface(surface)
        guard self.client === client, generation == ticket else { throw BackpackError.invalid("Late event response discarded.") }
    }
    func load() {
        invalidateConsent(); guestDraft.consent = false; preview = nil
        work { client, ticket in try await self.read(client, ticket) }
    }
    private func read(_ client: CommunityFeatureClient, _ ticket: UUID) async throws {
        let current = try await client.event(eventID)
        try client.checkEventSurface(surface, event: current)
        guard current.moderation?.held != true else { throw NativeEventSocialContextFailure.denied }
        try accept(client, ticket)
        switch surface {
        case .teams:
            let result = try await client.eventTeams(current); try accept(client, ticket)
            teams = result; teamDraft = result.teams; teamID = nil; withdrawalRevision = result.optinRevision
        case .collection:
            let result = try await client.eventCollection(current); try accept(client, ticket)
            collection = result; collectionDraft = result.plan; withdrawalRevision = result.optinRevision
        case .display:
            let selectedCheckpoint = manualCheckpointID
            let result = try await client.eventDisplayPlan(current, checkpointID: selectedCheckpoint); try accept(client, ticket)
            guard selectedCheckpoint == manualCheckpointID else { throw BackpackError.invalid("Manual checkpoint changed. Refresh cues.") }
            display = result; displayDraft = result.plan; withdrawalRevision = result.optinRevision
        case .guestbook:
            let settings = try await client.guestbookPreferences(current); try accept(client, ticket)
            let posts = settings.enabled ? try await client.eventGuestbook(current, page: page) : nil
            try accept(client, ticket)
            preferences = settings; guestbookEnabled = settings.enabled; guestbook = posts; gallery = []
            guestDraft = .init(); submission = nil; submissionPending = false; submissionConflict = false
        case .recap:
            let result = try await client.eventRecap(current, page: page); try accept(client, ticket); recap = result
        }
        event = current; needsReload = false; consent = false; cooperativeConsent = false; guestDraft.consent = false
    }
    private func mutate(_ action: @escaping @MainActor (CommunityFeatureClient, CatalogEvent) async throws -> Void) {
        guard let event, !needsReload else { failure = "Reload and review current revisions first."; return }
        invalidateConsent(); guestDraft.consent = false; needsReload = true
        work { client, ticket in
            try await action(client, event); try self.accept(client, ticket)
            try await self.read(client, ticket)
        }
    }
    func saveTeams() {
        guard let teams else { return }; let draft = teamDraft
        mutate { client, event in try await client.saveEventTeams(event, snapshot: teams, teams: draft) }
    }
    func chooseTeam() {
        guard let teams, let teamID else { return }; let accepted = consent
        mutate { client, event in try await client.chooseEventTeam(event, snapshot: teams, teamID: teamID, consent: accepted) }
    }
    func saveCollection() {
        guard let collection else { return }; let draft = collectionDraft
        mutate { client, event in try await client.saveEventCollection(event, snapshot: collection, plan: draft) }
    }
    func joinCollection() {
        guard let collection else { return }; let accepted = consent, cooperative = cooperativeConsent
        mutate { client, event in try await client.consentEventCollection(event, snapshot: collection, consent: accepted, cooperative: cooperative) }
    }
    func collect(_ id: UUID) {
        guard let collection else { return }; let accepted = consent
        mutate { client, event in try await client.collectHuntTarget(event, snapshot: collection, checkpointID: id, consent: accepted) }
    }
    func saveDisplay() {
        guard let display else { return }; let draft = displayDraft
        mutate { client, event in try await client.saveEventDisplay(event, snapshot: display, plan: draft) }
    }
    func joinDisplay() {
        guard let display else { return }; let accepted = consent
        mutate { client, event in try await client.consentEventDisplay(event, snapshot: display, consent: accepted) }
    }
    func withdraw() {
        guard let revision = withdrawalRevision else { return }
        invalidateConsent()
        work { client, ticket in
            let next: Int
            if self.surface == .teams { next = try await client.withdrawEventTeam(eventID: self.eventID, revision: revision) }
            else { next = try await client.withdrawEventPlan(eventID: self.eventID, surface: self.surface, optinRevision: revision) }
            try self.accept(client, ticket)
            self.eraseContent(); self.withdrawalRevision = next
        }
    }
    func loadGallery() {
        guard let event, !needsReload else { return }
        let context: NativeEventSocialContext
        do { context = try .init(event) } catch { failure = error.localizedDescription; return }
        work { client, ticket in
            _ = try await client.currentSocialEvent(context, surface: .guestbook)
            let value = try await client.eventImages(event.id); try self.accept(client, ticket)
            self.gallery = value.assets.filter(\.approved); self.guestDraft.imageID = nil; self.guestDraft.consent = false
        }
    }
    func saveGuestbookSettings() {
        guard let preferences else { return }; let enabled = guestbookEnabled
        mutate { client, event in try await client.saveGuestbookPreferences(event, snapshot: preferences, enabled: enabled) }
    }
    func cancelSubmission() { submission = nil; submissionPending = false; submissionConflict = false; guestDraft = .init() }
    func postGuestbook() {
        guard let event, let preferences, !needsReload else { failure = "Reload guestbook and explicitly review consent."; return }
        do {
            if submission == nil { submission = try .init(event: event, preferences: preferences, draft: guestDraft, gallery: gallery) }
            guard let intent = submission else { return }
            submissionPending = true
            work { client, ticket in
                _ = try await client.submitGuestbook(intent); try self.accept(client, ticket)
                self.cancelSubmission(); try await self.read(client, ticket)
            }
        } catch { failure = error.localizedDescription; guestDraft.consent = false }
    }
    func retryGuestbook() {
        guard let intent = submission, guestDraft.consent, !submissionConflict else {
            failure = "Cancel/reload a known conflict. Otherwise explicitly consent to retrying the exact immutable submission."; return
        }
        work { client, ticket in
            _ = try await client.submitGuestbook(intent); try self.accept(client, ticket)
            self.cancelSubmission(); try await self.read(client, ticket)
        }
    }
    func moderate(_ post: NativeGuestbookPost, approved: Bool) {
        mutate { client, event in try await client.moderateGuestbook(event, post: post, approved: approved) }
    }
    func withdrawPost(_ post: NativeGuestbookPost) {
        work { client, ticket in
            try await client.withdrawGuestbook(eventID: self.eventID, postID: post.id, revision: post.revision)
            try self.accept(client, ticket); try await self.read(client, ticket)
        }
    }
    func startPreview() {
        guard let event, let display, !needsReload, consent, displayDraft == display.plan else {
            failure = "Reload a saved plan, then explicitly consent to a foreground source preview."; return
        }
        let selected = manualCheckpointID
        work { client, ticket in
            let context = try NativeEventSocialContext(event)
            let current = try await client.currentSocialEvent(context, surface: .display)
            let requestStarted = ContinuousClock().now
            let result = try await client.eventDisplayPlan(current, checkpointID: selected)
            try self.accept(client, ticket)
            let clock = try CatalogEventClock(serverTime: result.serverTimeISO, instant: requestStarted)
            let end = try CatalogEventTime.parse(current.endsAtISO)
            guard result.ownEnabled, result.plan.enabled, result.revision == display.revision,
                  result.optinRevision == display.optinRevision, selected == self.manualCheckpointID, clock.now() < end else {
                throw BackpackError.invalid("Consent, plan, selected checkpoint or event expiry changed. Reload; preview remains paused.")
            }
            self.preview = NativeEventPlanPreview(accountID: client.accountID, accountEpoch: client.revision, context: context,
                planRevision: result.revision, optinRevision: result.optinRevision, manualCheckpointID: selected,
                snapshot: result, clock: clock, endsAt: end)
            self.consent = false
        }
    }
}

@MainActor
struct EventSocialView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var model: NativeEventSocialStore
    @State private var newScene = NativeDisplayScene()
    @State private var phoneSceneID: UUID?
    @State private var importPage: NativeOwnerPlaylistPage?
    @State private var importPageNumber = 1
    @State private var importPlaylistID: UUID?
    @State private var importFailure: String?
    @State private var importTask: Task<Void, Never>?
    var onPlanPreview: (@MainActor (NativeEventPlanPreview?) -> Void)?
    init(eventID: UUID, surface: NativeEventSocialSurface,
         onPlanPreview: (@MainActor (NativeEventPlanPreview?) -> Void)? = nil) {
        _model = StateObject(wrappedValue: NativeEventSocialStore(eventID: eventID, surface: surface))
        self.onPlanPreview = onPlanPreview
    }
    var body: some View {
        Form {
            Section {
                Text("Source controls only. Saved plans are not physical playback, frame synchronization, location, attendance, friendship or roster permission.").font(.caption)
                Button("Reload current access / discard unsaved drafts") { newScene = .init(); clearImport(); model.load() }
                    .disabled(model.busy)
                if model.busy { ProgressView() }
                if let failure = model.failure { Text(failure).foregroundStyle(.orange) }
                if model.needsReload { Text("Review a fresh snapshot before a new action. Conflicting drafts are retained, never silently overwritten.").font(.caption) }
            }
            if let event = model.event {
                Section { Text(event.title); Text("Event \(event.revision) / participation \(event.participationRevision.map(String.init) ?? "withheld")").font(.caption) }
                Group {
                    switch model.surface {
                    case .teams: teams(event)
                    case .collection: collection(event)
                    case .display: display(event)
                    case .guestbook: guestbook(event)
                    case .recap: recap
                    }
                }.disabled(model.busy || model.needsReload)
            } else if !model.busy { Text("No current authorized detail loaded. Case/admin authority never restores private event content.") }
            if model.submissionPending {
                Section("Owned immutable guestbook retry") {
                    Text("No new content or consent is inferred. A revision conflict requires cancel/reload; retry keeps the original message ID and exact bytes.").font(.caption)
                    Toggle("I explicitly consent to retrying that exact submission", isOn: $model.guestDraft.consent).disabled(model.submissionConflict)
                    Button("Retry exact captured submission") { model.retryGuestbook() }
                        .disabled(model.busy || model.submissionConflict || !model.guestDraft.consent)
                    Button("Cancel immutable submission draft") { model.cancelSubmission() }.disabled(model.busy)
                }
            }
            if let revision = model.withdrawalRevision, revision > 0, model.surface != .guestbook, model.surface != .recap {
                Section("Own consent withdrawal") {
                    Button("Withdraw my known choice / consent", role: .destructive) { model.withdraw() }.disabled(model.busy)
                    Text("Uses only the captured own revision, including after event view loss. A conflict requires an explicit reload; no stale retry.").font(.caption)
                }
            }
        }
        .navigationTitle(title).modernScene()
        .task(id: "\(community.accountRevision):\(community.config?.eventsEnabled == true):\(community.config?.eventTeamsEnabled == true):\(community.config?.eventCollectionsEnabled == true):\(community.config?.eventDisplayPlanningEnabled == true):\(community.config?.eventGuestbookAvailable == true):\(community.config?.eventRecapsEnabled == true)") {
            clearImport(); model.bind(community); model.load()
        }
        .task(id: model.preview?.id) {
            guard let preview = model.preview else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, preview.validUntil.timeIntervalSince(preview.clock.now()))))
                try Task.checkCancellation()
                if model.preview?.id == preview.id { model.stopPreview(); onPlanPreview?(nil) }
            } catch { }
        }
        .onChange(of: model.teamDraft) { _, _ in model.invalidateConsent() }
        .onChange(of: model.collectionDraft) { _, _ in model.invalidateConsent() }
        .onChange(of: model.displayDraft) { _, _ in model.invalidateConsent() }
        .onChange(of: model.teamID) { _, _ in model.consent = false }
        .onChange(of: model.guestDraft.text) { _, _ in model.guestDraft.consent = false }
        .onChange(of: model.guestDraft.reaction) { _, _ in model.guestDraft.consent = false }
        .onChange(of: model.guestDraft.imageID) { _, _ in model.guestDraft.consent = false }
        .onChange(of: model.guestDraft.publicSharing) { _, _ in model.guestDraft.consent = false }
        .onChange(of: model.guestDraft.shareAuthor) { _, _ in model.guestDraft.consent = false }
        .onChange(of: model.guestbookEnabled) { _, _ in model.guestDraft.consent = false }
        .onChange(of: model.manualCheckpointID) { _, _ in model.invalidateConsent() }
        .onChange(of: model.preview?.id) { _, _ in phoneSceneID = nil; onPlanPreview?(model.preview) }
        .onChange(of: phase) { _, value in
            onPlanPreview?(nil); clearImport(); model.clear()
            if value == .active { model.bind(community); model.load() }
        }
        .onDisappear { onPlanPreview?(nil); clearImport(); model.clear() }
    }
    private var title: String {
        switch model.surface {
        case .teams: return "Own team palette"
        case .collection: return "Hunt & cooperative goal"
        case .display: return "Show / rest-stop plan"
        case .guestbook: return "Consented guestbook"
        case .recap: return "My private recap"
        }
    }
    @ViewBuilder private func teams(_ event: CatalogEvent) -> some View {
        if let snapshot = model.teams {
            Section("Current named palettes") {
                if snapshot.teams.isEmpty { Text("No team palettes have been planned.") }
                ForEach(snapshot.teams) { team in
                    Text("\(team.name): \(team.colors.joined(separator: ", ")) / \(team.pattern.rawValue)")
                    if snapshot.ownTeamId == team.id { Text("Your currently valid own choice").font(.caption) }
                }
                Picker("My team", selection: $model.teamID) {
                    Text("Choose deliberately").tag(Optional<UUID>.none)
                    ForEach(snapshot.teams) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("I opt in to my own named team choice only", isOn: $model.consent)
                Button("Save my team choice") { model.chooseTeam() }
                    .disabled(!model.consent || model.teamID == nil || event.access.canChooseTeam != true || model.teamDraft != snapshot.teams)
            }
            if event.access.canManage && snapshot.canManage {
                Section("Organizer palette draft") {
                    ForEach($model.teamDraft) { $team in
                        VStack(alignment: .leading) {
                            TextField("Team name", text: $team.name)
                            GentleColorsEditor(colors: $team.colors, pattern: $team.pattern, period: $team.periodMilliseconds)
                            Button("Remove \(team.name)", role: .destructive) { model.teamDraft.removeAll { $0.id == team.id } }
                        }
                    }
                    Button("Add named team") { model.teamDraft.append(.init()) }.disabled(model.teamDraft.count >= 16)
                    Button("Save captured palette revision") { model.saveTeams() }
                    Text("Saving changes invalidates previous opt-ins; no one is assigned automatically.").font(.caption)
                }
            }
        }
    }
    @ViewBuilder private func collection(_ event: CatalogEvent) -> some View {
        if let snapshot = model.collection {
            Section("Private any-order hunt") {
                Text(snapshot.ownEnabled ? "Current own hunt consent is active." : "Not currently opted in.")
                Text(snapshot.ownCompleted ? "Your selected targets are self-collected." : "Your private hunt is incomplete or not opted in.")
                Text(snapshot.cooperativeReached ? "Server's cooperative goal boolean: reached." : "Server's cooperative goal boolean: not reached or disabled.")
                Text("No exact contributor counts, identities, arrivals or GPS. Private badges do not share progress. Finish requires all selected targets.").font(.caption)
                Toggle("I explicitly opt in to this private any-order collection", isOn: $model.consent)
                Toggle("Separately include my completion in the cooperative boolean", isOn: $model.cooperativeConsent)
                Button("Save these separate consent choices") { model.joinCollection() }
                    .disabled(!model.consent || !snapshot.plan.enabled || model.collectionDraft != snapshot.plan)
                ForEach(snapshot.checkpoints) { checkpoint in
                    Text("\(checkpoint.title): \(checkpoint.collected ? "self-collected" : "not collected")")
                    Button("Manually self-report \(checkpoint.title) privately") { model.collect(checkpoint.id) }
                        .disabled(!snapshot.ownEnabled || checkpoint.collected || !model.consent || model.collectionDraft != snapshot.plan)
                }
                ForEach(event.route?.checkpoints.filter { $0.kind == .finish } ?? []) { checkpoint in
                    Button("Manually self-report finish: \(checkpoint.title)") { model.collect(checkpoint.id) }
                        .disabled(!snapshot.ownCompleted || !model.consent || model.collectionDraft != snapshot.plan)
                }
            }
            if snapshot.canManage && event.access.canManage {
                Section("Organizer public hunt draft") {
                    Toggle("Enable public any-order plan", isOn: $model.collectionDraft.enabled)
                    ForEach(event.route?.checkpoints.filter { $0.kind == .checkpoint } ?? []) { checkpoint in
                        Toggle(checkpoint.title, isOn: Binding(get: { model.collectionDraft.checkpointIds.contains(checkpoint.id) }, set: { selected in
                            model.collectionDraft.checkpointIds.removeAll { $0 == checkpoint.id }
                            if selected { model.collectionDraft.checkpointIds.append(checkpoint.id) }
                        }))
                    }
                    Toggle("Optional cooperative goal", isOn: Binding(get: { model.collectionDraft.cooperativeGoal != nil },
                        set: { model.collectionDraft.cooperativeGoal = $0 ? 5 : nil }))
                    if model.collectionDraft.cooperativeGoal != nil {
                        Stepper("Goal threshold \(model.collectionDraft.cooperativeGoal ?? 5)", value: Binding(
                            get: { model.collectionDraft.cooperativeGoal ?? 5 }, set: { model.collectionDraft.cooperativeGoal = $0 }), in: 5...10000)
                    }
                    GentleColorsEditor(colors: $model.collectionDraft.celebrationColors, pattern: $model.collectionDraft.celebrationPattern)
                    Button("Save captured hunt plan") { model.saveCollection() }
                }
            }
        }
    }
    @ViewBuilder private func display(_ event: CatalogEvent) -> some View {
        if let snapshot = model.display {
            Section("Paused foreground source preview") {
                Text("Current plan consent: \(snapshot.ownEnabled ? "active" : "off/stale"). Server clock: \(snapshot.serverTimeISO)").font(.caption)
                Picker("Manual rest-stop / regroup checkpoint", selection: $model.manualCheckpointID) {
                    Text("No manual checkpoint").tag(Optional<UUID>.none)
                    ForEach(event.route?.checkpoints ?? []) { Text($0.title).tag(Optional($0.id)) }
                }
                Button("Refresh cues for this manual selection") { model.load() }
                Toggle("I explicitly consent to this saved plan / foreground preview", isOn: $model.consent)
                Button("Save my own current plan consent") { model.joinDisplay() }
                    .disabled(!model.consent || !snapshot.plan.enabled || model.displayDraft != snapshot.plan)
                Button("Start foreground source preview (not playback)") { model.startPreview() }
                    .disabled(!model.consent || !snapshot.ownEnabled || model.displayDraft != snapshot.plan)
                Button("Stop preview now") { model.stopPreview(); onPlanPreview?(nil) }
                if let preview = model.preview {
                    Picker("Explicit isolated PHONE scene", selection: $phoneSceneID) {
                        Text("Choose a currently returned named cue").tag(Optional<UUID>.none)
                        ForEach(preview.snapshot.cues) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if let phoneSceneID, let client = model.client {
                        NativeScopedPhonePreviewView(source: .event(preview, sceneID: phoneSceneID), client: client)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if preview.clock.now() >= preview.validUntil { Text("Source authorization preview expired; no cues. Deliberately refresh/review. Event expiry never extends old consent.") }
                        else {
                            Text("Server-anchored estimate: \(preview.clock.now().formatted())").font(.caption)
                            let cues = preview.currentCues()
                            if cues.isEmpty { Text("No currently active returned cue. Refresh deliberately; no background cue polling.") }
                            ForEach(cues) { cue in
                                Text("\(cue.name) / \(cue.pattern.rawValue) / \(cue.colors.joined(separator: ", "))")
                                if let prompt = cue.regroupPrompt { Text(prompt) }
                            }
                        }
                    }
                } else { Text("Paused. Saving and shared clocks do not prove physical sync, delivery or safety monitoring.") }
                Text("Global Phone/LED runtime is not connected. Isolated PHONE pixels above are separately explicit; authorization stops on expiry/page/account/background changes.").font(.caption)
            }
            Section("Saved scenes / currently authorized public artwork") {
                ForEach(snapshot.plan.scenes) { scene in
                    Text("\(scene.name) / \(scene.kind.rawValue) / \(scene.durationSeconds)s")
                    if let list = snapshot.scenePlaylists.first(where: { $0.sceneId == scene.id }) {
                        ForEach(Array(list.entries.enumerated()), id: \.offset) { _, entry in
                            Text(entry.item.map { "\($0.title) / \(entry.durationMilliseconds)ms" } ?? "Artwork unavailable; no item metadata.")
                        }
                    }
                }
                if snapshot.plan.scenes.isEmpty { Text("No scenes saved.") }
            }
            if event.access.canManage && snapshot.canManage {
                Section("Organizer scene draft") {
                    Toggle("Enable plan", isOn: $model.displayDraft.enabled)
                    ForEach($model.displayDraft.scenes) { $scene in
                        NativeDisplaySceneEditor(scene: $scene, event: event)
                        Button("Remove scene", role: .destructive) { model.displayDraft.scenes.removeAll { $0.id == scene.id } }
                    }
                    Text("New named scene").font(.headline)
                    NativeDisplaySceneEditor(scene: $newScene, event: event)
                    Button("Load named own playlists for public-only reference copy") { loadImports(page: 1) }
                    if let importFailure { Text(importFailure).foregroundStyle(.orange) }
                    if let page = importPage {
                        Picker("Optional private playlist source", selection: $importPlaylistID) {
                            Text("No playlist copy").tag(Optional<UUID>.none)
                            ForEach(page.playlists) { Text("\($0.title) / \($0.entryCount) GIFs").tag(Optional($0.id)) }
                        }
                        HStack {
                            Button("Previous private playlist page") { loadImports(page: importPageNumber - 1) }.disabled(importPageNumber == 1)
                            Button("Next private playlist page") { loadImports(page: importPageNumber + 1) }.disabled(!page.hasMore || importPageNumber >= 5)
                        }
                    }
                    Button("Append new scene / copy selected public references only") { appendScene(event) }
                        .disabled(model.displayDraft.scenes.count >= 24 || importTask != nil)
                    Button("Save captured display-plan revision") { model.saveDisplay() }
                    Text("Private playlist names, descriptions and schedules never enter event scene data. No private/exclusive/cloud artwork is imported.").font(.caption)
                }
            }
        }
    }
    @ViewBuilder private func guestbook(_ event: CatalogEvent) -> some View {
        if let preferences = model.preferences {
            Section("Guestbook settings") {
                Text(preferences.enabled ? "Organizer enabled" : "Default-off guestbook is disabled")
                if preferences.canManage && event.access.canManage {
                    Toggle("Organizer enables this event guestbook", isOn: $model.guestbookEnabled)
                    Button("Save current guestbook settings revision") { model.saveGuestbookSettings() }
                }
                Text("Server-managed encryption is not end-to-end encryption. Notes expire after 90 days; already viewed public copies cannot be recalled. No chat, venue, GPS, GIF or private-library content is copied.").font(.caption)
            }
            if let value = model.guestbook {
                Section("Visible posts") {
                    if value.posts.isEmpty { Text("No visible posts on this page.") }
                    ForEach(value.posts) { post in
                        VStack(alignment: .leading) {
                            Text("\(post.reaction.rawValue) / \(post.authorName ?? "Name withheld")")
                            Text(verbatim: post.text)
                            Text("\(post.state) / \(post.public ? "public requested" : "participants only") / \(post.createdAtISO)").font(.caption)
                            if post.image != nil { Text(post.image?.unavailable == true ? "Photo unavailable; no restored access." : "Reviewed gallery photo reference (not copied artwork).").font(.caption) }
                            if post.own { Button("Withdraw my post", role: .destructive) { model.withdrawPost(post) } }
                            if post.canModerate && value.canModerate && event.access.canManage {
                                Button("Approve this captured post revision") { model.moderate(post, approved: true) }
                                Button("Reject this captured post revision") { model.moderate(post, approved: false) }
                            }
                        }
                    }
                    pagination(hasMore: value.hasMore, max: 17)
                }
                if value.canPost && preferences.enabled {
                    Section("Explicit new submission") {
                        Group {
                            TextField("Typed note (up to 1,000 characters)", text: $model.guestDraft.text, axis: .vertical)
                            Picker("Reaction", selection: $model.guestDraft.reaction) {
                                ForEach(NativeGuestbookReaction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Button("Load current reviewed gallery choices") { model.loadGallery() }
                            Picker("Optional reviewed gallery reference", selection: $model.guestDraft.imageID) {
                                Text("No photo").tag(Optional<UUID>.none)
                                ForEach(model.gallery) { Text($0.caption.isEmpty ? $0.alt : $0.caption).tag(Optional($0.id)) }
                            }
                            Toggle("Separately request public sharing", isOn: $model.guestDraft.publicSharing).disabled(event.visibility != "public")
                            Toggle("Separately share my display name", isOn: $model.guestDraft.shareAuthor)
                        }.disabled(model.submissionPending)
                        Toggle("I consent to this note/reaction/reference and selected audience", isOn: $model.guestDraft.consent)
                        if !model.submissionPending {
                            Button("Submit for review (never auto-approve)") { model.postGuestbook() }.disabled(!model.guestDraft.consent)
                        }
                        Button("Cancel submission draft") { model.cancelSubmission() }
                    }
                }
            }
        }
    }
    @ViewBuilder private var recap: some View {
        if let value = model.recap {
            Section("Only my private recap") {
                Text("\(value.status.rawValue) / server \(value.serverTime)").font(.caption)
                Text(value.progress.completed ? "Latest currently shared checkpoint reports finish (uncertified)." : "No currently shared completion claim.")
                Text(value.progress.checkpoint?.title ?? "Shared checkpoint withheld or absent; no local-only history is restored.")
                if value.awards.isEmpty { Text("No private award records on this page.") }
                ForEach(value.awards) { award in
                    Text(award.title); Text(award.description).font(.caption)
                    Text(award.eventVersion == value.participationRevision ? "Current reviewed version / self-reported" : "Old participation version / private record").font(.caption)
                }
                ForEach(Array(value.artworkReferences.enumerated()), id: \.offset) { _, reference in
                    Text("\(reference.label): \(reference.available ? "current authorized reference" : "unavailable / ID withheld")")
                }
                pagination(hasMore: value.hasMore, max: 1000)
                Text("Not a GPS route, attendance certificate, downloaded-file proof, badge creation or progress-sharing action.").font(.caption)
            }
        }
    }
    private func pagination(hasMore: Bool, max: Int) -> some View {
        HStack {
            Button("Previous") { model.page -= 1; model.load() }.disabled(model.page == 1)
            Spacer(); Text("Page \(model.page)")
            Button("Next") { model.page += 1; model.load() }.disabled(!hasMore || model.page >= max)
        }
    }
    private func clearImport() {
        importTask?.cancel(); importTask = nil; importPage = nil; importPlaylistID = nil; importFailure = nil
    }
    private func loadImports(page: Int) {
        clearImport()
        guard let client = model.client, model.event?.access.canManage == true else { return }
        let epoch = community.accountRevision
        importTask = Task {
            defer { if epoch == community.accountRevision { importTask = nil } }
            do {
                let result = try await client.ownerPlaylists(page: page); try Task.checkCancellation(); try client.check()
                guard phase == .active, community.accountRevision == epoch, model.client === client, model.event?.access.canManage == true else { return }
                importPage = result; importPageNumber = page
            } catch { if !Task.isCancelled && epoch == community.accountRevision { importFailure = error.localizedDescription } }
        }
    }
    private func appendScene(_ event: CatalogEvent) {
        guard let client = model.client else { return }
        var scene = newScene
        if scene.kind != .restStop { scene.checkpointId = nil; scene.regroupPrompt = nil }
        let selected = importPlaylistID, epoch = community.accountRevision, revision = event.revision
        importTask?.cancel()
        importTask = Task {
            defer { if epoch == community.accountRevision { importTask = nil } }
            do {
                if let selected { scene.playlist = try await client.ownerPlaylist(selected).sceneSnapshot() }
                try Task.checkCancellation(); try client.check()
                guard phase == .active, epoch == community.accountRevision, model.client === client,
                      model.event?.revision == revision, !model.needsReload, model.event?.access.canManage == true else { return }
                try scene.validate(event: event); model.displayDraft.scenes.append(scene); newScene = .init(); importPlaylistID = nil
            } catch { if !Task.isCancelled && epoch == community.accountRevision { importFailure = error.localizedDescription } }
        }
    }
}

struct GentleColorsEditor: View {
    @Binding var colors: [String]
    @Binding var pattern: GentlePlanPattern
    var period: Binding<Int>?
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(colors.indices, id: \.self) { index in
                TextField("Color \(index + 1) #RRGGBB", text: $colors[index]).textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            HStack {
                Button("Add color") { colors.append("#55CCAA") }.disabled(colors.count >= 4)
                Button("Remove last color") { if colors.count > 1 { colors.removeLast() } }.disabled(colors.count <= 1)
            }
            Picker("Gentle pattern", selection: $pattern) {
                ForEach(GentlePlanPattern.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if let period { Stepper("Period \(period.wrappedValue) ms", value: period, in: 2000...60000, step: 1000) }
        }
    }
}
struct NativeDisplaySceneEditor: View {
    @Binding var scene: NativeDisplayScene
    let event: CatalogEvent
    var body: some View {
        VStack(alignment: .leading) {
            TextField("Scene name", text: $scene.name)
            Picker("Scene kind", selection: $scene.kind) {
                ForEach(NativeDisplayScene.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.onChange(of: scene.kind) { _, value in if value != .restStop { scene.checkpointId = nil; scene.regroupPrompt = nil } }
            if scene.kind == .restStop {
                Picker("Named rest-stop checkpoint", selection: $scene.checkpointId) {
                    Text("Choose checkpoint").tag(Optional<UUID>.none)
                    ForEach(event.route?.checkpoints ?? []) { Text($0.title).tag(Optional($0.id)) }
                }
                TextField("Optional regroup prompt", text: Binding(get: { scene.regroupPrompt ?? "" }, set: { scene.regroupPrompt = $0.isEmpty ? nil : $0 }))
            }
            Stepper("Clock offset \(scene.offsetSeconds)s", value: $scene.offsetSeconds, in: -3600...3600, step: 10)
            Stepper("Duration \(scene.durationSeconds)s", value: $scene.durationSeconds, in: 2...600)
            GentleColorsEditor(colors: $scene.colors, pattern: $scene.pattern, period: $scene.periodMilliseconds)
            if let playlist = scene.playlist {
                Text("Public-only copied playlist: \(playlist.entries.count) entries / \(playlist.order.rawValue)").font(.caption)
                Button("Remove copied playlist", role: .destructive) { scene.playlist = nil }
            }
        }
    }
}

@MainActor
struct OwnedGuestbookPostsView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var value: NativeOwnedGuestbookPage?
    @State private var page = 1
    var body: some View {
        List {
            Text("Only your typed submissions/receipts. No event details, author roster or gallery access is restored. Server-managed encryption is not E2EE; posts expire after 90 days.").font(.caption)
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            Button("Reload my submissions", action: load).disabled(session.busy)
            if let value {
                if value.posts.isEmpty { Text("No owned submissions on this page.") }
                ForEach(value.posts) { post in
                    VStack(alignment: .leading) {
                        Text("\(post.reaction.rawValue) / \(post.state)")
                        Text(verbatim: post.text)
                        Text(post.createdAtISO).font(.caption)
                        if post.imageId != nil { Text("Gallery reference withheld here; no image access granted.").font(.caption) }
                        Button("Withdraw my captured post revision", role: .destructive) {
                            session.run { client in
                                try await client.withdrawGuestbook(eventID: post.eventId, postID: post.id, revision: post.revision)
                                try session.checked(client); value = nil
                                let result = try await client.ownedGuestbook(page: page); try session.checked(client); value = result
                            }
                        }.disabled(session.busy || post.state == "withdrawn")
                    }
                }
                HStack {
                    Button("Previous") { page -= 1; load() }.disabled(page == 1)
                    Button("Next") { page += 1; load() }.disabled(!value.hasMore || page >= 1000)
                }.disabled(session.busy)
            }
        }.navigationTitle("My guestbook receipts").modernScene()
        .task(id: "\(community.accountRevision):\(community.config?.eventGuestbookAvailable == true)") { value = nil; page = 1; session.bind(community); load() }
        .onChange(of: session.denied) { _, denied in if denied { value = nil } }
        .onChange(of: phase) { _, state in value = nil; session.clear(); if state == .active { session.bind(community); load() } }
        .onDisappear { value = nil; session.clear() }
    }
    private func load() {
        value = nil; let selected = page
        session.run { client in
            let result = try await client.ownedGuestbook(page: selected); try session.checked(client)
            guard page == selected else { return }; value = result
        }
    }
}
