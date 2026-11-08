import Foundation
import BackpackProtocol

struct LocalMetFriend: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let canRequestFriendship: Bool
    // No token/key/peripheral/RSSI/coordinates/session time is persisted.
}
struct PhoneSwapThrottle {
    private(set) var journalID: UUID?
    private(set) var peers: Set<UUID> = []
    private(set) var nextUptime = 0.0
    mutating func resume(journal: LocalSwapOriginal, now: Date, uptime: Double) throws {
        guard uptime.isFinite, uptime >= 0 else { throw BackpackError.invalid("Invalid local game clock.") }
        if journalID != journal.transactionID { peers = [] }
        journalID = journal.transactionID
        peers.formUnion(journal.gamePeerIDs ?? [])
        let remaining = journal.cooldownUntil?.timeIntervalSince(now) ?? 0
        guard remaining.isFinite else { throw BackpackError.invalid("Invalid retained game cooldown.") }
        nextUptime = max(nextUptime, uptime + max(0, remaining))
    }
    func permits(_ peer: UUID, uptime: Double) -> Bool {
        uptime.isFinite && uptime >= nextUptime && !peers.contains(peer) && peers.count < 32
    }
    mutating func applied(_ peer: UUID, uptime: Double) throws {
        guard permits(peer, uptime: uptime) else { throw BackpackError.invalid("Game cooldown or same-peer suppression is active.") }
        peers.insert(peer)
        nextUptime = max(nextUptime, uptime + 60)
    }
}
struct PhoneSwapApplicationReceipt: Sendable {
    let exchangeID: UUID
    let peerID: UUID
    let outgoingHash: String
    let incomingHash: String
    let peerAppliedHash: String
    let proved, ownReadyAcknowledged, peerReady, ownApplied, ownAppliedSent: Bool
    func validate(data: Data, peer: LocalMetFriend) throws {
        guard proved, ownReadyAcknowledged, peerReady, ownApplied, ownAppliedSent,
              peerID == peer.id, incomingHash == LocalSwapOriginal.digest(data),
              outgoingHash.count == 64, outgoingHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              peerAppliedHash == outgoingHash else {
            throw BackpackError.invalid("A matched authenticated bilateral application receipt is required for Found Users.")
        }
    }
}
actor PhoneSwapLocalStore {
    private let root: URL
    private let recovery: SwapRecoveryRepository
    init(root: URL, recovery: SwapRecoveryRepository? = nil) {
        self.root = root; self.recovery = recovery ?? SwapRecoveryRepository(root: root.appendingPathComponent("SwapRecovery", isDirectory: true))
    }
    private func cardsURL(scope: String) -> URL {
        root.appendingPathComponent("MetFriends", isDirectory: true).appendingPathComponent(LocalSwapOriginal.digest(Data(scope.utf8)) + ".json")
    }
    func cards(scope: String) throws -> [LocalMetFriend] {
        let url = cardsURL(scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let bytes = try PhoneDisplayFileReader.read(url)
        guard bytes.count <= 20000 else { throw BackpackError.invalid("Local minimal Met friends index is oversized; not reset.") }
        let value = try JSONDecoder().decode([LocalMetFriend].self, from: bytes)
        guard value.count <= 50, Set(value.map(\.id)).count == value.count,
              value.allSatisfy({ (1...80).contains($0.displayName.utf16.count) }) else { throw BackpackError.invalid("Invalid local Met friends cards.") }
        return value
    }
    func retainCard(_ peer: PhoneSwapContact, scope: String) throws {
        try peer.validate()
        var current = try cards(scope: scope)
        current.removeAll { $0.id == peer.id }
        guard current.count < 50 else { throw BackpackError.invalid("Local Met friends limit reached (50). Dismiss cards explicitly.") }
        current.append(LocalMetFriend(id: peer.id, displayName: peer.displayName, canRequestFriendship: peer.canRequestFriendship))
        try save(current, scope: scope)
    }
    func dismiss(_ id: UUID, scope: String) throws { try save(cards(scope: scope).filter { $0.id != id }, scope: scope) }
    private func save(_ value: [LocalMetFriend], scope: String) throws {
        let url = cardsURL(scope: scope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        try JSONEncoder().encode(value.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
            .write(to: url, options: [.atomic, .completeFileProtection])
    }
    func original(snapshot: PhoneDisplaySnapshot, artworkRevision: UUID, scope: String, attribution: Attribution?,
        purpose: String = "game-v1") async throws -> LocalSwapOriginal {
        try await recovery.prepareGame(snapshot: snapshot, artworkRevision: artworkRevision, ownerScope: scope, attribution: attribution, purpose: purpose)
    }
    func stageFriendScene(scene: Data, receivedGIF: Data?, exchangeID: UUID, credit: Attribution,
        sessionID: UUID, ownConsent: Bool, peerConsent: Bool, bothReady: Bool, scope: String,
        expectedRevision: UUID, nextRevision: UUID, expiresAt: Date, now: Date) async throws -> LocalSwapOriginal {
        let staged = try await recovery.stageAcceptedFriendScene(sessionID: sessionID, ownConsent: ownConsent, peerConsent: peerConsent,
            bothReady: bothReady, ownerScope: scope, expectedRevision: expectedRevision, nextRevision: nextRevision,
            scene: scene, expiresAt: expiresAt, now: now)
        if let receivedGIF {
            _ = try await recovery.retainReceived(data: receivedGIF, transactionID: exchangeID,
                name: "Explicit friend pass-animation", attribution: credit, verifiedGame: true)
        }
        return staged
    }
    func receivedAndStage(_ incoming: Data, exchangeID: UUID, credit: Attribution, peer: PhoneSwapContact,
        readiness: SwapPeerReadiness, scope: String, expectedRevision: UUID, nextRevision: UUID,
        now: Date) async throws -> LocalSwapOriginal {
        guard exchangeID == readiness.sessionID else { throw BackpackError.invalid("Incoming exchange/session binding changed.") }
        try await recovery.validateIncomingForFuturePhoneReplacement(readiness: readiness, session: readiness.sessionID,
            accountEpoch: readiness.accountEpoch, ownerScope: scope, target: .phone, incoming: incoming, now: now)
        try peer.validate()
        try await recovery.ensureReceivedCapacity(for: incoming)
        return try await recovery.stageGameReplacement(readiness: readiness, session: readiness.sessionID,
            accountEpoch: readiness.accountEpoch, ownerScope: scope, expectedRevision: expectedRevision,
            nextRevision: nextRevision, incoming: incoming, now: now, peerID: peer.id)
    }
    func confirmReceived(_ incoming: Data, credit: Attribution, peer: PhoneSwapContact,
        receipt: PhoneSwapApplicationReceipt, scope: String) async throws -> ReceivedSwapArtwork {
        try peer.validate()
        return try await recovery.retainConfirmedGame(data: incoming, attribution: credit,
            sender: LocalMetFriend(id: peer.id, displayName: peer.displayName, canRequestFriendship: peer.canRequestFriendship),
            receipt: receipt, ownerScope: scope)
    }
    func found(scope: String) async throws -> [ReceivedSwapArtwork] {
        try await recovery.received().filter { $0.isFoundUser(ownerScope: scope) }
    }
    func removeFound(_ item: ReceivedSwapArtwork, scope: String) async throws {
        guard item.isFoundUser(ownerScope: scope),
              let current = try await recovery.received().first(where: { $0.id == item.id }),
              current.isFoundUser(ownerScope: scope), current.transactionID == item.transactionID,
              current.sender == item.sender, current.sha256 == item.sha256 else {
            throw BackpackError.invalid("The selected Found Users record changed or belongs to another account.")
        }
        try await recovery.removeReceived(item.id)
    }
    func originalForRestore(_ id: UUID, scope: String) async throws -> LocalSwapOriginal {
        try await recovery.beginRestore(id: id, ownerScope: scope, target: .phone)
    }
    func acknowledge(_ id: UUID, hash: String, scope: String) async throws {
        _ = try await recovery.acknowledgeRestore(id: id, originalSHA256: hash, ownerScope: scope)
    }
}
