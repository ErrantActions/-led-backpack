import Foundation
import BackpackProtocol

enum ChatConversation: Hashable {
    case direct(peer: UUID, event: UUID?)
    case room(UUID)
    var query: [URLQueryItem] {
        switch self {
        case .room(let id): return [URLQueryItem(name: "roomId", value: id.uuidString.lowercased())]
        case .direct(let peer, let event):
            return [URLQueryItem(name: "peerId", value: peer.uuidString.lowercased())] +
                (event.map { [URLQueryItem(name: "eventId", value: $0.uuidString.lowercased())] } ?? [])
        }
    }
}
struct ChatPin: Codable, Equatable {
    var label: String
    var latitude, longitude: Double
    func normalized() throws -> ChatPin {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 120,
              latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw BackpackError.invalid("Choose a named fixed place with valid coordinates.")
        }
        return ChatPin(label: trimmed,
            latitude: (latitude * 1_000_000).rounded() / 1_000_000, longitude: (longitude * 1_000_000).rounded() / 1_000_000)
    }
}
struct PrivateChatAttachment: Decodable, Identifiable {
    let id: UUID
    let url, previewUrl: URL
    let animated: Bool
    let mimeType: String
    let width, height: Int
}
struct NativeChatMessage: Decodable, Identifiable {
    let id, senderId: UUID
    let text: String
    let createdAt: Double
    var senderName: String?
    var recipientId: UUID?
    var eventId: UUID?
    var sequence: Int?
    var attachment: PrivateChatAttachment?
    var pin: ChatPin?
    var reference: HydratedChatReference?
}
struct NativeChatRoom: Decodable, Identifiable {
    let id: UUID
    let kind, title: String
    let eventId, ownerId: UUID?
    let revision: Int
    let archived, canManage, canSend: Bool
    let updatedAt: Double
    let readSequence, latestSequence, unread: Int
}
struct NativeChatRoomsPage: Decodable {
    let chats: [NativeChatRoom]
    let page, limit: Int
    let hasMore: Bool
}
struct NativeChatInvitation: Decodable, Identifiable {
    let id, chatId: UUID
    let title: String
    let inviter: SocialPerson
    let expiresAt: Double
    let revision: Int
    let shareHistory: Bool
}
struct NativeChatInvitationsPage: Decodable {
    let invitations: [NativeChatInvitation]
    let page, limit: Int
    let hasMore: Bool
}
struct NativeChatMember: Decodable, Identifiable {
    let id: UUID
    let displayName, state: String
    let owner, available: Bool
}
struct NativeChatMembersPage: Decodable {
    let members: [NativeChatMember]
    let page, limit, revision: Int
    let hasMore: Bool
}
struct DirectChatCursor: Decodable { let createdAt: Double; let id: UUID }
struct DirectChatPage: Decodable {
    let messages: [NativeChatMessage]
    let page, limit: Int
    let hasMore: Bool
    let nextBefore: DirectChatCursor?
    let viewToken: String?
}
struct RoomChatPage: Decodable {
    let chat: NativeChatRoom
    let messages: [NativeChatMessage]
    let hasMore: Bool
    let nextBefore: Int?
    let latestSequence, readSequence: Int
    let viewToken: String
}
struct RecentChatContact: Decodable, Identifiable {
    let profile: SocialPerson
    let eventId: UUID?
    let lastMessageCreatedAt: Double
    var id: String { "\(profile.id):\(eventId?.uuidString ?? "direct")" }
}
struct RecentChatPage: Decodable { let conversations: [RecentChatContact]; let page, limit: Int }
struct ChatTypingPage: Decodable {
    let typing: [Peer]
    let serverTime: Double
    struct Peer: Decodable, Identifiable { let id: UUID; let displayName: String; let expiresInMs: Int }
}
struct ChatSendIntent {
    let context: ChatConversation
    let clientMessageID: UUID
    let data: Data
    let attachmentID: UUID?
    let pin: ChatPin?
    let reference: ChatReferenceSelection?
    init(context: ChatConversation, text: String, attachmentID: UUID?, pin: ChatPin?, reference: ChatReferenceSelection? = nil, clientID: UUID = UUID()) throws {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.utf16.count <= 4000, !content.isEmpty || attachmentID != nil || pin != nil || reference != nil else {
            throw BackpackError.invalid("Write a message or explicitly attach media/place before sending.")
        }
        struct Body: Encodable {
            let text: String?
            let clientMessageId: String
            let attachmentId: String?
            var recipientId: String?
            var eventId: String?
            let pin: ChatPin?
            let reference: ChatReferenceSelection?
        }
        var body = Body(text: content.isEmpty ? nil : content, clientMessageId: clientID.uuidString.lowercased(),
            attachmentId: attachmentID?.uuidString.lowercased(), pin: try pin?.normalized(), reference: reference)
        if case .direct(let peer, let event) = context { body.recipientId = peer.uuidString.lowercased(); body.eventId = event?.uuidString.lowercased() }
        self.context = context; clientMessageID = clientID
        self.attachmentID = attachmentID; self.pin = try pin?.normalized()
        self.reference = reference
        data = try JSONEncoder().encode(body)
    }
}
struct ChatAttachmentDraft: Decodable {
    let attachment: PrivateChatAttachment
    let expiresAt: Double
}
