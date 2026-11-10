import SwiftUI
import BackpackProtocol

@MainActor
struct EventAwardListView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    @State private var page = 1
    @State private var value: NativeOwnedEventBadges?
    @State private var pending: Action?
    @State private var needsReload = false
    @State private var notice: String?
    private struct Action {
        enum Kind { case show, hide, remove }
        let award: NativeOwnedEventBadge
        let kind: Kind
        let scope: UUID
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your private badges").font(.title2.bold())
                Text("Self-reported and uncertified, not proof of attendance or arrival. Private by default. Names/descriptions can reveal participation or visits to known places.").font(.caption)
                FeatureDetails("Limits & stored data") {
                    Text("Up to 500 private records and 12 requested profile badges. No offline claim uploads, artwork bytes or private-media credentials are stored in a badge.")
                }
                Button("Refresh badges") { pending = nil; reload() }.disabled(session.busy)
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if needsReload { Text("Captured action was not confirmed. Refresh and review; no silent overwrite/republication or automatic retry.").foregroundStyle(.orange) }
                if session.busy { ProgressView() }
                if let value {
                    ForEach(value.awards) { award in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(award.title, systemImage: "seal").font(.headline)
                            Text(verbatim: award.description)
                            Text("\(award.kind.rawValue) · collected event version \(award.eventVersion) · self-reported / uncertified").font(.caption)
                            LabeledContent("Currently profile-visible", value: award.profileVisible ? "Yes" : "No")
                            FeatureDetails("Sharing permission & revision") {
                                LabeledContent("Sharing requested", value: award.sharingRequested ? "Yes" : "No")
                                LabeledContent("Current permission", value: award.canShowProfile ? "Available" : "Unavailable")
                                Text("Participation revision: \(award.currentParticipationRevision.map(String.init) ?? "unavailable")").font(.caption)
                            }
                            if award.canShowProfile, !award.sharingRequested {
                                Button("Review profile sharing") { capture(award, kind: .show) }
                            }
                            if award.sharingRequested || award.profileVisible {
                                Button("Review hiding this badge") { capture(award, kind: .hide) }
                            }
                            Button("Review removing badge", role: .destructive) { capture(award, kind: .remove) }
                            if !award.canShowProfile {
                                Text("Old versions stay private. Rejoining/reviewing an event never republishes an earlier choice automatically. Hide/remove do not require event access.").font(.caption)
                            }
                        }.padding(16).glassPanel().disabled(session.busy || needsReload)
                    }
                    HStack {
                        Button("Previous") { page -= 1; reload() }.disabled(page == 1)
                        Spacer()
                        Button("Next") { page += 1; reload() }.disabled(!value.hasMore)
                    }.disabled(session.busy)
                    if value.awards.isEmpty { Text("No owned records on this page. Collection is explicit from an authorized event.").font(.caption) }
                } else if !session.busy { Text("Private badge records are unavailable until social/me explicitly enables the capability. No event access or admin override is inferred.") }
                InteractionExplanation("Badge visibility needs profile and event permission. Friendship alone does not grant private-event access.", details: "Profile display still requires normal profile authorization AND current event authorization for every viewer. Friendship alone does not unlock private-event badges; already seen information cannot be recalled.").font(.caption)
            }.padding(20)
        }.modernScene().navigationTitle("My private badges")
        .task(id: community.accountRevision) { clear(); session.bind(community); reload() }
        .task(id: "\(phase):\(community.accountRevision)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !session.busy && pending == nil && !needsReload { reload() }
            }
        }
        .onChange(of: community.accountRevision) { _, _ in clear(); session.clear(); dismiss() }
        .onChange(of: phase) { _, state in clear(); session.clear(); if state == .active { session.bind(community); reload() } }
        .onDisappear { clear(); session.clear() }
        .alert("Confirm captured private badge action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
            Button(action.kind == .show ? "I consent: show this badge" : action.kind == .hide ? "Hide this badge" : "Remove my record",
                role: action.kind == .remove ? .destructive : nil) { apply(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text("Only \(action.award.title), collected version \(action.award.eventVersion), current displayed revision \(action.award.currentParticipationRevision.map(String.init) ?? "unavailable"). Showing can reveal participation/known-place visits and requires separate consent. Hiding/removing does not change RSVP or shared progress; no automatic republish.")
        }
    }
    private func capture(_ award: NativeOwnedEventBadge, kind: Action.Kind) {
        guard let client = session.client else { return }
        pending = Action(award: award, kind: kind, scope: client.instanceID)
    }
    private func reload() {
        value = nil
        if session.denied || session.client == nil { session.bind(community) }
        let requestedPage = page
        session.run { client in
            do {
                let result = try await client.ownEventBadges(page: requestedPage)
                try session.checked(client); guard requestedPage == page else { return }
                value = result; needsReload = false
            } catch { value = nil; pending = nil; needsReload = true; throw error }
        }
    }
    private func apply(_ action: Action) {
        session.run(expected: action.scope, { client in
            do {
                if action.kind == .remove { try await client.deleteOwnEventBadge(action.award) }
                else {
                    let intent = try EventBadgeProfileIntent(award: action.award, visible: action.kind == .show, consent: action.kind == .show)
                    _ = try await client.setBadgeProfileChoice(intent)
                }
                try session.checked(client); pending = nil; notice = "Captured badge action confirmed; no RSVP/progress change."
            } catch { needsReload = true; pending = nil; value = nil; throw error }
        }, success: reload)
    }
    private func clear() { value = nil; pending = nil; needsReload = false; notice = nil }
}

