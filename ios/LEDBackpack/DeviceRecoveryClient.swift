import Foundation
import BackpackProtocol

struct DeviceRecoveryPerson: Decodable, Equatable {
    let id: UUID
    let displayName: String
    func validate(account: UUID) throws {
        guard id != account, (1...80).contains(displayName.utf16.count),
              displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BackpackError.invalid("Invalid recovery conversation participant.")
        }
    }
}

struct DeviceRecoveryConversation: Decodable, Identifiable, Equatable {
    enum State: String, Decodable { case pending, accepted, closed }
    enum Role: String, Decodable { case owner, finder }
    let id: UUID
    let revision: Int
    let state: State
    let role: Role
    let peer: DeviceRecoveryPerson
    let createdAtISO, expiresAtISO: String
    let deviceId: UUID?

    func validate(account: UUID) throws {
        try peer.validate(account: account)
        let created = try CatalogEventTime.parse(createdAtISO), expires = try CatalogEventTime.parse(expiresAtISO)
        guard (1...9_007_199_254_740_991).contains(revision), created < expires,
              expires.timeIntervalSince(created) <= 30 * 86400 + 5,
              role == .owner || deviceId == nil else {
            throw BackpackError.invalid("Invalid recovery conversation scope or retention.")
        }
    }
}

struct DeviceRecoveryMessage: Decodable, Identifiable, Equatable {
    let id, senderId: UUID
    let text: String
    let sequence: Int
    let createdAtISO: String

    func validate(conversation: DeviceRecoveryConversation, account: UUID) throws {
        let created = try CatalogEventTime.parse(createdAtISO)
        let started = try CatalogEventTime.parse(conversation.createdAtISO)
        let expires = try CatalogEventTime.parse(conversation.expiresAtISO)
        guard senderId == account || senderId == conversation.peer.id,
              (1...1000).contains(text.utf16.count), (1...100).contains(sequence),
              created >= started, created < expires else {
            throw BackpackError.invalid("Invalid recovery message or sender.")
        }
    }
}

struct DeviceRecoveryConversationPage: Decodable {
    let conversations: [DeviceRecoveryConversation]
    let page: Int
    let hasMore: Bool
    func validate(account: UUID, requested: Int) throws {
        guard page == requested, conversations.count <= 24,
              Set(conversations.map(\.id)).count == conversations.count,
              !hasMore || !conversations.isEmpty else {
            throw BackpackError.invalid("Invalid recovery conversation page.")
        }
        for value in conversations {
            try value.validate(account: account)
            guard value.state != .closed else { throw BackpackError.invalid("Closed recovery conversations are not accessible.") }
        }
    }
}

struct DeviceRecoveryHistory: Decodable {
    let conversation: DeviceRecoveryConversation
    let messages: [DeviceRecoveryMessage]
    let hasMore: Bool
    let nextBefore: Int?
    func validate(account: UUID, id: UUID, before: Int?, limit: Int) throws {
        try conversation.validate(account: account)
        guard conversation.id == id, conversation.state != .closed,
              messages.count <= limit, Set(messages.map(\.id)).count == messages.count,
              messages.map(\.sequence) == messages.map(\.sequence).sorted(),
              Set(messages.map(\.sequence)).count == messages.count,
              nextBefore == messages.first?.sequence,
              !hasMore || !messages.isEmpty else {
            throw BackpackError.invalid("Invalid recovery message history or cursor.")
        }
        for message in messages {
            try message.validate(conversation: conversation, account: account)
            if let before, message.sequence >= before {
                throw BackpackError.invalid("Recovery history did not advance its captured cursor.")
            }
        }
    }
}

@MainActor
extension AccountServiceScope {
    func contactDeviceOwner(_ review: DeviceRegistryReview, identity: ConnectedBackpackIdentity,
        intent: DeviceRecoveryIntent) async throws -> DeviceRecoveryConversation {
        try checkDeviceRegistry(recovery: true)
        try identity.validate()
        let recovery = try review.recovery()
        try intent.requireRetry(account: accountID, origin: origin.url.absoluteString,
            peer: recovery.owner.id, vendorID: identity.vendorDeviceId)
        guard intent.kind == .contact else { throw BackpackError.invalid("Not a found-device introduction.") }
        struct Body: Encodable { let authorization, clientRequestId, text: String; let consent = true }
        struct Result: Decodable { let conversation: DeviceRecoveryConversation }
        let result = try await send(Result.self, "devices/recovery/contacts", method: "POST",
            body: JSONEncoder().encode(Body(authorization: recovery.contactAuthorization.token,
                clientRequestId: intent.clientID.uuidString.lowercased(), text: intent.text))).conversation
        try checkDeviceRegistry(recovery: true)
        try result.validate(account: accountID)
        guard result.role == .finder, result.peer.id == recovery.owner.id, result.state != .closed else {
            throw BackpackError.invalid("The found-device request was not linked to the displayed account.")
        }
        return result
    }

