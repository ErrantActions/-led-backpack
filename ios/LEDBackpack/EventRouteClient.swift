import Foundation
import BackpackProtocol

enum RouteArtworkReference: Hashable {
    case community(UUID), exclusive(UUID)
}
struct RouteArtworkChoice: Identifiable {
    let reference: RouteArtworkReference
    let title: String
    let previewURL: URL
    var id: RouteArtworkReference { reference }
}
struct PlannerCommunityArtwork: Decodable {
    let item: CommunityItem
    let mature: Bool
    let status, visibility: String?
    private enum CodingKeys: String, CodingKey { case mature, status, visibility }
    init(from decoder: Decoder) throws {
        item = try CommunityItem(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mature = try values.decode(Bool.self, forKey: .mature)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
    }
    var eligible: Bool { !mature && (status == nil || status == "approved") && (visibility == nil || visibility == "shared") }
}
struct PlannerCommunityPage: Decodable {
    let items: [PlannerCommunityArtwork]
    let page, limit, total: Int
}
struct PlannerExclusiveArtwork: Decodable, Identifiable {
    let id: UUID
    let title: String
    let exclusive: Bool
    let originalByteSize, width, height, frameCount: Int
    let gifUrl, previewUrl: URL
}

@MainActor
extension CommunityFeatureClient {
    func routeCatalog(query: String, page: Int) async throws -> PlannerCommunityPage {
        let value = try JSONDecoder().decode(PlannerCommunityPage.self, from: await plannerCatalogData(query: query, page: page))
        guard value.page == page, value.limit == 50, value.total >= 0, value.items.count <= 50 else {
            throw BackpackError.invalid("Invalid community artwork pagination.")
        }
        return value
    }
    func routeCommunityItem(_ id: UUID) async throws -> PlannerCommunityArtwork {
        struct Result: Decodable { let item: PlannerCommunityArtwork }
        let value = try JSONDecoder().decode(Result.self, from: await plannerCatalogData(id: id)).item
        guard value.item.id == id else { throw BackpackError.invalid("Wrong community artwork response.") }
        return value
    }
    func routeExclusives(_ event: CatalogEvent) async throws -> [PlannerExclusiveArtwork] {
        try checkPlanner()
        guard exclusiveRouteEnabled(event) else { throw BackpackError.invalid("Protected event artwork is unavailable on this server.") }
        struct Result: Decodable { let items: [PlannerExclusiveArtwork] }
        let items = try JSONDecoder().decode(Result.self, from: await send(.events,
            "events/\(event.id.uuidString.lowercased())/exclusive-gifs")).items
        guard items.count <= 100, Set(items.map(\.id)).count == items.count else { throw BackpackError.invalid("Invalid event artwork list.") }
        for item in items {
            guard item.exclusive, (1...5_000_000).contains(item.originalByteSize), (1...120).contains(item.frameCount),
                  (1...4096).contains(item.width), (1...4096).contains(item.height),
                  item.previewUrl.path == "/api/v1/events/\(event.id.uuidString.lowercased())/exclusive-gifs/\(item.id.uuidString.lowercased())/preview.png",
                  item.gifUrl.path == "/api/v1/events/\(event.id.uuidString.lowercased())/exclusive-gifs/\(item.id.uuidString.lowercased())/original.gif",
                  origin.contains(item.previewUrl), origin.contains(item.gifUrl),
                  item.previewUrl.query == nil, item.previewUrl.fragment == nil, item.gifUrl.query == nil, item.gifUrl.fragment == nil else {
                throw BackpackError.invalid("Event artwork does not match the captured event/asset context.")
            }
        }
        guard exclusiveRouteEnabled(event) else { throw BackpackError.invalid("Event artwork capability changed.") }
        return items
    }
    func routeArtworkImage(_ choice: RouteArtworkChoice, event: CatalogEvent) async throws -> Data {
        try checkPlanner()
        switch choice.reference {
        case .community:
            return try await plannerCommunityImage(choice.previewURL)
        case .exclusive(let id):
            guard exclusiveRouteEnabled(event) else { throw BackpackError.invalid("Protected artwork is unavailable.") }
            let result = try await send(.events, "events/\(event.id.uuidString.lowercased())/exclusive-gifs/\(id.uuidString.lowercased())/preview.png",
                maxBytes: 5_000_000)
            guard exclusiveRouteEnabled(event) else { throw BackpackError.invalid("Event artwork capability changed.") }
            return result
        }
    }
    func saveRoute(_ draft: EventRouteDraft) async throws -> CatalogEvent {
        try checkPlanner()
        let event = draft.original
        guard event.access.role == .owner, event.access.canManageRoute,
              event.organizers.contains(where: { $0.id == accountID && $0.eventRole == .owner }), !event.cancelled else {
            throw BackpackError.invalid("This event's owner-only route permission is required.")
        }
        let body = draft.body.normalized()
        try body.validate()
        if !eventOptionalCheckpointsAvailable || event.settings?.optionalCheckpointsEnabled != true {
            for checkpoint in body.checkpoints {
                let original = event.route?.checkpoints.first { $0.id == checkpoint.id }
                guard checkpoint.optional == original?.optional else { throw BackpackError.invalid("Optional-stage changes require the advertised config and event setting. Legacy assignments are retained.") }
            }
        }
        if draft.checkpoints.contains(where: { $0.exclusiveGifId != nil }) || draft.rewards.contains(where: { $0.exclusiveGifId != nil }) {
            guard exclusiveRouteEnabled(event) else { throw BackpackError.invalid("Protected artwork references are not enabled for this event.") }
        }
        struct Result: Decodable { let event: CatalogEvent }
        let value = try JSONDecoder().decode(Result.self, from: await send(.events,
            "events/\(event.id.uuidString.lowercased())/checkpoints", method: "PATCH", body: JSONEncoder().encode(body))).event
        try checkPlanner(); try value.validate()
        guard value.id == event.id, value.revision > event.revision, let route = value.route,
              route.published == body.published, route.checkpoints.count == body.checkpoints.count,
              zip(body.checkpoints, route.checkpoints).allSatisfy({ $0.0.matchesReturned($0.1) }), route.geometry == body.geometry,
              value.badges == body.badges else {
            throw BackpackError.invalid("The exact route save was not confirmed. Refresh before retrying.")
        }
        return value
    }
}
