import SwiftUI
import BackpackProtocol

@MainActor
struct FriendLocationFeaturesView: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var local: ForegroundCheckpointLocation
    @EnvironmentObject private var interactions: FriendPhoneInteractionStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    @State private var profile: SocialPreferences?
    @State private var friends: [SocialPerson] = []
    @State private var sessions: [NativeFriendSession] = []
    @State private var clock: CatalogEventClock?
    @State private var page = 1
    @State private var revision: Int?
    @State private var kind = FriendInteractionKind.greeting
    @State private var seconds = 60
    @State private var consent = false
    @State private var intent: FriendSessionIntent?
    @State private var confirmed = false
    @State private var needsReload = false
    @State private var notice: String?
    @State private var pending: Action?
    @State private var playbackSession: NativeFriendSession?
    private struct Action {
        let label, detail: String
        let work: @MainActor (CommunityFeatureClient) async throws -> Void
    }
    var body: some View {
        Form {
            Section("Real states, separate permissions") {
                Text(local.status)
                Label(local.sensing ? "Phone sensing ACTIVE" : "Phone sensing OFF", systemImage: local.sensing ? "location.fill" : "location.slash")
                Text("Service consent/session state is not actual proximity, ranging or playback. Friend sessions use no phone sensor. Local checkpoint sensing is enabled separately on a downloaded event.").font(.caption)
                Text("Participation, shared images and timed interactions can imply nearby presence without coordinates. Mutual per-friend permission, explicit session consent and separate foreground OS consent are required for their respective features.").font(.caption)
                Button("Stop all location features", role: .destructive) { stopAll() }
                if let notice { Text(notice).font(.caption) }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                Button("Explicitly reload current permissions/sessions") {
                    if confirmed { intent = nil; confirmed = false }
                    load()
                }
                if intent != nil && !confirmed { Text("Finalized invitation retained after uncertain I/O. Reconcile sessions before discarding it; no automatic retry/renewal.").foregroundStyle(.orange) }
                if intent != nil && !confirmed {
                    Button("Discard uncertain intent after reviewing sessions") { intent = nil; consent = false; needsReload = true }
                }
            }
            if let profile {
                Section("Independent per-friend permissions") {
                    Text("Current service stop revision: \(revision.map(String.init) ?? "unavailable")").font(.caption)
                    ForEach(friends) { person in
                        VStack(alignment: .leading) {
                            Text(person.displayName)
                            Text("Your allow: \(person.locationFeaturesAllowed == true ? "on" : "off"); mutual: \(person.mutualLocationFeaturesAllowed == true ? "yes" : "no")").font(.caption)
                            Button(person.locationFeaturesAllowed == true ? "Review disabling for this friend" : "Review enabling for this friend") {
                                let enabled = person.locationFeaturesAllowed != true, capture = revision
                                review("Change per-friend permission", "Only \(person.displayName); enabling uses captured stop revision \(capture.map(String.init) ?? "legacy"). OS permission does not enable this.") { client in
                                    local.stop("Per-friend permission changed — explicit restart required")
                                    try await client.futureLocation(person.id, enabled: enabled, expectedControlsRevision: capture)
                                }
                            }.disabled(needsReload || (revision == nil && profile.socialLocationGlobalStopEnabled == true))
                            if person.locationFeaturesAllowed == true && person.mutualLocationFeaturesAllowed == true &&
                                profile.friendSessionsAvailable == true && community.config?.friendSessionsAvailable == true {
                                Button("Review inviting \(person.displayName)") {
                                    do {
                                        let captured = try FriendSessionIntent(peer: person, kind: kind, seconds: seconds, consent: consent)
                                        review("Invite limited control session", "\(person.displayName), \(kind.rawValue), \(seconds)s. This starts no physical feature or sensor.") { client in
                                            intent = captured; confirmed = false
                                            _ = try await client.inviteFriendSession(captured)
                                            try session.checked(client); confirmed = true; consent = false
                                        }
                                    } catch { session.run { _ in throw error } }
                                }.disabled(!consent || intent != nil || needsReload)
                            }
                        }
                    }
                    HStack { Button("Previous") { page -= 1; load() }.disabled(page == 1); Spacer(); Button("Next") { page += 1; load() }.disabled(friends.count < 50) }
                }
                if profile.friendSessionsAvailable == true && community.config?.friendSessionsAvailable == true {
                    Section("Volatile timed session consent") {
                        Picker("Planned phone interaction kind", selection: $kind) { ForEach(FriendInteractionKind.allCases) { Text($0.rawValue).tag($0) } }
                        Stepper("Duration \(seconds) seconds", value: $seconds, in: 60...900, step: 30)
                        Toggle("I consent to one deliberately selected friend control session", isOn: $consent)
                        Text("Control acceptance alone starts no media. Active owned sessions have a separate PHONE scene page with explicit kind/preset/media arming. No game, coordinates/history, ranging or verified clock sync.").font(.caption)
                        if let clock {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                ForEach(sessions) { value in
                                    if let expires = try? CatalogEventTime.parse(value.expiresAtISO), expires > clock.now() {
                                        VStack(alignment: .leading) {
                                            Text("\(value.peer.displayName): \(value.kind.rawValue) — \(value.status)")
                                            Text("Expires \(value.expiresAtISO); this login owns it: \(value.ownedByCurrentSession ? "yes" : "no")").font(.caption)
                                            if value.direction == "incoming" && value.status == "pending" {
                                                Button("Review accept") { respond(value, accept: true) }
                                                Button("Review decline") { respond(value, accept: false) }
                                            }
                                            if value.status == "active" && value.ownedByCurrentSession && community.config?.friendSessionPeerIdentityEnabled == true {
                                                Button("Choose / preview / arm PHONE interaction") { playbackSession = value }
                                            }
                                            Button("Review stop", role: .destructive) {
                                                review("Stop captured session", "Stops only this service session; phone sensing is also stopped locally.") { client in
                                                    interactions.stopSelected(value.id)
                                                    local.stop("Session stopped"); try await client.stopFriendSession(value)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.modernScene().navigationTitle("Location-powered consent")
        .navigationDestination(isPresented: Binding(get: { playbackSession != nil }, set: { if !$0 { playbackSession = nil } })) {
            if let playbackSession { FriendPlaybackView(selected: playbackSession) }
        }
        .task(id: community.accountRevision) { clear(); session.bind(community); load() }
        .task(id: "\(phase):\(community.accountRevision)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if !session.busy && pending == nil && !needsReload { load() }
            }
        }
        .onChange(of: kind) { _, _ in consent = false }
        .onChange(of: seconds) { _, _ in consent = false }
        .onChange(of: community.accountRevision) { _, _ in local.stop("Account changed"); clear(); session.clear(); dismiss() }
        .onChange(of: phase) { _, value in
            if value != .active { local.stop("Background — no restart"); stopServiceOnExit(); clear() }
        }
        .onDisappear {
            local.stop("Feature page closed")
            if playbackSession == nil { stopServiceOnExit(); clear() }
            session.clear()
        }
        .alert("Confirm location-feature control", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { value in
            Button(value.label) {
                session.run({ client in
                    do { try await value.work(client); pending = nil }
                    catch { local.stop("Service consent/action failed"); needsReload = true; consent = false; pending = nil; throw error }
                }, success: load)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text($0.detail) }
    }
    private func review(_ label: String, _ detail: String, work: @escaping @MainActor (CommunityFeatureClient) async throws -> Void) {
        guard !session.busy else { return }
        pending = Action(label: label, detail: detail, work: work)
    }
    private func respond(_ value: NativeFriendSession, accept: Bool) {
        review(accept ? "Accept this timed session" : "Decline", "Captured revision \(value.revision); acceptance does not extend expiry or start sensing/playback.") { client in
            local.stop("Session permission changed"); try await client.respondFriendSession(value, accept: accept)
        }
    }
    private func load() {
        guard !session.busy else { return }
        if session.client == nil || session.denied { session.bind(community) }
        session.run { client in
            do {
                let info = try await client.preferences(), list = try await client.friends(page: page)
                let controls = list.locationControlsRevision ?? info.locationControlsRevision
                if revision != controls { local.stop("Service stop revision changed"); consent = false; pending = nil }
                let oldPermissions = friends.map { "\($0.id):\($0.locationFeaturesAllowed == true):\($0.mutualLocationFeaturesAllowed == true)" }
                let newPermissions = list.friends.map { "\($0.id):\($0.locationFeaturesAllowed == true):\($0.mutualLocationFeaturesAllowed == true)" }
                if oldPermissions != newPermissions { local.stop("Friend permissions changed"); consent = false; pending = nil }
                let current = info.friendSessionsAvailable == true && community.config?.friendSessionsAvailable == true ? try await client.friendSessions() : nil
                try session.checked(client)
                profile = info; friends = list.friends; revision = controls; sessions = current?.sessions ?? []
                clock = try current.map { try CatalogEventClock(serverTime: $0.serverTimeISO) }
                needsReload = false
            } catch { local.stop("Service access unavailable"); profile = nil; friends = []; sessions = []; consent = false; needsReload = true; throw error }
        }
    }
    private func stopAll() {
        community.stopLocalLocationFeatures?()
        local.stop("Stop all: local sensing OFF")
        consent = false; pending = nil; sessions = []
        session.bind(community)
        session.run { client in
            let next = try await client.stopAllServiceLocation()
            try session.checked(client); revision = next; friends = []; profile = nil; intent = nil
            notice = next == nil ? "Local sensing and service sessions stopped; per-friend flags were NOT globally cleared. A previously displayed hardware frame may remain." : "Local sensing stopped and service-wide flags/sessions/presence revoked. No hardware command/restoration was sent; a previous hardware frame may remain."
        }
    }
    private func stopServiceOnExit() {
        guard let client = session.client, !sessions.isEmpty else { return }
        Task {
            do { _ = try await client.stopAllServiceLocation() }
            catch { community.reportLocationStopFailure(error) }
        }
    }
    private func clear() { profile = nil; friends = []; sessions = []; clock = nil; consent = false; pending = nil; revision = nil }
}

@MainActor
struct EventLocalEligibilityView: View {
    @EnvironmentObject private var community: CommunityController
    @EnvironmentObject private var local: ForegroundCheckpointLocation
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    let eventID: UUID
    @State private var event: CatalogEvent?
    @State private var checkpointID: UUID?
    @State private var consent = false
    @State private var progressCheckpointID: UUID?
    @State private var showingProgress = false
    var body: some View {
        Form {
            Text("Foreground-only, local checkpoint hint").font(.headline)
            Text("Samples are discarded, never saved, logged, encoded or sent. No peer positions/distances, encounter history, background permission, GPS proof or navigation. Eligibility never records progress or badges.").font(.caption)
            Label(local.status, systemImage: local.sensing ? "location.fill" : "location.slash")
            Text(local.eligibility.rawValue)
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            Button("Refresh authorized fixed plan") { local.stop("Plan refresh requires new consent"); consent = false; load() }
            if let event, let route = event.route {
                Picker("Fixed checkpoint", selection: $checkpointID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(route.checkpoints) { Text($0.title).tag(Optional($0.id)) }
                }
                Toggle("I opt in to foreground local sensing for this checkpoint", isOn: $consent)
                Button("Request When In Use permission only") { local.requestWhenInUse(consent: consent) }
                Button("Start local sensing explicitly (60s maximum)") {
                    session.run { client in
                        local.stop("Validating fresh event context")
                        let current = try await client.event(eventID)
                        guard EventProgressContext(current) == EventProgressContext(event),
                              let checkpoint = current.route?.checkpoints.first(where: { $0.id == checkpointID }) else {
                            throw BackpackError.invalid("Current fixed plan changed; select/review again.")
                        }
                        try session.checked(client)
                        try local.start(event: current, checkpoint: checkpoint, accountRevision: community.accountRevision,
                            consent: consent, foreground: phase == .active, capability: client.progressDeadlinesEnabled(current))
                    }
                }.disabled(!consent || checkpointID == nil || session.busy)
            }
            Button("Stop local sensing", role: .destructive) { local.stop(); consent = false }
            if let hint = local.hint, hint.scope.eventID == eventID, hint.scope.accountRevision == community.accountRevision {
                Button("Review this selected checkpoint / sharing stays off") {
                    do {
                        try hint.require(hint.scope, uptime: ProcessInfo.processInfo.systemUptime)
                        _ = try local.consumeHint(hint.scope)
                        progressCheckpointID = hint.scope.checkpointID
                        local.stop("Selected checkpoint passed to explicit review — no GPS proof or upload"); consent = false
                        showingProgress = true
                    } catch { session.run { _ in throw error } }
                }
            }
            NavigationLink("Manual self-reported checkpoint choice") { EventProgressView(eventID: eventID) }
            Text("5s freshness, usable <=25m accuracy, 10s dwell inside confidence bounds, hysteresis reset and 60s cooldown. The configured radius is never enlarged. Manual fallback is always separate and uncertified.").font(.caption)
        }.modernScene().navigationTitle("Local checkpoint eligibility")
        .navigationDestination(isPresented: $showingProgress) {
            EventProgressView(eventID: eventID, initialCheckpointID: progressCheckpointID)
        }
        .task(id: community.accountRevision) { session.bind(community); load() }
        .onChange(of: checkpointID) { _, _ in local.stop("Checkpoint changed"); consent = false }
        .onChange(of: consent) { _, enabled in if !enabled { local.stop("Consent withdrawn") } }
        .onChange(of: phase) { _, value in if value != .active { local.stop("Background"); consent = false; event = nil; progressCheckpointID = nil; showingProgress = false; session.clear() } }
        .onChange(of: community.accountRevision) { _, _ in local.stop("Account changed"); consent = false; event = nil; progressCheckpointID = nil; showingProgress = false; session.clear() }
        .onDisappear { local.stop("Page closed"); consent = false; session.clear() }
    }
    private func load() {
        if session.client == nil || session.denied { session.bind(community) }
        session.run { client in
            do {
                let current = try await client.event(eventID)
                guard current.access.member, current.access.canViewProgress, client.progressDeadlinesEnabled(current) else { throw BackpackError.invalid("Current event/member capability is unavailable; manual fallback only.") }
                try session.checked(client); event = current; checkpointID = nil
            } catch { local.stop("Event access unavailable"); event = nil; consent = false; throw error }
        }
    }
}
