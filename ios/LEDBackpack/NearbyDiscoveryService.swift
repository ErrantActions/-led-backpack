import Foundation
import BackpackProtocol

struct NativeNearbyState: Decodable {
    let presenceId: UUID?
    let lookForFriends, discoverable, ownedByCurrentSession: Bool
    let expiresAtISO, tokenExpiresAtISO: String?
    let serverTimeISO: String
    let gpsUsed, encounterHistoryStored, physicalProximityVerified, backgroundDiscoveryVerified: Bool
    var advertisementToken: String? = nil
    var locationControlsRevision: Int? = nil
    func validate(requireToken: Bool) throws {
        let now = try CatalogEventTime.parse(serverTimeISO)
        guard !gpsUsed, !encounterHistoryStored, !physicalProximityVerified, !backgroundDiscoveryVerified else {
            throw BackpackError.invalid("Unsupported discovery privacy/proximity contract.")
        }
        if presenceId != nil {
            guard lookForFriends || discoverable else { throw BackpackError.invalid("Presence has no explicitly enabled control.") }
            guard let expiresAtISO, try CatalogEventTime.parse(expiresAtISO) > now,
                  try CatalogEventTime.parse(expiresAtISO).timeIntervalSince(now) <= 930 else {
                throw BackpackError.invalid("Discovery presence expired or has an invalid lifetime.")
            }
        } else {
            guard !lookForFriends, !discoverable, expiresAtISO == nil, tokenExpiresAtISO == nil, advertisementToken == nil else {
                throw BackpackError.invalid("Stopped discovery cannot retain controls, token or deadlines.")
            }
        }
        if requireToken && discoverable {
            guard ownedByCurrentSession, let advertisementToken, NearbyTokenPolicy.valid(advertisementToken),
                  let tokenExpiresAtISO, let expiresAtISO else { throw BackpackError.invalid("Current discoverable token is missing; nothing may be advertised.") }
            let deadline = try CatalogEventTime.parse(tokenExpiresAtISO)
            guard deadline > now, deadline <= (try CatalogEventTime.parse(expiresAtISO)),
                  deadline.timeIntervalSince(now) <= 120 else { throw BackpackError.invalid("Discovery token lifetime exceeds the recovered service contract.") }
        } else if !discoverable && advertisementToken != nil {
            throw BackpackError.invalid("Look-only presence must not issue an advertisement token.")
        }
    }
}
enum NearbyTokenPolicy {
    static let service = "8ED0B5CA-7C41-4BB7-93B9-F9600B153CA6"
    static let characteristic = "660FA9E0-AF37-4FAE-985C-85A11798436E"
    static func readValue(_ token: Data?, offset: Int, active: Bool, expired: Bool) throws -> Data {
        guard active, !expired, let token, token.count == 43, offset >= 0, offset <= token.count else {
            throw BackpackError.invalid("Read-only ephemeral token is unavailable or offset is invalid.")
        }
        _ = try decode(token)
        return token.subdata(in: offset..<token.count)
    }
    static func valid(_ token: String) -> Bool {
        guard token.utf8.count == 43,
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=") else { return false }
        return data.count == 32 && data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == token
    }
    static func decode(_ data: Data) throws -> String {
        guard data.count == 43, let token = String(data: data, encoding: .ascii), valid(token) else {
            throw BackpackError.invalid("Invalid ephemeral token characteristic. No name or identifier is accepted.")
        }
        return token
    }
}
struct NearbyTransportGate {
    private(set) var scanning = false
    private(set) var advertising = false
    mutating func arm(look: Bool, discoverable: Bool, foreground: Bool, ready: Bool, consent: Bool) throws {
        stop()
        guard foreground, ready, consent, look || discoverable else { throw BackpackError.invalid("Explicit foreground radio consent/readiness is required.") }
        scanning = look; advertising = discoverable
    }
    mutating func stop() { scanning = false; advertising = false }
}
struct NearbyObservedTokens {
    private var observed: [String: TimeInterval] = [:]
    private var seen: Set<String> = []
    mutating func record(_ token: String, now: TimeInterval) throws {
        guard NearbyTokenPolicy.valid(token), now.isFinite else { throw BackpackError.invalid("Invalid local discovery token/sample time.") }
        observed = observed.filter { now - $0.value <= 15 && now >= $0.value }
        guard !seen.contains(token) else { return }
        guard observed.count < 32, seen.count < 256 else { throw BackpackError.invalid("Local discovery observation/replay bound reached. Stop and explicitly restart if appropriate.") }
        seen.insert(token)
        observed[token] = now
    }
    mutating func fresh(now: TimeInterval) -> [String] {
        observed = observed.filter { (0...15).contains(now - $0.value) }
        return observed.keys.sorted()
    }
    mutating func clear() { observed = [:]; seen = [] }
}
@MainActor
extension CommunityFeatureClient {
    func checkNearby() throws {
        try check(.social)
        guard nearbyDiscoveryAvailable else { throw BackpackError.invalid("Nearby discovery is not enabled by this service.") }
    }
    func ownNearby() async throws -> NativeNearbyState {
        try checkNearby()
        let value = try JSONDecoder().decode(NativeNearbyState.self, from: await send(.social, "social/nearby"))
        try checkNearby(); try value.validate(requireToken: false); return value
    }
    func armNearby(expected: UUID?, look: Bool, discoverable: Bool, expectedControlsRevision: Int? = nil) async throws -> NativeNearbyState {
        try checkNearby()
        guard !nearbyRevisionRequired || (expectedControlsRevision != nil && (expectedControlsRevision ?? -1) >= 0) else {
            throw BackpackError.invalid("Current discovery stop revision must be captured explicitly; reload after Stop all.")
        }
        guard look || discoverable else { throw BackpackError.invalid("Explicitly select Look for friends and/or Let people find me.") }
        struct Body: Encodable {
            let expectedPresenceId: String?
            let lookForFriends, discoverable: Bool
            let expectedControlsRevision: Int?
            let consent = true
            let durationSeconds = 300
            enum CodingKeys: String, CodingKey { case expectedPresenceId, lookForFriends, discoverable, consent, durationSeconds, expectedControlsRevision }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(expectedPresenceId, forKey: .expectedPresenceId)
                try c.encode(lookForFriends, forKey: .lookForFriends); try c.encode(discoverable, forKey: .discoverable)
                try c.encode(consent, forKey: .consent); try c.encode(durationSeconds, forKey: .durationSeconds)
                try c.encodeIfPresent(expectedControlsRevision, forKey: .expectedControlsRevision)
            }
        }
        let value = try JSONDecoder().decode(NativeNearbyState.self, from: await send(.social, "social/nearby", method: "POST",
            body: JSONEncoder().encode(Body(expectedPresenceId: expected?.uuidString.lowercased(), lookForFriends: look, discoverable: discoverable, expectedControlsRevision: expectedControlsRevision))))
        try checkNearby(); try value.validate(requireToken: true)
        guard value.ownedByCurrentSession, value.presenceId != nil, value.lookForFriends == look, value.discoverable == discoverable else {
            throw BackpackError.invalid("Explicit discovery session choices were not confirmed.")
        }
        guard !nearbyRevisionRequired || value.locationControlsRevision == expectedControlsRevision else { throw BackpackError.invalid("Discovery stop revision changed; no local radio may start.") }
        return value
    }
    func rotateNearby(_ presence: UUID) async throws -> NativeNearbyState {
        try checkNearby()
        struct Body: Encodable { let expectedPresenceId: String }
        let value = try JSONDecoder().decode(NativeNearbyState.self, from: await send(.social, "social/nearby/rotate", method: "POST",
            body: JSONEncoder().encode(Body(expectedPresenceId: presence.uuidString.lowercased()))))
        try checkNearby(); try value.validate(requireToken: true)
        guard value.ownedByCurrentSession, value.presenceId != nil, value.presenceId != presence else { throw BackpackError.invalid("Token/capture rotation was not confirmed.") }
        return value
    }
    func withdrawNearby(_ presence: UUID) async throws {
        struct Body: Encodable { let expectedPresenceId: String }
        let value = try JSONDecoder().decode(NativeNearbyState.self, from: await send(.social, "social/nearby", method: "DELETE",
            body: JSONEncoder().encode(Body(expectedPresenceId: presence.uuidString.lowercased()))))
        try value.validate(requireToken: false)
        guard value.presenceId == nil, !value.lookForFriends, !value.discoverable, value.advertisementToken == nil else {
            throw BackpackError.invalid("Presence withdrawal was not confirmed. Radio remains locally stopped.")
        }
    }
    func resolveNearby(_ presence: UUID, tokens: [String]) async throws -> [SocialPerson] {
        try checkNearby()
        guard (1...32).contains(tokens.count), Set(tokens).count == tokens.count, tokens.allSatisfy(NearbyTokenPolicy.valid) else {
            throw BackpackError.invalid("Resolve only bounded distinct locally read ephemeral tokens.")
        }
        struct Body: Encodable { let expectedPresenceId: String; let tokens: [String] }
        struct Result: Decodable {
            let contacts: [SocialPerson]
            let distanceOrdering, friendshipCreated, physicalProximityVerified, gpsUsed, encounterHistoryStored: Bool
        }
        let result = try JSONDecoder().decode(Result.self, from: await send(.social, "social/nearby/resolve", method: "POST",
            body: JSONEncoder().encode(Body(expectedPresenceId: presence.uuidString.lowercased(), tokens: tokens))))
        try checkNearby()
        guard !result.distanceOrdering, !result.friendshipCreated, !result.physicalProximityVerified,
              !result.gpsUsed, !result.encounterHistoryStored, result.contacts.count <= 32,
              Set(result.contacts.map(\.id)).count == result.contacts.count else { throw BackpackError.invalid("Unsupported discovery contact grant or ordering.") }
        for contact in result.contacts {
            try validate(contact)
            guard contact.eventBadges == nil, contact.id != accountID else { throw BackpackError.invalid("Discovery cannot grant badge/profile data or self contacts.") }
        }
        return result.contacts
    }
}
