import Foundation
import BackpackProtocol

enum FriendInteractionKind: String, Codable, CaseIterable, Identifiable {
    case greeting, palette = "shared-palette", pass = "pass-animation", duet
    var id: String { rawValue }
}
struct NativeFriendSession: Decodable, Identifiable {
    let id: UUID
    let revision, durationSeconds: Int
    let kind: FriendInteractionKind
    let direction, status, expiresAtISO, serverTimeISO: String
    let peer: SocialPerson
    let ownedByCurrentSession, coordinatesIncluded, physicalProximityVerified, playbackStarted: Bool
    let automaticGifExchangeEnabled, clockSynchronizationVerified, historyStored: Bool
    func validate() throws {
        guard revision > 0, (60...900).contains(durationSeconds), ["incoming","outgoing"].contains(direction),
              ["pending","active"].contains(status), !coordinatesIncluded, !physicalProximityVerified,
              !playbackStarted, !automaticGifExchangeEnabled, !clockSynchronizationVerified, !historyStored else {
            throw BackpackError.invalid("Unsupported friend control-session contract; no physical interaction is inferred.")
        }
        _ = try CatalogEventTime.parse(expiresAtISO); _ = try CatalogEventTime.parse(serverTimeISO)
    }
}
struct NativeFriendSessions: Decodable {
    let sessions: [NativeFriendSession]
    let serverTimeISO: String
    let historyStored: Bool
}
struct FriendSessionIntent {
    let peerID, clientID: UUID
    let data: Data
    init(peer: SocialPerson, kind: FriendInteractionKind, seconds: Int, consent: Bool, clientID: UUID = UUID()) throws {
        guard consent, peer.locationFeaturesAllowed == true, peer.mutualLocationFeaturesAllowed == true,
              (60...900).contains(seconds) else { throw BackpackError.invalid("Mutual independent permissions, explicit session consent and 60–900 seconds are required.") }
        struct Body: Encodable { let peerId, clientSessionId: String; let kind: FriendInteractionKind; let durationSeconds: Int; let consent = true }
        peerID = peer.id; self.clientID = clientID
        data = try JSONEncoder().encode(Body(peerId: peer.id.uuidString.lowercased(), clientSessionId: clientID.uuidString.lowercased(), kind: kind, durationSeconds: seconds))
    }
}
@MainActor
extension CommunityFeatureClient {
    func locationCapabilities() async throws -> SocialPreferences {
        let value = try await preferences()
        guard communityLocationSessionsAvailable, value.friendSessionsAvailable == true else { throw BackpackError.invalid("Friend control sessions are unavailable on this service.") }
        return value
    }
    func friendSessions() async throws -> NativeFriendSessions {
        _ = try await locationCapabilities()
        let value = try JSONDecoder().decode(NativeFriendSessions.self, from: await send(.social, "social/friend-sessions"))
        guard communityLocationSessionsAvailable, !value.historyStored, value.sessions.count <= 10, Set(value.sessions.map(\.id)).count == value.sessions.count else { throw BackpackError.invalid("Invalid or withdrawn volatile session list.") }
        _ = try CatalogEventTime.parse(value.serverTimeISO)
        for session in value.sessions { try session.validate() }
        return value
    }
    func inviteFriendSession(_ intent: FriendSessionIntent) async throws -> NativeFriendSession {
        _ = try await locationCapabilities()
        struct Receipt: Decodable { let session: NativeFriendSession; let created: Bool }
        let value = try JSONDecoder().decode(Receipt.self, from: await send(.social, "social/friend-sessions", method: "POST", body: intent.data)).session
        try value.validate()
        guard communityLocationSessionsAvailable, value.peer.id == intent.peerID, value.direction == "outgoing", value.ownedByCurrentSession else { throw BackpackError.invalid("Captured friend session was not confirmed.") }
        return value
    }
    func respondFriendSession(_ value: NativeFriendSession, accept: Bool) async throws {
        _ = try await locationCapabilities(); try value.validate()
        guard value.direction == "incoming", value.status == "pending" else { throw BackpackError.invalid("Select a current incoming pending invitation.") }
        struct Body: Encodable { let expectedRevision: Int; let accept: Bool }
        let data = try await send(.social, "social/friend-sessions/\(value.id.uuidString.lowercased())/respond",
            method: "POST", body: JSONEncoder().encode(Body(expectedRevision: value.revision, accept: accept)))
        if accept {
            struct Receipt: Decodable { let session: NativeFriendSession }
            let result = try JSONDecoder().decode(Receipt.self, from: data).session
            try result.validate()
            guard result.id == value.id, result.status == "active", result.ownedByCurrentSession,
                  result.expiresAtISO == value.expiresAtISO else { throw BackpackError.invalid("Acceptance did not preserve the captured session deadline.") }
        } else {
            struct Receipt: Decodable { let declined, playbackStarted: Bool }
            let result = try JSONDecoder().decode(Receipt.self, from: data)
            guard result.declined, !result.playbackStarted else { throw BackpackError.invalid("Session decline was not confirmed.") }
        }
    }
    func stopFriendSession(_ value: NativeFriendSession) async throws {
        struct Body: Encodable { let expectedRevision: Int }
        struct Receipt: Decodable { let stopped, localPlaybackRestoredByBackend: Bool }
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.social,
            "social/friend-sessions/\(value.id.uuidString.lowercased())", method: "DELETE", body: JSONEncoder().encode(Body(expectedRevision: value.revision))))
        guard result.stopped, !result.localPlaybackRestoredByBackend else { throw BackpackError.invalid("Service session stop was not confirmed.") }
    }
    func stopAllServiceLocation() async throws -> Int? {
        let profile = try await preferences()
        if communityGlobalLocationStopAvailable && profile.socialLocationGlobalStopEnabled == true {
            struct Receipt: Decodable { let stopped: Bool; let locationControlsRevision: Int; let localSensorsStoppedByBackend, hardwarePlaybackRestoredByBackend: Bool }
            let value = try JSONDecoder().decode(Receipt.self, from: await send(.social, "social/location-permissions",
                method: "DELETE", body: Data(#"{"stopAll":true}"#.utf8)))
            guard value.stopped, value.locationControlsRevision >= 0, !value.localSensorsStoppedByBackend, !value.hardwarePlaybackRestoredByBackend else { throw BackpackError.invalid("Global service revocation was not confirmed.") }
            return value.locationControlsRevision
        }
        guard communityLocationSessionsAvailable, profile.friendSessionsAvailable == true else { throw BackpackError.invalid("Service revocation unavailable. Local sensing is stopped; remote stop is unconfirmed.") }
        struct Receipt: Decodable { let stopped, localPlaybackRestoredByBackend: Bool }
        let value = try JSONDecoder().decode(Receipt.self, from: await send(.social, "social/friend-sessions", method: "DELETE", body: Data(#"{"stopAll":true}"#.utf8)))
        guard value.stopped, !value.localPlaybackRestoredByBackend else { throw BackpackError.invalid("Service session stop-all was not confirmed.") }
        return nil
    }
}
