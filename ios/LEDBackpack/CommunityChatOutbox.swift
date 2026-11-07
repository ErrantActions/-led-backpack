import Foundation
import Security
import CryptoKit
import BackpackProtocol

enum NativeChatRetention {
    static let historySeconds: TimeInterval = 30 * 86400
    static let receiptSeconds: TimeInterval = 60 * 86400
    static func retained(createdAtMilliseconds: Double, now: Date) -> Bool {
        createdAtMilliseconds.isFinite && createdAtMilliseconds >= 0 &&
            now.timeIntervalSince1970 * 1000 < createdAtMilliseconds + historySeconds * 1000
    }
}
struct NativeChatClientReceipt: Codable {
    let accountID, clientID: UUID
    let state: NativeChatOutboxRecord.State
    let forgetAfter: Date
    func retained(at now: Date) -> Bool { now < forgetAfter }
}
struct NativeChatOutboxRecord: Codable {
    enum State: String, Codable { case uncertain, acknowledged, retired, accessLost, expired, abandoned }
    enum Purpose: String, Codable { case message, introduction }
    let accountID, clientID: UUID
    let origin: String
    let context: ChatConversation
    let purpose: Purpose
    let bytes: Data
    let createdAt, retryBefore, forgetAfter: Date
    let deliberateConsent: Bool
    var state: State
    var acknowledgedMessageID: UUID?
    init(account: UUID, origin: String, context: ChatConversation, clientID: UUID, bytes: Data,
         purpose: Purpose = .message, consent: Bool, now: Date = Date()) throws {
        guard consent, !bytes.isEmpty, bytes.count <= 32768, now.timeIntervalSince1970.isFinite else {
            throw BackpackError.invalid("Finalize and deliberately approve the exact message before storing it.")
        }
        accountID = account; self.origin = origin; self.context = context; self.clientID = clientID
        self.bytes = bytes; self.purpose = purpose; deliberateConsent = consent; createdAt = now
        retryBefore = now.addingTimeInterval(purpose == .introduction ? 14 * 86400 : NativeChatRetention.historySeconds)
        forgetAfter = now.addingTimeInterval(NativeChatRetention.receiptSeconds); state = .uncertain
        try validate()
    }
    func validate() throws {
        struct Body: Decodable { let clientMessageId: UUID; let recipientId, eventId: UUID? }
        let body = try JSONDecoder().decode(Body.self, from: bytes)
        guard deliberateConsent, bytes.count <= 32768, !origin.isEmpty,
              createdAt.timeIntervalSince1970.isFinite, retryBefore > createdAt,
              retryBefore <= createdAt.addingTimeInterval(NativeChatRetention.historySeconds),
              forgetAfter > retryBefore, forgetAfter <= createdAt.addingTimeInterval(NativeChatRetention.receiptSeconds),
              body.clientMessageId == clientID else { throw BackpackError.invalid("Outbox identity, consent or deadlines are invalid; nothing was resent.") }
        switch context {
        case .direct(let peer, let event):
            guard peer != accountID, body.recipientId == peer, body.eventId == event,
                  purpose != .introduction || event == nil else { throw BackpackError.invalid("Outbox recipient/context mismatch.") }
        case .room:
            guard purpose == .message, body.recipientId == nil, body.eventId == nil else { throw BackpackError.invalid("Outbox room context mismatch.") }
        }
        guard state != .acknowledged || acknowledgedMessageID != nil else { throw BackpackError.invalid("An acknowledgment must contain its actual message ID.") }
    }
    func requireRetry(account: UUID, origin: String, context: ChatConversation, now: Date = Date()) throws {
        try validate()
        guard account == accountID, origin == self.origin, context == self.context, state == .uncertain,
              now >= createdAt, now < retryBefore, now < forgetAfter else {
            throw BackpackError.invalid("This intent is retired, inaccessible or outside its recovery window. Never replace its ID to resend it.")
        }
    }
    mutating func recordFailure(_ failure: CommunityFailure) {
        acknowledgedMessageID = nil
        if failure.status == 409 && ["message_retired", "message_expired", "message_id_conflict", "chat_request_intent_changed", "chat_request_exists"].contains(failure.code) {
            state = .retired
        } else if [401, 403, 404].contains(failure.status) { state = .accessLost }
    }
}

