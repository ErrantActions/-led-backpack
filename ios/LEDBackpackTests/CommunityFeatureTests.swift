import XCTest
import ImageIO
import UIKit
import BackpackProtocol
@testable import LEDBackpack

private actor FeatureTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var requests: [URLRequest] = []
    private var budgets: [Int] = []
    private var pending: CheckedContinuation<CommunityResponse, Error>?
    private var notification: CheckedContinuation<Void, Never>?
    private var waiting = false
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request); budgets.append(maxBytes)
        if !replies.isEmpty { return replies.removeFirst() }
        waiting = true; notification?.resume(); notification = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForRequest() async { if waiting { return }; await withCheckedContinuation { notification = $0 } }
    func finish(_ response: CommunityResponse) { pending?.resume(returning: response); pending = nil }
    func history() -> [URLRequest] { requests }
    func limits() -> [Int] { budgets }
}
@MainActor
private final class FeatureVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class CommunityFeatureTests: XCTestCase {
    private let owner = UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef")!
    private let peer = UUID(uuidString: "12345678-1234-4567-89ab-123456789abc")!
    private let eventID = UUID(uuidString: "22345678-1234-4567-89ab-123456789abc")!
    private let version = UUID(uuidString: "32345678-1234-4567-89ab-123456789abc")!
    private func response(_ value: String, status: Int = 200) -> CommunityResponse {
        CommunityResponse(status: status, data: Data(value.utf8))
    }
    private var login: CommunityResponse {
        response("""
        {"user":{"id":"\(owner)","email":"test@example.invalid","displayName":"Owner","role":"user","verified":true},
        "token":"test-only-feature-session-not-real","expiresAt":"2099-01-01T00:00:00Z"}
        """)
    }
    private func config(enabled: Bool = true) -> CommunityResponse {
        response(enabled ? #"{"requireEmailVerification":false,"socialEnabled":true,"eventsEnabled":true,"avatarsEnabled":true,"avatarUploadsEnabled":true,"avatarApprovalMode":"ai"}"# :
            #"{"requireEmailVerification":false}"#)
    }
    private func controller(_ transport: FeatureTransport) async throws -> CommunityController {
        let value = CommunityController(vault: FeatureVault(), factory: { _ in transport })
        value.configure("https://catalog.example")
        try await value.signIn(email: "test@example.invalid", password: "example test password")
        try await value.loadConfig()
        return value
    }
    private func event(status: String = "scheduled", rsvp: String? = nil, cancelled: Bool = false,
        role: String? = nil, organizerID: UUID? = nil) -> String {
        let accessRole = role.map { "\"\($0)\"" } ?? "null"
        let going = rsvp.map { "\"\($0)\"" } ?? "null"
        let person = organizerID ?? (role == nil ? peer : owner)
        return """
        {"id":"\(eventID)","title":"Test event","description":"Fixed venue","startsAtISO":"2026-11-05T01:00:00.000Z",
        "endsAtISO":"2026-11-05T02:00:00.000Z","timezone":"UTC","visibility":"private","capacity":50,
        "location":{"label":"Venue","latitude":40,"longitude":-90,"radiusMeters":100},"revision":3,"cancelled":\(cancelled),
        "serverTime":"2026-11-05T00:00:00.000Z","status":"\(status)","rsvpStatus":\(going),
        "organizers":[{"id":"\(person)","displayName":"Organizer","eventRole":"owner"}],
        "access":{"role":\(accessRole),"invited":true,"member":true,"canManage":\(role != nil),
        "canManageRoute":\(role == "owner"),"canRsvp":\(!cancelled),"canViewProgress":true}}
        """
    }
    private func decodedEvent(_ json: String? = nil) throws -> CatalogEvent {
        try JSONDecoder().decode(CatalogEvent.self, from: Data((json ?? event()).utf8))
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testMissingCapabilitiesFailClosedWithoutSendingFeatureRequests() async throws {
        let transport = FeatureTransport([login, config(enabled: false)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        for feature in [CommunityFeature.social, .events, .avatars] { XCTAssertThrowsError(try client.check(feature)) }
        do { _ = try await client.events(.accessible, offset: 0); XCTFail("Disabled events must not be queried") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
    }

    func testProfilePatchUsesOnlyActualFieldsAndAcceptsSourceResponseWithoutMessagingFields() async throws {
        let transport = FeatureTransport([login, config(),
            response("{\"profile\":{\"id\":\"\(owner)\",\"displayName\":\"Updated\"},\"discoverable\":false,\"allowRequests\":true}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        try await client.saveProfile(name: " Updated ", discoverable: false, requests: true)
        let requests = await transport.history()
        XCTAssertEqual(requests[2].url?.path, "/api/v1/social/me")
        XCTAssertEqual(requests[2].httpMethod, "PATCH")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        XCTAssertNotNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        let data = try body(requests[2])
        XCTAssertEqual(Set(data.keys), Set(["displayName", "discoverable", "allowRequests"]))
        XCTAssertEqual(data["displayName"] as? String, "Updated")
        XCTAssertNil(data["latitude"])
    }

    func testFriendConsentIsDirectionalAndDoesNotInventGpsFields() async throws {
        let friend = "{\"id\":\"\(peer)\",\"displayName\":\"Peer\",\"locationFeaturesAllowed\":false,\"mutualLocationFeaturesAllowed\":false}"
        let enabled = "{\"id\":\"\(peer)\",\"displayName\":\"Peer\",\"locationFeaturesAllowed\":true,\"mutualLocationFeaturesAllowed\":false}"
        let transport = FeatureTransport([login, config(), response("{\"friends\":[\(friend)],\"page\":2,\"limit\":50}"),
            response("{\"friend\":\(enabled)}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let friends = try await client.friends(page: 2)
        XCTAssertEqual(friends.friends[0].mutualLocationFeaturesAllowed, false)
        try await client.futureLocation(peer, enabled: true)
        let requests = await transport.history()
        XCTAssertEqual(requests[3].url?.path, "/api/v1/social/friends/\(peer.uuidString.lowercased())/location-permission")
        XCTAssertEqual(try body(requests[3])["enabled"] as? Bool, true)
        XCTAssertEqual(try body(requests[3]).count, 1)
    }

    func testEventRsvpUsesGoingAndReturnsItsTimeState() async throws {
        let transport = FeatureTransport([login, config(), response("{\"event\":\(event(rsvp: "going"))}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let receipt = try await client.rsvp(decodedEvent(), status: .going)
        let result = try XCTUnwrap(receipt)
        XCTAssertEqual(result.rsvpStatus, .going)
        XCTAssertEqual(result.startsAtISO, "2026-11-05T01:00:00.000Z")
        let requests = await transport.history()
        XCTAssertEqual(requests[2].url?.path, "/api/v1/events/\(eventID.uuidString.lowercased())/rsvp")
        XCTAssertEqual(try body(requests[2])["status"] as? String, "going")
        XCTAssertEqual(try body(requests[2]).count, 1)
        XCTAssertThrowsError(try decodedEvent(event(rsvp: "accepted")))
    }

    func testCountdownUsesServerAnchorAndContinuousElapsedTimeAtExactBoundaries() throws {
        let instant = ContinuousClock().now
        let clock = try CatalogEventClock(serverTime: "2026-11-05T00:00:00.000Z", instant: instant)
        let start = try CatalogEventTime.parse("2026-11-05T01:00:00.000Z")
        let end = try CatalogEventTime.parse("2026-11-05T02:00:00.000Z")
        XCTAssertEqual(try clock.label(start: start, end: end, cancelled: false, instant: instant), "01h 00m 00s")
        XCTAssertEqual(try clock.label(start: start, end: end, cancelled: false, instant: instant.advanced(by: .seconds(3599))), "00h 00m 01s")
        XCTAssertEqual(try clock.label(start: start, end: end, cancelled: false, instant: instant.advanced(by: .seconds(3600))), "Starting now")
        XCTAssertEqual(try clock.label(start: start, end: end, cancelled: false, instant: instant.advanced(by: .seconds(3660))), "In progress")
        XCTAssertEqual(try clock.label(start: start, end: end, cancelled: false, instant: instant.advanced(by: .seconds(7200))), "Ended")
        XCTAssertEqual(try clock.label(start: start, end: end, cancelled: true, instant: instant), "Cancelled")
        XCTAssertThrowsError(try clock.label(start: end, end: start, cancelled: false, instant: instant))
    }

    func testEventOrganizerWritesAreScopedAndRevisionCheckedWithoutPrivateRouteOverwrite() async throws {
        let current = try decodedEvent(event(role: "owner"))
        let transport = FeatureTransport([login, config(), response("{\"event\":\(event(role: "owner"))}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let input = CatalogEventInput(title: "Test event", description: "", startsAtISO: current.startsAtISO,
            endsAtISO: current.endsAtISO, timezone: "UTC", visibility: "private", capacity: 50,
            location: current.location, expectedRevision: 3)
        _ = try await client.saveEvent(input, original: current)
        let requests = await transport.history()
        XCTAssertEqual(requests[2].httpMethod, "PATCH")
        let data = try body(requests[2])
        XCTAssertEqual(data["expectedRevision"] as? Int, 3)
        XCTAssertNotNil(data["startsAtISO"] as? String)
        XCTAssertNil(data["startsAt"])
        XCTAssertNil(data["route"])
        XCTAssertNil(data["published"])
        do { _ = try await client.cancelEvent(decodedEvent()); XCTFail("Non-owner cannot cancel") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let after = await transport.history()
        XCTAssertEqual(after.count, 3)
    }

    func testSourceConflictIsSurfacedWithoutRetryingOrChangingTheDraft() async throws {
        let current = try decodedEvent(event(role: "owner"))
        let transport = FeatureTransport([login, config(),
            response(#"{"error":{"code":"event_revision_conflict","message":"Reload event before editing"}}"#, status: 409)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let input = CatalogEventInput(title: "Unsaved new title", description: "", startsAtISO: current.startsAtISO,
            endsAtISO: current.endsAtISO, timezone: "UTC", visibility: "private", capacity: 50,
            location: current.location, expectedRevision: current.revision)
        do { _ = try await client.saveEvent(input, original: current); XCTFail("Conflict must surface") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.code, "event_revision_conflict") }
        XCTAssertEqual(input.title, "Unsaved new title")
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3)
    }

    func testPrivateEventNotFoundIsNotAnEmptySuccessOrAdminOverride() async throws {
        let transport = FeatureTransport([login, config(),
            response(#"{"error":{"code":"event_not_found","message":"Event not found"}}"#, status: 404)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        do { _ = try await client.event(eventID); XCTFail("Private unavailable event must fail") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 404) }
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 3)
    }

    func testEventInvitationCannotSilentlyRsvpOrPromoteGlobalRoles() async throws {
        let transport = FeatureTransport([login, config(), response(#"{"invited":true,"automaticRsvp":false}"#),
            response(#"{"invited":true,"automaticRsvp":true}"#)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let current = try decodedEvent(event(role: "owner"))
        try await client.organize(current, target: peer, action: .invite)
        do { try await client.organize(current, target: peer, action: .invite); XCTFail("Automatic RSVP must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("automatically RSVP")) }
        let requests = await transport.history()
        XCTAssertEqual(requests[2].url?.path, "/api/v1/events/\(eventID.uuidString.lowercased())/invitations")
        XCTAssertEqual(Set(try body(requests[2]).keys), Set(["userId"]))
        XCTAssertNil(try body(requests[2])["role"])
    }

    func testStaleFeatureConfirmationCannotRunAfterAccountRebind() async throws {
        let transport = FeatureTransport([login, config(), login, config()])
        let community = try await controller(transport)
        let session = CommunityFeatureSession()
        session.bind(community)
        let previous = try XCTUnwrap(session.client?.instanceID)
        community.configure("https://another.example")
        try await community.signIn(email: "test@example.invalid", password: "example test password")
        try await community.loadConfig()
        session.bind(community)
        session.run(expected: previous, { _ in XCTFail("Old confirmation must not execute") })
        XCTAssertNotNil(session.failure)
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 4)
    }

    func testInflightEventResponseIsDiscardedOnAccountOrOriginChange() async throws {
        let transport = FeatureTransport([login, config()])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let loading = Task { try await client.event(eventID) }
        await transport.waitForRequest()
        community.configure("https://another.example")
        await transport.finish(response("{\"event\":\(event())}"))
        do { _ = try await loading.value; XCTFail("Old-account data must not be accepted") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertThrowsError(try client.check())
    }

    func testAvatarMediaRejectsForeignOriginsWrongOwnersAndMixedVersions() async throws {
        let transport = FeatureTransport([login, config()])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let base = "https://catalog.example/api/v1/social/avatars/\(peer.uuidString.lowercased())/\(version.uuidString.lowercased())"
        let profile = SocialPerson(id: peer, displayName: "Peer", avatarUrl: URL(string: "\(base)/image.gif"),
            avatarPreviewUrl: URL(string: "\(base)/preview.png"), avatarAnimated: true)
        XCTAssertNoThrow(try client.validate(profile))
        var foreign = profile
        foreign.avatarUrl = URL(string: "https://other.example/image.gif")
        XCTAssertThrowsError(try client.validate(foreign))
        var wrongOwner = profile
        wrongOwner.avatarPreviewUrl = URL(string: base.replacingOccurrences(of: peer.uuidString.lowercased(), with: owner.uuidString.lowercased()) + "/preview.png")
        XCTAssertThrowsError(try client.validate(wrongOwner))
        var mixed = profile
        mixed.avatarPreviewUrl = URL(string: base.replacingOccurrences(of: version.uuidString.lowercased(), with: UUID().uuidString.lowercased()) + "/preview.png")
        XCTAssertThrowsError(try client.validate(mixed))
    }

    func testAvatarUploadHasExplicitMetadataFirstAndPreservesOneFrame() async throws {
        let gif = try MediaCodec.encode([.black(PanelSize(width: 16, height: 16))], delays: [1])
        let base = "https://catalog.example/api/v1/social/avatars/\(owner.uuidString.lowercased())/\(version.uuidString.lowercased())"
        let avatar = """
        {"userId":"\(owner)","version":"\(version)","status":"pending","createdAt":1700000000000,
        "avatarUrl":"\(base)/image.gif","avatarPreviewUrl":"\(base)/preview.png","avatarAnimated":false,"approvalMode":"ai","aiState":"queued","aiError":""}
        """
        let transport = FeatureTransport([login, config(), response(#"{"avatar":null,"uploadsEnabled":true,"approvalMode":"ai"}"#),
            response("{\"avatar\":\(avatar)}", status: 202)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        do { try await client.uploadAvatar(gif, publicConsent: false); XCTFail("Consent is required before any avatar upload") }
        catch { XCTAssertTrue(error.localizedDescription.contains("consent")) }
        try await client.uploadAvatar(gif, publicConsent: true)
        let requests = await transport.history()
        let data = try XCTUnwrap(requests[3].httpBody)
        let metadata = try XCTUnwrap(data.range(of: Data("name=\"metadata\"".utf8)))
        let file = try XCTUnwrap(data.range(of: Data("name=\"file\"".utf8)))
        XCTAssertLessThan(metadata.lowerBound, file.lowerBound)
        XCTAssertNotNil(data.range(of: Data("{\"public\":true}".utf8)))
        XCTAssertNotNil(data.range(of: gif))
        XCTAssertEqual(requests[3].url?.path, "/api/v1/social/avatar")
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "X-Catalog-Upload-Policy"))
        XCTAssertEqual(try MediaCodec.decode(gif).images.count, 1)
        XCTAssertThrowsError(try NativeAvatarInput.kind(Data(repeating: 0, count: 5_000_001)))
    }

    func testApiRootRelativeAvatarReadsResolveToPinnedOriginAndRetainAuthentication() async throws {
        let bytes = Data([1, 2, 3])
        let transport = FeatureTransport([login, config(), CommunityResponse(status: 200, data: bytes)])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let path = "/api/v1/social/avatars/\(peer.uuidString.lowercased())/\(version.uuidString.lowercased())/preview.png"
        let relative = try XCTUnwrap(URL(string: path))
        let expected = try XCTUnwrap(URL(string: "https://catalog.example" + path))
        XCTAssertEqual(try client.resolvedAvatarURL(relative), expected)
        let received = try await client.avatarMedia(relative)
        XCTAssertEqual(received, bytes)
        let requests = await transport.history()
        XCTAssertEqual(requests[2].url, expected)
        XCTAssertEqual(requests[2].httpMethod, "GET")
        XCTAssertNotNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Cookie"))
        let limits = await transport.limits()
        XCTAssertEqual(limits.last, 5_000_000)
    }

    func testRelativeAvatarResolverRejectsForeignAndNoncanonicalFormsWithoutNetwork() async throws {
        let transport = FeatureTransport([login, config()])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let prefix = "/api/v1/social/avatars/\(peer.uuidString.lowercased())/\(version.uuidString.lowercased())"
        for text in ["//evil.example\(prefix)/image.gif", "https://evil.example\(prefix)/image.gif",
                     "social/avatars/image.gif", "\(prefix)/../image.gif", "\(prefix)/%69mage.gif",
                     "\(prefix)/image.gif?token=x", "\(prefix)/image.gif#private"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertThrowsError(try client.resolvedAvatarURL(url), text)
        }
        let profile = SocialPerson(id: peer, displayName: "Peer", avatarUrl: URL(string: "\(prefix)/image.gif"),
            avatarPreviewUrl: URL(string: "\(prefix)/preview.png"), avatarAnimated: true)
        XCTAssertNoThrow(try client.validate(profile))
        let requests = await transport.history()
        XCTAssertEqual(requests.count, 2)
    }

    func testFriendsAndEventsHaveIndependentPaginationAndCapabilities() async throws {
        let transport = FeatureTransport([login, config(), response("{\"events\":[\(event())],\"serverTime\":\"2026-11-05T00:00:00Z\",\"limit\":50,\"offset\":50}")])
        let community = try await controller(transport)
        let client = try CommunityFeatureClient(community)
        let page = try await client.events(.invitations, offset: 50)
        XCTAssertEqual(page.offset, 50)
        let requests = await transport.history()
        let url = try XCTUnwrap(requests[2].url)
        XCTAssertEqual(url.path, "/api/v1/events/my-invitations")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "offset" }?.value, "50")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
    }
}
