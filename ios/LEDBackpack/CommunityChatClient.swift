import Foundation
import BackpackProtocol

@MainActor
extension CommunityFeatureClient {
    private func chatPaging(_ page: Int) throws -> [URLQueryItem] {
        guard (1...10000).contains(page) else { throw BackpackError.invalid("Invalid chat page.") }
        return [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "24")]
    }
    func recentChats(page: Int) async throws -> RecentChatPage {
        try JSONDecoder().decode(RecentChatPage.self, from: await send(.messaging, "social/conversations", query: chatPaging(page)))
    }
    func rooms(page: Int) async throws -> NativeChatRoomsPage {
        guard groupsEnabled || eventChatsEnabled else { throw BackpackError.invalid("Rooms are not enabled by this server.") }
        return try JSONDecoder().decode(NativeChatRoomsPage.self, from: await send(.messaging, "social/chats", query: chatPaging(page)))
    }
    func room(_ id: UUID) async throws -> NativeChatRoom {
        struct Result: Decodable { let chat: NativeChatRoom }
        let room = try JSONDecoder().decode(Result.self, from: await send(.messaging, "social/chats/\(id.uuidString.lowercased())")).chat
        guard room.id == id else { throw BackpackError.invalid("Wrong chat room response.") }
        return room
    }
    func createRoom(title: String, invitees: [UUID], shareHistory: Bool) async throws -> NativeChatRoom {
        guard groupsEnabled, (1...80).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count),
              invitees.count <= 29, Set(invitees).count == invitees.count, !invitees.contains(accountID) else {
            throw BackpackError.invalid("Choose a room title and up to 29 distinct friends.")
        }
        struct Body: Encodable { let title: String; let inviteeIds: [String]; let shareHistory: Bool }
        struct Result: Decodable { let chat: NativeChatRoom }
        return try JSONDecoder().decode(Result.self, from: await send(.messaging, "social/chats", method: "POST",
            body: JSONEncoder().encode(Body(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                inviteeIds: invitees.map { $0.uuidString.lowercased() }, shareHistory: shareHistory)))).chat
    }
    func openEventRoom(_ id: UUID) async throws -> NativeChatRoom {
        guard eventChatsEnabled else { throw BackpackError.invalid("Event-wide chat is not enabled.") }
        struct Result: Decodable { let chat: NativeChatRoom }
        let value = try JSONDecoder().decode(Result.self, from: await send(.messaging,
            "social/event-chats/\(id.uuidString.lowercased())", method: "POST", body: Data("{}".utf8))).chat
        guard value.kind == "event", value.eventId == id else { throw BackpackError.invalid("Event-wide chat context mismatch.") }
        return value
    }
    func chatInvitations(page: Int) async throws -> NativeChatInvitationsPage {
        guard groupsEnabled else { throw BackpackError.invalid("Group invitations are unavailable.") }
        return try JSONDecoder().decode(NativeChatInvitationsPage.self, from: await send(.messaging, "social/chat-invitations", query: chatPaging(page)))
    }
    func respondChatInvite(_ invite: NativeChatInvitation, accept: Bool) async throws {
        struct Body: Encodable { let accept: Bool; let expectedRevision: Int }
        _ = try await send(.messaging, "social/chat-invitations/\(invite.id.uuidString.lowercased())", method: "POST",
            body: JSONEncoder().encode(Body(accept: accept, expectedRevision: invite.revision)))
    }
    func roomMembers(_ room: NativeChatRoom, page: Int) async throws -> NativeChatMembersPage {
        try JSONDecoder().decode(NativeChatMembersPage.self, from: await send(.messaging,
            "social/chats/\(room.id.uuidString.lowercased())/members", query: chatPaging(page)))
    }
    func leaveRoom(_ id: UUID) async throws {
        _ = try await send(.messaging, "social/chats/\(id.uuidString.lowercased())/leave", method: "POST", body: Data("{}".utf8))
    }
    func editRoom(_ room: NativeChatRoom, title: String) async throws {
        guard room.kind == "group", room.canManage, room.ownerId == accountID, (1...80).contains(title.utf16.count) else {
            throw BackpackError.invalid("Current group owner access/title is required.")
        }
        struct Body: Encodable { let title: String; let expectedRevision: Int }
        _ = try await send(.messaging, "social/chats/\(room.id.uuidString.lowercased())", method: "PATCH",
            body: JSONEncoder().encode(Body(title: title, expectedRevision: room.revision)))
    }
    func manageRoom(_ room: NativeChatRoom, target: UUID?, action: String, shareHistory: Bool = false) async throws {
        guard room.kind == "group", room.canManage, room.ownerId == accountID else { throw BackpackError.invalid("Current group owner access is required.") }
        struct Body: Encodable { let expectedRevision: Int; var userId: String?; var shareHistory: Bool? }
        var body = Body(expectedRevision: room.revision)
        let root = "social/chats/\(room.id.uuidString.lowercased())"
        let path: String, method: String
        switch action {
        case "delete": path = root; method = "DELETE"
        case "invite", "transfer":
            guard let target, target != accountID else { throw BackpackError.invalid("Choose another eligible contact/member.") }
            body.userId = target.uuidString.lowercased()
            if action == "invite" { body.shareHistory = shareHistory }
            path = "\(root)/\(action == "invite" ? "invitations" : "ownership")"; method = "POST"
        case "remove":
            guard let target, target != accountID else { throw BackpackError.invalid("The owner is protected.") }
            path = "\(root)/members/\(target.uuidString.lowercased())"; method = "DELETE"
        default: throw BackpackError.invalid("Unknown room-management action.")
        }
        _ = try await send(.messaging, path, method: method, body: JSONEncoder().encode(body))
    }
    func directHistory(peer: UUID, event: UUID?, before: DirectChatCursor?) async throws -> DirectChatPage {
        var query = [URLQueryItem(name: "userId", value: peer.uuidString.lowercased()), URLQueryItem(name: "limit", value: "50")]
        if let event { query.append(URLQueryItem(name: "eventId", value: event.uuidString.lowercased())) }
        if let before {
            guard before.createdAt.isFinite, before.createdAt >= 0, before.createdAt <= 9_007_199_254_740_991,
                  before.createdAt.rounded() == before.createdAt else {
                throw BackpackError.invalid("Invalid private history cursor.")
            }
            query += [URLQueryItem(name: "beforeCreatedAt", value: String(Int64(before.createdAt))),
                URLQueryItem(name: "beforeId", value: before.id.uuidString.lowercased())]
        }
        let page = try JSONDecoder().decode(DirectChatPage.self, from: await send(.messaging, "social/messages", query: query))
        guard page.limit == 50, page.messages.count <= 50, page.messages.allSatisfy({ row in
            guard let recipient = row.recipientId else { return false }
            return Set([row.senderId, recipient]) == Set([accountID, peer]) && row.eventId == event &&
                row.createdAt.isFinite && (0...9_007_199_254_740_991).contains(row.createdAt)
        }) else { throw BackpackError.invalid("Private conversation history does not match its captured context.") }
        for row in page.messages { _ = try row.pin?.normalized() }
        return page
    }
    func roomHistory(_ id: UUID, before: Int?) async throws -> RoomChatPage {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let before { guard before > 0 else { throw BackpackError.invalid("Invalid room cursor.") }; query.append(URLQueryItem(name: "before", value: String(before))) }
        let page = try JSONDecoder().decode(RoomChatPage.self, from: await send(.messaging,
            "social/chats/\(id.uuidString.lowercased())/messages", query: query))
        guard page.chat.id == id, !page.viewToken.isEmpty, page.messages.count <= 50,
              ["group", "event"].contains(page.chat.kind),
              page.messages.allSatisfy({ ($0.sequence ?? 0) > 0 && $0.createdAt.isFinite &&
                  (0...9_007_199_254_740_991).contains($0.createdAt) }) else { throw BackpackError.invalid("Invalid scoped room history.") }
        guard page.chat.kind == "group" ? groupsEnabled : eventChatsEnabled else { throw BackpackError.invalid("This room kind became unavailable.") }
        for row in page.messages { _ = try row.pin?.normalized() }
        return page
    }
    func sendChat(_ intent: ChatSendIntent) async throws -> NativeChatMessage {
        if intent.attachmentID != nil && !chatMediaEnabled { throw BackpackError.invalid("Private chat media is unavailable.") }
        if intent.pin != nil && !chatPinsEnabled { throw BackpackError.invalid("Fixed chat pins are unavailable.") }
        struct Result: Decodable { let message: NativeChatMessage }
        let path: String
        switch intent.context {
        case .room(let id): path = "social/chats/\(id.uuidString.lowercased())/messages"
        case .direct: path = "social/messages"
        }
        let value = try JSONDecoder().decode(Result.self, from: await send(.messaging, path, method: "POST", body: intent.data)).message
        guard value.senderId == accountID else { throw BackpackError.invalid("Message response belongs to another sender.") }
        return value
    }
    func uploadChatMedia(_ data: Data, context: ChatConversation) async throws -> ChatAttachmentDraft {
            guard chatMediaEnabled else { throw BackpackError.invalid("Private chat media is not enabled.") }
            let kind = try NativeAvatarInput.kind(data)
            var metadata: [String: String] = [:]
            switch context {
            case .room(let id): metadata["roomId"] = id.uuidString.lowercased()
            case .direct(let peer, let event):
                metadata["peerId"] = peer.uuidString.lowercased()
                if let event { metadata["eventId"] = event.uuidString.lowercased() }
            }
            let json = try JSONSerialization.data(withJSONObject: metadata)
            let boundary = "LEDBackpack-\(UUID().uuidString)"
            guard data.range(of: Data(boundary.utf8)) == nil else { throw BackpackError.invalid("Private upload boundary collision.") }
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n".utf8)
            body.append(json)
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"attachment.\(kind.extensionName)\"\r\nContent-Type: \(kind.mime)\r\n\r\n".utf8))
            body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let draft = try JSONDecoder().decode(ChatAttachmentDraft.self, from: await send(.messaging, "social/chat-attachments",
                method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
            guard draft.expiresAt.isFinite, draft.expiresAt > 0, draft.attachment.width == 512, draft.attachment.height == 512,
                  ["image/png", "image/gif"].contains(draft.attachment.mimeType) else { throw BackpackError.invalid("Invalid private attachment draft.") }
            _ = try privateAttachmentPath(draft.attachment.previewUrl, id: draft.attachment.id)
            _ = try privateAttachmentPath(draft.attachment.url, id: draft.attachment.id)
            guard chatMediaEnabled else { throw BackpackError.invalid("Private media availability changed.") }
            return draft
        }
        private func privateAttachmentPath(_ value: URL, id: UUID) throws -> String {
            guard value.baseURL == nil, value.query == nil, value.fragment == nil,
                  let parts = URLComponents(url: value, resolvingAgainstBaseURL: false),
                  !parts.percentEncodedPath.contains("%"), !value.relativeString.contains("\\") else {
                throw BackpackError.invalid("Invalid private media URL.")
            }
            let url: URL
            if value.scheme == nil {
                guard value.host == nil, value.relativeString.hasPrefix("/api/v1/social/chat-attachments/"),
                      let resolved = URL(string: value.relativeString, relativeTo: origin.url)?.absoluteURL else {
                    throw BackpackError.invalid("Private attachments must use the catalog API root.")
                }
                url = resolved
            } else { url = value }
            let segments = url.path.split(separator: "/").map(String.init)
            guard origin.contains(url), segments.count == 6, Array(segments.prefix(4)) == ["api", "v1", "social", "chat-attachments"],
                  segments[4] == id.uuidString.lowercased(), ["image.png", "image.gif", "preview.png"].contains(segments[5]),
                  try origin.api(segments.dropFirst(2).joined(separator: "/")) == url else {
                throw BackpackError.invalid("Private attachment path/account-origin context mismatch.")
            }
            return segments.dropFirst(2).joined(separator: "/")
        }
        func privateChatMedia(_ item: PrivateChatAttachment, animated: Bool) async throws -> Data {
            guard chatMediaEnabled else { throw BackpackError.invalid("Private media unavailable; recheck conversation access.") }
            let path = try privateAttachmentPath(animated ? item.url : item.previewUrl, id: item.id)
            return try await send(.messaging, path, maxBytes: 5_000_000)
        }
        func discardChatAttachment(_ id: UUID) async throws {
            struct Result: Decodable { let removed: Bool }
            guard try JSONDecoder().decode(Result.self, from: await send(.messaging,
                "social/chat-attachments/\(id.uuidString.lowercased())", method: "DELETE")).removed else {
                throw BackpackError.invalid("The unsent attachment was not discarded.")
            }
        }
    func deleteChatMessage(_ message: NativeChatMessage, context: ChatConversation) async throws {
        guard message.senderId == accountID else { throw BackpackError.invalid("Only your sent message can be deleted.") }
        let path: String
        switch context { case .room: path = "social/chat-messages"; case .direct: path = "social/messages" }
        _ = try await send(.messaging, "\(path)/\(message.id.uuidString.lowercased())", method: "DELETE")
    }
    func markRoomRead(_ id: UUID, sequence: Int) async throws {
        struct Body: Encodable { let throughSequence: Int }
        _ = try await send(.messaging, "social/chats/\(id.uuidString.lowercased())/read", method: "POST",
            body: JSONEncoder().encode(Body(throughSequence: sequence)))
    }
    func typing(_ context: ChatConversation) async throws -> ChatTypingPage {
        guard chatLiveEnabled else { throw BackpackError.invalid("Live typing is not enabled.") }
        return try JSONDecoder().decode(ChatTypingPage.self, from: await send(.messaging, "social/chat-typing", query: context.query))
    }
    func setTyping(_ context: ChatConversation, clientID: UUID, active: Bool) async throws {
        guard chatLiveEnabled else { throw BackpackError.invalid("Live typing is not enabled.") }
        struct Body: Encodable {
            let clientId: String; let typing: Bool
            var roomId, peerId, eventId: String?
        }
        var body = Body(clientId: clientID.uuidString.lowercased(), typing: active)
        switch context {
        case .room(let id): body.roomId = id.uuidString.lowercased()
        case .direct(let peer, let event): body.peerId = peer.uuidString.lowercased(); body.eventId = event?.uuidString.lowercased()
        }
        _ = try await send(.messaging, "social/chat-typing", method: "POST", body: JSONEncoder().encode(body))
    }
}