    func recoveryConversations(page: Int) async throws -> DeviceRecoveryConversationPage {
        try checkDeviceRegistry(recovery: true)
        guard (1...5).contains(page) else { throw BackpackError.invalid("Invalid recovery inbox page.") }
        let result = try await send(DeviceRecoveryConversationPage.self, "devices/recovery/conversations",
            query: [.init(name: "page", value: String(page))])
        try checkDeviceRegistry(recovery: true)
        try result.validate(account: accountID, requested: page)
        return result
    }

    func recoveryHistory(_ id: UUID, before: Int? = nil, limit: Int = 50) async throws -> DeviceRecoveryHistory {
        try checkDeviceRegistry(recovery: true)
        guard (1...50).contains(limit), before.map({ $0 > 0 }) ?? true else {
            throw BackpackError.invalid("Invalid recovery history request.")
        }
        let result = try await send(DeviceRecoveryHistory.self, "devices/recovery/conversations/\(id.uuidString.lowercased())",
            query: [.init(name: "limit", value: String(limit))] + (before.map { [.init(name: "before", value: String($0))] } ?? []))
        try checkDeviceRegistry(recovery: true)
        try result.validate(account: accountID, id: id, before: before, limit: limit)
        return result
    }

    func respondRecovery(_ conversation: DeviceRecoveryConversation, accept: Bool) async throws -> DeviceRecoveryConversation {
        try checkDeviceRegistry(recovery: true)
        try conversation.validate(account: accountID)
        guard conversation.role == .owner, conversation.state == .pending else {
            throw BackpackError.invalid("Only the registered account can answer this pending request.")
        }
        struct Body: Encodable { let expectedRevision: Int; let accept: Bool }
        struct Result: Decodable { let conversation: DeviceRecoveryConversation }
        let result = try await send(Result.self,
            "devices/recovery/conversations/\(conversation.id.uuidString.lowercased())/respond", method: "POST",
            body: JSONEncoder().encode(Body(expectedRevision: conversation.revision, accept: accept))).conversation
        try checkDeviceRegistry(recovery: true)
        try result.validate(account: accountID)
        guard result.id == conversation.id, result.revision == conversation.revision + 1,
              result.peer.id == conversation.peer.id, result.role == conversation.role,
              result.state == (accept ? .accepted : .closed) else {
            throw BackpackError.invalid("The recovery response was not confirmed. Refresh the conversation.")
        }
        return result
    }

    func sendRecovery(_ intent: DeviceRecoveryIntent, conversation: DeviceRecoveryConversation) async throws -> DeviceRecoveryMessage {
        try checkDeviceRegistry(recovery: true)
        try conversation.validate(account: accountID)
        try intent.requireRetry(account: accountID, origin: origin.url.absoluteString,
            peer: conversation.peer.id, conversation: conversation.id)
        guard conversation.state == .accepted, intent.kind == .message else {
            throw BackpackError.invalid("The owner must accept before recovery messages can be sent.")
        }
        struct Body: Encodable { let clientMessageId, text: String }
        struct Result: Decodable { let message: DeviceRecoveryMessage }
        let result = try await send(Result.self,
            "devices/recovery/conversations/\(conversation.id.uuidString.lowercased())/messages", method: "POST",
            body: JSONEncoder().encode(Body(clientMessageId: intent.clientID.uuidString.lowercased(), text: intent.text))).message
        try checkDeviceRegistry(recovery: true)
        try result.validate(conversation: conversation, account: accountID)
        guard result.senderId == accountID, result.text.utf8.elementsEqual(intent.text.utf8) else {
            throw BackpackError.invalid("The recovery send receipt did not match the saved message.")
        }
        return result
    }

    func closeRecovery(_ conversation: DeviceRecoveryConversation) async throws -> DeviceRecoveryConversation {
        try checkDeviceRegistry(recovery: true)
        try conversation.validate(account: accountID)
        guard conversation.state != .closed else { throw BackpackError.invalid("This recovery conversation is already closed.") }
        struct Body: Encodable { let expectedRevision: Int }
        struct Result: Decodable { let conversation: DeviceRecoveryConversation }
        let result = try await send(Result.self,
            "devices/recovery/conversations/\(conversation.id.uuidString.lowercased())", method: "DELETE",
            body: JSONEncoder().encode(Body(expectedRevision: conversation.revision))).conversation
        try checkDeviceRegistry(recovery: true)
        try result.validate(account: accountID)
        guard result.id == conversation.id, result.peer.id == conversation.peer.id, result.role == conversation.role,
              result.revision == conversation.revision + 1, result.state == .closed else {
            throw BackpackError.invalid("Closing the recovery conversation was not confirmed.")
        }
        return result
    }
}
