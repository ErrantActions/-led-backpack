import SwiftUI
import BackpackProtocol

@MainActor
struct EventRosterView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let eventID: UUID
    @State private var event: CatalogEvent?
    @State private var roster: NativeEventRoster?
    @State private var page = 1
    @State private var friends: [SocialPerson] = []
    @State private var friendPage = 1
    @State private var moreFriends = false
    @State private var customDeadline = false
    @State private var deadline = Date().addingTimeInterval(7 * 86400)
    @State private var pending: Action?
    @State private var needsReload = false
    @State private var notice: String?
    private struct Action {
        let event: CatalogEvent
        let target: UUID
        let name: String
        let kind: CommunityFeatureClient.OrganizerAction
        let expiry: String?
        let scope: UUID
        let friendPage: Int
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if session.busy { ProgressView() }
                Button("Explicitly refresh current roster / access") { pending = nil; load() }.disabled(session.busy)
                if needsReload { Text("Review failed/stale action. No automatic replay; refresh current access and select again.").foregroundStyle(.orange) }
                if let event, let roster, let client = session.client, event.access.canManage {
                    Text("Participants & current invitations").font(.title2.bold())
                    Text("Revision \(roster.eventRevision) · \(roster.organizerRole.rawValue) · server \(roster.serverTime)").font(.caption)
                    Text("This is a current roster, not a historical archive of expired/revoked grants. Invitation expiry/revocation does not remove independent going or organizer membership.").font(.caption)
                    ForEach(roster.participants, id: \.user.id) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                CommunityProfileAvatar(person: row.user, client: client).frame(width: 44, height: 44)
                                Text(row.user.displayName).font(.headline)
                            }
                            Text("Role: \(row.eventRole?.rawValue ?? "participant") · RSVP: \(row.rsvpStatus?.rawValue ?? "none")").font(.caption)
                            if row.invited { Text(row.invitationDeadline.label).font(.caption) }
                            if row.requiresReconfirmation { Label("Current plan needs fresh review", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                            if row.invited { Button("Review invitation revocation") { capture(event, person: row.user, kind: .revokeInvite) } }
                            if event.access.role == .owner && row.eventRole == nil {
                                Button("Review participant removal", role: .destructive) { capture(event, person: row.user, kind: .removeParticipant) }
                            }
                        }.padding(16).glassPanel().disabled(session.busy || needsReload)
                    }
                    HStack {
                        Button("Previous participants") { page -= 1; load() }.disabled(page == 1)
                        Spacer()
                        Button("Next participants") { page += 1; load() }.disabled(page * 24 >= roster.total)
                    }.disabled(session.busy)
                    if community.config?.socialEnabled == true {
                        Text("Invite a current friend").font(.headline)
                        if client.invitationDeadlinesEnabled(event) {
                            Toggle("Explicitly set / change grant deadline", isOn: $customDeadline)
                            if customDeadline {
                                DatePicker("Expiry (UTC)", selection: $deadline, displayedComponents: [.date, .hourAndMinute]).environment(\.timeZone, .gmt)
                            }
                            Text("Omit expiry: new grants default to seven days; active grants retain their actual expiry/legacy null. Explicit future UTC <=30 days deliberately changes the grant.").font(.caption)
                        }
                        ForEach(friends) { person in
                            Button { capture(event, person: person, kind: .invite) } label: {
                                HStack { CommunityProfileAvatar(person: person, client: client).frame(width: 40, height: 40); Text("Review inviting \(person.displayName)") }
                            }.disabled(session.busy || needsReload)
                        }
                        HStack {
                            Button("Previous friends") { friendPage -= 1; load() }.disabled(friendPage == 1)
                            Spacer()
                            Button("Next friends") { friendPage += 1; load() }.disabled(!moreFriends)
                        }.disabled(session.busy)
                    }
                    InteractionExplanation("Invitation withdrawal is not participant removal. Removal can clear progress/access; protected organizer roles still apply.", details: "Revocation only withdraws the invitation. Owner-only participant removal is separate and can clear shared progress/access. Organizers are protected from participant removal; no global-admin role bypass.").font(.caption)
                } else if !session.busy { Text("Current event organizer access is required. Cached names/avatars are cleared when access is lost.") }
            }.padding(20)
        }.modernScene().navigationTitle("Event roster")
        .task(id: community.accountRevision) { clear(); session.bind(community); load() }
        .task(id: "\(phase):\(community.accountRevision)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !session.busy && pending == nil && !needsReload { load() }
            }
        }
        .task(id: "\(roster?.serverTime ?? ""):\(phase)") {
            guard phase == .active, let roster else { return }
            do {
                let server = try CatalogEventClock(serverTime: roster.serverTime)
                let remaining = try roster.participants.compactMap { row -> TimeInterval? in
                    guard row.invited, let raw = row.invitationDeadline.wireValue else { return nil }
                    return max(0, try CatalogEventTime.parse(raw).timeIntervalSince(server.now()))
                }.min()
                guard let remaining else { return }
                try await Task.sleep(for: .seconds(remaining)); try Task.checkCancellation()
                self.roster = nil; friends = []; pending = nil; load()
            } catch { if !Task.isCancelled { session.run { _ in throw error } } }
        }
        .onChange(of: community.accountRevision) { _, _ in clear(); session.clear(); dismiss() }
        .onChange(of: phase) { _, state in clear(); session.clear(); if state == .active { session.bind(community); load() } }
        .onDisappear { clear(); session.clear() }
        .alert("Confirm captured roster action", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { value in
            Button(value.kind.label, role: value.kind == .removeParticipant ? .destructive : nil) { apply(value) }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            Text("\(value.kind.label): \(value.name), captured event revision \(value.event.revision). \(value.expiry.map { "Explicit expiry: \($0)." } ?? "No expiry is supplied; no active grant is automatically renewed.") No RSVP/friendship/role is automatically granted. Revoking an invite is not participant removal.")
        }
    }
    private func capture(_ event: CatalogEvent, person: SocialPerson, kind: CommunityFeatureClient.OrganizerAction) {
        guard let client = session.client else { return }
        let expiry = kind == .invite && customDeadline ? CatalogEventTime.wire(deadline) : nil
        pending = Action(event: event, target: person.id, name: person.displayName, kind: kind, expiry: expiry, scope: client.instanceID, friendPage: friendPage)
    }
    private func load() {
        let currentPage = page, currentFriends = friendPage
        roster = nil; friends = []
        session.run { client in
            do {
                let current = try await client.event(eventID)
                guard current.access.canManage else { throw BackpackError.invalid("Current organizer access was lost.") }
                let list = try await client.participantRoster(current, page: currentPage)
                let peers = community.config?.socialEnabled == true ? try await client.friends(page: currentFriends).friends : []
                try session.checked(client)
                guard page == currentPage, friendPage == currentFriends else { return }
                event = current; roster = list; friends = peers; moreFriends = peers.count == 50; needsReload = false
            } catch { event = nil; roster = nil; friends = []; customDeadline = false; pending = nil; needsReload = true; throw error }
        }
    }
    private func apply(_ action: Action) {
        session.run(expected: action.scope, { client in
            do {
                if action.kind == .invite {
                    let current = try await client.event(eventID)
                    guard current.revision == action.event.revision, current.access.role == action.event.access.role else { throw BackpackError.invalid("Roster/event revision or role changed. Refresh; no automatic renewal.") }
                    let peers = try await client.friends(page: action.friendPage)
                    guard peers.friends.contains(where: { $0.id == action.target }) else { throw BackpackError.invalid("Selected friend is no longer in the captured current friend page.") }
                    let result = try await client.invite(current, target: action.target, expiresAtISO: action.expiry)
                    try session.checked(client); notice = result.deadline.label
                } else {
                    try await client.rosterAction(action.event, target: action.target, action: action.kind)
                    try session.checked(client); notice = action.kind == .revokeInvite ? "Invitation revoked; independent membership may remain." : "Participant removal confirmed."
                }
                pending = nil
            } catch { needsReload = true; pending = nil; roster = nil; friends = []; throw error }
        }, success: load)
    }
    private func clear() { event = nil; roster = nil; friends = []; pending = nil; customDeadline = false; needsReload = false; notice = nil }
}
