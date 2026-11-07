import XCTest
@testable import LEDBackpack

// Prepared only: no build, decoder, test or device execution in this source slice.
@MainActor
final class ScopedPhonePreviewTests: XCTestCase {
    private let playlist = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let item = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
    private let event = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    private let scene = UUID(uuidString: "30000000-0000-4000-8000-000000000004")!
    private func card(_ path: String) throws -> NativePlaylistItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": item.uuidString, "title": "Current public GIF", "gifUrl": path,
            "previewUrl": "/unused-preview.png", "nativeSize": "32x32"
        ])
        return try JSONDecoder().decode(NativePlaylistItem.self, from: data)
    }
    private var ownerPath: String {
        "/api/v1/playlists/\(playlist.uuidString.lowercased())/items/\(item.uuidString.lowercased())/original.gif"
    }
    private var eventPath: String {
        "/api/v1/events/\(event.uuidString.lowercased())/display-plan/items/\(scene.uuidString.lowercased())/\(item.uuidString.lowercased())/original.gif"
    }
    private func content(order: NativePlaylistOrder = .inOrder) -> NativePublicPlaylistContent {
        .init(order: order, entries: [
            .init(itemId: item, durationMilliseconds: 1000),
            .init(itemId: scene, durationMilliseconds: 3000),
            .init(itemId: event, durationMilliseconds: 2000)
        ])
    }
    func testOwnerAliasUsesExactOwnerOriginalMembership() throws {
        let value = try NativeScopedPhoneAlias.owner(playlistID: playlist, item: card(ownerPath),
            origin: CommunityOrigin.parse("https://catalog.example"))
        XCTAssertEqual(value, String(ownerPath.dropFirst("/api/v1/".count)))
    }
    func testOwnerAliasCannotUseAnotherPrivatePlaylist() throws {
        XCTAssertThrowsError(try NativeScopedPhoneAlias.owner(playlistID: scene, item: card(ownerPath),
            origin: CommunityOrigin.parse("https://catalog.example")))
    }
    func testOwnerAliasCannotUseGenericPublicCatalogRoute() throws {
        XCTAssertThrowsError(try NativeScopedPhoneAlias.owner(playlistID: playlist,
            item: card("/api/v1/items/\(item)/original.gif"), origin: CommunityOrigin.parse("https://catalog.example")))
    }
    func testOriginalAliasRejectsCrossOriginAndQuery() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example")
        XCTAssertThrowsError(try NativeScopedPhoneAlias.owner(playlistID: playlist, item: card("https://other.example" + ownerPath), origin: origin))
        XCTAssertThrowsError(try NativeScopedPhoneAlias.owner(playlistID: playlist, item: card(ownerPath + "?private=1"), origin: origin))
    }
    func testOriginalAliasRejectsPreviewAndEncodedAliases() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example")
        XCTAssertThrowsError(try NativeScopedPhoneAlias.owner(playlistID: playlist,
            item: card(ownerPath.replacingOccurrences(of: "original.gif", with: "preview.png")), origin: origin))
        XCTAssertThrowsError(try NativeScopedPhoneAlias.owner(playlistID: playlist,
            item: card(ownerPath.replacingOccurrences(of: "original", with: "%6Friginal")), origin: origin))
    }
    func testEventAliasBindsCurrentSceneAndOriginal() throws {
        let value = try NativeScopedPhoneAlias.event(eventID: event, sceneID: scene, item: card(eventPath),
            origin: CommunityOrigin.parse("https://catalog.example"))
        XCTAssertEqual(value, String(eventPath.dropFirst("/api/v1/".count)))
        XCTAssertThrowsError(try NativeScopedPhoneAlias.event(eventID: event, sceneID: playlist, item: card(eventPath),
            origin: CommunityOrigin.parse("https://catalog.example")))
    }
    func testOrderedTimelineHonorsEntryDurationBoundaries() throws {
        let timeline = try NativePhonePlaylistTimeline(content())
        XCTAssertEqual(timeline.position(at: 0)?.index, 0)
        XCTAssertEqual(timeline.position(at: 0.999)?.index, 0)
        XCTAssertEqual(timeline.position(at: 1)?.index, 1)
        XCTAssertEqual(timeline.position(at: 4)?.index, 2)
    }
    func testTimelineReportsCurrentEntryRemainingTime() throws {
        let timeline = try NativePhonePlaylistTimeline(content())
        let position = try XCTUnwrap(timeline.position(at: 2))
        XCTAssertEqual(position.index, 1); XCTAssertEqual(position.elapsed, 1); XCTAssertEqual(position.remaining, 2)
    }
    func testShufflePermutesOccurrencesWithoutLosingDurations() throws {
        let timeline = try NativePhonePlaylistTimeline(content(order: .shuffle), shuffled: [2, 0, 1])
        XCTAssertEqual(timeline.position(at: 0)?.index, 2)
        XCTAssertEqual(timeline.position(at: 2)?.index, 0)
        XCTAssertEqual(timeline.position(at: 3)?.index, 1)
        XCTAssertEqual(timeline.duration, 6)
        XCTAssertEqual(timeline.offset(of: 0), 2); XCTAssertEqual(timeline.offset(of: 1), 3)
    }
    func testInvalidShufflePermutationCannotDuplicateOrOmitOccurrence() {
        XCTAssertThrowsError(try NativePhonePlaylistTimeline(content(order: .shuffle), shuffled: [0, 0, 1]))
        XCTAssertThrowsError(try NativePhonePlaylistTimeline(content(order: .shuffle), shuffled: [0, 1]))
    }
    func testTimelineFinishesOnceWithoutInventedLoop() throws {
        let timeline = try NativePhonePlaylistTimeline(content())
        XCTAssertNil(timeline.position(at: 6)); XCTAssertNil(timeline.position(at: 600))
        XCTAssertNil(timeline.position(at: -.infinity)); XCTAssertNil(timeline.position(at: .nan))
    }
    func testSolidSceneUsesNamedFirstColor() {
        let scene = NativeDisplayScene(name: "Opening", colors: ["#55CCAA", "#112233"], pattern: .solid)
        XCTAssertEqual(NativeGentlePhoneFrame.frame(scene: scene, elapsed: 20, animated: true),
            .init(hex: "#55CCAA", opacity: 1))
    }
    func testGentlePulseNeverFlashesToBlackOrExceedsOpacity() {
        let scene = NativeDisplayScene(name: "Gentle opening", pattern: .gentlePulse)
        for elapsed in [0.0, 0.5, 1, 2, 3, 4, 10] {
            let frame = NativeGentlePhoneFrame.frame(scene: scene, elapsed: elapsed, animated: true)
            XCTAssertGreaterThanOrEqual(frame.opacity, 0.55); XCTAssertLessThanOrEqual(frame.opacity, 1)
        }
    }
    func testAlternateSceneUsesGentleRecordedPeriod() {
        let scene = NativeDisplayScene(name: "Regroup", colors: ["#112233", "#55CCAA"], pattern: .alternate, periodMilliseconds: 4000)
        XCTAssertEqual(NativeGentlePhoneFrame.frame(scene: scene, elapsed: 3.99, animated: true).hex, "#112233")
        XCTAssertEqual(NativeGentlePhoneFrame.frame(scene: scene, elapsed: 4, animated: true).hex, "#55CCAA")
    }
    func testPausedOrLocalStillSceneDoesNotAnimate() {
        let scene = NativeDisplayScene(name: "Regroup", colors: ["#112233", "#55CCAA"], pattern: .alternate)
        XCTAssertEqual(NativeGentlePhoneFrame.frame(scene: scene, elapsed: 100, animated: false),
            .init(hex: "#112233", opacity: 1))
    }
    func testLocalPhoneOptionsDefaultToNoAwakeOrBrightnessLease() {
        let options = NativeScopedPhoneOptions()
        XCTAssertFalse(options.keepAwake); XCTAssertFalse(options.brightnessEnabled)
        XCTAssertTrue(options.animations); XCTAssertFalse(options.dataSaving)
    }
    func testSavedManualVersusAutomaticPolicyIsNotMutatedByPreview() {
        let saved = ViewerMediaPreferences(revision: 4, animationsEnabled: false, dataSaving: true)
        XCTAssertTrue(saved.permitsAnimation(reducedMotion: true, manual: true))
        XCTAssertFalse(saved.permitsAnimation(reducedMotion: false, manual: false))
        XCTAssertEqual(saved.revision, 4); XCTAssertFalse(saved.animationsEnabled); XCTAssertTrue(saved.dataSaving)
    }
    func testExpiredLeaseCannotBeExtendedByConstructingPreviewSurface() throws {
        let request = NativePlaylistPreviewRequest(accountID: playlist, accountEpoch: scene, playlistID: playlist,
            revision: 1, content: content(), hydratedEntries: [],
            requestStarted: ContinuousClock().now.advanced(by: .seconds(-31)))
        XCTAssertTrue(request.expired); XCTAssertTrue(NativeScopedPhoneSource.playlist(request).expired)
        XCTAssertEqual(NativeScopedPhoneSource.playlist(request).remainingLease, 0)
    }
}
