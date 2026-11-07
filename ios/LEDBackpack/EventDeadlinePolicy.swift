import Foundation
import BackpackProtocol

enum EventInvitationDeadline: Equatable {
    case unspecified
    case legacy
    case expires(String)

    static func decode<C: CodingKey>(_ values: KeyedDecodingContainer<C>, key: C) throws -> Self {
        guard values.contains(key) else { return .unspecified }
        guard let raw = try values.decodeIfPresent(String.self, forKey: key) else { return .legacy }
        _ = try CatalogEventTime.parse(raw)
        return .expires(raw)
    }
    var wireValue: String? { if case .expires(let value) = self { return value }; return nil }
    var label: String {
        switch self {
        case .unspecified: return "Invitation deadline not supplied by this server"
        case .legacy: return "Legacy invitation — no automatic expiry"
        case .expires(let raw): return "Invitation access ends \(raw)"
        }
    }
    func expired(at serverNow: Date) throws -> Bool {
        guard case .expires(let raw) = self else { return false }
        return try serverNow >= CatalogEventTime.parse(raw)
    }
}

enum EventDeadlinePolicy {
    static let maximumInvitationSeconds: TimeInterval = 30 * 86400
    static let sharedRetentionSeconds = 86400
    static func explicitInvitation(_ raw: String, serverNow: Date) throws -> Date {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#, options: .regularExpression) != nil else {
            throw BackpackError.invalid("Invitation expiry must be an explicit UTC ISO timestamp ending in Z.")
        }
        let expiry = try CatalogEventTime.parse(raw)
        guard expiry > serverNow, expiry.timeIntervalSince(serverNow) <= maximumInvitationSeconds else {
            throw BackpackError.invalid("Choose a future invitation deadline no more than 30 days after current server time.")
        }
        return expiry
    }
    static func retainsIndependentAccess(_ event: CatalogEvent) -> Bool {
        event.rsvpStatus == .going || event.access.role != nil
    }
    static func invitationOnlyExpired(_ event: CatalogEvent, serverNow: Date) throws -> Bool {
        guard event.access.invited, !retainsIndependentAccess(event) else { return false }
        return try event.access.invitationDeadline.expired(at: serverNow)
    }
    static func validateRetention(_ raw: String, eventEnd: String) throws -> Date {
        let deadline = try CatalogEventTime.parse(raw), end = try CatalogEventTime.parse(eventEnd)
        guard deadline <= end.addingTimeInterval(TimeInterval(sharedRetentionSeconds)) else {
            throw BackpackError.invalid("Shared-progress retention exceeds the event-end policy. No deadline is extended locally.")
        }
        return deadline
    }
}

struct EventInvitationIntent {
    let eventID, recipientID: UUID
    let expiresAtISO: String?
    let data: Data
    init(event: CatalogEvent, recipient: UUID, expiresAtISO: String?, serverNow: Date) throws {
        if let expiresAtISO { _ = try EventDeadlinePolicy.explicitInvitation(expiresAtISO, serverNow: serverNow) }
        struct Body: Encodable { let userId: String; let expiresAtISO: String? }
        eventID = event.id; recipientID = recipient; self.expiresAtISO = expiresAtISO
        data = try JSONEncoder().encode(Body(userId: recipient.uuidString.lowercased(), expiresAtISO: expiresAtISO))
    }
}
struct EventInvitationReceipt: Decodable {
    let invited, automaticRsvp: Bool
    let deadline: EventInvitationDeadline
    private enum CodingKeys: String, CodingKey { case invited, automaticRsvp, expiresAtISO }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        invited = try values.decode(Bool.self, forKey: .invited)
        automaticRsvp = try values.decode(Bool.self, forKey: .automaticRsvp)
        deadline = try .decode(values, key: .expiresAtISO)
    }
}

struct EventParticipantDeadline: Decodable {
    let user: Person
    let invited: Bool
    let rsvpStatus: CatalogRSVP?
    let eventRole: CatalogEventRole?
    let invitationDeadline: EventInvitationDeadline
    let requiresReconfirmation: Bool
    typealias Person = SocialPerson
    private enum CodingKeys: String, CodingKey { case user, invited, rsvpStatus, eventRole, invitationExpiresAtISO, requiresReconfirmation }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(Person.self, forKey: .user); invited = try c.decode(Bool.self, forKey: .invited)
        rsvpStatus = try c.decodeIfPresent(CatalogRSVP.self, forKey: .rsvpStatus)
        eventRole = try c.decodeIfPresent(CatalogEventRole.self, forKey: .eventRole)
        invitationDeadline = try .decode(c, key: .invitationExpiresAtISO)
        requiresReconfirmation = try c.decodeIfPresent(Bool.self, forKey: .requiresReconfirmation) ?? false
    }
}
struct EventSharedProgressDeadline: Decodable {
    let user: EventParticipantDeadline.Person
    let checkpointId: UUID
    let started, finished, selfReported: Bool
    let expiresAtISO: String?
    func retained(at serverNow: Date, eventEnd: String, expiryEnabled: Bool) throws -> Bool {
        guard expiryEnabled, selfReported, let expiresAtISO else {
            throw BackpackError.invalid("Shared-progress expiry contract is unavailable. Do not invent a retention deadline.")
        }
        return try serverNow < EventDeadlinePolicy.validateRetention(expiresAtISO, eventEnd: eventEnd)
    }
}