@MainActor
struct EventAwardCollectionView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let eventID: UUID
    @State private var event: CatalogEvent?
    @State private var choice = EventBadgeCollectionChoice()
    @State private var pending: EventBadgeCollectionIntent?
    @State private var notice: String?
    @State private var needsReload = false
    var body: some View {
        Form {
            Text("Collect privately, only by choice").font(.headline)
            InteractionExplanation("Private, self-reported collection—not proof of attendance. Names may reveal participation; nothing is published automatically.", details: "Self-reported/uncertified; not verified attendance, arrival or route completion. Names/descriptions can reveal participation or visits to known places even in a private account record. Collection does not share progress, RSVP or publish to a profile.").font(.caption)
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if let notice { Text(notice).font(.caption) }
            if session.busy { ProgressView() }
            Button("Refresh collection access") { pending = nil; reload() }.disabled(session.busy)
            if let event, event.settings?.accountAwardsEnabled == true {
                if event.requiresReconfirmation == true {
                    NavigationLink("Review changed event first") { CommunityEventDetailView(id: eventID) }
                } else if event.access.member && event.rsvpStatus == .going && !event.cancelled {
                    Picker("Private record choice", selection: $choice.checkpointID) {
                        Text("Joined-event record only (not attendance)").tag(UUID?.none)
                        if let route = event.route, route.published {
                            ForEach(route.checkpoints.sorted { $0.order < $1.order }) { checkpoint in
                                Text("\(checkpoint.title) · \(checkpoint.kind.rawValue)\(checkpoint.optional == true ? " · optional" : " · required")").tag(Optional(checkpoint.id))
                            }
                        }
                    }.disabled(session.busy)
                    Toggle("Collect this choice privately", isOn: $choice.consent).disabled(session.busy)
                    InteractionExplanation("Event order and time rules apply. Repeating is idempotent, not an automatic retry. Up to 500 private records.", details: "Server enforces ordered required checkpoints, optional skips, published start/finish and the actual event window. Finish may collect finish/named rewards. Repeating is idempotent, not an automatic retry. Limit: 500 private records.").font(.caption)
                    FeatureDetails("Collection privacy") {
                        Text("Captured event/participation revision and checkpoint only. No GPS, arrival/departure timeline, media bytes or credentials. Profile display requires another explicit choice. Context/conflict resets consent; no queued replay.")
                    }
                    Button("Review private collection") { prepare(event) }.buttonStyle(AuroraPrimaryButton()).disabled(!choice.consent || session.busy || needsReload)
                } else { Text("A current reviewed going RSVP is required. No badge is collected automatically by RSVP or progress.") }
            } else if !session.busy { Text("Both social/me and this event must explicitly enable account badges. Missing capabilities remain unavailable.") }
            NavigationLink("My private badge records / profile choices") { EventAwardListView() }
        }.modernScene().navigationTitle("Private badge collection")
        .task(id: community.accountRevision) { clear(); session.bind(community); reload() }
        .onChange(of: choice.checkpointID) { _, _ in choice.consent = false; pending = nil }
        .onChange(of: community.accountRevision) { _, _ in clear(); session.clear(); dismiss() }
        .onChange(of: phase) { _, state in clear(); session.clear(); if state == .active { session.bind(community); reload() } }
        .onDisappear { clear(); session.clear() }
        .confirmationDialog("Collect only this private self-report?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let pending { Button("I consent: collect privately") { collect(pending) } }
        } message: { Text("This checkpoint and revision only. No GPS or media is sent. Context changes reset consent; profile sharing is separate.") }
    }
    private func reload() {
        choice.clear(); event = nil
        if session.denied || session.client == nil { session.bind(community) }
        session.run { client in
            do {
                try await client.requireAccountAwards()
                let current = try await client.event(eventID)
                guard current.settings?.accountAwardsEnabled == true else { throw BackpackError.invalid("This event has not enabled private account badge collection.") }
                try session.checked(client); event = current; choice.update(current); needsReload = false
            } catch { event = nil; choice.clear(); pending = nil; needsReload = true; throw error }
        }
    }
    private func prepare(_ current: CatalogEvent) {
        session.run { _ in pending = try EventBadgeCollectionIntent(event: current, checkpointID: choice.checkpointID, consent: choice.consent) }
    }
    private func collect(_ intent: EventBadgeCollectionIntent) {
        pending = nil; choice.consent = false
        session.run { client in
            do {
                let result = try await client.collectEventBadges(intent)
                try session.checked(client)
                notice = "\(result.collected) new private self-reported record(s) confirmed. Profile display remains a separate choice; shared progress unchanged."
                choice.clear(); needsReload = true
            } catch { choice.clear(); event = nil; needsReload = true; throw error }
        }
    }
    private func clear() { event = nil; choice.clear(); pending = nil; notice = nil; needsReload = false }
}

struct AuthorizedProfileEventBadges: View {
    let badges: [NativeProfileEventBadge]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(badges) { badge in
                Label(badge.title, systemImage: "seal").font(.caption)
            }
            if !badges.isEmpty { Text("Self-reported, not certified attendance. Only currently authorized profile/event badges are supplied by the service.").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
