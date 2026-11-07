import XCTest
import BackpackProtocol
@testable import LEDBackpack

actor PlaylistSourceTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var pending: CheckedContinuation<CommunityResponse, Error>?
    private var notification: CheckedContinuation<Void, Never>?
    private var waiting = false
    private var requests: [URLRequest] = []
    private var budgets: [Int] = []
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        budgets.append(maxBytes)
        if !replies.isEmpty { return replies.removeFirst() }
        waiting = true; notification?.resume(); notification = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForRequest() async {
        if waiting { return }
        await withCheckedContinuation { notification = $0 }
    }
    func finish(_ response: CommunityResponse) { pending?.resume(returning: response); pending = nil }
    func history() -> [URLRequest] { requests }
    func limits() -> [Int] { budgets }
}
@MainActor
final class PlaylistSourceVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

// Prepared fixtures only. No test/build/typecheck execution accompanies this slice.
@MainActor
final class OwnerPlaylistSourceTests: XCTestCase {
    private let ownerID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let playlistID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let itemID = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    private let shareID = UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
    private let token = String(repeating: "A", count: 43)
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    private func content() -> NativePlaylistContent {
        .init(title: "Private owner title", description: "Private notes", entries: [
            .init(itemId: itemID, durationMilliseconds: 10000)], order: .inOrder,
            schedule: .init(enabled: true, time: "13:00", timezone: "UTC", days: [5]))
    }
    private func playlistObject(available: Bool = true, leakedItem: Bool = false,
                                cloud: Bool = false, item: UUID? = nil) -> [String: Any] {
        var hydration: [String: Any] = ["durationMilliseconds": 10000, "available": available]
        if available || leakedItem {
            hydration["item"] = ["id": (item ?? itemID).uuidString, "title": "Currently public mint GIF",
                "gifUrl": "/api/v1/playlists/\(playlistID.uuidString.lowercased())/items/\(itemID.uuidString.lowercased())/original.gif",
                "previewUrl": "/api/v1/playlists/\(playlistID.uuidString.lowercased())/items/\(itemID.uuidString.lowercased())/preview.png", "nativeSize": "32x32"]
        }
        return [
            "id": playlistID.uuidString, "revision": 4, "title": "Private owner title", "description": "Private notes",
            "entries": [["itemId": itemID.uuidString, "durationMilliseconds": 10000]], "order": "in-order",
            "schedule": ["enabled": true, "time": "13:00", "timezone": "UTC", "days": [5]],
            "hydratedEntries": [hydration], "scheduleExecutionVerified": false, "privateCloudIncluded": cloud
        ]
    }
    private func receipt(url: String? = nil, privateSchedule: Bool = false) throws -> NativePublishedPlaylistReceipt {
        try decode(NativePublishedPlaylistReceipt.self, [
            "id": shareID.uuidString, "url": url ?? "https://catalog.example/playlist-share/\(token)",
            "expiresAtISO": "2026-11-07T13:00:00Z", "privateScheduleIncluded": privateSchedule,
            "privateCloudIncluded": false
        ])
    }
    private func response(_ object: [String: Any], status: Int = 200) throws -> CommunityResponse {
        .init(status: status, data: try JSONSerialization.data(withJSONObject: object))
    }
    private func controller(_ transport: PlaylistSourceTransport) async throws -> CommunityController {
        let community = CommunityController(vault: PlaylistSourceVault(), factory: { _ in transport })
        community.configure("https://catalog.example")
        try await community.signIn(email: "owner@example.invalid", password: "fixture-password-not-real")
        try await community.loadConfig()
        return community
    }
    private func initialResponses(enabled: Bool = true) throws -> [CommunityResponse] {
        [
            try response(["user": ["id": ownerID.uuidString, "email": "owner@example.invalid",
                "displayName": "Owner", "role": "user", "verified": true],
                "token": "fixture-only-session-not-real", "expiresAt": "2099-01-01T00:00:00Z"]),
            try response(["requireEmailVerification": false, "playlistsEnabled": enabled])
        ]
    }

