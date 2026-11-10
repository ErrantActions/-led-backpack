import SwiftUI
import BackpackProtocol

struct ChatNotificationPreference: Decodable {
    let revision: Int
    let muted: Bool
    func validate() throws {
        guard (0...9_007_199_254_740_991).contains(revision) else { throw BackpackError.invalid("Invalid conversation notification revision.") }
    }
}
struct ChatMuteIntent {
    let context: ChatConversation
    let expectedRevision: Int
    let muted: Bool
    let data: Data
    init(context: ChatConversation, preference: ChatNotificationPreference, muted: Bool) throws {
        try preference.validate()
        struct Body: Encodable { let context: [String: String]; let expectedRevision: Int; let muted: Bool }
        var fields: [String: String]
        switch context {
        case .room(let id): fields = ["roomId": id.uuidString.lowercased()]
        case .direct(let peer, let event):
            fields = ["peerId": peer.uuidString.lowercased()]
            if let event { fields["eventId"] = event.uuidString.lowercased() }
        }
        self.context = context; expectedRevision = preference.revision; self.muted = muted
        data = try JSONEncoder().encode(Body(context: fields, expectedRevision: preference.revision, muted: muted))
    }
}
@MainActor
extension CommunityFeatureClient {
    func chatNotificationPreference(_ context: ChatConversation) async throws -> ChatNotificationPreference {
        guard chatNotificationPreferencesEnabled else { throw BackpackError.invalid("Conversation notification controls are unavailable.") }
        try check(.messaging)
        let result = try JSONDecoder().decode(ChatNotificationPreference.self, from: await send(.notifications,
            "notifications/chat-preferences", query: context.query))
        try check(.messaging)
        guard chatNotificationPreferencesEnabled else { throw BackpackError.invalid("Conversation notification capability changed during the request.") }
        try result.validate(); return result
    }
    func saveChatNotificationPreference(_ intent: ChatMuteIntent) async throws -> ChatNotificationPreference {
        guard chatNotificationPreferencesEnabled else { throw BackpackError.invalid("Conversation notification controls are unavailable.") }
        try check(.messaging)
        let result = try JSONDecoder().decode(ChatNotificationPreference.self, from: await send(.notifications,
            "notifications/chat-preferences", method: "PATCH", body: intent.data))
        try result.validate()
        try check(.messaging)
        guard chatNotificationPreferencesEnabled else { throw BackpackError.invalid("Conversation notification capability changed during the save.") }
        guard result.revision >= intent.expectedRevision, result.muted == intent.muted else {
            throw BackpackError.invalid("The captured conversation mute choice/revision was not confirmed.")
        }
        return result
    }
}
@MainActor
struct ConversationNotificationView: View {
    @EnvironmentObject private var community: CommunityController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CommunityFeatureSession()
    let context: ChatConversation
    @State private var preference: ChatNotificationPreference?
    @State private var choice = false
    @State private var intent: ChatMuteIntent?
    @State private var confirming = false
    @State private var reloading = false
    var body: some View {
        Form {
            if community.config?.chatNotificationPreferencesEnabled == true && !session.denied {
                if let preference {
                    LabeledContent("Confirmed alerts", value: preference.muted ? "Muted" : "Unmuted")
                    LabeledContent("Displayed revision", value: String(preference.revision))
                    Toggle("Mute new message alerts for this conversation", isOn: $choice).disabled(session.busy || intent != nil)
                    Button("Review displayed mute choice") { confirming = true }.disabled(session.busy || intent != nil)
                }
                if intent != nil { Text("Captured intent retained. Explicitly reload current access/revision before saving again; no automatic retry or overwrite.").foregroundStyle(.orange) }
                Button("Explicitly reload current conversation settings") { reloading = true }.disabled(session.busy)
                InteractionExplanation("Only alerts for this conversation change. Messages, unread counts, membership and existing activity links remain.",
                    details: "Only your alerts for this exact direct thread, private organizer question or room change. Messages, history, unread counts, membership, typing, invitations and already delivered inbox/activity links remain intact. Global/category/channel settings still apply.").font(.caption)
            } else { Text("Conversation notification controls are unavailable or current access was lost.") }
            if let failure = session.failure { Text(failure).foregroundStyle(.orange) }
            if session.busy { ProgressView() }
        }.modernScene().navigationTitle("Conversation alerts")
        .task { session.bind(community); load(retainChoice: false) }
        .onChange(of: community.accountRevision) { _, _ in preference = nil; intent = nil; session.clear(); dismiss() }
        .onDisappear { session.clear() }
        .confirmationDialog("Save only your alerts for this captured conversation?", isPresented: $confirming) {
            Button(choice ? "Mute new message alerts" : "Unmute new message alerts") { save() }
        } message: { Text("Uses displayed revision \(preference?.revision ?? 0). A conflict retains this choice and requires explicit reload; it never mutes other threads or private organizer questions.") }
        .confirmationDialog("Reload current access/revision?", isPresented: $reloading) {
            Button("Reload revision, retain my choice") { intent = nil; load(retainChoice: true) }
            Button("Discard choice and reload", role: .destructive) { intent = nil; load(retainChoice: false) }
        } message: { Text("Reload is explicit. A retained choice still requires a new confirmation against the newly displayed revision; no automatic save occurs.") }
    }
    private func load(retainChoice: Bool) {
        session.run { client in
            let current = try await client.chatNotificationPreference(context)
            try session.checked(client); preference = current
            if !retainChoice { choice = current.muted }
        }
    }
    private func save() {
        session.run { client in
            guard intent == nil, let preference else { throw BackpackError.invalid("Explicitly reload before capturing another conversation preference intent.") }
            let captured = try ChatMuteIntent(context: context, preference: preference, muted: choice); intent = captured
            let result = try await client.saveChatNotificationPreference(captured)
            try session.checked(client); self.preference = result; choice = result.muted; intent = nil
        }
    }
}
