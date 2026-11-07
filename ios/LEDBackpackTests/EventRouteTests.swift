import XCTest
import Combine
import BackpackProtocol
@testable import LEDBackpack

private actor PlannerTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected planner fixture request.") }
        return replies.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class PlannerVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class EventRouteTests: XCTestCase {
    private let owner = UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef")!
    private let eventID = UUID(uuidString: "12345678-1234-4567-89ab-123456789abc")!
    private let artID = UUID(uuidString: "22345678-1234-4567-89ab-123456789abc")!
    private func response(_ value: String, status: Int = 200) -> CommunityResponse {
        CommunityResponse(status: status, data: Data(value.utf8))
    }
    private var login: CommunityResponse {
        response("""
        {"user":{"id":"\(owner)","email":"owner@example.invalid","displayName":"Owner","role":"user","verified":true},
        "token":"test-only-planner-session-not-real","expiresAt":"2099-01-01T00:00:00Z"}
        """)
    }
    private func config(enabled: Bool = true, webTiles: Bool? = true) -> CommunityResponse {
        let tileFlag = webTiles.map { ",\"eventMapPlanningEnabled\":\($0)" } ?? ""
        return response("""
        {"requireEmailVerification":false,"eventsEnabled":\(enabled)\(tileFlag),
        "eventParticipationReviewEnabled":true,"eventExclusiveGifsEnabled":true,"eventExclusiveRouteArtworkEnabled":true}
        """)
    }
    private func json(revision: Int = 3, review: Bool = false, cancelled: Bool = false, rsvp: String = "going") -> String {
        """
        {"id":"\(eventID)","title":"Test ride","description":"Fixed plan","kind":"group-ride",
        "startsAtISO":"2026-11-05T12:00:03.125Z","endsAtISO":"2026-11-05T13:00:04.375Z","timezone":"UTC",
        "visibility":"private","capacity":50,"location":{"label":"Fixed venue","latitude":40,"longitude":-90,"radiusMeters":75},
        "revision":\(revision),"participationRevision":2,"requiresReconfirmation":\(review),
        "cancelled":\(cancelled),"serverTime":"2026-11-05T11:00:00.000Z","status":"\(cancelled ? "cancelled" : "scheduled")",
        "rsvpStatus":"\(rsvp)","organizers":[{"id":"\(owner)","displayName":"Owner","eventRole":"owner"}],
        "access":{"role":"owner","invited":false,"member":true,"canManage":true,"canManageRoute":true,
        "canRsvp":\(!cancelled),"canViewProgress":true},"route":{"published":false,"checkpoints":[],"geometry":[]},
        "badges":[],"settings":{"exclusiveArtworkReferences":true}}
        """
    }
    private func event(revision: Int = 3) throws -> CatalogEvent {
        try JSONDecoder().decode(CatalogEvent.self, from: Data(json(revision: revision).utf8))
    }
    private func eventWithExclusiveCheckpoint() throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json().utf8)) as? [String: Any])
        let item = EventRouteCheckpoint(title: "Private event point", kind: .checkpoint, latitude: 40, longitude: -90,
            radiusMeters: 75, order: 0, exclusiveGifId: artID)
        object["route"] = ["published": false, "checkpoints": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))], "geometry": []]
        return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }
    private func controller(_ transport: PlannerTransport) async throws -> CommunityController {
        let value = CommunityController(vault: PlannerVault(), factory: { _ in transport })
        value.configure("https://catalog.example")
        try await value.signIn(email: "owner@example.invalid", password: "example test password")
        try await value.loadConfig()
        return value
    }
    private func settle(_ session: CommunityFeatureSession, start: () -> Void) async {
        let finished = expectation(description: "Planner operation")
        var began = false, completed = false
        let token = session.$busy.sink { busy in
            if busy { began = true }
            else if began && !completed { completed = true; finished.fulfill() }
        }
        start()
        await fulfillment(of: [finished], timeout: 3)
        token.cancel()
    }

    func testTypedPlannerAddsStartAndFinishAndReordersOnlyIntermediatePoints() throws {
        var draft = try EventRouteDraft(event())
        let point = EventCoordinate(latitude: 40, longitude: -90)
        try draft.addCheckpoint(.finish, at: point)
        try draft.addCheckpoint(.start, at: point)
        try draft.addCheckpoint(.checkpoint, at: point)
        try draft.addCheckpoint(.checkpoint, at: point)
        XCTAssertEqual(draft.checkpoints.map(\.kind), [.start, .checkpoint, .checkpoint, .finish])
        let second = draft.checkpoints[2].id
        try draft.moveCheckpoint(second, by: -1)
        XCTAssertEqual(draft.checkpoints[1].id, second)
        XCTAssertEqual(draft.checkpoints.map(\.order), [0, 1, 2, 3])
        XCTAssertThrowsError(try draft.addCheckpoint(.start, at: point))
        draft.published = true
        XCTAssertNoThrow(try draft.body.validate())
        draft.removeCheckpoint(draft.checkpoints[0].id)
        XCTAssertThrowsError(try draft.body.validate())
    }

    func testPlannerBoundsCoordinatesOrderAndMutuallyExclusiveArtworkAreExact() throws {
        var draft = try EventRouteDraft(event())
        XCTAssertThrowsError(try EventCoordinate(latitude: .nan, longitude: 0).validate())
        XCTAssertThrowsError(try EventCoordinate(latitude: 91, longitude: 0).validate())
        XCTAssertNoThrow(try EventCoordinate(latitude: -90, longitude: 180).validate())
        for _ in 0..<50 { try draft.addCheckpoint(.checkpoint, at: EventCoordinate(latitude: 40, longitude: -90)) }
        XCTAssertThrowsError(try draft.addCheckpoint(.checkpoint, at: EventCoordinate(latitude: 40, longitude: -90)))
        draft.checkpoints[0].gifItemId = artID; draft.checkpoints[0].exclusiveGifId = artID
        XCTAssertThrowsError(try draft.body.validate())
        draft.checkpoints[0].exclusiveGifId = nil
        draft.geometry = (0..<200).map { _ in EventGeometryPoint(point: EventCoordinate(latitude: 40, longitude: -90)) }
        draft.rewards = (0..<10).map { _ in EventRouteReward(title: "Reward", description: "") }
        XCTAssertNoThrow(try draft.body.validate())
        draft.geometry.append(EventGeometryPoint(point: EventCoordinate(latitude: 40, longitude: -90)))
        XCTAssertThrowsError(try draft.body.validate())
        draft.geometry.removeLast(); draft.rewards.append(EventRouteReward(title: "Too many", description: ""))
        XCTAssertThrowsError(try draft.body.validate())
    }

    func testRouteWireEncodingHasOnlyLiveKeysAndCanonicalLowercaseIDs() throws {
        var draft = try EventRouteDraft(event())
        try draft.addCheckpoint(.checkpoint, at: EventCoordinate(latitude: 40, longitude: -90))
        draft.checkpoints[0].exclusiveGifId = artID
        draft.rewards = [EventRouteReward(title: "Finish", description: "Self-reported", gifItemId: artID)]
        let data = try JSONEncoder().encode(draft.body)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["expectedRevision", "published", "checkpoints", "geometry", "badges"]))
        XCTAssertEqual(value["expectedRevision"] as? Int, 3)
        let checkpoints = try XCTUnwrap(value["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(checkpoints[0]["id"] as? String, draft.checkpoints[0].id.uuidString.lowercased())
        XCTAssertEqual(checkpoints[0]["exclusiveGifId"] as? String, artID.uuidString.lowercased())
        XCTAssertNil(checkpoints[0]["gifItemId"])
        XCTAssertNil(value["accountAwards"])
        XCTAssertNil(value["userLocation"])
    }

    func testArtworkRepairRestoresFixedStructureWithoutDroppingRewardEdits() throws {
        var draft = try EventRouteDraft(event())
        try draft.addCheckpoint(.checkpoint, at: EventCoordinate(latitude: 41, longitude: -91))
        draft.geometry = [EventGeometryPoint(point: EventCoordinate(latitude: 41, longitude: -91))]
        draft.rewards = [EventRouteReward(title: "Repaired reward", description: "Not certified")]
        XCTAssertFalse(draft.fixedGeometryMatchesOriginal)
        try draft.restoreFixedGeometryKeepingArtwork()
        XCTAssertTrue(draft.fixedGeometryMatchesOriginal)
        XCTAssertEqual(draft.rewards.first?.title, "Repaired reward")
        XCTAssertEqual(draft.original.revision, 3)
    }

    func testDisabledEventCapabilityNeverSendsPlannerRequest() async throws {
        let transport = PlannerTransport([login, config(enabled: false)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        XCTAssertFalse(client.plannerEnabled)
        do { _ = try await client.routeCatalog(query: "", page: 1); XCTFail("Disabled planner must fail closed") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
    }

    func testWebTileFlagFalseOrMissingDoesNotDisableNativeMapKit() async throws {
        for webTiles in [Optional(false), nil] {
            let transport = PlannerTransport([login, config(webTiles: webTiles)])
            let community = try await controller(transport)
            let client = try CommunityFeatureClient(community)
            XCTAssertTrue(client.plannerEnabled)
            XCTAssertNoThrow(try client.checkPlanner())
            let requests = await transport.history()
            XCTAssertEqual(requests.count, 2)
            XCTAssertFalse(requests.contains { $0.url?.path == "/api/v1/events/map-config" })
        }
    }

    func testWebTileConfigurationChangePreservesExistingNativeDraft() async throws {
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json())}"),
            response(#"{"items":[]}"#), config(webTiles: false)])
        let community = try await controller(transport)
        let store = EventRoutePlannerStore()
        let current = try event()
        await settle(store.session) { store.bind(community, event: current) }
        try store.draft?.addCheckpoint(.checkpoint, at: EventCoordinate(latitude: 40, longitude: -90))
        let before = store.draft?.checkpoints.map(\.id)
        try await community.loadConfig()
        XCTAssertTrue(store.session.client?.plannerEnabled == true)
        XCTAssertEqual(store.draft?.checkpoints.map(\.id), before)
        XCTAssertEqual(store.draft?.original.revision, 3)
        XCTAssertFalse(store.readOnly)
    }

    func testRouteSaveUsesOwnerScopedRevisionAndNoGpsOrAdminOverrideFields() async throws {
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json(revision: 4))}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let result = try await client.saveRoute(EventRouteDraft(event()))
        XCTAssertEqual(result.revision, 4)
        let requests = await transport.history()
        XCTAssertEqual(requests[2].url?.path, "/api/v1/events/\(eventID.uuidString.lowercased())/checkpoints")
        XCTAssertEqual(requests[2].httpMethod, "PATCH")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        XCTAssertNotNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(body["expectedRevision"] as? Int, 3)
        XCTAssertNil(body["admin"])
        XCTAssertNil(body["participantCoordinates"])
    }

    func testConflictPreservesCapturedDraftWithoutSendingPatchOrRebasing() async throws {
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json())}"), response(#"{"items":[]}"#),
            response("{\"event\":\(json(revision: 4))}")])
        let community = try await controller(transport)
        let store = EventRoutePlannerStore()
        let current = try event()
        await settle(store.session) { store.bind(community, event: current) }
        try store.draft?.addCheckpoint(.checkpoint, at: EventCoordinate(latitude: 40, longitude: -90))
        let ids = store.draft?.checkpoints.map(\.id)
        let captured = try NativeEventRouteReview(XCTUnwrap(store.draft))
        await settle(store.session) { store.save(captured: captured, done: { XCTFail("Conflicted draft must not save") }) }
        XCTAssertTrue(store.conflict)
        XCTAssertEqual(store.draft?.original.revision, 3)
        XCTAssertEqual(store.draft?.checkpoints.map(\.id), ids)
        let requests = await transport.history()
        XCTAssertFalse(requests.contains { $0.httpMethod == "PATCH" })
    }

    func testSharedProgressLockRequiresExplicitGeometryRestorationAndNoAutoRetry() async throws {
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json())}"), response(#"{"items":[]}"#),
            response("{\"event\":\(json())}"),
            response(#"{"error":{"code":"event_route_locked","message":"Shared progress locks fixed geometry"}}"#, status: 409)])
        let community = try await controller(transport)
        let store = EventRoutePlannerStore()
        let current = try event()
        await settle(store.session) { store.bind(community, event: current) }
        try store.draft?.addCheckpoint(.checkpoint, at: EventCoordinate(latitude: 40, longitude: -90))
        let captured = try NativeEventRouteReview(XCTUnwrap(store.draft))
        await settle(store.session) { store.save(captured: captured, done: { XCTFail("Locked write must fail") }) }
        XCTAssertTrue(store.structureLocked)
        XCTAssertEqual(store.draft?.checkpoints.count, 1)
        try store.draft?.restoreFixedGeometryKeepingArtwork()
        XCTAssertTrue(store.draft?.fixedGeometryMatchesOriginal == true)
        let requests = await transport.history()
        XCTAssertEqual(requests.filter { $0.httpMethod == "PATCH" }.count, 1)
    }

    func testReconfirmationBindsDisplayedParticipationRevisionAndNeverSharesProgress() async throws {
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json(review: false))}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let current = try JSONDecoder().decode(CatalogEvent.self, from: Data(json(review: true).utf8))
        let receipt = try await client.rsvp(current, status: .going)
        let result = try XCTUnwrap(receipt)
        XCTAssertEqual(result.requiresReconfirmation, false)
        let requests = await transport.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(body["status"] as? String, "going")
        XCTAssertEqual(body["expectedParticipationRevision"] as? Int, 2)
        XCTAssertNil(body["share"])
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/progress") == true })
        XCTAssertEqual(try TimedCatalogEvent(current).label(), "Review updated event")
    }

    func testWithdrawalStillWorksAfterCancellation() async throws {
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json(cancelled: true, rsvp: "declined"))}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let current = try JSONDecoder().decode(CatalogEvent.self, from: Data(json(cancelled: true).utf8))
        let receipt = try await client.rsvp(current, status: .declined)
        let result = try XCTUnwrap(receipt)
        XCTAssertEqual(result.rsvpStatus, .declined)
        XCTAssertTrue(result.cancelled)
    }

    func testUnavailableExclusiveReferenceStaysOpaqueAndNeverBecomesCommunity() async throws {
        let json = try eventWithExclusiveCheckpoint()
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json)}"), response(#"{"items":[]}"#)])
        let community = try await controller(transport)
        let current = try JSONDecoder().decode(CatalogEvent.self, from: Data(json.utf8))
        let store = EventRoutePlannerStore()
        await settle(store.session) { store.bind(community, event: current) }
        XCTAssertTrue(store.unavailable.contains(.exclusive(artID)))
        XCTAssertEqual(store.draft?.checkpoints.first?.exclusiveGifId, artID)
        XCTAssertNil(store.draft?.checkpoints.first?.gifItemId)
        XCTAssertTrue(store.artworkLabel(.exclusive(artID)).contains("Unavailable"))
        let captured = try NativeEventRouteReview(XCTUnwrap(store.draft))
        await settle(store.session) { store.save(captured: captured, done: { XCTFail("Unrepaired artwork must not save") }) }
        let requests = await transport.history()
        XCTAssertFalse(requests.contains { $0.httpMethod == "PATCH" })
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/v1/items/\(artID.uuidString.lowercased())" })
    }

    func testExclusiveListingRejectsCrossEventMediaContext() async throws {
        let other = UUID().uuidString.lowercased()
        let base = "https://catalog.example/api/v1/events/\(other)/exclusive-gifs/\(artID.uuidString.lowercased())"
        let item = """
        {"id":"\(artID)","title":"Wrong event","exclusive":true,"originalByteSize":100,"width":16,"height":16,
        "frameCount":1,"gifUrl":"\(base)/original.gif","previewUrl":"\(base)/preview.png"}
        """
        let transport = PlannerTransport([login, config(), response("{\"items\":[\(item)]}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        do { _ = try await client.routeExclusives(event()); XCTFail("Cross-event media must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("context")) }
    }

    func testPermissionLossClearsPlannerDataInsteadOfLeavingAnEditablePrivateDraft() async throws {
        let transport = PlannerTransport([login, config(), response("{\"event\":\(json())}"), response(#"{"items":[]}"#),
            response(#"{"error":{"code":"event_not_found","message":"Event not found"}}"#, status: 404)])
        let community = try await controller(transport)
        let store = EventRoutePlannerStore()
        let current = try event()
        await settle(store.session) { store.bind(community, event: current) }
        await settle(store.session) { store.refreshPermission() }
        XCTAssertTrue(store.readOnly)
        XCTAssertNil(store.draft)
        XCTAssertTrue(store.choices.isEmpty)
    }

    func testStaleParticipationRevisionIsNotRetriedOrShared() async throws {
        let transport = PlannerTransport([login, config(),
            response(#"{"error":{"code":"event_review_required","message":"Review the updated event"}}"#, status: 409)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let current = try JSONDecoder().decode(CatalogEvent.self, from: Data(json(review: true).utf8))
        do { _ = try await client.rsvp(current, status: .going); XCTFail("Old review must fail") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.code, "event_review_required") }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[2].url?.path, "/api/v1/events/\(eventID.uuidString.lowercased())/rsvp")
    }
}