// Exact pending bytes are device-only Keychain data, never UserDefaults or a public media cache.
@MainActor
enum NativeChatOutbox {
    private static let service = "com.errantactions.ledbackpack.chat-outbox-v1"
    private static func query(origin: String, account: UUID, context: ChatConversation, purpose: NativeChatOutboxRecord.Purpose) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let contextBytes = try encoder.encode(context)
        let digest = SHA256.hash(data: Data(origin.utf8) + contextBytes).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account.uuidString.lowercased()):\(purpose.rawValue):\(digest)"]
    }
    static func load(origin: String, account: UUID, context: ChatConversation,
                     purpose: NativeChatOutboxRecord.Purpose = .message, now: Date = Date()) throws -> NativeChatOutboxRecord? {
        var q = try query(origin: origin, account: account, context: context, purpose: purpose)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw BackpackError.invalid("Private outbox is locked or unavailable (\(status)).") }
        var value = try JSONDecoder().decode(NativeChatOutboxRecord.self, from: bytes); try value.validate()
        guard value.origin == origin, value.accountID == account, value.context == context, value.purpose == purpose else {
            throw BackpackError.invalid("Stored outbox scope mismatch.")
        }
        if now >= value.forgetAfter {
            try remove(value); return nil
        }
        if now >= value.retryBefore, value.state == .uncertain {
            value.state = .expired; value.acknowledgedMessageID = nil
            let updated = SecItemUpdate(try query(origin: origin, account: account, context: context, purpose: purpose) as CFDictionary,
                [kSecValueData as String: try JSONEncoder().encode(value)] as CFDictionary)
            guard updated == errSecSuccess else { throw BackpackError.invalid("Unable to retire an expired outbox intent.") }
        }
        return value
    }
    static func save(_ value: NativeChatOutboxRecord) throws {
        try value.validate()
        try rejectArchivedClientID(value)
        if let prior = try load(origin: value.origin, account: value.accountID, context: value.context, purpose: value.purpose) {
            guard prior.clientID == value.clientID, prior.bytes == value.bytes, prior.createdAt == value.createdAt,
                  prior.retryBefore == value.retryBefore, prior.forgetAfter == value.forgetAfter,
                  prior.state == .uncertain || prior.state == value.state else {
                throw BackpackError.invalid("The existing finalized outbox cannot be replaced or reset. Reconcile its exact intent first.")
            }
        }
        let q = try query(origin: value.origin, account: value.accountID, context: value.context, purpose: value.purpose)
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            try requirePendingCapacity()
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BackpackError.invalid("Unable to persist the finalized outbox. Nothing was sent.") }
        } else if status != errSecSuccess { throw BackpackError.invalid("Unable to update private outbox (\(status)).") }
    }
    private static func requirePendingCapacity() throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw BackpackError.invalid("Cannot inspect the bounded private outbox.") }
        var retained = 0
        for row in rows {
            guard let data = row[kSecValueData as String] as? Data, let key = row[kSecAttrAccount as String] as? String else {
                throw BackpackError.invalid("Invalid private outbox storage.")
            }
            let record = try JSONDecoder().decode(NativeChatOutboxRecord.self, from: data); try record.validate()
            if Date() >= record.forgetAfter {
                let deletion: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: key]
                let removed = SecItemDelete(deletion as CFDictionary)
                guard removed == errSecSuccess || removed == errSecItemNotFound else { throw BackpackError.invalid("Expired outbox cleanup failed.") }
            } else { retained += 1 }
        }
        guard retained < 100 else { throw BackpackError.invalid("The device-only 100-intent bound is full. Reconcile or explicitly archive terminal intents; nothing new was sent.") }
    }
    private static func rejectArchivedClientID(_ value: NativeChatOutboxRecord) throws {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".receipts", kSecAttrAccount as String: "\(value.accountID):\(value.clientID)"]
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data else { throw BackpackError.invalid("Invalid client receipt storage.") }
            let receipt = try JSONDecoder().decode(NativeChatClientReceipt.self, from: data)
            if !receipt.retained(at: Date()) {
                q.removeValue(forKey: kSecReturnData as String)
                let removed = SecItemDelete(q as CFDictionary)
                guard removed == errSecSuccess || removed == errSecItemNotFound else { throw BackpackError.invalid("Expired client receipt cleanup failed.") }
            }
            throw BackpackError.invalid("A terminal sender/client-ID cannot be reused, even after its receipt expires.")
        }
        guard status == errSecItemNotFound else {
            throw BackpackError.invalid("Unable to check retired client-ID receipts (\(status)).")
        }
    }
    static func remove(_ value: NativeChatOutboxRecord) throws {
        let status = SecItemDelete(try query(origin: value.origin, account: value.accountID, context: value.context, purpose: value.purpose) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackpackError.invalid("Unable to clear the private outbox (\(status)).") }
    }
    static func archiveTerminal(_ value: NativeChatOutboxRecord) throws {
        guard value.state != .uncertain else { throw BackpackError.invalid("An uncertain send must be reconciled, not replaced.") }
        let receipt = NativeChatClientReceipt(accountID: value.accountID, clientID: value.clientID, state: value.state, forgetAfter: value.forgetAfter)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".receipts", kSecAttrAccount as String: "\(value.accountID):\(value.clientID)"]
        let data = try JSONEncoder().encode(receipt)
        var existing = q; existing[kSecReturnAttributes as String] = true; existing[kSecReturnData as String] = true
        existing[kSecMatchLimit as String] = kSecMatchLimitAll
        existing.removeValue(forKey: kSecAttrAccount as String)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(existing as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackpackError.invalid("Unable to inspect bounded client receipts.") }
        if status == errSecSuccess {
            guard let rows = result as? [[String: Any]] else { throw BackpackError.invalid("Invalid bounded client receipt storage.") }
            var retained = 0
            var alreadyStored = false
            for row in rows {
                guard let stored = row[kSecValueData as String] as? Data, let key = row[kSecAttrAccount as String] as? String else {
                    throw BackpackError.invalid("Invalid client receipt storage.")
                }
                let old = try JSONDecoder().decode(NativeChatClientReceipt.self, from: stored)
                if !old.retained(at: Date()) {
                    let deletion: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service + ".receipts", kSecAttrAccount as String: key]
                    let removed = SecItemDelete(deletion as CFDictionary)
                    guard removed == errSecSuccess || removed == errSecItemNotFound else { throw BackpackError.invalid("Expired client receipt cleanup failed.") }
                } else {
                    retained += 1
                    if old.accountID == value.accountID && old.clientID == value.clientID { alreadyStored = true }
                }
            }
            guard retained < 500 || alreadyStored else { throw BackpackError.invalid("Client receipt bound reached; wait for expiry before clearing more intents.") }
        }
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BackpackError.invalid("Client receipt could not be preserved.") }
        } else if updated != errSecSuccess { throw BackpackError.invalid("Client receipt could not be updated.") }
        try remove(value)
    }
}

