import SwiftUI
import BackpackProtocol

@MainActor
struct PeerIncidentComposeView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let selection: PeerIncidentSelection
    @State private var category = PeerIncidentCategory.other
    @State private var details = ""
    @State private var consent = false
    @State private var captured: PeerIncidentIntent?
    @State private var confirmation = false
    @State private var submitted: NativePeerIncident?
    @State private var clock: CatalogEventClock?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your explicitly selected claimed peer") {
                    Text(selection.label).font(.headline)
                    Text("Claimed account: \(selection.reportedUserID.uuidString.lowercased())").font(.caption.monospaced())
                    Text("Selected under your current account/catalog. The service does NOT confirm this target exists or that an exchange, identity, proximity or misconduct occurred. All cases remain UNVERIFIED, including after review.").font(.caption)
                }
                Text("Only the explanation/category you deliberately type is retained, with the claimed account ID. No GIF, bytes/hash, screenshot, chat, private URL, coordinates, scan or encounter history is copied automatically. No account is automatically blocked or changed.").font(.caption)
                if community.config?.peerIncidentReportsEnabled == true && submitted == nil && !session.denied {
                    Picker("Category", selection: $category) { ForEach(PeerIncidentCategory.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Deliberately typed explanation (1–1000 UTF-16 units)", text: $details, axis: .vertical).lineLimit(4...12)
                    Toggle("I consent to retaining only my entered explanation for private review", isOn: $consent)
                    Text("\(details.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) / 1000 UTF-16 units").font(.caption)
                    Button("Review deliberate unverified report") { confirmation = true }
                        .disabled(!consent || captured != nil || session.busy || details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if submitted == nil {
                    Text("Description/create capability unavailable (key may be absent). No empty-description success is implied. Local stop, block/remove and permitted owner receipts/withdrawal are independent.")
                }
                if let submitted, let clock {
                    Text("Your unverified explanation was retained. Claim verified: NO. No account action.")
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let deadline = (try? CatalogEventTime.parse(submitted.expiresAtISO)) ?? Date.distantPast
                        Text(clock.now() < deadline ?
                            "Description retention ends \(submitted.expiresAtISO)" : "Description retention ended; use owned receipts for withdrawal.").font(.caption)
                    }
                }
                if captured != nil && submitted == nil {
                    Text("Finalized selected-peer intent retained after uncertain failure/conflict. Check your owned cases; changed explanations require explicit withdrawal. No retry/rebase was performed.").font(.caption).foregroundStyle(.orange)
                    Button("Discard captured request, keep deliberately typed draft") { captured = nil; consent = false }.disabled(session.busy)
                }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if session.busy { ProgressView() }
                NavigationLink("My peer reports / withdrawal receipts") { PeerIncidentOwnerView() }
                Text("100 cases/account, 5000 service-wide; 20 writes/120 reads per minute. Description reads end at 30 days; cleanup is bounded, not forensic backup erasure.").font(.caption)
            }
            .modernScene().navigationTitle("Private peer incident")
            .toolbar { Button("Cancel / close") { invalidate(); dismiss() } }
            .task(id: selection.id) {
                invalidate()
                session.bind(community)
                do { try selection.check(community) }
                catch { session.run { _ in throw error }; dismiss() }
            }
            .onChange(of: category) { _, _ in consent = false }
            .onChange(of: details) { _, _ in consent = false }
            .onChange(of: community.accountRevision) { _, _ in invalidate(); dismiss() }
            .onChange(of: community.user?.role) { _, _ in invalidate(); dismiss() }
            .onChange(of: community.origin?.url) { _, _ in invalidate(); dismiss() }
            .onChange(of: community.config?.peerIncidentReportsEnabled) { _, enabled in if enabled != true { invalidate() } }
            .onChange(of: session.denied) { _, denied in if denied { invalidate(); dismiss() } }
            .onChange(of: phase) { _, state in if state != .active { invalidate(); dismiss() } }
            .onDisappear { invalidate() }
            .confirmationDialog("Retain only your typed unverified allegation?", isPresented: $confirmation) {
                Button("Consent and submit this selected-peer report") { submit() }
            } message: { Text("Claimed peer: \(selection.label). No artwork or automatic evidence copy; no target-profile lookup or account action. Review never certifies this allegation.") }
        }
    }
    private func submit() {
        session.run { client in
            guard captured == nil else { throw BackpackError.invalid("An existing captured report intent must be explicitly reconciled/discarded.") }
            let intent = try PeerIncidentIntent(selection: selection, category: category, details: details, consent: consent, community: community)
            captured = intent
            let value = try await client.submitPeerIncident(intent, community: community)
            try session.checked(client); try selection.check(community)
            submitted = value.report; clock = try CatalogEventClock(serverTime: value.serverTimeISO); captured = nil; consent = false
        }
    }
    private func invalidate() {
        session.clear(); details = ""; consent = false; captured = nil; previewReset()
    }
    private func previewReset() { confirmation = false; submitted = nil; clock = nil }
}

