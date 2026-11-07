import Foundation
import BackpackProtocol

enum NativeEventBadgeKind: String, Decodable { case participation, checkpoint, finish, reward }
struct NativeProfileEventBadge: Decodable, Identifiable {
    let id: UUID
    let kind: NativeEventBadgeKind
    let title: String
    let selfReported, certified: Bool
    func validate() throws {
        guard selfReported, !certified, !title.isEmpty else { throw BackpackError.invalid("Invalid self-reported profile badge.") }
    }
}
struct NativeOwnedEventBadge: Decodable, Identifiable {
    let id, eventId: UUID
    let kind: NativeEventBadgeKind
    let title, description: String
    let eventVersion: Int
    let selfReported, certified, sharingRequested, profileVisible, canShowProfile: Bool
    let currentParticipationRevision: Int?
    func validate() throws {
        guard eventVersion > 0, selfReported, !certified, !title.isEmpty,
              !profileVisible || (sharingRequested && canShowProfile),
              canShowProfile == (currentParticipationRevision != nil),
              currentParticipationRevision == nil || currentParticipationRevision == eventVersion else {
            throw BackpackError.invalid("Invalid owned badge/version/profile authorization. No stale badge is republished.")
        }
    }
}
struct NativeOwnedEventBadges: Decodable {
    let awards: [NativeOwnedEventBadge]
    let page, limit: Int
    let hasMore: Bool
    func validate(page: Int) throws {
        guard self.page == page, limit == 24, awards.count <= 24, Set(awards.map(\.id)).count == awards.count else {
            throw BackpackError.invalid("Invalid bounded private-badge page.")
        }
        for award in awards { try award.validate() }
    }
}
struct EventBadgeCollectionIntent {
    let context: EventProgressContext
    let checkpointID: UUID?
    let data: Data
    init(event: CatalogEvent, checkpointID: UUID?, consent: Bool) throws {
        guard consent, event.settings?.accountAwardsEnabled == true, event.access.member,
              event.rsvpStatus == .going, event.requiresReconfirmation == false, !event.cancelled,
              let revision = event.participationRevision else {
            throw BackpackError.invalid("Explicit private collection consent and current reviewed going membership are required.")
        }
        if let checkpointID {
            guard event.route?.published == true, event.route?.checkpoints.contains(where: { $0.id == checkpointID }) == true else {
                throw BackpackError.invalid("Choose a current published checkpoint for private collection.")
            }
        }
        struct Body: Encodable { let collect = true; let expectedParticipationRevision: Int; let checkpointId: String? }
        context = EventProgressContext(event); self.checkpointID = checkpointID
        data = try JSONEncoder().encode(Body(expectedParticipationRevision: revision, checkpointId: checkpointID?.uuidString.lowercased()))
    }
}
struct EventBadgeCollectionChoice {
    private(set) var context: EventProgressContext?
    var checkpointID: UUID?
    var consent = false
    mutating func update(_ event: CatalogEvent) {
        let next = EventProgressContext(event)
        if context != next { checkpointID = nil; consent = false }
        context = next
    }
    mutating func clear() { context = nil; checkpointID = nil; consent = false }
}
struct EventBadgeProfileIntent {
    let award: NativeOwnedEventBadge
    let visible: Bool
    let data: Data
    init(award: NativeOwnedEventBadge, visible: Bool, consent: Bool) throws {
        try award.validate()
        guard !visible || (consent && award.canShowProfile && award.currentParticipationRevision != nil) else {
            throw BackpackError.invalid("Profile display requires separate consent and the displayed current participation revision.")
        }
        struct Body: Encodable { let profileVisible: Bool; let expectedParticipationRevision: Int? }
        self.award = award; self.visible = visible
        data = try JSONEncoder().encode(Body(profileVisible: visible,
            expectedParticipationRevision: visible ? award.currentParticipationRevision : nil))
    }
}
struct EventBadgeCollectionReceipt: Decodable {
    let collected: Int
    let `private`, selfReported, certified: Bool
    func validate() throws {
        guard collected >= 0, collected <= 500, self.private, selfReported, !certified else {
            throw BackpackError.invalid("Private self-reported collection was not confirmed.")
        }
    }
}
@MainActor
extension CommunityFeatureClient {
    func requireAccountAwards() async throws {
        let current = try await preferences()
        guard current.accountAwardsEnabled == true else { throw BackpackError.invalid("Private account event badges are not enabled by social/me.") }
    }
    func ownEventBadges(page: Int) async throws -> NativeOwnedEventBadges {
        guard (1...1000).contains(page) else { throw BackpackError.invalid("Choose a bounded private-badge page.") }
        try await requireAccountAwards()
        let result = try JSONDecoder().decode(NativeOwnedEventBadges.self, from: await send(.events, "events/my-awards",
            query: [.init(name: "page", value: String(page)), .init(name: "limit", value: "24")]))
        try result.validate(page: page); return result
    }
    func collectEventBadges(_ intent: EventBadgeCollectionIntent) async throws -> EventBadgeCollectionReceipt {
        try await requireAccountAwards()
        let current = try await event(intent.context.eventID)
        guard EventProgressContext(current) == intent.context else { throw BackpackError.invalid("Event context changed. Reset collection consent and review; no automatic replay.") }
        _ = try EventBadgeCollectionIntent(event: current, checkpointID: intent.checkpointID, consent: true)
        if intent.checkpointID != nil {
            let now = try CatalogEventTime.parse(current.serverTime)
            guard now >= (try CatalogEventTime.parse(current.startsAtISO)), now < (try CatalogEventTime.parse(current.endsAtISO)) else {
                throw BackpackError.invalid("Checkpoint badges may be collected only during the actual event window.")
            }
        }
        let result = try JSONDecoder().decode(EventBadgeCollectionReceipt.self, from: await send(.events,
            "events/\(current.id.uuidString.lowercased())/awards", method: "POST", body: intent.data))
        try result.validate(); return result
    }
    func setBadgeProfileChoice(_ intent: EventBadgeProfileIntent) async throws -> NativeOwnedEventBadge {
        try await requireAccountAwards()
        struct Receipt: Decodable { let award: NativeOwnedEventBadge }
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.events,
            "events/my-awards/\(intent.award.id.uuidString.lowercased())", method: "PATCH", body: intent.data)).award
        try result.validate()
        guard result.id == intent.award.id, result.eventId == intent.award.eventId, result.eventVersion == intent.award.eventVersion,
              result.kind == intent.award.kind, result.title == intent.award.title, result.description == intent.award.description,
              result.sharingRequested == intent.visible,
              !intent.visible || (result.profileVisible && result.currentParticipationRevision == intent.award.currentParticipationRevision),
              intent.visible || !result.profileVisible else { throw BackpackError.invalid("The captured profile badge choice was not confirmed.") }
        return result
    }
    func deleteOwnEventBadge(_ award: NativeOwnedEventBadge) async throws {
        try award.validate(); try await requireAccountAwards()
        struct Receipt: Decodable { let removed: Bool }
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.events,
            "events/my-awards/\(award.id.uuidString.lowercased())", method: "DELETE"))
        guard result.removed else { throw BackpackError.invalid("Owned badge removal was not confirmed.") }
    }
}