@MainActor
extension CommunityFeatureClient {
    func submitOutbox(_ original: NativeChatOutboxRecord) async throws -> NativeChatOutboxRecord {
        try original.requireRetry(account: accountID, origin: origin.url.absoluteString, context: original.context)
        if case .direct = original.context, original.purpose == .message, !retainedChatRecoveryEnabled {
            throw BackpackError.invalid("This server has not advertised the retained-history recovery contract.")
        }
        try NativeChatOutbox.save(original)
        var value = original
        do {
            struct Result: Decodable { let message: NativeChatMessage }
            let path: String
            if original.purpose == .introduction {
                guard messageRequestsEnabled else { throw BackpackError.invalid("Message requests are unavailable.") }
                path = "social/message-requests"
                struct Receipt: Decodable { let request: NativeMessageRequest }
                let receipt = try JSONDecoder().decode(Receipt.self, from: await send(.messaging, path, method: "POST", body: original.bytes)).request
                try receipt.validate(account: accountID)
                guard case .direct(let peer, nil) = original.context,
                      !receipt.incoming, receipt.contact == nil || receipt.contact?.id == peer,
                      messageRequestsEnabled else { throw BackpackError.invalid("Introduction receipt changed recipient, account or capability.") }
                value.acknowledgedMessageID = receipt.id
            } else {
                struct Content: Decodable { let text: String?; let attachmentId: UUID?; let pin: ChatPin?; let reference: ChatReferenceSelection? }
                let content = try JSONDecoder().decode(Content.self, from: original.bytes)
                try content.reference?.validate()
                if case .room = original.context, content.reference?.inviteRecipient == true {
                    throw BackpackError.invalid("A room reference cannot invite a direct recipient.")
                }
                guard content.attachmentId == nil || chatMediaEnabled, content.pin == nil || chatPinsEnabled,
                      content.reference == nil || chatReferencesEnabled,
                      content.reference?.kind != "playlist" || chatPlaylistReferencesEnabled else {
                    throw BackpackError.invalid("Captured attachment/reference capability changed. Reconcile history; no replacement send was made.")
                }
                switch original.context {
                case .direct: path = "social/messages"
                case .room(let id):
                    _ = try await room(id)
                    path = "social/chats/\(id.uuidString.lowercased())/messages"
                }
                let receipt = try JSONDecoder().decode(Result.self, from: await send(.messaging, path, method: "POST", body: original.bytes)).message
                guard receipt.senderId == accountID, receipt.text == (content.text ?? ""),
                      receipt.pin == content.pin, receipt.attachment?.id == content.attachmentId,
                      NativeChatRetention.retained(createdAtMilliseconds: receipt.createdAt, now: Date()) else {
                    throw BackpackError.invalid("Message receipt is not a currently retained acknowledgment.")
                }
                if case .direct(let peer, let event) = original.context {
                    guard receipt.recipientId == peer, receipt.eventId == event else { throw BackpackError.invalid("Message acknowledgment belongs to another peer.") }
                }
                value.acknowledgedMessageID = receipt.id
            }
            try check(.messaging); try Task.checkCancellation()
            value.state = .acknowledged; try NativeChatOutbox.save(value); return value
        } catch {
            if let failure = error as? CommunityFailure { value.recordFailure(failure); try NativeChatOutbox.save(value) }
            throw error
        }
    }
}
