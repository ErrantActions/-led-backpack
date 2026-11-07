import Foundation
import CryptoKit
import BackpackProtocol

struct NativeFriendPeerIdentity: Decodable {
    let sessionId: UUID
    let sessionRevision, identityRevision: Int
    let ownPublicKey, peerPublicKey, ownTokenHash, peerTokenHash: String?
    let ownTokenExpiresAtISO, peerTokenExpiresAtISO: String?
    let expiresAtISO, serverTimeISO: String
    let ownedByCurrentSession, coordinatesIncluded, physicalProximityVerified, playbackStarted, historyStored: Bool
    var advertisementToken: String? = nil
    static func tokenHash(_ token: String) -> String { LocalSwapOriginal.digest(Data(token.utf8)) }
    func validate(session: NativeFriendSession) throws {
        guard sessionId == session.id, sessionRevision == session.revision, identityRevision >= 0,
              expiresAtISO == session.expiresAtISO, ownedByCurrentSession,
              !coordinatesIncluded, !physicalProximityVerified, !playbackStarted, !historyStored else {
            throw BackpackError.invalid("Accepted friend identity/role/login/session binding changed.")
        }
        let now = try CatalogEventTime.parse(serverTimeISO), end = try CatalogEventTime.parse(expiresAtISO)
        guard end > now else { throw BackpackError.invalid("Friend session expired; no scene or renewal.") }
        for key in [ownPublicKey, peerPublicKey].compactMap({ $0 }) {
            guard try PhoneSwapWire.bytes(key).contains(where: { $0 != 0 }) else { throw BackpackError.invalid("Invalid bound peer public key.") }
        }
        for hash in [ownTokenHash, peerTokenHash].compactMap({ $0 }) {
            guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw BackpackError.invalid("Invalid UTF8-token SHA256 binding.") }
        }
        for raw in [ownTokenExpiresAtISO, peerTokenExpiresAtISO].compactMap({ $0 }) {
            let deadline = try CatalogEventTime.parse(raw)
            guard deadline <= end, deadline > now, deadline.timeIntervalSince(now) <= 120 else { throw BackpackError.invalid("Friend peer hint expiry is invalid.") }
        }
        guard (ownTokenHash == nil) == (ownTokenExpiresAtISO == nil), (peerTokenHash == nil) == (peerTokenExpiresAtISO == nil),
              ownTokenHash == nil || ownPublicKey != nil, peerTokenHash == nil || peerPublicKey != nil else {
            throw BackpackError.invalid("Incomplete live friend hint/key/expiry binding.")
        }
        if let advertisementToken {
            guard NearbyTokenPolicy.valid(advertisementToken), Self.tokenHash(advertisementToken) == ownTokenHash else { throw BackpackError.invalid("Own raw hint does not match server UTF8-string hash.") }
        }
    }
}
@MainActor
extension CommunityFeatureClient {
    func currentAcceptedFriendSession(_ selected: NativeFriendSession) async throws -> NativeFriendSession {
        let list = try await friendSessions()
        guard let current = list.sessions.first(where: { $0.id == selected.id }),
              current.revision == selected.revision, current.peer.id == selected.peer.id,
              current.kind == selected.kind, current.expiresAtISO == selected.expiresAtISO,
              current.direction == selected.direction, current.status == "active", current.ownedByCurrentSession else {
            throw BackpackError.invalid("Friend session must be active, mutually permitted and owned by the original start/accept login. Reload rather than replay.")
        }
        return current
    }
    func friendPeerIdentity(_ selected: NativeFriendSession, publish: String? = nil) async throws -> NativeFriendPeerIdentity {
        guard friendPeerIdentityAvailable else { throw BackpackError.invalid("Accepted-friend peer-key preparation unavailable; game/discovery cannot substitute.") }
        let current = try await currentAcceptedFriendSession(selected)
        let path = "social/friend-sessions/\(current.id.uuidString.lowercased())/peer-identity"
        let bytes: Data
        if let publish {
            guard try PhoneSwapWire.bytes(publish).contains(where: { $0 != 0 }) else { throw BackpackError.invalid("Invalid local friend ephemeral key.") }
            struct Body: Encodable { let expectedRevision: Int; let publicKey: String; let consent = true }
            bytes = try await send(.social, path, method: "POST", body: JSONEncoder().encode(Body(expectedRevision: current.revision, publicKey: publish)))
        } else {
            bytes = try await send(.social, path, query: [.init(name: "expectedRevision", value: String(current.revision))])
        }
        let value = try JSONDecoder().decode(NativeFriendPeerIdentity.self, from: bytes)
        guard friendPeerIdentityAvailable else { throw BackpackError.invalid("Friend peer-key capability changed.") }
        try value.validate(session: current)
        if let publish {
            guard value.ownPublicKey == publish, value.advertisementToken != nil else { throw BackpackError.invalid("Own immutable friend key/hint publication was not confirmed.") }
        } else if value.advertisementToken != nil { throw BackpackError.invalid("Read-only friend identity must not return a raw advertisement token.") }
        return value
    }
}
enum FriendScenePreset: String, Codable, CaseIterable, Identifiable {
    case aurora = "aurora-soft", sunset = "sunset-soft"
    var id: String { rawValue }
    var colors: ([UInt8], [UInt8]) {
        self == .aurora ? ([80,210,180],[150,120,220]) : ([235,140,100],[180,100,170])
    }
}
struct FriendClockEstimate: Equatable {
    let offset, roundTrip, uncertainty: Double
    init(t0: Double, t1: Double, t2: Double, t3: Double) throws {
        guard [t0,t1,t2,t3].allSatisfy({ $0.isFinite && $0 >= 0 }), t3 >= t0, t2 >= t1 else {
            throw BackpackError.invalid("Invalid authenticated monotonic clock sample.")
        }
        let rtt = (t3 - t0) - (t2 - t1)
        guard rtt >= 0, rtt <= 0.6 else { throw BackpackError.invalid("Timing quality too poor for this shared start. Manual preview remains available; no verified sync claim.") }
        let delta = ((t1 - t0) + (t2 - t3)) / 2
        guard delta.isFinite else { throw BackpackError.invalid("Peer monotonic translation overflowed.") }
        roundTrip = rtt; uncertainty = rtt / 2 + 0.05; offset = delta
    }
}
enum FriendInteractionPixels {
    static func render(kind: FriendInteractionKind, preset: FriendScenePreset, sender: Bool, chosen: Data, received: Data?) throws -> Data {
        switch kind {
        case .greeting: return chosen
        case .palette, .duet:
            return try MediaCodec.encode(frames(kind: kind, preset: preset, sender: sender), delays: Array(repeating: 0.1, count: 24), loopCount: 0)
        case .pass:
            if sender { return try PrivateOutgoingGIF.inspectAlreadySanitized(PrivateOutgoingGIF.make(chosen)) }
            guard let received else { throw BackpackError.invalid("Remote pass artwork is not available in a manual/offline preview.") }
            return try PrivateOutgoingGIF.inspectAlreadySanitized(received)
        }
    }
    static func frames(kind: FriendInteractionKind, preset: FriendScenePreset, sender: Bool) -> [PixelFrame] {
        let size = PanelSize(width: 16, height: 16), colors = preset.colors
        return (0..<24).map { frame in
            var result = PixelFrame.black(size)
            for y in 0..<16 {
                for x in 0..<16 {
                    let globalX = sender ? x : x + 16
                    let phase = Double(frame) / 24 * .pi * 2
                    let pulse = 0.5 + 0.5 * sin(phase + Double(kind == .duet ? globalX : x) * 0.16)
                    let color = (0..<3).map { c in UInt8((Double(colors.0[c]) * pulse + Double(colors.1[c]) * (1 - pulse)).rounded()) }
                    let paint = kind == .duet ? (abs(globalX - (8 + frame % 16)) + abs(y - 8) < 9) : true
                    if paint { result.rgb.replaceSubrange((y * 16 + x) * 3..<(y * 16 + x) * 3 + 3, with: color) }
                }
            }
            result.exactLiveColors = true; return result
        }
    }
}
@MainActor
final class AcceptedFriendAuthority {
    let selected: NativeFriendSession
    let preset: FriendScenePreset
    let consentEpoch: UUID
    let chosenArtwork: Data
    let chosenAttribution: Attribution?
    let phonePolicy: UUID
    let initialRevision: UUID
    let ownerAccount: UUID
    let mainSender: Bool
    private(set) var identity: NativeFriendPeerIdentity?
    private var retainedKey: Curve25519.KeyAgreement.PrivateKey?
    private var generation = UUID()
    private var cancelled = false
    init(session: NativeFriendSession, preset: FriendScenePreset, consent: Bool,
        phone: PhoneDisplayController, account: UUID, attribution: Attribution?, artwork: FriendArtworkChoice? = nil) throws {
        guard consent, session.status == "active", session.ownedByCurrentSession, let data = phone.data else {
            throw BackpackError.invalid("Choose actual local phone art and explicitly arm this accepted-session/media intent. Old control acceptance is not media consent.")
        }
        let sender = session.direction == "outgoing"
        let usesArtwork = session.kind == .greeting || (session.kind == .pass && sender)
        selected = session; self.preset = preset; consentEpoch = UUID()
        chosenArtwork = usesArtwork ? artwork?.data ?? data : data
        chosenAttribution = usesArtwork ? (artwork == nil ? attribution : artwork?.attribution) : nil
        phonePolicy = phone.playbackPolicyRevision; initialRevision = phone.artworkRevision
        ownerAccount = account; mainSender = sender
        if session.kind == .pass && sender { _ = try PhoneSwapWire.Credit(chosenAttribution) }
    }
    func key() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard !cancelled else { throw BackpackError.invalid("Stopped friend key cannot resume; create a fresh accepted session.") }
        if let retainedKey { return retainedKey }
        let next = Curve25519.KeyAgreement.PrivateKey(); retainedKey = next; return next
    }
    func eraseKey() { cancelled = true; generation = UUID(); retainedKey = nil; identity = nil }
    func prepare(_ client: CommunityFeatureClient, publicKey: String) async throws -> PhoneSwapPresence {
        let stamp = generation
        guard !cancelled else { throw CancellationError() }
        let value = try await client.friendPeerIdentity(selected, publish: publicKey)
        guard stamp == generation, !cancelled else { throw CancellationError() }
        identity = value
        return presence(value)
    }
    func current(_ client: CommunityFeatureClient) async throws -> PhoneSwapPresence {
        let stamp = generation
        guard !cancelled else { throw CancellationError() }
        let value = try await client.friendPeerIdentity(selected)
        guard stamp == generation, !cancelled else { throw CancellationError() }
        if let identity {
            guard value.ownPublicKey == identity.ownPublicKey, value.expiresAtISO == identity.expiresAtISO,
                  value.ownTokenHash == identity.ownTokenHash else { throw BackpackError.invalid("Intended friend/session/hint changed; re-arm explicitly.") }
        }
        identity = value; return presence(value)
    }
    private func presence(_ value: NativeFriendPeerIdentity) -> PhoneSwapPresence {
        PhoneSwapPresence(presenceId: value.sessionId, enabled: true, ownedByCurrentSession: value.ownedByCurrentSession,
            publicKey: value.ownPublicKey, expiresAtISO: value.expiresAtISO, tokenExpiresAtISO: value.ownTokenExpiresAtISO,
            locationControlsRevision: 0, serverTimeISO: value.serverTimeISO, gpsUsed: false,
            encounterHistoryStored: false, physicalProximityVerified: false, backgroundDiscoveryVerified: false,
            advertisementToken: value.advertisementToken)
    }
    func resolve(_ token: String, client: CommunityFeatureClient) async throws -> PhoneSwapContact? {
        let stamp = generation
        guard !cancelled else { throw CancellationError() }
        let value = try await client.friendPeerIdentity(selected)
        guard stamp == generation, !cancelled else { throw CancellationError() }
        if let identity, identity.ownPublicKey != nil {
            guard identity.ownPublicKey == value.ownPublicKey, identity.ownTokenHash == value.ownTokenHash else {
                throw BackpackError.invalid("Own immutable friend key/hint changed; do not adopt another intent.")
            }
        }
        identity = value
        guard NativeFriendPeerIdentity.tokenHash(token) == value.peerTokenHash,
              let key = value.peerPublicKey, let expiry = value.peerTokenExpiresAtISO else { return nil }
        return PhoneSwapContact(id: selected.peer.id, displayName: selected.peer.displayName, canRequestFriendship: false,
            publicKey: key, token: token, tokenExpiresAtISO: expiry)
    }
    func binding() throws -> [String] {
        guard let identity else { throw BackpackError.invalid("Accepted friend binding unavailable.") }
        guard identity.ownPublicKey != nil, identity.peerPublicKey != nil, identity.ownTokenHash != nil, identity.peerTokenHash != nil else {
            throw BackpackError.invalid("Both current accepted-session participants must publish a live key/hint first.")
        }
        return [selected.id.uuidString.lowercased(), String(selected.revision), String(identity.identityRevision),
            selected.kind.rawValue, preset.rawValue, selected.expiresAtISO,
            (mainSender ? ownerAccount : selected.peer.id).uuidString.lowercased(),
            (mainSender ? selected.peer.id : ownerAccount).uuidString.lowercased()]
    }
    func agreement() -> PhoneSwapWire.Message {
        PhoneSwapWire.Message(kind: "friend-agreement", interaction: selected.kind.rawValue, preset: preset.rawValue,
            role: mainSender ? "session-sender" : "session-recipient", mediaConsent: true)
    }
    func checkAgreement(_ value: PhoneSwapWire.Message) throws {
        guard value.interaction == selected.kind.rawValue, value.preset == preset.rawValue, value.mediaConsent == true,
              value.role == (mainSender ? "session-recipient" : "session-sender") else {
            throw BackpackError.invalid("Both friends must explicitly arm the same kind/preset and complementary session roles; no media is sent from a control-only acceptance.")
        }
    }
    nonisolated static var controlMarker: Data {
        Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,0,0,0,255,255,255,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
    }
    func validatePayloadIntent(_ bytes: Data) throws {
        if selected.kind != .pass || mainSender {
            guard bytes == Self.controlMarker else { throw BackpackError.invalid("This role consented only to a control marker, not a received artwork transfer.") }
        }
    }
}
