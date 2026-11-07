import Foundation
import BackpackProtocol

struct EventCoordinate: Codable, Equatable {
    var latitude, longitude: Double
    func validate() throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw BackpackError.invalid("Choose a valid fixed map point.")
        }
    }
}
enum EventCheckpointKind: String, Codable, CaseIterable { case start, checkpoint, finish }
struct EventRouteCheckpoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var kind: EventCheckpointKind
    var latitude, longitude, radiusMeters: Double
    var order: Int
    var gifItemId: UUID?
    var exclusiveGifId: UUID?
    var optional: Bool? = nil
    var point: EventCoordinate {
        get { EventCoordinate(latitude: latitude, longitude: longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude }
    }
    func matchesReturned(_ other: EventRouteCheckpoint) -> Bool {
        var lhs = self, rhs = other
        lhs.optional = optional == true ? true : nil
        rhs.optional = other.optional == true ? true : nil
        return lhs == rhs
    }
    private enum CodingKeys: String, CodingKey { case id, title, kind, latitude, longitude, radiusMeters, order, gifItemId, exclusiveGifId, optional }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(title, forKey: .title); try values.encode(kind, forKey: .kind)
        try values.encode(latitude, forKey: .latitude); try values.encode(longitude, forKey: .longitude)
        try values.encode(radiusMeters, forKey: .radiusMeters); try values.encode(order, forKey: .order)
        try values.encodeIfPresent(gifItemId?.uuidString.lowercased(), forKey: .gifItemId)
        try values.encodeIfPresent(exclusiveGifId?.uuidString.lowercased(), forKey: .exclusiveGifId)
        try values.encodeIfPresent(optional, forKey: .optional)
    }
    func validate() throws {
        try point.validate()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 160,
              radiusMeters.isFinite, (1...100000).contains(radiusMeters), (0..<50).contains(order),
              gifItemId == nil || exclusiveGifId == nil,
              optional != true || kind == .checkpoint else { throw BackpackError.invalid("Review checkpoint title, radius, order and artwork source. Start and finish must be required.") }
    }
}
struct EventRouteReward: Codable, Identifiable, Equatable {
    var id = UUID()
    var title, description: String
    var gifItemId: UUID?
    var exclusiveGifId: UUID?
    private enum CodingKeys: String, CodingKey { case id, title, description, gifItemId, exclusiveGifId }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(title, forKey: .title); try values.encode(description, forKey: .description)
        try values.encodeIfPresent(gifItemId?.uuidString.lowercased(), forKey: .gifItemId)
        try values.encodeIfPresent(exclusiveGifId?.uuidString.lowercased(), forKey: .exclusiveGifId)
    }
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 120,
              description.utf16.count <= 500, gifItemId == nil || exclusiveGifId == nil else {
            throw BackpackError.invalid("Review finish reward name, description and artwork source.")
        }
    }
}
struct CatalogEventRoute: Decodable {
    let published: Bool
    let checkpoints: [EventRouteCheckpoint]
    let geometry: [EventCoordinate]
}
struct CatalogEventRouteSettings: Decodable {
    let exclusiveArtworkReferences: Bool?
    var expiringInvitationsEnabled: Bool? = nil
    var sharedProgressExpiryEnabled: Bool? = nil
    var sharedProgressRetentionSeconds: Int? = nil
    var accountAwardsEnabled: Bool? = nil
    var unlistedEventsEnabled: Bool? = nil
    var ownershipAuditEnabled: Bool? = nil
    var formerOwnerRoleChoiceEnabled: Bool? = nil
    var eventReportsEnabled: Bool? = nil
    var optionalCheckpointsEnabled: Bool? = nil
    var eventTeamsEnabled: Bool? = nil
    var eventCollectionsEnabled: Bool? = nil
    var eventDisplayPlanningEnabled: Bool? = nil
    var eventGuestbookAvailable: Bool? = nil
    var eventGuestbookEnabled: Bool? = nil
    var eventRecapsEnabled: Bool? = nil
}
struct EventRouteWrite: Encodable {
    let expectedRevision: Int
    let published: Bool
    let checkpoints: [EventRouteCheckpoint]
    let geometry: [EventCoordinate]
    let badges: [EventRouteReward]
    func normalized() -> EventRouteWrite {
        EventRouteWrite(expectedRevision: expectedRevision, published: published,
            checkpoints: checkpoints.map { source in
                var value = source; value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines); return value
            }, geometry: geometry, badges: badges.map { source in
                var value = source; value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
                value.description = value.description.trimmingCharacters(in: .whitespacesAndNewlines); return value
            })
    }
    func validate() throws {
        guard (1...9_007_199_254_740_991).contains(expectedRevision), checkpoints.count <= 50, geometry.count <= 200,
              badges.count <= 10, Set(checkpoints.map(\.id)).count == checkpoints.count,
              Set(badges.map(\.id)).count == badges.count, checkpoints.enumerated().allSatisfy({ $0.offset == $0.element.order }) else {
            throw BackpackError.invalid("Use at most 50 unique ordered checkpoints, 200 route points and 10 finish rewards.")
        }
        for checkpoint in checkpoints { try checkpoint.validate() }
        for point in geometry { try point.validate() }
        for badge in badges { try badge.validate() }
        if published {
            guard checkpoints.count >= 2, checkpoints.first?.kind == .start, checkpoints.last?.kind == .finish,
                  checkpoints.filter({ $0.kind == .start }).count == 1, checkpoints.filter({ $0.kind == .finish }).count == 1 else {
                throw BackpackError.invalid("Publishing needs exactly one start first and one finish last.")
            }
        }
    }
}
struct EventGeometryPoint: Identifiable {
    let id = UUID()
    var point: EventCoordinate
}
struct EventRouteDraft {
    let original: CatalogEvent
    var published: Bool
    var checkpoints: [EventRouteCheckpoint]
    var geometry: [EventGeometryPoint]
    var rewards: [EventRouteReward]
    init(_ event: CatalogEvent) throws {
        guard let route = event.route, let rewards = event.badges, event.access.canManageRoute,
              event.access.role == .owner, !event.cancelled else {
            throw BackpackError.invalid("Refresh this event's owner-only route planning permission.")
        }
        let body = EventRouteWrite(expectedRevision: event.revision, published: route.published,
            checkpoints: route.checkpoints, geometry: route.geometry, badges: rewards)
        try body.validate()
        original = event; published = route.published; checkpoints = route.checkpoints
        geometry = route.geometry.map { EventGeometryPoint(point: $0) }; self.rewards = rewards
    }
    var body: EventRouteWrite {
        EventRouteWrite(expectedRevision: original.revision, published: published, checkpoints: checkpoints,
            geometry: geometry.map(\.point), badges: rewards)
    }
    var fixedGeometryMatchesOriginal: Bool {
        guard let route = original.route, published == route.published, geometry.map(\.point) == route.geometry else { return false }
        func fixed(_ entries: [EventRouteCheckpoint]) -> [EventRouteCheckpoint] {
            entries.map {
                source in
                var value = source; value.gifItemId = nil; value.exclusiveGifId = nil
                value.optional = value.optional == true ? true : nil
                return value
            }
        }
        return fixed(checkpoints) == fixed(route.checkpoints)
    }
    mutating func addCheckpoint(_ kind: EventCheckpointKind, at point: EventCoordinate) throws {
        try point.validate()
        guard checkpoints.count < 50, kind == .checkpoint || !checkpoints.contains(where: { $0.kind == kind }) else {
            throw BackpackError.invalid("Use one start, one finish and at most 50 checkpoints.")
        }
        let name = kind == .start ? "Start" : kind == .finish ? "Finish" : "Checkpoint \(checkpoints.count + 1)"
        let item = EventRouteCheckpoint(title: name, kind: kind, latitude: point.latitude, longitude: point.longitude,
            radiusMeters: 100, order: 0)
        if kind == .start { checkpoints.insert(item, at: 0) }
        else if kind == .finish { checkpoints.append(item) }
        else { checkpoints.insert(item, at: checkpoints.firstIndex(where: { $0.kind == .finish }) ?? checkpoints.count) }
        normalizeOrder()
    }
    mutating func moveCheckpoint(_ id: UUID, by offset: Int) throws {
        guard let index = checkpoints.firstIndex(where: { $0.id == id }), checkpoints[index].kind == .checkpoint,
              abs(offset) == 1, checkpoints.indices.contains(index + offset), checkpoints[index + offset].kind == .checkpoint else {
            throw BackpackError.invalid("Reorder intermediate checkpoints between the fixed start and finish.")
        }
        checkpoints.swapAt(index, index + offset); normalizeOrder()
    }
    mutating func removeCheckpoint(_ id: UUID) { checkpoints.removeAll { $0.id == id }; normalizeOrder() }
    mutating func normalizeOrder() { for index in checkpoints.indices { checkpoints[index].order = index } }
    mutating func restoreFixedGeometryKeepingArtwork() throws {
        guard let route = original.route, Set(checkpoints.map(\.id)).count == checkpoints.count else {
            throw BackpackError.invalid("Cannot restore an invalid captured route.")
        }
        let choices = Dictionary(uniqueKeysWithValues: checkpoints.map { ($0.id, ($0.gifItemId, $0.exclusiveGifId)) })
        checkpoints = route.checkpoints.map { source in
            var value = source
            if let choice = choices[source.id] { value.gifItemId = choice.0; value.exclusiveGifId = choice.1 }
            return value
        }
        geometry = route.geometry.map { EventGeometryPoint(point: $0) }; published = route.published
    }
}
