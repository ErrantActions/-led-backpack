import Foundation
import CryptoKit
import BackpackProtocol

enum LocalSwapStage: String, Codable, Sendable {
    case prepared, replacementApplied, recoveryRequired, restoring, restored
}
struct LocalSwapOriginal: Codable, Sendable {
    let schema: Int
    let transactionID, installationID: UUID
    let ownerScope: String
    let target: NativeDisplayTarget
    let phone: PhoneDisplaySnapshot
    let originalFrame: Int
    let originalSHA256: String
    let sourceArtworkRevision: UUID
    let stagedHardwareArtworkID: UUID?
    let attribution: Attribution?
    var stage: LocalSwapStage
    var replacementSHA256: String?
    var replacementArtworkRevision: UUID?
    var acknowledgementSHA256: String?
    var cooldownUntil: Date?
    var peerPurpose: String? = nil
    var gamePeerIDs: [UUID]? = nil
    var gameExchangeID: UUID? = nil
    var gameExchangePeerID: UUID? = nil
    var needsRecovery: Bool { stage != .restored }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func frameIndex(_ snapshot: PhoneDisplaySnapshot) throws -> Int {
        guard let data = snapshot.data, snapshot.elapsed.isFinite, snapshot.elapsed >= 0 else {
            throw BackpackError.invalid("A complete original and valid playhead are required.")
        }
        let preview = try GIFPreviewDecoder.phoneDisplay(data)
        if preview.duration > 0, let cycles = preview.cycles, snapshot.elapsed >= preview.duration * Double(cycles) {
            return preview.frames.count - 1
        }
        return preview.frameIndex(at: snapshot.elapsed)
    }
    func validate(installation: UUID, ownerScope: String, target: NativeDisplayTarget) throws {
        guard schema == 1, installationID == installation, self.ownerScope == ownerScope,
              self.target == target, target == .phone,
              !ownerScope.isEmpty, ownerScope.utf8.count <= 2200,
              let data = phone.data, (1...5_000_000).contains(data.count),
              originalSHA256 == Self.digest(data), phone.elapsed.isFinite, phone.elapsed >= 0 else {
            throw BackpackError.invalid("Recovery snapshot identity/target/integrity is invalid. Original journal is retained; no hardware fallback.")
        }
        let index = try Self.frameIndex(phone)
        guard originalFrame == index, (phone.brightnessLevel ?? 0.5).isFinite,
              (0.1...1).contains(phone.brightnessLevel ?? 0.5) else {
            throw BackpackError.invalid("Recovery frame/playhead/presentation does not match the retained original.")
        }
        if let attribution {
            guard [attribution.source, attribution.author, attribution.license, attribution.licenseURL].allSatisfy({ $0.utf16.count <= 2048 }) else {
                throw BackpackError.invalid("Recovery attribution exceeds its metadata bounds.")
            }
        }
        if let peerPurpose {
            let prefixes = ["friend-v1:", "phone-session-v1:"]
            guard peerPurpose == "game-v1" || peerPurpose == "solo-v1" ||
                prefixes.contains(where: { prefix in
                    peerPurpose.hasPrefix(prefix) && UUID(uuidString: String(peerPurpose.dropFirst(prefix.count)))?.uuidString.lowercased() == String(peerPurpose.dropFirst(prefix.count))
                }) else {
                throw BackpackError.invalid("Unknown recovery controller/session association; original retained.")
            }
        }
        if let gamePeerIDs {
            guard peerPurpose == "game-v1", gamePeerIDs.count <= 32,
                  Set(gamePeerIDs).count == gamePeerIDs.count else {
                throw BackpackError.invalid("Invalid retained game peer suppression; original retained.")
            }
        }
        if gameExchangeID != nil || gameExchangePeerID != nil {
            guard peerPurpose == "game-v1", stage != .prepared, gameExchangeID != nil, let gameExchangePeerID,
                  gamePeerIDs?.contains(gameExchangePeerID) == true else {
                throw BackpackError.invalid("Invalid staged game exchange binding; original retained.")
            }
        }
        if stage == .restored {
            guard acknowledgementSHA256 == originalSHA256 else { throw BackpackError.invalid("Restoration acknowledgment is incomplete; original copy retained.") }
        }
    }
}
struct SwapPeerReadiness: Sendable {
    let transactionID, sessionID, accountEpoch: UUID
    var gameEnabled = false
    var ownReady = false
    var peerGameEnabled = false
    var peerReady = false
    var cancelled = false
    let expiresAt: Date
    func requireApply(journal: LocalSwapOriginal, installation: UUID, ownerScope: String,
        session: UUID, account: UUID, incoming: Data, now: Date) throws {
        try journal.validate(installation: installation, ownerScope: ownerScope, target: .phone)
        guard gameEnabled, ownReady, peerGameEnabled, peerReady, !cancelled, now < expiresAt,
              sessionID == session, accountEpoch == account, transactionID == journal.transactionID,
              [.prepared, .replacementApplied].contains(journal.stage), !incoming.isEmpty else {
            throw BackpackError.invalid("Both peers' explicit game/readiness, current session and durable recovery are required. No replay or inferred discovery permission.")
        }
        if let cooldown = journal.cooldownUntil, now < cooldown { throw BackpackError.invalid("Local swap cooldown has not elapsed.") }
        _ = try GIFPreviewDecoder.phoneDisplay(incoming)
    }
}
struct ReceivedSwapArtwork: Codable, Identifiable, Sendable {
    let schema: Int
    let id: UUID
    let transactionID: UUID
    let data: Data
    let sha256: String
    let name: String
    let attribution: Attribution?
    let transportVerified: Bool
    var sender: LocalMetFriend? = nil
    var ownerScope: String? = nil
    var bilateralConfirmed: Bool? = nil
    var sentSHA256: String? = nil
    func isFoundUser(ownerScope: String) -> Bool {
        transportVerified && bilateralConfirmed == true && sender != nil && self.ownerScope == ownerScope && sentSHA256?.count == 64
    }
    func validate() throws {
        guard schema == 1, (1...5_000_000).contains(data.count), sha256 == LocalSwapOriginal.digest(data),
              !name.isEmpty, name.utf16.count <= 160 else { throw BackpackError.invalid("Received artwork is incomplete, corrupted or outside its bounds.") }
        if let attribution {
            guard [attribution.source, attribution.author, attribution.license, attribution.licenseURL].allSatisfy({ $0.utf16.count <= 2048 }) else {
                throw BackpackError.invalid("Received attribution exceeds its metadata bounds.")
            }
        }
        if sender != nil || ownerScope != nil || bilateralConfirmed != nil || sentSHA256 != nil {
            guard transportVerified, bilateralConfirmed == true, let sender, let ownerScope,
                  !ownerScope.isEmpty, ownerScope.utf8.count <= 2200,
                  (1...80).contains(sender.displayName.utf16.count), let sentSHA256,
                  sentSHA256.count == 64, sentSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw BackpackError.invalid("Received GIF and confirmed minimal sender card are not paired.")
            }
        }
        _ = try GIFPreviewDecoder.phoneDisplay(data)
    }
}
actor SwapRecoveryRepository {
    static let shared: SwapRecoveryRepository? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
        SwapRecoveryRepository(root: $0.appendingPathComponent("SwapRecovery", isDirectory: true))
    }
    private let root: URL
    private var journalURL: URL { root.appendingPathComponent("active.json") }
    init(root: URL) { self.root = root }
    private struct Envelope: Codable { let schema: Int; let payload: Data; let sha256: String }
    private func read(_ url: URL, max: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              (1...max).contains(size), let stream = InputStream(url: url) else { throw BackpackError.invalid("Owned recovery file is missing, linked or oversized; it was not reset.") }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? BackpackError.invalid("Recovery read failed.") }
            if count == 0 { break }
            guard data.count + count <= max else { throw BackpackError.invalid("Recovery file grew beyond budget.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == size else { throw BackpackError.invalid("Recovery file changed during read.") }
        return data
    }
    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        let bytes = try JSONEncoder().encode(Envelope(schema: 1, payload: payload, sha256: LocalSwapOriginal.digest(payload)))
        guard bytes.count <= 10_000_000 else { throw BackpackError.invalid("Recovery record exceeds its envelope budget.") }
        return bytes
    }
    private func decode<Value: Decodable>(_ type: Value.Type, url: URL) throws -> Value {
        let envelope = try JSONDecoder().decode(Envelope.self, from: read(url, max: 10_000_000))
        guard envelope.schema == 1, envelope.sha256 == LocalSwapOriginal.digest(envelope.payload) else {
            throw BackpackError.invalid("Recovery envelope integrity/version mismatch. Existing original is preserved.")
        }
        return try JSONDecoder().decode(type, from: envelope.payload)
    }
    private func directory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
    }
    func installation() throws -> UUID {
        let url = root.appendingPathComponent("installation.json")
        if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode(UUID.self, from: read(url, max: 100)) }
        guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw BackpackError.invalid("Recovery installation identity is missing; journal retained, not adopted by a new identity.") }
        try directory()
        let id = UUID()
        try JSONEncoder().encode(id).write(to: url, options: [.atomic, .completeFileProtection])
        return id
    }
    func load() throws -> LocalSwapOriginal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let value = try decode(LocalSwapOriginal.self, url: journalURL)
        try value.validate(installation: installation(), ownerScope: value.ownerScope, target: value.target)
        return value
    }
    func prepare(snapshot: PhoneDisplaySnapshot, frame: Int?, artworkRevision: UUID, ownerScope: String,
        target: NativeDisplayTarget, hardwareArtwork: UUID?, attribution: Attribution?) throws -> LocalSwapOriginal {
        let installation = try installation()
        if let current = try load() {
            guard current.stage == .restored else {
                throw BackpackError.invalid("One durable transaction at a time. Restore the original and wait out the local cooldown; no journal is overwritten.")
            }
            if let cooldown = current.cooldownUntil, Date() < cooldown { throw BackpackError.invalid("Wait for the local recovery cooldown before preparing another transaction.") }
        }
        guard target == .phone, let original = snapshot.data else { throw BackpackError.invalid("Only an actual selected phone original can be prepared. Hardware pointer/hash/sentinel is not recoverable artwork.") }
        let actualFrame = try LocalSwapOriginal.frameIndex(snapshot)
        guard frame == nil || frame == actualFrame else { throw BackpackError.invalid("Captured phone frame does not match the retained playhead. No original was overwritten.") }
        if let attribution {
            guard [attribution.source, attribution.author, attribution.license, attribution.licenseURL].allSatisfy({ $0.utf16.count <= 2048 }) else {
                throw BackpackError.invalid("Original attribution exceeds recovery metadata bounds.")
            }
        }
        let value = LocalSwapOriginal(schema: 1, transactionID: UUID(), installationID: installation,
            ownerScope: ownerScope, target: target, phone: snapshot, originalFrame: actualFrame,
            originalSHA256: LocalSwapOriginal.digest(original), sourceArtworkRevision: artworkRevision,
            stagedHardwareArtworkID: hardwareArtwork, attribution: attribution, stage: .prepared)
        try value.validate(installation: installation, ownerScope: ownerScope, target: target)
        try directory()
        try encode(value).write(to: journalURL, options: [.atomic, .completeFileProtection])
        let verified = try load()
        guard verified?.transactionID == value.transactionID, verified?.originalSHA256 == value.originalSHA256 else { throw BackpackError.invalid("Durable original read-back did not confirm. Replacement is prohibited.") }
        return value
    }
    func beginRestore(id: UUID, ownerScope: String, target: NativeDisplayTarget) throws -> LocalSwapOriginal {
        guard var current = try load(), current.transactionID == id else { throw BackpackError.invalid("Recovery transaction changed or is unavailable.") }
        try current.validate(installation: installation(), ownerScope: ownerScope, target: target)
        current.stage = .restoring
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        return current
    }
    func validateIncomingForFuturePhoneReplacement(readiness: SwapPeerReadiness, session: UUID,
        accountEpoch: UUID, ownerScope: String, target: NativeDisplayTarget, incoming: Data, now: Date) throws {
        guard target == .phone, let current = try load() else {
            throw BackpackError.invalid("An acknowledged durable PHONE original is required. Hardware exchange is unavailable.")
        }
        try readiness.requireApply(journal: current, installation: installation(), ownerScope: ownerScope,
            session: session, account: accountEpoch, incoming: incoming, now: now)
        // Validation grants no transport, UI replacement or service/game permission.
    }
    func prepareGame(snapshot: PhoneDisplaySnapshot, artworkRevision: UUID, ownerScope: String,
        attribution: Attribution?, purpose: String = "game-v1") throws -> LocalSwapOriginal {
        if var current = try load(), current.needsRecovery {
            let expected = current.stage == .prepared ? current.sourceArtworkRevision : current.replacementArtworkRevision
            guard current.ownerScope == ownerScope, [.prepared,.replacementApplied].contains(current.stage),
                  current.peerPurpose == purpose || (current.peerPurpose == nil && current.stage == .prepared),
                  expected == artworkRevision,
                  snapshot.data.map(LocalSwapOriginal.digest) == (current.stage == .prepared ? current.originalSHA256 : current.replacementSHA256) else {
                throw BackpackError.invalid("Restore/review the existing original first; a different phone selection, bytes or purpose cannot be adopted silently.")
            }
            if current.peerPurpose == nil {
                current.peerPurpose = purpose
                try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
            }
            return current
        }
        var current = try prepare(snapshot: snapshot, frame: nil, artworkRevision: artworkRevision, ownerScope: ownerScope,
            target: .phone, hardwareArtwork: nil, attribution: attribution)
        current.peerPurpose = purpose
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        return current
    }
    func stageAcceptedFriendScene(sessionID: UUID, ownConsent: Bool, peerConsent: Bool, bothReady: Bool,
        ownerScope: String, expectedRevision: UUID, nextRevision: UUID, scene: Data, expiresAt: Date,
        now: Date) throws -> LocalSwapOriginal {
        guard var current = try load(), ownConsent, peerConsent, bothReady, now < expiresAt,
              current.peerPurpose == "friend-v1:" + sessionID.uuidString.lowercased(),
              [.prepared,.replacementApplied].contains(current.stage) else { throw BackpackError.invalid("Current accepted-friend media consent/readiness/durable original is required; game consent cannot substitute.") }
        try current.validate(installation: installation(), ownerScope: ownerScope, target: .phone)
        let expected = current.stage == .prepared ? current.sourceArtworkRevision : current.replacementArtworkRevision
        guard expected == expectedRevision else { throw BackpackError.invalid("Newer deliberate phone artwork cannot be replaced by a friend scene.") }
        if let cooldown = current.cooldownUntil, now < cooldown { throw BackpackError.invalid("Friend-scene cooldown active.") }
        _ = try GIFPreviewDecoder.phoneDisplay(scene)
        current.stage = .replacementApplied; current.replacementArtworkRevision = nextRevision
        current.replacementSHA256 = LocalSwapOriginal.digest(scene); current.cooldownUntil = now.addingTimeInterval(60)
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        return current
    }
    func stageGameReplacement(readiness: SwapPeerReadiness, session: UUID, accountEpoch: UUID,
        ownerScope: String, expectedRevision: UUID, nextRevision: UUID, incoming: Data, now: Date,
        peerID: UUID? = nil) throws -> LocalSwapOriginal {
        guard var current = try load() else { throw BackpackError.invalid("No durable original; replacement forbidden.") }
        let expected = current.stage == .prepared ? current.sourceArtworkRevision : current.replacementArtworkRevision
        guard expected == expectedRevision else { throw BackpackError.invalid("A newer deliberate phone selection must not be overwritten.") }
        try readiness.requireApply(journal: current, installation: installation(), ownerScope: ownerScope,
            session: session, account: accountEpoch, incoming: incoming, now: now)
        if let peerID {
            var peers = current.gamePeerIDs ?? []
            guard current.peerPurpose == "game-v1", !peers.contains(peerID), peers.count < 32 else {
                throw BackpackError.invalid("This peer already exchanged in the retained game; stop/rearm cannot permit ping-pong.")
            }
            peers.append(peerID)
            current.gamePeerIDs = peers.sorted { $0.uuidString < $1.uuidString }
            current.gameExchangeID = session; current.gameExchangePeerID = peerID
        } else {
            current.gameExchangeID = nil; current.gameExchangePeerID = nil
        }
        current.stage = .replacementApplied
        current.replacementSHA256 = LocalSwapOriginal.digest(incoming); current.replacementArtworkRevision = nextRevision
        current.cooldownUntil = now.addingTimeInterval(60)
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        guard let checked = try load(), checked.transactionID == current.transactionID,
              checked.replacementArtworkRevision == nextRevision, checked.replacementSHA256 == current.replacementSHA256,
              checked.gameExchangeID == current.gameExchangeID, checked.gameExchangePeerID == current.gameExchangePeerID,
              checked.gamePeerIDs == current.gamePeerIDs else {
            throw BackpackError.invalid("Game staging read-back failed; first original retained, do not apply.")
        }
        return checked
    }
    func stageSoloReplacement(ownerScope: String, expectedRevision: UUID, nextRevision: UUID,
        incoming: Data, now: Date) throws -> LocalSwapOriginal {
        guard var current = try load(), current.peerPurpose == "solo-v1",
              [.prepared, .replacementApplied].contains(current.stage) else {
            throw BackpackError.invalid("A known SOLO durable original is required; another purpose cannot be adopted.")
        }
        try current.validate(installation: installation(), ownerScope: ownerScope, target: .phone)
        let expected = current.stage == .prepared ? current.sourceArtworkRevision : current.replacementArtworkRevision
        guard expected == expectedRevision else { throw BackpackError.invalid("Phone selection changed. Restore/review the first original; no overwrite.") }
        if let until = current.cooldownUntil, now < until { throw BackpackError.invalid("SOLO scene cooldown active; original retained.") }
        _ = try GIFPreviewDecoder.phoneDisplay(incoming)
        current.stage = .replacementApplied; current.replacementArtworkRevision = nextRevision
        current.replacementSHA256 = LocalSwapOriginal.digest(incoming)
        current.cooldownUntil = now.addingTimeInterval(10)
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        guard let checked = try load(), checked.transactionID == current.transactionID,
              checked.replacementArtworkRevision == nextRevision,
              checked.replacementSHA256 == current.replacementSHA256 else {
            throw BackpackError.invalid("SOLO replacement staging was not durably confirmed. Do not apply; original retained.")
        }
        return checked
    }
    func stagePhoneSession(purpose: String, ownerScope: String, expectedRevision: UUID,
        nextRevision: UUID, bytes: Data) throws -> LocalSwapOriginal {
        guard var current = try load(), current.peerPurpose == purpose, purpose.hasPrefix("phone-session-v1:"),
              [.prepared,.replacementApplied].contains(current.stage) else { throw BackpackError.invalid("Known purpose-bound durable PHONE original required.") }
        try current.validate(installation: installation(), ownerScope: ownerScope, target: .phone)
        let expected = current.stage == .prepared ? current.sourceArtworkRevision : current.replacementArtworkRevision
        guard expected == expectedRevision, nextRevision != expectedRevision else { throw BackpackError.invalid("A newer PHONE selection cannot be adopted by automatic playback.") }
        _ = try GIFPreviewDecoder.phoneDisplay(bytes)
        current.stage = .replacementApplied; current.replacementArtworkRevision = nextRevision
        current.replacementSHA256 = LocalSwapOriginal.digest(bytes)
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        guard let checked = try load(), checked.transactionID == current.transactionID,
              checked.replacementArtworkRevision == nextRevision, checked.replacementSHA256 == current.replacementSHA256 else {
            throw BackpackError.invalid("Automatic PHONE staging read-back failed; original retained, do not apply.")
        }
        return checked
    }
    func cancelReadiness(id: UUID, ownerScope: String) throws -> LocalSwapOriginal {
        guard var current = try load(), current.transactionID == id, current.ownerScope == ownerScope,
              current.stage != .restored else { throw BackpackError.invalid("Current active local recovery transaction is unavailable.") }
        current.stage = .recoveryRequired
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        return current
    }
    func acknowledgeRestore(id: UUID, originalSHA256: String, ownerScope: String) throws -> LocalSwapOriginal {
        guard var current = try load(), current.transactionID == id, current.stage == .restoring,
              current.originalSHA256 == originalSHA256, current.ownerScope == ownerScope else {
            throw BackpackError.invalid("Restore acknowledgment does not match the saved original. Journal retained.")
        }
        current.stage = .restored; current.acknowledgementSHA256 = originalSHA256
        current.cooldownUntil = Date().addingTimeInterval(60)
        try encode(current).write(to: journalURL, options: [.atomic, .completeFileProtection])
        return current
    }
    func received() throws -> [ReceivedSwapArtwork] {
        let directory = root.appendingPathComponent("received", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        guard files.count <= 20 else { throw BackpackError.invalid("Received collection exceeds its 20-record bound; nothing was cleared.") }
        var results: [ReceivedSwapArtwork] = [], cost = 0
        for file in files {
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw BackpackError.invalid("Unknown received collection file; no peer path is followed.") }
            let value = try decode(ReceivedSwapArtwork.self, url: file)
            guard value.id == id else { throw BackpackError.invalid("Received record identity mismatch.") }
            try value.validate(); cost += value.data.count
            guard cost <= 50_000_000 else { throw BackpackError.invalid("Received originals exceed 50 MB.") }
            results.append(value)
        }
        return results.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func retainReceived(data: Data, transactionID: UUID, name: String, attribution: Attribution?, verifiedGame: Bool = false) throws -> ReceivedSwapArtwork {
        let value = ReceivedSwapArtwork(schema: 1, id: UUID(), transactionID: transactionID, data: data,
            sha256: LocalSwapOriginal.digest(data), name: String(name.prefix(160)), attribution: attribution, transportVerified: verifiedGame)
        try value.validate()
        let existing = try received()
        if let receipt = existing.first(where: { $0.transactionID == transactionID }) {
            guard receipt.sha256 == value.sha256, receipt.attribution == attribution else { throw BackpackError.invalid("Local transaction receipt conflicts; no content-based global deduplication.") }
            return receipt
        }
        return try persistReceived(value, existing: existing)
    }
    func retainConfirmedGame(data: Data, attribution: Attribution?, sender: LocalMetFriend,
        receipt: PhoneSwapApplicationReceipt, ownerScope: String) throws -> ReceivedSwapArtwork {
        try receipt.validate(data: data, peer: sender)
        let value = ReceivedSwapArtwork(schema: 1, id: UUID(), transactionID: receipt.exchangeID, data: data,
            sha256: LocalSwapOriginal.digest(data), name: "Received peer GIF", attribution: attribution,
            transportVerified: true, sender: sender, ownerScope: ownerScope, bilateralConfirmed: true,
            sentSHA256: receipt.outgoingHash)
        try value.validate()
        let existing = try received()
        if let current = existing.first(where: { $0.transactionID == receipt.exchangeID }) {
            guard current.isFoundUser(ownerScope: ownerScope), current.sender == sender,
                  current.sha256 == value.sha256, current.attribution == attribution,
                  current.sentSHA256 == receipt.outgoingHash else {
                throw BackpackError.invalid("Confirmed exchange receipt conflicts with the retained GIF/sender; no Found success.")
            }
            return current
        }
        guard let journal = try load(), journal.ownerScope == ownerScope, journal.peerPurpose == "game-v1",
              journal.stage == .replacementApplied, journal.gameExchangeID == receipt.exchangeID,
              journal.gameExchangePeerID == sender.id, journal.replacementSHA256 == value.sha256 else {
            throw BackpackError.invalid("Confirmed receipts do not match the staged game, peer, bytes and first-original recovery.")
        }
        return try persistReceived(value, existing: existing)
    }
    private func persistReceived(_ value: ReceivedSwapArtwork, existing: [ReceivedSwapArtwork]) throws -> ReceivedSwapArtwork {
        try checkReceivedCapacity(data: value.data, existing: existing)
        let folder = root.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        try Task.checkCancellation()
        try encode(value).write(to: folder.appendingPathComponent(value.id.uuidString.lowercased() + ".json"), options: [.atomic, .completeFileProtection])
        guard let checked = try received().first(where: { $0.id == value.id }),
              checked.sha256 == value.sha256, checked.sender == value.sender,
              checked.ownerScope == value.ownerScope, checked.bilateralConfirmed == value.bilateralConfirmed,
              checked.sentSHA256 == value.sentSHA256 else {
            throw BackpackError.invalid("Received GIF/card write was not durably confirmed; no Found success.")
        }
        return checked
    }
    func ensureReceivedCapacity(for data: Data) throws {
        try checkReceivedCapacity(data: data, existing: received())
    }
    private func checkReceivedCapacity(data: Data, existing: [ReceivedSwapArtwork]) throws {
        guard existing.count < 20, existing.reduce(data.count, { $0 + $1.data.count }) <= 50_000_000 else {
            throw BackpackError.invalid("Received collection is full (20 originals / 50 MB). Remove copies explicitly.")
        }
    }
    func removeReceived(_ id: UUID) throws {
        guard try received().contains(where: { $0.id == id }) else { throw BackpackError.invalid("Received record no longer exists.") }
        try FileManager.default.removeItem(at: root.appendingPathComponent("received").appendingPathComponent(id.uuidString.lowercased() + ".json"))
    }
}
