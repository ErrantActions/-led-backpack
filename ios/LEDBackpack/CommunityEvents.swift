import Foundation
import BackpackProtocol

enum CatalogRSVP: String, Codable { case going, declined }
enum CatalogEventStatus: String, Codable { case scheduled, inProgress = "in-progress", ended, cancelled }
enum CatalogEventRole: String, Codable { case owner, coorganizer }

struct CatalogEventLocation: Codable {
    var label: String
    var latitude, longitude, radiusMeters: Double
    func validate() throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf16.count <= 200,
              latitude.isFinite, longitude.isFinite, radiusMeters.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              (1...100000).contains(radiusMeters) else { throw BackpackError.invalid("Provide valid fixed venue coordinates, label and radius.") }
    }
}
struct CatalogEventInput: Encodable {
    var title, description, startsAtISO, endsAtISO, timezone, visibility: String
    var capacity: Int
    var location: CatalogEventLocation
    var expectedRevision: Int? = nil
    var kind: String? = nil
    var unlistedLinkConsent: Bool? = nil
    func validate() throws {
        try location.validate()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 160,
              description.utf16.count <= 5000, ["public", "private", "unlisted"].contains(visibility),
              (1...10000).contains(capacity), timezone.utf16.count <= 100,
              TimeZone.knownTimeZoneIdentifiers.contains(timezone) || timezone == "UTC",
              try CatalogEventTime.parse(endsAtISO) > CatalogEventTime.parse(startsAtISO),
              expectedRevision == nil || (1...9_007_199_254_740_991).contains(expectedRevision ?? 0) else {
            throw BackpackError.invalid("Review event title, UTC time range, timezone, visibility, capacity and revision.")
        }
        guard kind == nil || ["meetup", "group-ride"].contains(kind ?? "") else { throw BackpackError.invalid("Choose a supported event type.") }
        guard unlistedLinkConsent == nil || unlistedLinkConsent == true else { throw BackpackError.invalid("Unlisted link consent must be explicitly true or omitted.") }
    }
}
struct CatalogEvent: Decodable, Identifiable {
    let id: UUID
    let title, description, startsAtISO, endsAtISO, timezone, visibility, serverTime: String
    let capacity, revision: Int
    let cancelled: Bool
    let location: CatalogEventLocation
    let status: CatalogEventStatus
    let rsvpStatus: CatalogRSVP?
    let organizers: [Organizer]
    let access: Access
    let kind: String?
    let participationRevision: Int?
    let requiresReconfirmation: Bool?
    let route: CatalogEventRoute?
    let badges: [EventRouteReward]?
    let settings: CatalogEventRouteSettings?
    var moderation: NativeEventModeration? = nil
    struct Organizer: Decodable, Identifiable {
        let id: UUID
        let displayName: String
        let eventRole: CatalogEventRole
    }
    struct Access: Decodable {
        let role: CatalogEventRole?
        let invited, member, canManage, canManageRoute, canRsvp, canViewProgress: Bool
        let invitationDeadline: EventInvitationDeadline
        let canChooseTeam, canViewRecap: Bool?
        private enum CodingKeys: String, CodingKey {
            case role, invited, member, canManage, canManageRoute, canRsvp, canViewProgress, invitationExpiresAtISO, canChooseTeam, canViewRecap
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decodeIfPresent(CatalogEventRole.self, forKey: .role)
            invited = try c.decode(Bool.self, forKey: .invited); member = try c.decode(Bool.self, forKey: .member)
            canManage = try c.decode(Bool.self, forKey: .canManage)
            canManageRoute = try c.decode(Bool.self, forKey: .canManageRoute)
            canRsvp = try c.decode(Bool.self, forKey: .canRsvp); canViewProgress = try c.decode(Bool.self, forKey: .canViewProgress)
            invitationDeadline = try .decode(c, key: .invitationExpiresAtISO)
            canChooseTeam = try c.decodeIfPresent(Bool.self, forKey: .canChooseTeam)
            canViewRecap = try c.decodeIfPresent(Bool.self, forKey: .canViewRecap)
        }
    }
    func validate() throws {
        try CatalogEventInput(title: title, description: description, startsAtISO: startsAtISO,
            endsAtISO: endsAtISO, timezone: timezone, visibility: visibility, capacity: capacity,
            location: location, expectedRevision: revision).validate()
        try moderation?.validate()
        _ = try CatalogEventTime.parse(serverTime)
        if let participationRevision {
            guard (1...9_007_199_254_740_991).contains(participationRevision) else { throw BackpackError.invalid("Invalid participation revision.") }
        }
        if requiresReconfirmation == true && (participationRevision == nil || rsvpStatus != .going) {
            throw BackpackError.invalid("Invalid event participation-review context.")
        }
        if let route {
            try EventRouteWrite(expectedRevision: revision, published: route.published, checkpoints: route.checkpoints,
                geometry: route.geometry, badges: badges ?? []).validate()
        }
        guard access.canManage == (access.role != nil), access.canManageRoute == (access.role == .owner),
              moderation?.held != true || (!access.canViewProgress && !access.canRsvp),
              cancelled == (status == .cancelled), Set(organizers.map(\.id)).count == organizers.count else {
            throw BackpackError.invalid("Invalid event authorization/status context.")
        }
    }
}
struct CatalogEventsPage: Decodable {
    let events: [CatalogEvent]
    let serverTime: String
    let limit, offset: Int
}
enum CatalogEventList: String, CaseIterable, Identifiable {
    case accessible = "All accessible", mine = "My events", invitations = "Invitations"
    var id: String { rawValue }
    var path: String {
        switch self { case .accessible: return "events"; case .mine: return "events/mine"; case .invitations: return "events/my-invitations" }
    }
}
enum CatalogEventTime {
    static func parse(_ text: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            throw BackpackError.invalid("The event contains an invalid ISO timestamp.")
        }
        return date
    }
    static func wire(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
struct CatalogEventClock {
    let serverTime: Date
    let baseline: ContinuousClock.Instant
    init(serverTime: String, instant: ContinuousClock.Instant = ContinuousClock().now) throws {
        self.serverTime = try CatalogEventTime.parse(serverTime); baseline = instant
    }
    func now(instant: ContinuousClock.Instant = ContinuousClock().now) -> Date {
        let delta = baseline.duration(to: instant).components
        return serverTime.addingTimeInterval(max(0, Double(delta.seconds) + Double(delta.attoseconds) / 1e18))
    }
    func label(start: Date, end: Date, cancelled: Bool, instant: ContinuousClock.Instant = ContinuousClock().now) throws -> String {
        let duration = baseline.duration(to: instant).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let now = serverTime.addingTimeInterval(max(0, elapsed))
        guard end > start else { throw BackpackError.invalid("Invalid event time range.") }
        if cancelled { return "Cancelled" }
        if now >= end { return "Ended" }
        if now >= start { return now.timeIntervalSince(start) < 60 ? "Starting now" : "In progress" }
        let remaining = ceil(start.timeIntervalSince(now))
        guard remaining.isFinite, remaining < Double(Int.max) else { throw BackpackError.invalid("Event countdown is out of range.") }
        let seconds = Int(remaining), days = seconds / 86400
        return (days > 0 ? "\(days)d " : "") + String(format: "%02dh %02dm %02ds",
            seconds % 86400 / 3600, seconds % 3600 / 60, seconds % 60)
    }
}
struct TimedCatalogEvent: Identifiable {
    let event: CatalogEvent
    let clock: CatalogEventClock
    let start, end: Date
    var id: UUID { event.id }
    init(_ event: CatalogEvent) throws {
        try event.validate(); self.event = event; clock = try CatalogEventClock(serverTime: event.serverTime)
        start = try CatalogEventTime.parse(event.startsAtISO); end = try CatalogEventTime.parse(event.endsAtISO)
    }
    func label() throws -> String {
        let label = try clock.label(start: start, end: end, cancelled: event.cancelled)
        if event.requiresReconfirmation == true && label != "Cancelled" && label != "Ended" { return "Review updated event" }
        return label
    }
}

@MainActor
extension CommunityFeatureClient {
    func events(_ list: CatalogEventList, offset: Int) async throws -> CatalogEventsPage {
        guard (0...100000).contains(offset) else { throw BackpackError.invalid("Invalid event page offset.") }
        let value = try JSONDecoder().decode(CatalogEventsPage.self, from: await send(.events, list.path,
            query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "50")]))
        guard value.offset == offset, value.limit == 50, value.events.count <= 50,
              Set(value.events.map(\.id)).count == value.events.count else { throw BackpackError.invalid("Invalid event pagination.") }
        _ = try CatalogEventTime.parse(value.serverTime)
        for event in value.events { try event.validate() }
        for event in value.events { try validateAccess(event) }
        for event in value.events {
            let now = try CatalogEventTime.parse(value.serverTime)
            let expiredInvite = try event.access.invitationDeadline.expired(at: now)
            let expiredPrivateAccess = try EventDeadlinePolicy.invitationOnlyExpired(event, serverNow: now)
            if (list == .invitations && event.access.invited && expiredInvite) ||
                (event.visibility == "private" && expiredPrivateAccess) {
                throw BackpackError.invalid("An invitation expired; discard this event page and refresh current access.")
            }
        }
        return value
    }
    func event(_ id: UUID) async throws -> CatalogEvent {
        try await eventResponse(path: "events/\(id.uuidString.lowercased())", expected: id)
    }
    private func eventResponse(path: String, method: String = "GET", data: Data? = nil, expected: UUID? = nil) async throws -> CatalogEvent {
        struct Result: Decodable { let event: CatalogEvent }
        let value = try JSONDecoder().decode(Result.self, from: await send(.events, path, method: method, body: data)).event
        try value.validate()
        try validateAccess(value)
        if value.visibility == "private", try EventDeadlinePolicy.invitationOnlyExpired(value, serverNow: CatalogEventTime.parse(value.serverTime)) {
            throw CommunityFailure(status: 403, code: "event_invitation_expired", message: "Invitation access expired. Refresh current membership; no cached private event access is retained.")
        }
        guard expected == nil || value.id == expected else { throw BackpackError.invalid("The server returned a different event.") }
        return value
    }
    private func validateAccess(_ event: CatalogEvent) throws {
        if invitationDeadlinesEnabled(event), event.access.invited, event.access.invitationDeadline == .unspecified {
            throw BackpackError.invalid("The enabled server omitted active invitation expiry semantics. Refresh access rather than assuming legacy no-expiry.")
        }
        if let role = event.access.role {
            guard event.access.member, event.organizers.contains(where: { $0.id == accountID && $0.eventRole == role }) else {
                throw BackpackError.invalid("The event role is not bound to this account.")
            }
        }
    }
    func saveEvent(_ input: CatalogEventInput, original: CatalogEvent?) async throws -> CatalogEvent {
        try input.validate()
        if input.visibility == "unlisted" && original?.visibility != "unlisted" {
            guard unlistedEventsAvailable, original == nil || original?.settings?.unlistedEventsEnabled == true,
                  input.unlistedLinkConsent == true else { throw BackpackError.invalid("Unlisted links require the actual capability and explicit venue/link consent.") }
        }
        if let original {
            try validateAccess(original)
            guard original.access.canManage, !original.cancelled, input.expectedRevision == original.revision else {
                throw BackpackError.invalid("Refresh organizer access and confirm the current revision before editing.")
            }
            let current = try await event(original.id)
            guard current.access.canManage, current.access.role == original.access.role else {
                throw CommunityFailure(status: 403, code: "event_access_changed", message: "Organizer access changed; clear private editing context.")
            }
            guard current.revision == original.revision else {
                throw CommunityFailure(status: 409, code: "event_revision_conflict", message: "Event changed. Keep your draft; explicitly reload before another review.")
            }
        } else if input.expectedRevision != nil { throw BackpackError.invalid("New events cannot carry an update revision.") }
        return try await eventResponse(path: original.map { "events/\($0.id.uuidString.lowercased())" } ?? "events",
            method: original == nil ? "POST" : "PATCH", data: JSONEncoder().encode(input), expected: original?.id)
    }
    func rsvp(_ event: CatalogEvent, status: CatalogRSVP) async throws -> CatalogEvent? {
        try validateAccess(event)
        guard status == .declined ? (event.rsvpStatus != nil || event.access.member) : (event.access.canRsvp && !event.cancelled) else {
            throw BackpackError.invalid("RSVP is not available for this event.")
        }
        if event.requiresReconfirmation == true && !participationReviewEnabled {
            throw BackpackError.invalid("This server has not enabled revision-bound participation review.")
        }
        if status == .going && participationReviewEnabled && event.participationRevision == nil {
            throw BackpackError.invalid("Refresh the event's participation revision before confirming.")
        }
        struct Body: Encodable { let status: CatalogRSVP; let expectedParticipationRevision: Int? }
        struct Receipt: Decodable { let event: CatalogEvent?; let declined: Bool? }
        let receipt = try JSONDecoder().decode(Receipt.self, from: await send(.events,
            "events/\(event.id.uuidString.lowercased())/rsvp", method: "POST",
            body: JSONEncoder().encode(Body(status: status,
                expectedParticipationRevision: status == .going && participationReviewEnabled ? event.participationRevision : nil))))
        guard let value = receipt.event else {
            guard status == .declined, receipt.declined == true else { throw BackpackError.invalid("Nullable event requires an actual acknowledged decline; no cached access is inferred.") }
            return nil
        }
        try value.validate(); try validateAccess(value)
        guard value.id == event.id else { throw BackpackError.invalid("RSVP returned a different event.") }
        guard value.rsvpStatus == status else { throw BackpackError.invalid("The server did not confirm the requested RSVP.") }
        if status == .going && participationReviewEnabled {
            guard value.participationRevision == event.participationRevision, value.requiresReconfirmation == false else {
                throw BackpackError.invalid("The displayed participation revision was not confirmed. Review the event again.")
            }
        }
        return value
    }
    func cancelEvent(_ event: CatalogEvent) async throws -> CatalogEvent {
        try validateAccess(event)
        guard event.access.role == .owner else { throw BackpackError.invalid("Only this event's owner can cancel it.") }
        struct Body: Encodable { let expectedRevision: Int }
        let value = try await eventResponse(path: "events/\(event.id.uuidString.lowercased())", method: "DELETE",
            data: JSONEncoder().encode(Body(expectedRevision: event.revision)), expected: event.id)
        guard value.cancelled else { throw BackpackError.invalid("Cancellation was not confirmed.") }
        return value
    }
    enum OrganizerAction: String, CaseIterable, Identifiable {
        case invite, revokeInvite, removeParticipant, addOrganizer, removeOrganizer, transferOwnership
        var id: String { rawValue }
        var label: String {
            switch self {
            case .invite: return "Invite account"
            case .revokeInvite: return "Revoke invitation"
            case .removeParticipant: return "Remove participant"
            case .addOrganizer: return "Add co-organizer"
            case .removeOrganizer: return "Remove co-organizer"
            case .transferOwnership: return "Transfer event ownership"
            }
        }
    }
    func organize(_ event: CatalogEvent, target: UUID, action: OrganizerAction) async throws {
        try validateAccess(event)
        guard event.access.canManage, !event.cancelled else { throw BackpackError.invalid("Event organizer access is required.") }
        if ![OrganizerAction.invite, .revokeInvite].contains(action), event.access.role != .owner {
            throw BackpackError.invalid("This action requires the event's owner, not a global account role.")
        }
        let root = "events/\(event.id.uuidString.lowercased())", user = target.uuidString.lowercased()
        struct Target: Encodable { let userId: String; var expectedRevision: Int? }
        struct Revision: Encodable { let expectedRevision: Int }
        switch action {
        case .invite:
            _ = try await invite(event, target: target, expiresAtISO: nil)
        case .revokeInvite:
            struct Result: Decodable { let revoked, membershipRetained: Bool }
            guard try JSONDecoder().decode(Result.self, from: await send(.events, "\(root)/invitations/\(user)", method: "DELETE")).revoked else {
                throw BackpackError.invalid("Invitation revocation was not confirmed.")
            }
        case .removeParticipant:
            struct Result: Decodable { let removed: Bool }
            guard try JSONDecoder().decode(Result.self, from: await send(.events, "\(root)/participants/\(user)/remove",
                method: "POST")).removed else { throw BackpackError.invalid("Participant removal was not confirmed.") }
        case .transferOwnership:
            _ = try await transferEventOwnership(event, target: target, formerRole: nil)
        case .addOrganizer:
            _ = try await eventResponse(path: "\(root)/organizers",
                method: "POST", data: JSONEncoder().encode(Target(userId: user, expectedRevision: event.revision)), expected: event.id)
        case .removeOrganizer:
            guard event.organizers.contains(where: { $0.id == target && $0.eventRole == .coorganizer }) else {
                throw BackpackError.invalid("Choose a co-organizer; the owner is protected.")
            }
            _ = try await eventResponse(path: "\(root)/organizers/\(user)", method: "DELETE",
                data: JSONEncoder().encode(Revision(expectedRevision: event.revision)), expected: event.id)
        }
    }
}