    func testMissingScheduleEncodesExplicitNull() throws {
        var value = content(); value.schedule = nil
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertTrue(body["schedule"] is NSNull)
    }
    func testPublicSceneSnapshotContainsReferencesNotPrivateTextOrSchedule() throws {
        let value = try decode(NativeOwnerPlaylist.self, playlistObject())
        let scene = try value.sceneSnapshot()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(scene)) as? [String: Any])
        XCTAssertNil(body["title"]); XCTAssertNil(body["description"]); XCTAssertNil(body["schedule"])
        XCTAssertEqual(scene.entries.first?.itemId, itemID); XCTAssertEqual(scene.order, .inOrder)
    }
    func testPublicDraftNeverAutofillsPrivateText() {
        let value = NativePlaylistPublishDraft()
        XCTAssertTrue(value.title.isEmpty); XCTAssertTrue(value.description.isEmpty); XCTAssertFalse(value.consent)
    }
    func testPublishRequiresSeparateExplicitConsent() {
        var value = NativePlaylistPublishDraft(); value.title = "Public title"
        XCTAssertThrowsError(try value.validate())
        value.consent = true; XCTAssertNoThrow(try value.validate())
    }
    func testPublicExpiryIsBoundedWithoutSilentExtension() {
        var value = NativePlaylistPublishDraft(); value.title = "Public"; value.consent = true
        value.expiresInHours = 0; XCTAssertThrowsError(try value.validate())
        value.expiresInHours = 169; XCTAssertThrowsError(try value.validate())
        value.expiresInHours = 1; XCTAssertNoThrow(try value.validate())
    }
    func testPrivateCloudInclusionClaimIsRejected() throws {
        let value = try decode(NativeOwnerPlaylist.self, playlistObject(cloud: true))
        XCTAssertThrowsError(try value.validate())
    }
    func testUnavailableHydrationCannotExposeItemMetadata() throws {
        let value = try decode(NativeOwnerPlaylist.self, playlistObject(available: false, leakedItem: true))
        XCTAssertThrowsError(try value.validate())
    }
    func testHydratedItemMustMatchSavedPublicReference() throws {
        let value = try decode(NativeOwnerPlaylist.self, playlistObject(item: shareID))
        XCTAssertThrowsError(try value.validate())
    }
    func testUnavailableReferenceCannotBeCopiedIntoEventScene() throws {
        let value = try decode(NativeOwnerPlaylist.self, playlistObject(available: false))
        try value.validate(); XCTAssertNil(value.hydratedEntries.first?.item)
        XCTAssertThrowsError(try value.sceneSnapshot())
    }
    func testDurationBoundsAreOneToSixHundredSeconds() {
        var value = content()
        value.entries[0].durationMilliseconds = 999; XCTAssertThrowsError(try value.validate())
        value.entries[0].durationMilliseconds = 600001; XCTAssertThrowsError(try value.validate())
        value.entries[0].durationMilliseconds = 1000; XCTAssertNoThrow(try value.validate())
    }
    func testScheduleRequiresDistinctValidSelectedDays() {
        var value = NativePlaylistSchedule()
        value.days = []; XCTAssertThrowsError(try value.validate())
        value.days = [1, 1]; XCTAssertThrowsError(try value.validate())
        value.days = [7]; XCTAssertThrowsError(try value.validate())
        value.days = [0, 6]; XCTAssertNoThrow(try value.validate())
    }
    func testScheduleRejectsInvalidTimeAndTimezone() {
        var value = NativePlaylistSchedule()
        value.time = "25:00"; XCTAssertThrowsError(try value.validate())
        value.time = "13:00"; value.timezone = "Not/AZone"; XCTAssertThrowsError(try value.validate())
    }
    func testScheduleMatchesOnlyExplicitLocalWeekdayAndMinute() throws {
        let value = NativePlaylistSchedule(enabled: true, time: "13:00", timezone: "UTC", days: [5])
        XCTAssertNotNil(try value.occurrence(at: CatalogEventTime.parse("2026-11-06T13:00:20Z")))
        XCTAssertNil(try value.occurrence(at: CatalogEventTime.parse("2026-11-06T13:01:00Z")))
        XCTAssertNil(try value.occurrence(at: CatalogEventTime.parse("2026-11-07T13:00:00Z")))
    }
    func testForegroundScheduleDefaultsDisarmed() throws {
        var state = NativeForegroundScheduleState()
        XCTAssertFalse(state.armed)
        XCTAssertFalse(try state.due(schedule: content().schedule, at: CatalogEventTime.parse("2026-11-06T13:00:00Z"), foreground: true))
    }
    func testScheduleCannotRunWhenNotForeground() throws {
        var state = NativeForegroundScheduleState(); state.arm(explicitConsent: true)
        XCTAssertFalse(try state.due(schedule: content().schedule, at: CatalogEventTime.parse("2026-11-06T13:00:00Z"), foreground: false))
    }
    func testScheduleDoesNotRepeatSameLocalOccurrence() throws {
        var state = NativeForegroundScheduleState(); state.arm(explicitConsent: true)
        let date = try CatalogEventTime.parse("2026-11-06T13:00:00Z")
        XCTAssertTrue(state.due(schedule: content().schedule, at: date, foreground: true))
        XCTAssertFalse(state.due(schedule: content().schedule, at: date.addingTimeInterval(30), foreground: true))
    }
    func testStoppingScheduleErasesForegroundArming() {
        var state = NativeForegroundScheduleState(); state.arm(explicitConsent: true); state.stop()
        XCTAssertFalse(state.armed); XCTAssertNil(state.lastOccurrence)
    }
    func testShareReceiptMustUseConfiguredOrigin() throws {
        let value = try receipt(url: "https://other.example/playlist-share/\(token)")
        XCTAssertThrowsError(try value.validate(origin: CommunityOrigin.parse("https://catalog.example")))
    }
    func testShareURLRejectsQueryAndNoncanonicalToken() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example")
        XCTAssertThrowsError(try receipt(url: "https://catalog.example/playlist-share/\(token)?private=1").validate(origin: origin))
        XCTAssertThrowsError(try receipt(url: "https://catalog.example/playlist-share/not-a-token").validate(origin: origin))
    }
    func testShareReceiptMustNotIncludePrivateSchedule() throws {
        XCTAssertThrowsError(try receipt(privateSchedule: true).validate(origin: CommunityOrigin.parse("https://catalog.example")))
    }
    func testPublishedSnapshotIdentityIsNotPrivatePlaylistIdentity() throws {
        let value = try receipt()
        XCTAssertEqual(value.publishedID, NativePublishedPlaylistID(value: shareID))
        XCTAssertNotEqual(value.publishedID.value, playlistID)
    }
    func testPublicSnapshotRejectsPrivateCloudOrScheduleClaim() throws {
        let value = try decode(NativePublicPlaylistSnapshot.self, [
            "title": "Explicit public title", "description": "", "order": "in-order",
            "entries": [["durationMilliseconds": 1000, "available": false]],
            "expiresAtISO": "2026-11-07T13:00:00Z", "privateScheduleIncluded": true, "privateCloudIncluded": false
        ])
        XCTAssertThrowsError(try value.validate())
    }
    func testDisabledServerNeverIssuesPlaylistRequest() async throws {
        let transport = PlaylistSourceTransport(try initialResponses(enabled: false))
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.ownerPlaylists(page: 1); XCTFail("Missing feature must remain unavailable") }
        catch { }
        let requests = await transport.history()
        XCTAssertFalse(requests.contains { $0.url?.path.contains("/playlists") == true })
    }
    func testLatePrivatePlaylistReadAfterAccountOriginChangeIsRejected() async throws {
        let transport = PlaylistSourceTransport(try initialResponses())
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        let task = Task { try await client.ownerPlaylist(playlistID) }
        await transport.waitForRequest()
        community.configure("https://other.example")
        await transport.finish(try response(["playlist": playlistObject()]))
        do { _ = try await task.value; XCTFail("Late private content must not be accepted") }
        catch { }
    }
    private var originalGIF: Data {
        Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0,
              0, 0, 0, 255, 255, 255, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3b])
    }
    private func phoneSource(_ client: CommunityFeatureClient, expired: Bool = false) throws -> NativeScopedPhoneSource {
        let value = try decode(NativeOwnerPlaylist.self, playlistObject())
        return .playlist(.init(accountID: client.accountID, accountEpoch: client.revision, playlistID: playlistID,
            revision: value.revision, content: value.content.publicReferences, hydratedEntries: value.hydratedEntries,
            requestStarted: ContinuousClock().now.advanced(by: .seconds(expired ? -31 : 0))))
    }
    func testScopedPhoneReadsOnlyExactBoundedOwnerOriginalAlias() async throws {
        let metadata = try response(["playlist": playlistObject()])
        let transport = PlaylistSourceTransport(try initialResponses() + [metadata, .init(status: 200, data: originalGIF), metadata])
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        let bytes = try await client.scopedPhoneOriginal(phoneSource(client), index: 0)
        XCTAssertEqual(bytes, originalGIF)
        let requests = await transport.history(), budgets = await transport.limits()
        let media = requests.filter { $0.url?.path.hasSuffix("/original.gif") == true }
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media.first?.url?.path, "/api/v1/playlists/\(playlistID.uuidString.lowercased())/items/\(itemID.uuidString.lowercased())/original.gif")
        XCTAssertTrue(budgets.contains(5_000_000))
    }
    func testScopedPhoneRejectsStaleRevisionBeforeAnyMediaRead() async throws {
        var changed = playlistObject(); changed["revision"] = 5
        let transport = PlaylistSourceTransport(try initialResponses() + [response(["playlist": changed])])
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.scopedPhoneOriginal(phoneSource(client), index: 0); XCTFail("Stale revision must stop before media") }
        catch { }
        let history = await transport.history()
        XCTAssertFalse(history.contains { $0.url?.path.hasSuffix("/original.gif") == true })
    }
    func testScopedPhoneRejectsRevisionChangedAfterOriginalIO() async throws {
        var changed = playlistObject(); changed["revision"] = 5
        let transport = PlaylistSourceTransport(try initialResponses() + [
            response(["playlist": playlistObject()]), .init(status: 200, data: originalGIF), response(["playlist": changed])])
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.scopedPhoneOriginal(phoneSource(client), index: 0); XCTFail("Late old-revision bytes must not escape") }
        catch { }
    }
    func testScopedPhoneRejectsPolicyChangeDuringOriginalIO() async throws {
        let transport = PlaylistSourceTransport(try initialResponses() + [response(["playlist": playlistObject()])])
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        let source = try phoneSource(client)
        let task = Task { try await client.scopedPhoneOriginal(source, index: 0) }
        await transport.waitForRequest()
        community.applyViewerPreferences(.init(revision: 2, animationsEnabled: false, dataSaving: true))
        await transport.finish(.init(status: 200, data: originalGIF))
        do { _ = try await task.value; XCTFail("Old-policy bytes must be cleared without retry") }
        catch { }
    }
    func testScopedPhoneExpiredLeaseNeverReadsMedia() async throws {
        let transport = PlaylistSourceTransport(try initialResponses())
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.scopedPhoneOriginal(phoneSource(client, expired: true), index: 0); XCTFail("Expired lease must not renew") }
        catch { }
        let history = await transport.history()
        XCTAssertFalse(history.contains { $0.url?.path.hasSuffix("/original.gif") == true })
    }
    func testScopedPhoneCancellationRejectsLateOriginalBytes() async throws {
        let transport = PlaylistSourceTransport(try initialResponses() + [response(["playlist": playlistObject()])])
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        let source = try phoneSource(client)
        let task = Task { try await client.scopedPhoneOriginal(source, index: 0) }
        await transport.waitForRequest(); task.cancel()
        await transport.finish(.init(status: 200, data: originalGIF))
        do { _ = try await task.value; XCTFail("Cancelled media must not be accepted") }
        catch { }
    }
    func testScopedPhoneUnavailableOriginalDoesNotUseCachedItem() async throws {
        let transport = PlaylistSourceTransport(try initialResponses() + [response(["playlist": playlistObject(available: false)])])
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.scopedPhoneOriginal(phoneSource(client), index: 0); XCTFail("Unavailable membership must not use a cached alias") }
        catch { }
        let history = await transport.history()
        XCTAssertFalse(history.contains { $0.url?.path.hasSuffix("/original.gif") == true })
    }
    func testScopedPhoneStopAndLeaveNeverOwnGlobalPhoneOrJournal() async throws {
        let transport = PlaylistSourceTransport(try initialResponses())
        let community = try await controller(transport), client = try CommunityFeatureClient(community)
        let runtime = NativeScopedPhonePreview()
        runtime.bind(source: try phoneSource(client), client: client, community: community, reducedMotion: false)
        XCTAssertNil(runtime.phone); XCTAssertFalse(runtime.playing)
        runtime.stop(); runtime.leave()
        XCTAssertNil(runtime.phone); XCTAssertFalse(runtime.loading); XCTAssertFalse(runtime.playing)
        let history = await transport.history()
        XCTAssertFalse(history.contains { $0.url?.path.hasSuffix("/original.gif") == true })
    }
}
