import Foundation
import BackpackProtocol

struct PhoneSwapPresence: Decodable {
    let presenceId: UUID?
    let enabled, ownedByCurrentSession: Bool
    let publicKey, expiresAtISO, tokenExpiresAtISO: String?
    let locationControlsRevision: Int
    let serverTimeISO: String
    let gpsUsed, encounterHistoryStored, physicalProximityVerified, backgroundDiscoveryVerified: Bool
    var advertisementToken: String? = nil
    func validate(requireToken: Bool) throws {
        let now = try CatalogEventTime.parse(serverTimeISO)
        guard locationControlsRevision >= 0, !gpsUsed, !encounterHistoryStored, !physicalProximityVerified, !backgroundDiscoveryVerified else { throw BackpackError.invalid("Unsupported game-consent privacy/stop contract.") }
        if enabled {
            guard presenceId != nil, let publicKey, NearbyTokenPolicy.valid(publicKey),
                  try PhoneSwapWire.bytes(publicKey).contains(where: { $0 != 0 }),
                  let expiresAtISO, try CatalogEventTime.parse(expiresAtISO) > now,
                  try CatalogEventTime.parse(expiresAtISO).timeIntervalSince(now) <= 930 else { throw BackpackError.invalid("Invalid game key/presence expiry.") }
            if requireToken {
                guard ownedByCurrentSession, let advertisementToken, NearbyTokenPolicy.valid(advertisementToken),
                      let tokenExpiresAtISO else { throw BackpackError.invalid("Game token/key ownership was not confirmed.") }
                let end = try CatalogEventTime.parse(tokenExpiresAtISO)
                guard end > now, end <= (try CatalogEventTime.parse(expiresAtISO)), end.timeIntervalSince(now) <= 120 else { throw BackpackError.invalid("Invalid game-token lifetime.") }
            }
        } else {
            guard presenceId == nil, publicKey == nil, advertisementToken == nil else { throw BackpackError.invalid("Stopped game still returned key/token state.") }
        }
    }
}
struct PhoneSwapContact: Decodable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let canRequestFriendship: Bool
    let publicKey, token, tokenExpiresAtISO: String
    func validate() throws {
        guard (1...80).contains(displayName.utf16.count), NearbyTokenPolicy.valid(publicKey), NearbyTokenPolicy.valid(token) else {
            throw BackpackError.invalid("Invalid purpose-bound minimal game card.")
        }
        guard try PhoneSwapWire.bytes(publicKey).contains(where: { $0 != 0 }) else { throw BackpackError.invalid("Invalid zero game public key.") }
        _ = try CatalogEventTime.parse(tokenExpiresAtISO)
    }
}
@MainActor
extension CommunityFeatureClient {
    func gamePresence() async throws -> PhoneSwapPresence {
        guard phoneSwapAvailable else { throw BackpackError.invalid("GIF-swap game is not enabled by this service.") }
        let value = try JSONDecoder().decode(PhoneSwapPresence.self, from: await send(.social, "social/swap-presence"))
        try value.validate(requireToken: false); return value
    }
    func enableGame(expected: UUID?, controls: Int, key: String) async throws -> PhoneSwapPresence {
        guard phoneSwapAvailable, controls >= 0, NearbyTokenPolicy.valid(key) else { throw BackpackError.invalid("Current game key/stop revision is required.") }
        var body: [String: Any] = ["expectedControlsRevision": controls, "publicKey": key, "consent": true, "durationSeconds": 300]
        if let expected { body["expectedPresenceId"] = expected.uuidString.lowercased() }
        else { body["expectedPresenceId"] = NSNull() }
        let value = try JSONDecoder().decode(PhoneSwapPresence.self, from: await send(.social, "social/swap-presence",
            method: "POST", body: JSONSerialization.data(withJSONObject: body)))
        try value.validate(requireToken: true)
        guard phoneSwapAvailable, value.enabled, value.ownedByCurrentSession, value.publicKey == key,
              value.locationControlsRevision == controls else { throw BackpackError.invalid("Purpose-separated game consent/key was not confirmed.") }
        return value
    }
    func rotateGame(_ id: UUID) async throws -> PhoneSwapPresence {
        struct Body: Encodable { let expectedPresenceId: String }
        let value = try JSONDecoder().decode(PhoneSwapPresence.self, from: await send(.social, "social/swap-presence/rotate",
            method: "POST", body: JSONEncoder().encode(Body(expectedPresenceId: id.uuidString.lowercased()))))
        try value.validate(requireToken: true); return value
    }
    func stopGame(_ id: UUID) async throws {
        struct Body: Encodable { let expectedPresenceId: String }
        let value = try JSONDecoder().decode(PhoneSwapPresence.self, from: await send(.social, "social/swap-presence",
            method: "DELETE", body: JSONEncoder().encode(Body(expectedPresenceId: id.uuidString.lowercased()))))
        try value.validate(requireToken: false)
        guard !value.enabled else { throw BackpackError.invalid("Game withdrawal was not confirmed; local exchange stays stopped.") }
    }
    func resolveGame(_ id: UUID, observed: [String]) async throws -> [PhoneSwapContact] {
        guard phoneSwapAvailable, (1...32).contains(observed.count), Set(observed).count == observed.count,
              observed.allSatisfy(NearbyTokenPolicy.valid) else { throw BackpackError.invalid("Resolve only current locally observed GAME tokens.") }
        struct Body: Encodable { let expectedPresenceId: String; let tokens: [String] }
        struct Result: Decodable {
            let contacts: [PhoneSwapContact]
            let distanceOrdering, friendshipCreated, physicalProximityVerified, gpsUsed, encounterHistoryStored: Bool
        }
        let value = try JSONDecoder().decode(Result.self, from: await send(.social, "social/swap-presence/resolve", method: "POST",
            body: JSONEncoder().encode(Body(expectedPresenceId: id.uuidString.lowercased(), tokens: observed))))
        guard phoneSwapAvailable, value.contacts.count <= observed.count, !value.distanceOrdering, !value.friendshipCreated,
              Set(value.contacts.map(\.id)).count == value.contacts.count,
              !value.physicalProximityVerified, !value.gpsUsed, !value.encounterHistoryStored else { throw BackpackError.invalid("Unsupported game identity/proximity grant.") }
        for card in value.contacts {
            try card.validate()
            guard card.id != accountID, observed.contains(card.token) else { throw BackpackError.invalid("Game card does not match an observed purpose-bound token.") }
        }
        return value.contacts
    }
}