@MainActor
struct PeerIncidentOwnerView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = CommunityFeatureSession()
    @State private var page = 1
    @State private var receiptsOnly = false
    @State private var descriptions: NativePeerIncidentPage?
    @State private var receipts: NativePeerIncidentReceipts?
    @State private var clock: CatalogEventClock?
    @State private var pending: Withdrawal?
    @State private var needsReload = false
    @State private var notice: String?
    private struct Withdrawal {
        let id: UUID
        let revision: Int
        let scope: UUID
    }
    private var hasMore: Bool { receiptsOnly ? receipts?.hasMore == true : descriptions?.hasMore == true }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("My private peer incidents").font(.title2.bold())
                Text("UNVERIFIED claims, not proof of account existence, misconduct, encounter or proximity. No report triggers an automatic account action.").font(.caption)
                if community.config?.peerIncidentReportsEnabled == true {
                    Toggle("Metadata-only withdrawal mode (no descriptions)", isOn: $receiptsOnly)
                        .disabled(session.busy || community.config?.peerIncidentWithdrawalEnabled != true)
                } else if community.config?.peerIncidentWithdrawalEnabled == true {
                    Text("WITHDRAWAL-ONLY MODE — description/key capability unavailable. Metadata receipts, including expired cases awaiting cleanup, remain manageable. This is not a successful empty-description list.").foregroundStyle(.orange)
                    Button("Load permitted receipts explicitly") {
                        page = 1
                        if receiptsOnly { load() } else { receiptsOnly = true }
                    }.disabled(session.busy)
                } else { Text("Neither encrypted descriptions nor receipt withdrawal capability is available.") }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.caption) }
                if needsReload { Text("Captured revision was not confirmed. Explicitly reload and select again; no overwrite/retry/rebase.").foregroundStyle(.orange) }
                if session.busy { ProgressView() }
                if let clock {
                    Text("Server read clock: \(receiptsOnly ? receipts?.serverTimeISO ?? "" : descriptions?.serverTimeISO ?? ""). Not an encounter/arrival time.").font(.caption)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if receiptsOnly, let receipts {
                            ForEach(receipts.receipts) { receipt in
                                metadata(id: receipt.id, target: receipt.reportedUserId, revision: receipt.revision,
                                    resolved: receipt.resolved, expires: receipt.expiresAtISO,
                                    expired: receipt.expired || clock.now() >= ((try? CatalogEventTime.parse(receipt.expiresAtISO)) ?? .distantPast))
                            }
                        } else if let descriptions {
                            ForEach(descriptions.reports) { report in
                                if let deadline = try? CatalogEventTime.parse(report.expiresAtISO), clock.now() < deadline {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(report.category.rawValue).font(.headline)
                                        Text(verbatim: report.details).textSelection(.enabled)
                                        metadata(id: report.id, target: report.reportedUserId, revision: report.revision,
                                            resolved: report.resolved, expires: report.expiresAtISO, expired: false)
                                    }.padding(16).glassPanel()
                                } else { Text("Description expired. Explicitly load metadata-only receipts to withdraw.").font(.caption) }
                            }
                        }
                    }
                }
                HStack {
                    Button("Previous") { page -= 1; load() }.disabled(page == 1 || session.busy)
                    Spacer()
                    Button("Next") { page += 1; load() }.disabled(!hasMore || session.busy || page >= 10000)
                }
                Button("Explicitly reload current owned cases / revisions") { pending = nil; load() }.disabled(session.busy)
                Text("Withdrawal needs no current game/friendship/event/profile access and works for known owned cases after expiry/key loss when advertised. Only current-account receipts are used; no other account's data is adopted.").font(.caption)
                Text("Limits: 100/account, 5000 global; 20 writes/120 reads per minute, 30-day description reads, at most 500 cleanup/pass. Erasure removes cases by/about an account; cleanup is not forensic backup erasure.").font(.caption)
            }.padding(20)
        }.modernScene().navigationTitle("Own peer reports")
        .task(id: community.accountRevision) { clear(); page = 1; session.bind(community); if community.config?.peerIncidentReportsEnabled == true { load() } }
        .onChange(of: receiptsOnly) { _, _ in page = 1; pending = nil; load() }
        .onChange(of: community.accountRevision) { _, _ in clear(); session.clear() }
        .onChange(of: community.user?.role) { _, _ in clear(); session.clear() }
        .onChange(of: community.origin?.url) { _, _ in clear(); session.clear() }
        .onChange(of: community.config?.peerIncidentReportsEnabled) { _, _ in clear(); session.clear() }
        .onChange(of: community.config?.peerIncidentWithdrawalEnabled) { _, _ in clear(); session.clear() }
        .onChange(of: session.denied) { _, denied in if denied { clear() } }
        .onChange(of: phase) { _, state in if state != .active { clear(); session.clear() } }
        .onDisappear { clear(); session.clear() }
        .confirmationDialog("Withdraw this known owned case at the displayed revision?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let pending {
                Button("Withdraw my report", role: .destructive) {
                    session.run(expected: pending.scope, { client in
                        do { try await client.withdrawPeerIncident(id: pending.id, expectedRevision: pending.revision) }
                        catch { needsReload = true; throw error }
                    }, success: { self.pending = nil; notice = "Owned report withdrawn; no account action."; load() })
                }
            }
        } message: { Text("No description/key/target lookup is required. Revision conflict requires an explicit reload; no automatic retry.") }
    }
    private func metadata(id: UUID, target: UUID, revision: Int, resolved: Bool, expires: String, expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claimed target UUID: \(target.uuidString.lowercased())").font(.caption.monospaced())
            Text("Revision \(revision) · \(resolved ? "Resolved (still unverified)" : "Open (unverified)")").font(.caption)
            Text("Case retention deadline: \(expires)").font(.caption)
            if expired { Text("Expired description; metadata awaiting bounded cleanup. Known owned withdrawal still permitted.").font(.caption).foregroundStyle(.orange) }
            if community.config?.peerIncidentWithdrawalEnabled == true {
                Button("Review owned withdrawal", role: .destructive) {
                    guard let client = session.client else { return }
                    pending = Withdrawal(id: id, revision: revision, scope: client.instanceID)
                }.disabled(session.busy || needsReload)
            }
        }
    }
    private func load() {
        descriptions = nil; receipts = nil; clock = nil
        if session.client == nil || session.denied { session.bind(community) }
        let requestedPage = page, mode = receiptsOnly
        session.run { client in
            do {
                if mode {
                    let value = try await client.ownPeerReceipts(page: requestedPage); try session.checked(client)
                    guard requestedPage == page, receiptsOnly == mode else { return }
                    receipts = value; clock = try CatalogEventClock(serverTime: value.serverTimeISO)
                } else {
                    let value = try await client.ownPeerIncidents(page: requestedPage); try session.checked(client)
                    guard requestedPage == page, receiptsOnly == mode else { return }
                    descriptions = value; clock = try CatalogEventClock(serverTime: value.serverTimeISO)
                }
                needsReload = false
            } catch { descriptions = nil; receipts = nil; clock = nil; needsReload = true; throw error }
        }
    }
    private func clear() { descriptions = nil; receipts = nil; clock = nil; pending = nil; notice = nil; needsReload = false }
}
