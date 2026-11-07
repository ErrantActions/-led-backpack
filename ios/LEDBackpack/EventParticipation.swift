import Foundation
import BackpackProtocol

struct NativeEventRoster: Decodable {
    let participants: [EventParticipantDeadline]
    let page, limit, total, eventRevision: Int
    let organizerRole: CatalogEventRole
    let serverTime: String
    func validate(event: CatalogEvent, requestedPage: Int, deadlinesEnabled: Bool) throws {
        guard page == requestedPage, limit == 24, (1...10000).contains(page), total >= 0,
              participants.count <= limit, Set(participants.map(\.user.id)).count == participants.count,
              eventRevision == event.revision, event.access.role == organizerRole, event.access.canManage else {
            throw BackpackError.invalid("Event roster role/revision/page changed. Refresh and review; no global-admin override.")
        }
        let now = try CatalogEventTime.parse(serverTime)
        for participant in participants where participant.invited {
            let expired = try participant.invitationDeadline.expired(at: now)
            guard !deadlinesEnabled || participant.invitationDeadline != .unspecified,
                  !expired else {
                throw BackpackError.invalid("Roster invitation access changed; discard this page and refresh.")
            }
        }
    }
}
struct EventProgressContext: Equatable {
    let eventID: UUID
    let revision: Int
    let participationRevision: Int?
    let going, member, requiresReview: Bool
    let canViewProgress, cancelled, routePublished: Bool
    init(_ event: CatalogEvent) {
        eventID = event.id; revision = event.revision; participationRevision = event.participationRevision
        going = event.rsvpStatus == .going; member = event.access.member
        requiresReview = event.requiresReconfirmation == true
        canViewProgress = event.access.canViewProgress; cancelled = event.cancelled
        routePublished = event.route?.published == true
    }
}
struct EventProgressChoice {
    private(set) var context: EventProgressContext?
    var checkpointID: UUID?
    var share = false
    mutating func update(_ event: CatalogEvent) {
        let next = EventProgressContext(event)
        if context != next { checkpointID = nil; share = false }
        context = next
    }
    mutating func clear() { context = nil; checkpointID = nil; share = false }
}
struct EventProgressIntent {
    let context: EventProgressContext
    let checkpointID: UUID
    let share: Bool
    let data: Data
    init(event: CatalogEvent, checkpointID: UUID, share: Bool) throws {
        guard event.access.member, event.access.canViewProgress, event.rsvpStatus == .going, event.requiresReconfirmation == false,
              event.participationRevision != nil, !event.cancelled, event.route?.published == true,
              event.route?.checkpoints.contains(where: { $0.id == checkpointID }) == true else {
            throw BackpackError.invalid("A current reviewed going membership and published checkpoint are required.")
        }
        struct Body: Encodable { let checkpointId: String; let share: Bool }
        context = EventProgressContext(event); self.checkpointID = checkpointID; self.share = share
        data = try JSONEncoder().encode(Body(checkpointId: checkpointID.uuidString.lowercased(), share: share))
    }
}
struct EventProgressClaimReceipt: Decodable {
    let localOnly, shared, selfReported: Bool
    let checkpointId: UUID?
    let expiresAtISO: String?
    let serverTime, startsAtISO, endsAtISO: String
    let participationRevision: Int
    let requiresReconfirmation: Bool
    func validate(_ intent: EventProgressIntent, event: CatalogEvent) throws {
        _ = try CatalogEventTime.parse(serverTime)
        guard shared == intent.share, localOnly != shared, selfReported,
              participationRevision == intent.context.participationRevision, !requiresReconfirmation,
              startsAtISO == event.startsAtISO, endsAtISO == event.endsAtISO else {
            throw BackpackError.invalid("Captured checkpoint choice/current reviewed participation was not confirmed.")
        }
        if shared {
            guard checkpointId == intent.checkpointID, let expiresAtISO else { throw BackpackError.invalid("Shared claim did not return its actual checkpoint/retention deadline.") }
            _ = try EventDeadlinePolicy.validateRetention(expiresAtISO, eventEnd: endsAtISO)
        }
    }
}
@MainActor
extension CommunityFeatureClient {
    func participantRoster(_ event: CatalogEvent, page: Int) async throws -> NativeEventRoster {
        try check(.events)
        guard event.access.canManage, event.access.role != nil, event.moderation?.held != true,
              event.organizers.contains(where: { $0.id == accountID && $0.eventRole == event.access.role }),
              (1...10000).contains(page) else { throw BackpackError.invalid("Event organizer access and a bounded roster page are required.") }
        let result = try JSONDecoder().decode(NativeEventRoster.self, from: await send(.events,
            "events/\(event.id.uuidString.lowercased())/participants",
            query: [.init(name: "page", value: String(page)), .init(name: "limit", value: "24")]))
        try result.validate(event: event, requestedPage: page, deadlinesEnabled: invitationDeadlinesEnabled(event))
        return result
    }
    func currentSharedProgress(_ event: CatalogEvent) async throws -> EventSharedProgressBoard {
        try check(.events)
        guard event.access.member, event.access.canViewProgress, progressDeadlinesEnabled(event) else {
            throw BackpackError.invalid("Shared progress requires current membership/access and the actual retention capability.")
        }
        let result = try JSONDecoder().decode(EventSharedProgressBoard.self, from: await send(.events,
            "events/\(event.id.uuidString.lowercased())/progress"))
        guard progressDeadlinesEnabled(event), result.endsAtISO == event.endsAtISO,
              result.participationRevision == nil || result.participationRevision == event.participationRevision,
              result.requiresReconfirmation != true,
              Set(result.progress.map(\.user.id)).count == result.progress.count else {
            throw BackpackError.invalid("Shared-progress context changed. No stale board is retained.")
        }
        _ = try result.currentEntries(expiryEnabled: true, at: CatalogEventTime.parse(result.serverTime))
        return result
    }
    func claimCheckpoint(_ intent: EventProgressIntent) async throws -> EventProgressClaimReceipt {
        let current = try await event(intent.context.eventID)
        guard progressDeadlinesEnabled(current), EventProgressContext(current) == intent.context else {
            throw BackpackError.invalid("Event/review/membership changed. Reset checkpoint sharing consent; no replay.")
        }
        _ = try EventProgressIntent(event: current, checkpointID: intent.checkpointID, share: intent.share)
        let now = try CatalogEventTime.parse(current.serverTime)
        guard now >= (try CatalogEventTime.parse(current.startsAtISO)), now < (try CatalogEventTime.parse(current.endsAtISO)) else {
            throw BackpackError.invalid("Checkpoint claims are accepted only in the actual event window.")
        }
        let receipt = try JSONDecoder().decode(EventProgressClaimReceipt.self, from: await send(.events,
            "events/\(current.id.uuidString.lowercased())/progress", method: "POST", body: intent.data))
        guard progressDeadlinesEnabled(current) else { throw BackpackError.invalid("Shared-progress capability changed during the claim.") }
        try receipt.validate(intent, event: current)
        return receipt
    }
    func withdrawOwnProgress(eventID: UUID) async throws {
        struct Receipt: Decodable { let cleared: Bool }
        // This consent-withdrawal endpoint deliberately does not require an event-detail read.
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.events,
            "events/\(eventID.uuidString.lowercased())/progress", method: "DELETE"))
        guard result.cleared else { throw BackpackError.invalid("Own shared-progress withdrawal was not confirmed.") }
    }
    func rosterAction(_ event: CatalogEvent, target: UUID, action: OrganizerAction) async throws {
        guard [.revokeInvite, .removeParticipant].contains(action) else { throw BackpackError.invalid("Choose a supported roster action.") }
        let current = try await self.event(event.id)
        guard current.revision == event.revision, current.access.role == event.access.role, current.access.canManage else {
            throw BackpackError.invalid("Captured roster/event role or revision changed. Refresh before confirming again.")
        }
        try await organize(current, target: target, action: action)
    }
}
