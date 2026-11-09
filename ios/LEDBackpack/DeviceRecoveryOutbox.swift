import Foundation
import CryptoKit
import BackpackProtocol

struct DeviceRecoveryIntent: Codable, Equatable {
    enum Kind: String, Codable { case contact, message }
    enum State: String, Codable { case uncertain, acknowledged, retired, abandoned, expired }
    let accountID, peerID, clientID: UUID
    let origin: String
    let kind: Kind
    let vendorID: String?
    let conversationID: UUID?
    let text: String
    let createdAt, retryBefore, forgetAfter: Date
    var state: State
    var receiptID: UUID?

    init(account: UUID, origin: String, peer: UUID, kind: Kind, vendorID: String? = nil,
        conversationID: UUID? = nil, text: String, clientID: UUID = UUID(),
        now: Date = Date(), expiresAt: Date? = nil) throws {
        accountID = account; self.origin = origin; peerID = peer; self.kind = kind
        self.vendorID = vendorID; self.conversationID = conversationID
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines); self.clientID = clientID
        createdAt = now
        retryBefore = min(expiresAt ?? now.addingTimeInterval(30 * 86400),
            now.addingTimeInterval(kind == .contact ? 600 : 30 * 86400))
        forgetAfter = now.addingTimeInterval(30 * 86400)
        state = .uncertain
        try validate()
    }

    func validate() throws {
        guard accountID != peerID, (1...1000).contains(text.utf16.count),
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              createdAt.timeIntervalSince1970.isFinite, retryBefore > createdAt,
              retryBefore <= forgetAfter, forgetAfter <= createdAt.addingTimeInterval(30 * 86400),
              try CommunityOrigin.parse(origin).url.absoluteString == origin,
              state != .acknowledged || receiptID != nil else {
            throw BackpackError.invalid("The saved recovery message has invalid scope, text or deadlines.")
        }
        switch kind {
        case .contact:
            guard let vendorID, conversationID == nil, retryBefore <= createdAt.addingTimeInterval(600) else {
                throw BackpackError.invalid("The found-device request has invalid device scope.")
            }
            try VendorDeviceID.validate(vendorID)
        case .message:
            guard vendorID == nil, conversationID != nil else {
                throw BackpackError.invalid("The recovery reply has no matching conversation.")
            }
        }
    }

    func requireRetry(account: UUID, origin: String, peer: UUID, conversation: UUID? = nil,
        vendorID: String? = nil, now: Date = Date()) throws {
        try validate()
        guard accountID == account, self.origin == origin, peerID == peer,
              conversationID == conversation, self.vendorID == vendorID,
              state == .uncertain, now >= createdAt, now < retryBefore else {
            throw BackpackError.invalid("This saved message cannot be retried in the current context. Check recovery messages or clear the pending draft.")
        }
    }

    func sameIntent(as other: Self) -> Bool {
        var first = self, second = other
        first.state = .uncertain; first.receiptID = nil
        second.state = .uncertain; second.receiptID = nil
        return first == second && first.text.utf8.elementsEqual(second.text.utf8)
    }
}

@MainActor
final class DeviceRecoveryOutbox {
    private let vault: any CommunityVault
    init(vault: any CommunityVault) { self.vault = vault }

    private func key(account: UUID, origin: String, kind: DeviceRecoveryIntent.Kind) -> String {
        let digest = SHA256.hash(data: Data("\(origin)\n\(account.uuidString.lowercased())".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "device-recovery.outbox.v1:\(kind.rawValue):\(digest)"
    }

    func load(account: UUID, origin: String, kind: DeviceRecoveryIntent.Kind,
        now: Date = Date()) throws -> DeviceRecoveryIntent? {
        let key = key(account: account, origin: origin, kind: kind)
        guard let data = try vault.read(key) else { return nil }
        guard data.count <= 16_384 else { throw BackpackError.invalid("Saved recovery message exceeds its storage limit.") }
        var value = try JSONDecoder().decode(DeviceRecoveryIntent.self, from: data)
        try value.validate()
        guard value.accountID == account, value.origin == origin, value.kind == kind else {
            throw BackpackError.invalid("Saved recovery message belongs to another account or context.")
        }
        if now >= value.forgetAfter { try vault.remove(key); return nil }
        if now >= value.retryBefore, value.state == .uncertain {
            value.state = .expired
            try vault.save(JSONEncoder().encode(value), key: key)
        }
        return value
    }

    func save(_ value: DeviceRecoveryIntent) throws {
        try value.validate()
        if let prior = try load(account: value.accountID, origin: value.origin, kind: value.kind) {
            guard value.sameIntent(as: prior),
                  prior.state == .uncertain || prior.state == value.state,
                  prior.receiptID == nil || prior.receiptID == value.receiptID else {
                throw BackpackError.invalid("Resolve the pending recovery message before starting another. Its recipient, text and request ID cannot be replaced.")
            }
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 16_384 else { throw BackpackError.invalid("Recovery message exceeds its storage limit.") }
        try vault.save(data, key: key(account: value.accountID, origin: value.origin, kind: value.kind))
    }

    func requireCurrent(_ value: DeviceRecoveryIntent) throws {
        guard let current = try load(account: value.accountID, origin: value.origin, kind: value.kind),
              current.sameIntent(as: value), current.state == .uncertain else {
            throw BackpackError.invalid("The current recovery draft changed or was already resolved.")
        }
    }

    func acknowledge(_ value: DeviceRecoveryIntent, receipt: UUID) throws {
        try requireCurrent(value)
        var updated = value; updated.state = .acknowledged; updated.receiptID = receipt
        try save(updated)
    }

    func discard(_ value: DeviceRecoveryIntent) throws {
        guard let current = try load(account: value.accountID, origin: value.origin, kind: value.kind),
              current.sameIntent(as: value) else {
            throw BackpackError.invalid("The pending recovery message changed. Reload before clearing it.")
        }
        var updated = current; updated.state = .abandoned
        if current.state == .uncertain { try save(updated) }
        try vault.remove(key(account: value.accountID, origin: value.origin, kind: value.kind))
    }

    func clearResolved(_ value: DeviceRecoveryIntent) throws {
        guard let current = try load(account: value.accountID, origin: value.origin, kind: value.kind),
              current.sameIntent(as: value), current.state != .uncertain else {
            throw BackpackError.invalid("An uncertain recovery message cannot be silently cleared.")
        }
        try vault.remove(key(account: value.accountID, origin: value.origin, kind: value.kind))
    }
}
