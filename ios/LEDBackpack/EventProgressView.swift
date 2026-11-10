import SwiftUI
import BackpackProtocol

@MainActor
struct EventProgressView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let eventID: UUID
    var initialCheckpointID: UUID? = nil
    @State private var didSeedInitial = false
    @State private var event: CatalogEvent?
    @State private var board: EventSharedProgressBoard?
    @State private var clock: CatalogEventClock?
    @State private var choice = EventProgressChoice()
    @State private var pending: EventProgressIntent?
    @State private var withdrawing = false
    @State private var localCheckpoint: UUID?
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Latest self-reported checkpoint").font(.title2.bold())
                Text("Not a GPS fix, travel timeline, certified arrival or attendance. No sensors activate here. Private badge collection/deletion is separate.").font(.caption)
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if session.busy { ProgressView() }
                Button("Refresh current membership / board") { pending = nil; load() }.disabled(session.busy)
                if let event, let client = session.client, client.progressDeadlinesEnabled(event) {
                    if event.requiresReconfirmation == true {
                        NavigationLink("Review changed event before claiming") { CommunityEventDetailView(id: eventID) }
                    }
                    if event.access.member && event.access.canViewProgress, let board, let clock {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            entries(board, clock: clock, event: event, client: client)
                        }
                    }
                    if canClaim(event), let route = event.route {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Published checkpoint", selection: $choice.checkpointID) {
                                Text("Choose checkpoint").tag(UUID?.none)
                                ForEach(route.checkpoints.sorted { $0.order < $1.order }) { checkpoint in
                                    Text("\(checkpoint.title) · \(checkpoint.kind.rawValue)\(checkpoint.optional == true ? " · optional" : " · required")").tag(Optional(checkpoint.id))
                                }
                            }
                            Toggle("Explicitly share this latest claim with current members", isOn: $choice.share)
                            InteractionExplanation("Sharing is off by default. Local-only also withdraws any earlier shared claim. No offline replay is queued.", details: "Default off. Local-only validates the checkpoint but does not publish a claim; it also withdraws any previously shared claim on the server. Its checkpoint remains only in this screen's memory, not a queued replay.").font(.caption)
                            Button(choice.share ? "Review shared self-report" : "Review local-only choice / unshare") { prepare(event) }
                                .disabled(choice.checkpointID == nil || session.busy)
                            InteractionExplanation("Current participation, checkpoint order and event timing apply. Rejection resets sharing consent; no retry is queued.", details: "Server enforces required checkpoint order, optional skips, published start/finish, current reviewed participation and the exact event time window. A rejection resets sharing consent; no retry is queued.").font(.caption)
                        }.padding(16).glassPanel().disabled(session.busy)
                    } else {
                        Text("Claims require going RSVP, current reviewed membership, a published route and the actual event window.").font(.caption)
                    }
                    if let localCheckpoint { Text("Local-only checkpoint ID: \(localCheckpoint.uuidString.lowercased()). Not shared or certified.").font(.caption) }
                } else if !session.busy { Text("Current member progress/retention capability is unavailable. Existing shared state can still be explicitly withdrawn below.") }
                Button("Withdraw my shared progress", role: .destructive) { withdrawing = true }.disabled(session.busy)
                Text("Withdrawal sends only DELETE for your own event progress, even after event access loss. It does not decline RSVP, delete private badges or require a current board/detail read.").font(.caption)
            }.padding(20)
        }.modernScene().navigationTitle("Shared progress")
        .task(id: community.accountRevision) { clear(); session.bind(community); load() }
        .task(id: "\(phase):\(community.accountRevision)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if !session.busy && pending == nil && !withdrawing { load() }
            }
        }
        .onChange(of: choice.checkpointID) { _, _ in choice.share = false; pending = nil }
        .onChange(of: community.accountRevision) { _, _ in clear(); session.clear(); dismiss() }
        .onChange(of: phase) { _, state in clear(); session.clear(); if state == .active { session.bind(community); load() } }
        .onDisappear { clear(); session.clear() }
        .confirmationDialog("Confirm captured checkpoint choice?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let pending { Button(pending.share ? "Share this self-report" : "Keep local-only / withdraw prior sharing") { claim(pending) } }
        } message: { Text("Only the captured checkpoint/share choice is sent. Context/review/membership changes cancel the intent and reset consent; no automatic retry or sensor collection.") }
        .confirmationDialog("Withdraw your own latest shared progress?", isPresented: $withdrawing) {
            Button("Withdraw shared progress", role: .destructive) {
                choice.clear(); pending = nil; board = nil; localCheckpoint = nil; withdrawing = false
                // Rebind account scope, not event access, after a denied board/detail read.
                session.bind(community)
                session.run({ try await $0.withdrawOwnProgress(eventID: eventID) }, success: { notice = "Shared progress withdrawn. Private badges unchanged." })
            }
        }
    }
    @ViewBuilder private func entries(_ board: EventSharedProgressBoard, clock: CatalogEventClock,
        event: CatalogEvent, client: CommunityFeatureClient) -> some View {
        switch Result(catching: { try board.currentEntries(expiryEnabled: client.progressDeadlinesEnabled(event), at: clock.now()) }) {
        case .failure(let error): Text(error.localizedDescription).foregroundStyle(.orange)
        case .success(let rows):
            Text("Current members' latest claims").font(.headline)
            if rows.isEmpty { Text("No currently retained shared claims.").font(.caption) }
            ForEach(rows, id: \.user.id) { row in
                HStack(alignment: .top) {
                    CommunityProfileAvatar(person: row.user, client: client).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.user.displayName).font(.headline)
                        Text(event.route?.checkpoints.first(where: { $0.id == row.checkpointId })?.title ?? "Checkpoint unavailable")
                        Text(row.finished ? "Finish self-reported" : "Checkpoint self-reported").font(.caption)
                        Text("Retention deadline: \(row.expiresAtISO ?? "unavailable")").font(.caption)
                    }
                }.padding(12).glassPanel()
            }
        }
    }
    private func canClaim(_ event: CatalogEvent) -> Bool {
        guard let clock, event.access.member, event.access.canViewProgress, event.rsvpStatus == .going, event.requiresReconfirmation == false,
              event.participationRevision != nil, event.route?.published == true, !event.cancelled,
              let start = try? CatalogEventTime.parse(event.startsAtISO), let end = try? CatalogEventTime.parse(event.endsAtISO) else { return false }
        return clock.now() >= start && clock.now() < end
    }
    private func load() {
        board = nil
        session.run { client in
            do {
                let current = try await client.event(eventID)
                try session.checked(client)
                choice.update(current); event = current; clock = try CatalogEventClock(serverTime: current.serverTime)
                if !didSeedInitial, let initialCheckpointID {
                    guard current.route?.checkpoints.contains(where: { $0.id == initialCheckpointID }) == true else {
                        throw BackpackError.invalid("The selected GPS checkpoint is no longer in the current fixed plan. Choose/review again.")
                    }
                    choice.checkpointID = initialCheckpointID; choice.share = false; didSeedInitial = true
                }
                guard current.access.member, current.access.canViewProgress, current.requiresReconfirmation != true,
                      client.progressDeadlinesEnabled(current) else {
                    choice.clear(); return
                }
                let result = try await client.currentSharedProgress(current)
                try session.checked(client); board = result; clock = try CatalogEventClock(serverTime: result.serverTime)
            } catch { event = nil; board = nil; clock = nil; choice.clear(); pending = nil; localCheckpoint = nil; throw error }
        }
    }
    private func prepare(_ event: CatalogEvent) {
        session.run { client in
            guard client.progressDeadlinesEnabled(event), let checkpoint = choice.checkpointID else { throw BackpackError.invalid("Select a current published checkpoint.") }
            pending = try EventProgressIntent(event: event, checkpointID: checkpoint, share: choice.share)
        }
    }
    private func claim(_ intent: EventProgressIntent) {
        pending = nil; choice.share = false
        session.run({ client in
            do {
                let receipt = try await client.claimCheckpoint(intent)
                try session.checked(client)
                localCheckpoint = receipt.localOnly ? intent.checkpointID : nil
                notice = receipt.shared ? "Self-report shared. Retention deadline: \(receipt.expiresAtISO ?? "unavailable")." : "Local-only choice confirmed; prior shared claim cleared. No private badge collected."
                choice.clear()
            } catch { choice.clear(); board = nil; pending = nil; notice = "Claim not confirmed. Refresh current board before any new deliberate claim; no retry is queued."; throw error }
        }, success: load)
    }
    private func clear() { event = nil; board = nil; clock = nil; choice.clear(); didSeedInitial = false; pending = nil; withdrawing = false; localCheckpoint = nil; notice = nil }
}
