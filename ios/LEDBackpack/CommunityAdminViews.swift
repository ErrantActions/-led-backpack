import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CommunityAdminView: View {
    @EnvironmentObject private var community: CommunityController
    @StateObject private var store = CommunityAdminStore()
    @State private var tool = AdminTool.moderation
    @State private var page = 1
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var role = ""
    @State private var status = AdminItemStatus.pending
    @State private var reload = UUID()
    @State private var threshold = 4
    @State private var pickingZIP = false
    @State private var selectedZIP: URL?
    @State private var zipScope: UUID?
    @State private var resultLimit = 100
    @State private var pending: Confirmation?

    private struct Confirmation {
        let title, detail: String
        let destructive: Bool
        let scope: UUID?
        let work: @MainActor (CommunityAdminClient) async throws -> String?
    }
    private var loadID: String {
        "\(community.accountRevision)|\(community.user?.role ?? "")|\(tool)|\(page)|\(appliedQuery)|\(role)|\(status)|\(reload)"
    }
    var body: some View {
        Group {
            if community.isAdmin && !store.denied {
                Form {
                    Section {
                        Picker("Admin tools", selection: $tool) {
                            ForEach(AdminTool.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu).disabled(store.busy)
                        DisclosureGroup("More administration tools") {
                        NavigationLink { CommunityBulkModerationView() } label: {
                            FeatureRowLabel(title: "Bulk moderation", symbol: "checklist",
                                subtitle: "Review exact community items before quarantine or deletion")
                        }
                        NavigationLink("Content-blind upload alerts / holds") { CommunityUploadAlertsView() }
                        NavigationLink("Firmware drafts / publish / withdraw") { FirmwareLibraryView(admin: true) }
                        NavigationLink("Generic research target curation") { DeviceResearchView(admin: true) }
                        NavigationLink("Artwork studio") { AdminArtworkView() }
                        Text("Community administration only. Private GIFs and vault keys are never available here.")
                            .font(.caption).foregroundStyle(.secondary)
                        if community.config?.chatReportsEnabled == true {
                            NavigationLink("Deliberately submitted message incidents") { MessageIncidentListView(staff: true) }
                        }
                        if community.config?.eventReportsEnabled == true {
                            NavigationLink("Typed event report cases") { EventModerationView(holdsOnly: false) }
                        }
                        if community.config?.eventModerationEnabled ?? (community.config?.eventReportsEnabled == true) {
                            NavigationLink("Existing event holds / release only") { EventModerationView(holdsOnly: true) }
                        }
                        if community.config?.peerIncidentReportsEnabled == true || community.config?.peerIncidentWithdrawalEnabled == true {
                            NavigationLink("Private peer-incident review (unverified claims)") { PeerIncidentAdminView() }
                        }
                        }
                    }
                    if store.busy { ProgressView("Contacting catalog…") }
                    if let failure = store.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                    if let message = store.message { Text(message).foregroundStyle(Aurora.mint) }
                    tools
                    Section {
                        Button("Refresh \(tool.rawValue.lowercased())") { reload = UUID() }.disabled(store.busy)
                    }
                }
            } else {
                ContentUnavailableView("Admin access required", systemImage: "lock.shield",
                    description: Text(store.failure ?? "Refresh your account or sign in with an admin account."))
            }
        }
        .modernScene().navigationTitle("Administration").buttonStyle(.borderless)
        .task(id: loadID) {
            pending = nil; selectedZIP = nil
            store.bind(community)
            if community.isAdmin && !store.denied { load() }
        }
        .onChange(of: tool) { _, _ in page = 1 }
        .onChange(of: store.settings?.reportHideThreshold) { _, value in if let value { threshold = value } }
        .onDisappear {
            if store.selectedItem == nil && !pickingZIP { store.clear() }
            pending = nil
        }
        .sheet(item: Binding(get: { store.selectedItem }, set: { if $0 == nil { store.closeItem() } })) { item in
            CommunityAdminItemEditor(item: item, store: store) { reload = UUID() }
        }
        .fileImporter(isPresented: $pickingZIP, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): selectedZIP = url; zipScope = store.contextID
            case .failure(let error):
                store.run { _ in throw error }
            }
        }
        .confirmationDialog("Import for community screening?", isPresented: Binding(
            get: { selectedZIP != nil }, set: { if !$0 { selectedZIP = nil } })) {
                if let url = selectedZIP {
                    Button("I have sharing rights; import and allow publication") {
                        selectedZIP = nil; store.importZIP(url, expectedScope: zipScope)
                    }
                }
            } message: {
                InteractionExplanation("Community import, not backup. Cleared items may publish automatically. Check recent imports before retrying.", details: "The ZIP's GIFs and metadata may be sent for AI review and published automatically when cleared. This is not private backup. Up to 250 MiB and 500 GIFs. Check recent imports before retrying an interrupted upload.")
            }
        .alert("Confirm admin action", isPresented: Binding(get: { pending != nil },
            set: { if !$0 { pending = nil } }), presenting: pending) { value in
                Button(value.title, role: value.destructive ? .destructive : nil) {
                    store.run(value.work, expectedScope: value.scope) { reload = UUID() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text($0.detail) }
    }
    private func load() {
        store.load(tool, page: page, query: appliedQuery, role: role, status: status)
    }
    @ViewBuilder private var tools: some View {
        switch tool {
        case .statistics: statistics
        case .accounts: accounts
        case .moderation: moderation
        case .reports: reports
        case .settings: settings
        case .imports: imports
        }
    }
    @ViewBuilder private var statistics: some View {
        if let value = store.statistics {
            Section("Accounts") {
                metric("Total", value.accounts.total); metric("Admins", value.accounts.admins)
                metric("Enabled", value.accounts.enabled); metric("Email verified", value.accounts.emailVerified)
                metric("Active sessions", value.activeSessions)
            }
            Section("GIF records") {
                metric("Active", value.items.active); metric("Private (count only)", value.items.private)
                metric("Shared", value.items.shared); metric("Approved shared", value.items.approvedShared)
                metric("Pending shared", value.items.pendingShared); metric("Rejected shared", value.items.rejectedShared)
                metric("Deleted metadata", value.items.deleted); metric("Detached legacy shared", value.items.retainedShared)
                metric("All records", value.items.total); metric("Likes", value.likes)
            }
            Section("Storage and review") {
                LabeledContent("Managed media", value: "\(bytes(value.storage.usedBytes)) / \(bytes(value.storage.limitBytes))")
                metric("Open reports", value.reports.open); metric("Resolved reports", value.reports.resolved)
                metric("Queued AI reviews", value.reviews.queued); metric("Failed AI reviews", value.reviews.failed)
                Text("Snapshot: \(value.generatedAt)").font(.caption)
                Text("Counts refresh on demand. Storage excludes databases, backups and logs; deleted records may retain metadata.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func metric(_ label: String, _ value: Int) -> some View { LabeledContent(label, value: String(value)) }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) }
    private var accounts: some View {
        Group {
            Section("Find accounts") {
                TextField("Name or email", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Role", selection: $role) {
                    Text("All").tag(""); Text("User").tag("user"); Text("Admin").tag("admin")
                    Text("Legacy moderator").tag("moderator")
                }.onChange(of: role) { _, _ in page = 1 }
                Button("Search accounts") { appliedQuery = query; page = 1; reload = UUID() }
                Text("Admin-only account details. Changes revoke that account's sessions. Your own account and existing admins are protected.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(store.busy)
            if let result = store.accounts {
                ForEach(result.users) { account in
                    Section(account.displayName) {
                        AccountApprovedProfileAvatar(person: SocialPerson(id: account.id, displayName: account.displayName,
                            avatarUrl: account.avatarUrl, avatarPreviewUrl: account.avatarPreviewUrl,
                            avatarAnimated: account.avatarAnimated, avatarMature: account.avatarMature,
                            avatarMasked: account.avatarMasked)).frame(width: 56, height: 70)
                        Text(account.email).textSelection(.enabled)
                        LabeledContent("Role", value: account.role)
                        LabeledContent("Account", value: account.disabled ? "Disabled" : "Enabled")
                        LabeledContent("Email", value: account.verified ? "Verified" : "Unverified")
                        metric("Active items (count only)", account.itemCount)
                        LabeledContent("Reporter trust", value: account.trustedReporter ? "Trusted" : "Not manually trusted")
                        Text("Created \(account.createdAt)").font(.caption)
                        if account.id == community.user?.id || account.role == "admin" {
                            Text("Protected account").font(.caption)
                        } else {
                            accountActions(account)
                        }
                    }
                }
                pager(page: result.page, limit: result.limit, total: result.total)
            }
        }
    }
    private func accountActions(_ account: AdminAccount) -> some View {
        Group {
            Button("Promote to admin") { confirm(account, .promote) }
                .disabled(account.disabled || (community.config?.requireEmailVerification != false && !account.verified))
            Button(account.disabled ? "Enable account" : "Disable account") {
                confirm(account, account.disabled ? .enable : .disable)
            }
            Button(account.trustedReporter ? "Remove reporter trust" : "Trust reporter") {
                confirm(account, account.trustedReporter ? .untrust : .trust)
            }
        }.disabled(store.busy)
    }
    private func confirm(_ account: AdminAccount, _ action: AdminAccountAction) {
        let consequence = action == .promote ? "This grants full administration and moderation rights." :
            ([AdminAccountAction.trust, .untrust].contains(action) ? "This affects automatic-hide votes, not admin permissions." :
                "Disabling an uploader also hides their public GIFs.")
        pending = Confirmation(title: action.label,
            detail: "\(account.displayName) (\(account.email)): \(consequence) Their sessions will be revoked.",
            destructive: action == .disable, scope: store.contextID) { client in
                try await client.update(account, action: action)
                return "Account updated. The affected user must sign in again."
            }
    }
    private var moderation: some View {
        Group {
            Section("Community submissions") {
                Picker("Status", selection: $status) {
                    ForEach(AdminItemStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.onChange(of: status) { _, _ in page = 1 }.disabled(store.busy)
                Text("Private libraries are excluded. Open a submission to review safety, edit classification, approve, reject, retry AI or delete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = store.items {
                ForEach(result.items) { item in
                    Button { store.openItem(item.id) } label: {
                        HStack(spacing: 12) {
                            GIFThumbnail(key: store.itemPreviewKey(item), cache: false) {
                                try await community.download(item.item.previewUrl)
                            }.frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading) {
                                Text("Community artwork").accessibilityLabel(item.item.title)
                                Text("\(item.status.rawValue) / AI: \(item.aiState)").font(.caption)
                                if item.heldByReports { Text("Held by reports").font(.caption).foregroundStyle(.orange) }
                                if item.requiresAdminReview { Text("Needs human review").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }.disabled(store.busy).onAppear {
                        let captured = status
                        store.nearItemsEnd(item.id, status: captured, valid: { status == captured && tool == .moderation })
                    }
                }
                if result.items.count == 100 { Text("Showing 100 submissions. Change the status filter.").font(.caption) }
                if store.canRetryItems {
                    Button("Retry page") {
                        let captured = status
                        store.retryItems(status: captured, valid: { status == captured && tool == .moderation })
                    }
                }
            }
        }
    }
    private var reports: some View {
        Group {
            if let result = store.reports {
                Section("Open reports") {
                    Text("Resolving a report does not unpublish the GIF. Review its submission separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(result.reports) { report in
                    Section {
                        Text(report.reason).textSelection(.enabled)
                        Text(report.date, style: .date).font(.caption)
                        Text("Reporter: \(report.reporterId.uuidString.lowercased())").font(.caption)
                        Button("Review reported GIF") { store.openItem(report.itemId) }
                        Button("Resolve report") {
                            pending = Confirmation(title: "Resolve report",
                                detail: "Mark this report resolved? This does not change the GIF's publication status.",
                                destructive: false, scope: store.contextID) { client in
                                    try await client.resolve(report.id); return "Report resolved."
                                }
                        }
                    }.disabled(store.busy)
                }
                pager(page: result.page, limit: result.limit, total: result.total)
            }
        }
    }
    private var settings: some View {
        Group {
            if let value = store.settings {
                Section("Automatic report holds") {
                    Stepper("Qualified reporters: \(threshold)", value: $threshold, in: 2...50)
                    Text(value.reporterRule).font(.caption)
                    Text("Lowering the threshold may hold more GIFs. Raising it never releases existing holds; review them manually.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save report threshold") {
                        let requested = threshold
                        pending = Confirmation(title: "Save threshold",
                            detail: "Require \(requested) distinct qualified reporters before automatically holding a GIF?",
                            destructive: false, scope: store.contextID) { client in
                                try await client.setThreshold(requested); return "Report threshold updated."
                            }
                    }
                }.disabled(store.busy)
                Section {
                    FeatureDetails("Sign in with Apple diagnostics") {
                    LabeledContent("Server support", value: value.appleSignInEnabled ? "Enabled" : "Disabled")
                    Text(value.appleDiagnostic).textSelection(.enabled)
                    }
                }
            }
        }
    }
    private var imports: some View {
        Group {
            Section("Community ZIP import") {
                Text("Up to 250 MiB, 500 GIFs, 1 GB expanded data. GIFs must have 1–120 frames and satisfy the normal 5 MB / decoded-pixel budgets. No manifest is needed.")
                    .font(.caption)
                Button("Choose ZIP for community screening") { pickingZIP = true }.disabled(store.busy)
                Text("Imports can publish automatically after AI clearance. No private files are scanned. Imports shown here belong to this admin only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recent imports") {
                ForEach(store.imports) { job in
                    Button("\(job.filename) — \(job.status)") {
                        resultLimit = 100; store.openImport(job.id)
                    }.disabled(store.busy)
                }
            }
            if let job = store.selectedImport {
                Section(job.filename) {
                    Text(job.status)
                    metric("Processed", job.processed)
                    metric("Total", job.total); metric("Imported", job.imported)
                    metric("Duplicates reused", job.duplicates); metric("Skipped", job.skipped); metric("Failed", job.failed)
                    if let error = job.error { Text(error).foregroundStyle(.orange) }
                    Button("Refresh this import") { store.openImport(job.id) }.disabled(store.busy)
                    ForEach(Array(job.results.prefix(resultLimit).enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading) {
                            Text(row.status).accessibilityLabel("\(row.status): \(row.name)")
                            if let error = row.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if let id = row.itemId { Button("Review imported GIF") { store.openItem(id) }.disabled(store.busy) }
                        }
                    }
                    if job.results.count > resultLimit { Button("Show more results") { resultLimit += 100 } }
                }
            }
        }
    }
    private func pager(page current: Int, limit: Int, total: Int) -> some View {
        Section {
            Text("\(total) results / page \(current)").font(.caption)
            HStack {
                Button("Previous") { page = current - 1 }.disabled(store.busy || current <= 1)
                Spacer()
                Button("Next") { page = current + 1 }.disabled(store.busy || current * limit >= total || current >= 10000)
            }
        }
    }
}

@MainActor
private struct CommunityAdminItemEditor: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    let item: AdminItem
    @ObservedObject var store: CommunityAdminStore
    let changed: () -> Void
    private let scope: UUID?
    @State private var title: String
    @State private var category: String
    @State private var tags: String
    @State private var reason: String
    @State private var status: AdminItemStatus
    @State private var audience = "general"
    @State private var reviewed = false
    @State private var confirmation = false
    @State private var deleting = false
    @State private var retryAI = false
    init(item: AdminItem, store: CommunityAdminStore, changed: @escaping () -> Void) {
        self.item = item; self.store = store; self.changed = changed
        scope = store.contextID
        _title = State(initialValue: item.item.title); _category = State(initialValue: item.item.category)
        _tags = State(initialValue: item.item.tags.joined(separator: ", "))
        _reason = State(initialValue: item.moderationReason); _status = State(initialValue: item.status)
    }
    var body: some View {
        NavigationStack {
            Form {
                if community.isAdmin && !store.denied {
                    Section("Review community GIF") {
                        GIFThumbnail(key: "admin-editor:\(community.accountRevision):\(item.id)", cache: false) {
                            try await community.download(item.item.gifUrl)
                        }.frame(height: 220)
                        Picker("Category", selection: $category) {
                            ForEach(CommunityCategory.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        TextField("Tags, comma separated", text: $tags)
                        Picker("Status", selection: $status) {
                            ForEach(AdminItemStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        TextField("Reason (required for rejection)", text: $reason, axis: .vertical)
                        Picker("Audience", selection: $audience) {
                            Text("General").tag("general"); Text("Mature").tag("mature")
                        }
                        Toggle("I reviewed content safety and audience", isOn: $reviewed)
                        Text("Nudity must not be approved merely by classifying it as mature. Human review overrides AI.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Review & save") { confirmation = true }
                            .buttonStyle(AuroraPrimaryButton()).disabled(status == .approved && !reviewed)
                    }.disabled(store.busy)
                    DisclosureGroup("AI review details") {
                        Text(item.aiState)
                        if let review = item.aiReview {
                            Text("Audience: \(review.audience) / confidence: \(review.confidence.formatted(.percent))")
                            Text("Flags: \(review.flags.joined(separator: ", "))")
                            Text(review.notes)
                        }
                        if let error = item.aiError { Text(error).foregroundStyle(.orange) }
                        Button("Queue AI review again") { retryAI = true }.disabled(store.busy)
                    }
                    Section {
                        Button("Delete community GIF", role: .destructive) { deleting = true }.disabled(store.busy)
                        Text("Deletion removes this community GIF from the server. It never deletes local copies or private vault items.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.busy { ProgressView() }
                    if let failure = store.failure { Text(failure).foregroundStyle(.orange) }
                } else { Text("Admin access is no longer available.") }
            }
            .modernScene().navigationTitle("Moderate GIF")
            .toolbar { Button("Done") { dismiss() }.disabled(store.busy) }
            .safeAreaInset(edge: .bottom) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .frame(maxWidth: .infinity).padding().background(.bar).disabled(store.busy)
            }
            .interactiveDismissDisabled(store.busy)
            .confirmationDialog("Save this moderation decision?", isPresented: $confirmation) {
                Button("Save moderation") {
                    let change = AdminModeration(status: status, reason: reason, title: title, category: category,
                        tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                        audience: reviewed ? audience : nil, safetyReviewed: reviewed ? true : nil)
                    store.run({ client in try await client.moderate(item.id, change: change); return "Moderation saved." },
                        expectedScope: scope, success: { dismiss(); changed() })
                }
            }
            .confirmationDialog("Delete this community GIF?", isPresented: $deleting) {
                Button("Delete community GIF", role: .destructive) {
                    store.run({ client in try await client.delete(item.id); return "Community GIF deleted." },
                        expectedScope: scope, success: { dismiss(); changed() })
                }
            }
            .confirmationDialog("Send this community GIF for AI review?", isPresented: $retryAI) {
                Button("Queue AI review") {
                    store.run({ client in try await client.review(item.id); return "AI review queued." },
                        expectedScope: scope, success: { dismiss(); changed() })
                }
            }
            .onChange(of: community.accountRevision) { _, _ in dismiss() }
            .onChange(of: community.user?.role) { _, role in if role != "admin" { dismiss() } }
            .onChange(of: store.denied) { _, denied in if denied { dismiss() } }
        }
    }
}
