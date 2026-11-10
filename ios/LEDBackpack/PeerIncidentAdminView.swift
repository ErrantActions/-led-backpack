import SwiftUI
import BackpackProtocol

@MainActor
struct PeerIncidentAdminView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var store = CommunityAdminStore()
    @State private var page = 1
    @State private var value: NativePeerIncidentPage?
    @State private var clock: CatalogEventClock?
    @State private var selected: NativePeerIncident?
    @State private var selectedScope: UUID?
    @State private var resolved = true
    @State private var note = ""
    @State private var intent: PeerIncidentReviewIntent?
    @State private var confirming = false
    @State private var needsReload = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Private peer-incident review").font(.title2.bold())
                Text("Unverified allegations. Review does not prove misconduct or change an account.").font(.caption)
                if let failure = store.failure { Text(failure).foregroundStyle(.orange) }
                if store.busy { ProgressView() }
                if community.isAdmin && !store.denied {
                    if community.config?.peerIncidentReportsEnabled == true {
                        if let value, let clock {
                            if value.reports.isEmpty && !store.busy {
                                Text("No retained cases on this page.").foregroundStyle(.secondary)
                            }
                            Text("Server read clock: \(value.serverTimeISO), not encounter time.").font(.caption)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                ForEach(value.reports) { report in
                                    if let expires = try? CatalogEventTime.parse(report.expiresAtISO), clock.now() < expires {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(report.category.rawValue).font(.headline)
                                            Text(verbatim: report.details).textSelection(.enabled)
                                            Text("Claimed target: \(report.reportedUserId.uuidString.lowercased())").font(.caption.monospaced())
                                            Text("Reporter: \(report.reporterId?.uuidString.lowercased() ?? "unavailable")").font(.caption.monospaced())
                                            Text("Revision \(report.revision) · \(report.resolved ? "Resolved" : "Open") · Claim verified: NO").font(.caption)
                                            Text("Description deadline: \(report.expiresAtISO)").font(.caption)
                                            if let review = report.review {
                                                Text("Latest staff note (never returned to reporter)").font(.caption)
                                                Text(verbatim: review.note).textSelection(.enabled)
                                                Text(review.atISO).font(.caption)
                                            }
                                            Button("Review case") {
                                                selected = report; selectedScope = store.contextID; note = ""
                                                resolved = !report.resolved; intent = nil; confirming = false
                                            }.disabled(store.busy || selected != nil || needsReload)
                                        }.padding(16).glassPanel()
                                    } else { Text("Case description expired; no historical private evidence is retained in this view.").font(.caption) }
                                }
                            }
                            HStack {
                                Button("Previous") { page -= 1; load() }.disabled(page == 1 || selected != nil)
                                Spacer()
                                Button("Next") { page += 1; load() }.disabled(!value.hasMore || page >= 10000 || selected != nil)
                            }.disabled(store.busy)
                        }
                        if let selected {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Captured case \(selected.id.uuidString.lowercased()) / revision \(selected.revision)").font(.caption.monospaced())
                                Toggle("Mark resolved (still UNVERIFIED)", isOn: $resolved).disabled(intent != nil || store.busy)
                                TextField("Deliberately typed staff note (1–1000 UTF-16 units)", text: $note, axis: .vertical)
                                    .lineLimit(4...12).disabled(intent != nil || store.busy)
                                Button("Review & save note") { confirming = true }
                                    .buttonStyle(AuroraPrimaryButton())
                                    .disabled(store.busy || needsReload || intent != nil || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if needsReload { Text("Revision/key/access failure retained your captured intent. Explicitly cancel/reload; no retry or silent overwrite.").foregroundStyle(.orange) }
                                Button("Cancel review & reload", role: .cancel) { discardReview(); load() }.disabled(store.busy)
                            }.padding(16).glassPanel()
                        } else {
                            Button("Explicitly refresh retained cases") { load() }.disabled(store.busy)
                        }
                    } else {
                        Text("Description/review capability disabled or usable key absent. Review is unavailable, NOT an empty successful list. Permitted own receipts/withdrawal remain independent.").foregroundStyle(.orange)
                        if community.config?.peerIncidentWithdrawalEnabled == true {
                            NavigationLink("My own metadata withdrawal receipts") { PeerIncidentOwnerView() }
                        }
                    }
                } else { Text("Current global-admin access required. Role changes discard descriptions, selection and staff-note drafts.") }
                FeatureDetails("Retention & privacy") {
                    Text("Descriptions expire after 30 days; cleanup is bounded. No automatic account action, profile grant or artwork copy.")
                }
            }.padding(20)
        }.modernScene().navigationTitle("Peer reports (admin)")
        .task(id: "\(community.accountRevision):\(community.user?.role ?? "")") { clear(); page = 1; store.bind(community); if community.isAdmin && community.config?.peerIncidentReportsEnabled == true { load() } }
        .onChange(of: community.accountRevision) { _, _ in clear(); store.clear() }
        .onChange(of: community.user?.role) { _, _ in clear(); store.clear() }
        .onChange(of: community.origin?.url) { _, _ in clear(); store.clear() }
        .onChange(of: community.config?.peerIncidentReportsEnabled) { _, _ in clear(); store.clear() }
        .onChange(of: store.denied) { _, denied in if denied { clear() } }
        .onChange(of: phase) { _, state in if state != .active { clear(); store.clear() } }
        .onDisappear { clear(); store.clear() }
        .confirmationDialog("Save this captured staff note/review state?", isPresented: $confirming) {
            Button(resolved ? "Resolve — claim remains unverified" : "Reopen — claim remains unverified") { review() }
        } message: { Text("Uses the displayed revision. The note stays staff-only. Review takes no account action and grants no profile, artwork, message or proximity proof.") }
    }
    private func load() {
        value = nil; clock = nil
        store.bind(community)
        let requestedPage = page
        store.run { client in
            do {
                let result = try await client.peerIncidents(page: requestedPage); try store.checked(client)
                guard requestedPage == page else { return nil }
                value = result; clock = try CatalogEventClock(serverTime: result.serverTimeISO); needsReload = false
                return nil
            } catch { value = nil; clock = nil; needsReload = true; throw error }
        }
    }
    private func review() {
        guard let selected else { return }
        store.run({ client in
            guard intent == nil, !needsReload else { throw BackpackError.invalid("Explicitly discard/reload the retained peer review before another write.") }
            let captured = try PeerIncidentReviewIntent(report: selected, resolved: resolved, note: note); intent = captured
            do {
                _ = try await client.reviewPeerIncident(captured); try store.checked(client)
                discardReview()
                return "Peer incident review saved. Claim remains unverified; no account action."
            } catch { needsReload = true; throw error }
        }, expectedScope: selectedScope, success: load)
    }
    private func discardReview() { selected = nil; selectedScope = nil; note = ""; intent = nil; confirming = false; needsReload = false }
    private func clear() { value = nil; clock = nil; discardReview() }
}
