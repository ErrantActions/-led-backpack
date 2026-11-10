import SwiftUI
import BackpackProtocol

enum MessageIncidentCategory: String, Codable, CaseIterable, Identifiable {
    case spam, harassment, threat, safety, other
    var id: String { rawValue }
}
struct NativeMessageIncident: Decodable, Identifiable {
    let id, messageId: UUID
    let kind, details, createdAtISO: String
    let category: MessageIncidentCategory
    let revision: Int
    let resolved: Bool
    let reporterId, subjectId: UUID?
    func validate(staff: Bool) throws {
        guard ["direct", "room", "device-recovery"].contains(kind), revision >= 1, (1...1000).contains(details.utf16.count),
              staff ? reporterId != nil && subjectId != nil : reporterId == nil && subjectId == nil else {
            throw BackpackError.invalid("Invalid retained incident/explanation/review scope.")
        }
        _ = try CatalogEventTime.parse(createdAtISO)
    }
}
struct NativeMessageIncidents: Decodable {
    let reports: [NativeMessageIncident]
    let total, page, limit: Int
    let hasMore: Bool
    func validate(page: Int, staff: Bool) throws {
        guard self.page == page, limit == 24, total >= 0, reports.count <= 24, Set(reports.map(\.id)).count == reports.count else {
            throw BackpackError.invalid("Invalid bounded incident report page.")
        }
        for report in reports { try report.validate(staff: staff) }
    }
}
struct MessageIncidentIntent {
    let kind: String
    let messageID: UUID
    let category: MessageIncidentCategory
    let details: String
    let data: Data
    init(recoveryMessage: DeviceRecoveryMessage, context: DeviceRecoveryConversation, account: UUID,
        category: MessageIncidentCategory, details: String, consent: Bool) throws {
        try context.validate(account: account)
        try recoveryMessage.validate(conversation: context, account: account)
        let explanation = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard consent, context.state != .closed, recoveryMessage.senderId == context.peer.id,
              (1...1000).contains(explanation.utf16.count) else {
            throw BackpackError.invalid("Choose an incoming recovery message and enter your incident explanation.")
        }
        kind = "device-recovery"; messageID = recoveryMessage.id
        self.category = category; self.details = explanation
        struct Body: Encodable { let kind, messageId: String; let category: MessageIncidentCategory; let details: String; let consent = true }
        data = try JSONEncoder().encode(Body(kind: kind, messageId: messageID.uuidString.lowercased(),
            category: category, details: explanation))
    }
    init(message: NativeChatMessage, context: ChatConversation, account: UUID,
        category: MessageIncidentCategory, details: String, consent: Bool) throws {
        let explanation = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard consent, message.senderId != account, (1...1000).contains(explanation.utf16.count) else {
            throw BackpackError.invalid("Select an incoming message, deliberately explain the incident and consent before submitting.")
        }
        switch context {
        case .room: kind = "room"
        case .direct(let peer, _):
            guard message.senderId == peer else { throw BackpackError.invalid("This message belongs to a different direct conversation.") }
            kind = "direct"
        }
        struct Body: Encodable { let kind, messageId: String; let category: MessageIncidentCategory; let details: String; let consent = true }
        messageID = message.id; self.category = category; self.details = explanation
        data = try JSONEncoder().encode(Body(kind: kind, messageId: message.id.uuidString.lowercased(), category: category, details: explanation))
    }
}
@MainActor
extension CommunityFeatureClient {
    func submitMessageIncident(_ intent: MessageIncidentIntent) async throws -> NativeMessageIncident {
        guard chatReportsEnabled else { throw BackpackError.invalid("Deliberate message incident reporting is unavailable.") }
        struct Result: Decodable { let report: NativeMessageIncident }
        let result = try JSONDecoder().decode(Result.self, from: await send(.messaging, "social/message-reports", method: "POST", body: intent.data)).report
        try result.validate(staff: false)
        guard chatReportsEnabled, result.messageId == intent.messageID, result.kind == intent.kind,
              result.category == intent.category, result.details == intent.details else {
            throw BackpackError.invalid("The deliberate captured explanation/report was not confirmed.")
        }
        return result
    }
    func ownedMessageIncidents(page: Int, state: String) async throws -> NativeMessageIncidents {
        guard chatReportsEnabled, (1...209).contains(page), ["all", "open", "resolved"].contains(state) else {
            throw BackpackError.invalid("Message incident controls/page are unavailable.")
        }
        let result = try JSONDecoder().decode(NativeMessageIncidents.self, from: await send(.messaging, "social/message-reports",
            query: [.init(name: "page", value: String(page)), .init(name: "limit", value: "24"), .init(name: "state", value: state)]))
        guard chatReportsEnabled else { throw BackpackError.invalid("Incident report capability changed during the read.") }
        try result.validate(page: page, staff: false); return result
    }
    func withdrawMessageIncident(_ value: NativeMessageIncident) async throws {
        guard chatReportsEnabled else { throw BackpackError.invalid("Owned message incident withdrawal is unavailable.") }
        try value.validate(staff: false)
        struct Body: Encodable { let expectedRevision: Int }
        struct Receipt: Decodable { let removed: Bool }
        let receipt = try JSONDecoder().decode(Receipt.self, from: await send(.messaging, "social/message-reports/\(value.id.uuidString.lowercased())", method: "DELETE",
            body: JSONEncoder().encode(Body(expectedRevision: value.revision))))
        guard receipt.removed, chatReportsEnabled else { throw BackpackError.invalid("Owned incident withdrawal was not confirmed.") }
    }
}
@MainActor
struct MessageIncidentComposeView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    private enum Source {
        case chat(NativeChatMessage, ChatConversation)
        case recovery(DeviceRecoveryMessage, DeviceRecoveryConversation)
    }
    private let source: Source
    init(message: NativeChatMessage, context: ChatConversation) { source = .chat(message, context) }
    init(recoveryMessage: DeviceRecoveryMessage, context: DeviceRecoveryConversation) { source = .recovery(recoveryMessage, context) }
    @State private var category = MessageIncidentCategory.other
    @State private var details = ""
    @State private var consent = false
    @State private var intent: MessageIncidentIntent?
    @State private var submitted: NativeMessageIncident?
    var body: some View {
        NavigationStack {
            Form {
                Text("Deliberately explain this incident").font(.headline)
                InteractionExplanation("Only your explanation/category and opaque IDs are retained for review. No automatic content copy, punishment or block.",
                    details: "Nothing is copied automatically: no message text, GIF/image, place, event, room roster or neighboring history. Only your typed explanation/category and opaque identifiers are retained for moderator review. You may explicitly quote content yourself. No automatic punishment or blocking occurs.").font(.caption)
                if community.config?.chatReportsEnabled == true && !session.denied && submitted == nil {
                    Picker("Reason", selection: $category) { ForEach(MessageIncidentCategory.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    TextField("Your deliberate explanation (1–1000 characters)", text: $details, axis: .vertical).lineLimit(4...12)
                    Toggle("I consent to retaining my entered explanation for incident review", isOn: $consent)
                    Button("Submit report") { submit() }.buttonStyle(AuroraPrimaryButton())
                        .disabled(!consent || details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.busy || intent != nil)
                }
                if submitted != nil { Label("Your incident explanation was retained; original message unchanged.", systemImage: "checkmark.shield") }
                if intent != nil && submitted == nil {
                    Text("Captured explanation retained after failure/conflict. Review your existing reports before another submission; no overwrite or automatic copy.").font(.caption).foregroundStyle(.orange)
                    Button("Discard captured request, retain typed explanation") { intent = nil }.disabled(session.busy)
                }
                if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
                if session.busy { ProgressView() }
            }.disabled(intent != nil && submitted == nil && session.busy).modernScene().navigationTitle("Message incident")
                .toolbar { Button("Close") { dismiss() }.disabled(session.busy) }
                .safeAreaInset(edge: .bottom) {
                    Button(submitted == nil ? "Cancel" : "Done") { dismiss() }
                        .frame(maxWidth: .infinity).padding().background(.bar).disabled(session.busy)
                }
                .interactiveDismissDisabled(session.busy)
                .task { session.bind(community) }
                .onChange(of: community.accountRevision) { _, _ in details = ""; intent = nil; submitted = nil; session.clear(); dismiss() }
                .onDisappear { session.clear() }
        }
    }
    private func submit() {
        session.run { client in
            guard intent == nil else { throw BackpackError.invalid("Review/discard the existing captured request explicitly.") }
            let captured: MessageIncidentIntent
            switch source {
            case .chat(let message, let context):
                captured = try MessageIncidentIntent(message: message, context: context, account: client.accountID,
                    category: category, details: details, consent: consent)
            case .recovery(let message, let context):
                captured = try MessageIncidentIntent(recoveryMessage: message, context: context, account: client.accountID,
                    category: category, details: details, consent: consent)
            }
            intent = captured
            let report = try await client.submitMessageIncident(captured)
            try session.checked(client); submitted = report; intent = nil
        }
    }
}
@MainActor
struct MessageIncidentListView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    @StateObject private var admin = CommunityAdminStore()
    var staff = false
    @State private var page = 1
    @State private var state = "all"
    @State private var value: NativeMessageIncidents?
    @State private var pending: NativeMessageIncident?
    var body: some View {
        Form {
            Text(staff ? "Only deliberately entered incident explanations. Underlying private chats/media are not unlocked." : "Only your retained explanations. Withdrawal is available even after conversation access is lost.").font(.caption)
            if community.config?.chatReportsEnabled == true && (!staff || community.isAdmin) {
                Picker("State", selection: $state) { Text("All").tag("all"); Text("Open").tag("open"); Text("Resolved").tag("resolved") }
                if let value {
                    if value.reports.isEmpty && !(staff ? admin.busy : session.busy) {
                        Text("No reports match this filter.").foregroundStyle(.secondary)
                    }
                    ForEach(value.reports) { report in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(report.category.rawValue.capitalized).font(.headline)
                            Text(verbatim: report.details).textSelection(.enabled)
                            Text("Revision \(report.revision) · \(report.resolved ? "Resolved" : "Open") · \(report.createdAtISO)").font(.caption)
                            Button(staff ? report.resolved ? "Review reopening" : "Review resolving" : "Review withdrawing my report", role: staff ? nil : .destructive) { pending = report }
                        }.padding(10).glassPanel()
                    }
                    HStack { Button("Previous") { page -= 1 }.disabled(page == 1); Spacer(); Button("Next") { page += 1 }.disabled(!value.hasMore) }
                }
                Button("Explicitly refresh reports") { pending = nil; load() }
            } else { Text("Incident reporting/review is unavailable.") }
            if let failure = staff ? admin.failure : session.failure { Text(failure).foregroundStyle(.orange) }
            if staff ? admin.busy : session.busy { ProgressView() }
        }.disabled(staff ? admin.busy : session.busy).modernScene().navigationTitle(staff ? "Incident review" : "My message incidents")
        .task(id: "\(page):\(state):\(community.accountRevision)") {
            if staff { admin.bind(community) } else { session.bind(community) }
            pending = nil; load()
        }
        .onChange(of: state) { _, _ in page = 1 }
        .onChange(of: community.accountRevision) { _, _ in value = nil; pending = nil; admin.clear(); session.clear(); dismiss() }
        .onDisappear { admin.clear(); session.clear() }
        .confirmationDialog("Apply captured incident revision?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let pending {
                Button(staff ? pending.resolved ? "Reopen captured report" : "Resolve captured report" : "Withdraw captured report", role: staff ? nil : .destructive) { change(pending) }
            }
        } message: { Text("Uses displayed revision \(pending?.revision ?? 0). A conflict retains the selection; explicitly refresh/review. No message deletion, automatic block or private-chat access.") }
    }
    private func load() {
        if staff {
            admin.run { client in let result = try await client.messageIncidents(page: page, state: state); try admin.checked(client); value = result; return nil }
        } else {
            session.run { client in let result = try await client.ownedMessageIncidents(page: page, state: state); try session.checked(client); value = result }
        }
    }
    private func change(_ report: NativeMessageIncident) {
        if staff {
            admin.run({ client in _ = try await client.reviewMessageIncident(report, resolved: !report.resolved); return nil }, success: { pending = nil; load() })
        } else {
            session.run({ try await $0.withdrawMessageIncident(report) }, success: { pending = nil; load() })
        }
    }
}