struct EventSharedProgressBoard: Decodable {
    let progress: [EventSharedProgressDeadline]
    let serverTime, endsAtISO: String
    let retentionSecondsAfterEventEnd: Int?
    var participationRevision: Int? = nil
    var requiresReconfirmation: Bool? = nil
    func currentEntries(expiryEnabled: Bool, at now: Date) throws -> [EventSharedProgressDeadline] {
        guard expiryEnabled, retentionSecondsAfterEventEnd == EventDeadlinePolicy.sharedRetentionSeconds else {
            throw BackpackError.invalid("Shared-progress retention policy is not advertised. No arrival/retention fallback.")
        }
        _ = try CatalogEventTime.parse(serverTime)
        return try progress.filter { try $0.retained(at: now, eventEnd: endsAtISO, expiryEnabled: expiryEnabled) }
    }
}
struct EventSharedProgressReceipt: Decodable {
    let localOnly, shared, selfReported: Bool
    let expiresAtISO: String?
    func retentionDeadline(eventEnd: String, expiryEnabled: Bool) throws -> Date? {
        guard selfReported, shared != localOnly else { throw BackpackError.invalid("Invalid self-reported shared-progress receipt.") }
        if !shared { return nil }
        guard expiryEnabled, let expiresAtISO else { throw BackpackError.invalid("A shared claim requires the actual enabled retention deadline.") }
        return try EventDeadlinePolicy.validateRetention(expiresAtISO, eventEnd: eventEnd)
    }
}

@MainActor
extension CommunityFeatureClient {
    func invite(_ event: CatalogEvent, target: UUID, expiresAtISO: String?, serverNow: Date? = nil) async throws -> EventInvitationReceipt {
        try check(.events)
        guard event.access.canManage, !event.cancelled,
              event.organizers.contains(where: { $0.id == accountID && $0.eventRole == event.access.role }) else {
            throw BackpackError.invalid("Current event-scoped organizer access is required to invite.")
        }
        guard expiresAtISO == nil || invitationDeadlinesEnabled(event) else {
            throw BackpackError.invalid("This server/event has not enabled explicit invitation deadlines.")
        }
        let currentServerTime: Date
        if let serverNow { currentServerTime = serverNow }
        else { currentServerTime = try CatalogEventTime.parse(event.serverTime) }
        let intent = try EventInvitationIntent(event: event, recipient: target, expiresAtISO: expiresAtISO,
            serverNow: currentServerTime)
        let receipt = try JSONDecoder().decode(EventInvitationReceipt.self, from: await send(.events,
            "events/\(intent.eventID.uuidString.lowercased())/invitations", method: "POST", body: intent.data))
        guard receipt.invited, !receipt.automaticRsvp else { throw BackpackError.invalid("Invitation was not confirmed without automatic RSVP.") }
        if let expiresAtISO {
            guard invitationDeadlinesEnabled(event), let actual = receipt.deadline.wireValue,
                  try CatalogEventTime.parse(actual) == CatalogEventTime.parse(expiresAtISO) else {
                throw BackpackError.invalid("The explicitly captured invitation deadline was not confirmed. Refresh; do not renew or resend automatically.")
            }
        } else if invitationDeadlinesEnabled(event), receipt.deadline == .unspecified {
            throw BackpackError.invalid("The enabled server omitted its actual invitation deadline. No default was invented.")
        }
        return receipt
    }

    func verifyEventNotice(_ notice: NativeActivityNotice, page: Int) async throws -> UUID {
        guard [.eventInvite, .eventUpdated, .eventCancelled, .eventReminder].contains(notice.type) else {
            throw BackpackError.invalid("This activity is not an event notice.")
        }
        let id = try notice.reference()
        let current = try await notices(page: page)
        guard current.notifications.contains(where: { $0.id == notice.id && $0.type == notice.type && $0.referenceId == notice.referenceId }) else {
            throw CommunityFailure(status: 403, code: "event_notice_unavailable",
                message: "This exact event notice/grant is no longer authorized. Reload activity; public access or going membership does not revive it.")
        }
        return id
    }
}
