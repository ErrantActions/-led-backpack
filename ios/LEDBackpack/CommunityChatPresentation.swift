import Foundation

enum NativeChatInboxFilter: String, CaseIterable, Identifiable {
    case chats = "Chats", groups = "Groups", requests = "Requests"
    var id: String { rawValue }
    func matches(_ name: String, context: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query) || context.localizedStandardContains(query)
    }
}

enum NativeChatInboxEntry: Identifiable {
    case direct(RecentChatContact), room(NativeChatRoom)
    var id: String {
        switch self {
        case .direct(let contact): return "direct:\(contact.id)"
        case .room(let room): return "room:\(room.id)"
        }
    }
    var updatedAt: Double {
        switch self {
        case .direct(let contact): return contact.lastMessageCreatedAt
        case .room(let room): return room.updatedAt
        }
    }
    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }
}

struct NativeChatDraftScope: Equatable {
    let origin: String
    let account: UUID
    let accountRevision: UUID
    let accessRevision: UUID
}

struct NativeChatDraft {
    var text = ""
    var attachment: ChatAttachmentDraft?
    var pin: ChatPin?
    var reference: ChatReferenceSelection?
    var isEmpty: Bool { text.isEmpty && attachment == nil && pin == nil && reference == nil }
}

@MainActor
final class NativeChatDraftStore {
    static let shared = NativeChatDraftStore()
    private var scope: NativeChatDraftScope?
    private var drafts: [ChatConversation: NativeChatDraft] = [:]

    func restore(scope next: NativeChatDraftScope, context: ChatConversation) -> NativeChatDraft? {
        if scope != next { drafts.removeAll(); scope = next }
        return drafts[context]
    }
    @discardableResult
    func save(_ draft: NativeChatDraft, scope expected: NativeChatDraftScope, context: ChatConversation) -> Bool {
        guard scope == expected else { return false }
        drafts[context] = draft.isEmpty ? nil : draft
        return true
    }
    func remove(scope expected: NativeChatDraftScope, context: ChatConversation) {
        guard scope == expected else { return }
        drafts[context] = nil
    }
    func invalidate() { scope = nil; drafts.removeAll() }
}
