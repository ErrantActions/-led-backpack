import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class EventBuilderGalleryTests: XCTestCase {
    private func input(_ event: CatalogEvent) -> CatalogEventInput {
        CatalogEventInput(title: event.title, description: event.description,
            startsAtISO: event.startsAtISO, endsAtISO: event.endsAtISO, timezone: event.timezone,
            visibility: event.visibility, capacity: event.capacity, location: event.location,
            expectedRevision: event.revision, kind: event.kind)
    }
    private func image(_ id: UUID = UUID(), revision: Int = 3) throws -> NativeEventImage {
        let url = try XCTUnwrap(URL(string: "https://catalog.example.invalid/api/v1/events/\(NativeEventScopeFixtures.eventID)/assets/\(id.uuidString.lowercased())/image.png"))
        return NativeEventImage(id: id, caption: "Caption", alt: "Accessible still", createdAt: "2026-11-01T00:00:00Z",
            byteSize: 100, revision: revision, approved: false, url: url)
    }
    private func gallery(count: Int = 2) throws -> NativeEventImages {
        let assets = try (0..<count).map { _ in try image() }
        return NativeEventImages(assets: assets, canReorder: true, coverAssetId: assets.first?.id)
    }
    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
    func testUnchangedDefinitionRetainsExactOriginalSecondsAndMilliseconds() throws {
        let event = try NativeEventScopeFixtures.event()
        let review = try NativeEventDefinitionReview(input: input(event), original: event, scope: UUID())
        XCTAssertEqual(review.input.startsAtISO, "2026-11-10T15:00:12.345Z")
        XCTAssertEqual(review.input.endsAtISO, "2026-11-10T17:00:23.678Z")
        XCTAssertTrue(review.matches(input(event)))
    }
    func testInvalidIANATimezoneAndInvalidScheduleNeverDefaultSilently() throws {
        var value = input(try NativeEventScopeFixtures.event())
        value.timezone = "Not/A_Zone"; XCTAssertThrowsError(try value.validate())
        value.timezone = "America/New_York"; value.endsAtISO = value.startsAtISO
        XCTAssertThrowsError(try value.validate())
        value.endsAtISO = "not-a-time"; XCTAssertThrowsError(try value.validate())
    }
    func testUnlistedReviewCapturesExplicitLinkConsent() throws {
        let event = try NativeEventScopeFixtures.event()
        var value = input(event); value.visibility = "unlisted"; value.unlistedLinkConsent = true
        let review = try NativeEventDefinitionReview(input: value, original: event, scope: UUID())
        let text = String(decoding: review.bytes, as: UTF8.self)
        XCTAssertTrue(text.contains(#""unlistedLinkConsent":true"#)); XCTAssertTrue(text.contains(#""visibility":"unlisted""#))
    }
    func testPublicAndUnlistedToPrivateReviewDisclosesMembershipRetention() throws {
        for visibility in ["public", "unlisted"] {
            let event = try NativeEventScopeFixtures.event(visibility: visibility)
            var value = input(event); value.visibility = "private"
            XCTAssertTrue(try NativeEventDefinitionReview(input: value, original: event, scope: UUID()).retainsMembership)
        }
    }
    func testDefinitionInputAndRevisionChangesInvalidateCapturedReview() throws {
        let event = try NativeEventScopeFixtures.event()
        var value = input(event)
        let review = try NativeEventDefinitionReview(input: value, original: event, scope: UUID())
        value.location.radiusMeters = 200; XCTAssertFalse(review.matches(value))
        value = input(event); value.expectedRevision = 5; XCTAssertFalse(review.matches(value))
        XCTAssertFalse(review.matches(nil))
    }
    func testRouteAndEventDraftsHaveDisjointSavePayloads() throws {
        let event = try NativeEventScopeFixtures.event()
        let definition = try NativeEventDefinitionReview(input: input(event), original: event, scope: UUID())
        let route = try NativeEventRouteReview(EventRouteDraft(event))
        XCTAssertFalse(String(decoding: definition.bytes, as: UTF8.self).contains("checkpoints"))
        XCTAssertFalse(String(decoding: route.bytes, as: UTF8.self).contains(event.startsAtISO))
        XCTAssertFalse(String(decoding: route.bytes, as: UTF8.self).contains(event.title))
    }
    func testLoopStartAndFinishUseDistinctIDsEvenAtSameCoordinates() throws {
        var draft = try EventRouteDraft(NativeEventScopeFixtures.event())
        let point = EventCoordinate(latitude: 40, longitude: -73)
        try draft.addCheckpoint(.start, at: point); try draft.addCheckpoint(.finish, at: point); draft.published = true
        try draft.body.validate()
        XCTAssertNotEqual(draft.checkpoints.first?.id, draft.checkpoints.last?.id)
        XCTAssertEqual(draft.checkpoints.first?.point, draft.checkpoints.last?.point)
    }
    func testOptionalStartAndFinishAreRejected() throws {
        for kind in [EventCheckpointKind.start, .finish] {
            let value = EventRouteCheckpoint(title: "Required endpoint", kind: kind, latitude: 40, longitude: -73,
                radiusMeters: 100, order: 0, optional: true)
            XCTAssertThrowsError(try value.validate())
        }
    }
    func testLegacyOptionalAndArtworkAssignmentsSurviveNormalization() throws {
        var draft = try EventRouteDraft(NativeEventScopeFixtures.event())
        try draft.addCheckpoint(.checkpoint, at: .init(latitude: 40, longitude: -73))
        let artwork = UUID(); draft.checkpoints[0].optional = true; draft.checkpoints[0].exclusiveGifId = artwork
        let normalized = draft.body.normalized()
        XCTAssertEqual(normalized.checkpoints[0].optional, true); XCTAssertEqual(normalized.checkpoints[0].exclusiveGifId, artwork)
    }
    func testRouteEditsDuringAcknowledgementRemainDistinctFromCapturedPayload() throws {
        var draft = try EventRouteDraft(NativeEventScopeFixtures.event())
        try draft.addCheckpoint(.checkpoint, at: .init(latitude: 40, longitude: -73))
        let review = try NativeEventRouteReview(draft), bytes = review.bytes
        draft.checkpoints[0].title = "New edit typed during save"
        XCTAssertFalse(review.matches(draft)); XCTAssertEqual(review.bytes, bytes)
    }
    func testLocalRasterPreviewDecodesWithoutChangingOriginalBytes() throws {
        let bytes = png(), raster = try NativeEventRaster(bytes)
        XCTAssertEqual(raster.bytes, bytes); XCTAssertFalse(raster.preview.isEmpty)
        XCTAssertEqual(raster.kind.mime, "image/png"); XCTAssertNotNil(UIImage(data: raster.preview))
    }
    func testRasterRejectsPDFVideoAndOversizeInput() throws {
        XCTAssertThrowsError(try NativeEventRaster(Data("%PDF-1.7".utf8)))
        XCTAssertThrowsError(try NativeEventRaster(Data("video-not-a-still".utf8)))
        XCTAssertThrowsError(try NativeEventRaster(Data(repeating: 0, count: 5_000_001)))
    }
    func testStagedMultipartIsMetadataFirstAndCapturesPermissionDescriptions() throws {
        let event = try NativeEventScopeFixtures.event(), images = try gallery()
        let intent = try NativeEventGalleryIntent(event: event, gallery: images, action: .upload,
            scope: UUID(), draftVersion: UUID(), caption: " New caption ", alt: " New alt ",
            raster: NativeEventRaster(png()), permission: true)
        let body = try XCTUnwrap(intent.body)
        let metadata = try XCTUnwrap(body.range(of: Data("name=\"metadata\"".utf8)))
        let file = try XCTUnwrap(body.range(of: Data("name=\"file\"".utf8)))
        XCTAssertLessThan(metadata.lowerBound, file.lowerBound)
        let text = String(decoding: body.prefix(file.lowerBound), as: UTF8.self)
        XCTAssertTrue(text.contains(#""permissionAttested":true"#)); XCTAssertTrue(text.contains(#""alt":"New alt""#))
        XCTAssertFalse(text.contains("GPS")); XCTAssertFalse(text.contains("expectedAssetIds"))
    }
    func testUncheckedPermissionAndFullTwentyGalleryRejectNewUpload() throws {
        let event = try NativeEventScopeFixtures.event()
        let raster = try NativeEventRaster(png())
        XCTAssertThrowsError(try NativeEventGalleryIntent(event: event, gallery: gallery(), action: .upload,
            scope: UUID(), draftVersion: UUID(), alt: "Typed alt", raster: raster, permission: false))
        XCTAssertThrowsError(try NativeEventGalleryIntent(event: event, gallery: gallery(count: 20), action: .upload,
            scope: UUID(), draftVersion: UUID(), alt: "Typed alt", raster: raster, permission: true))
    }
    func testFullOrderPinsExpectedIDsAndFirstImageCoverWithoutApprovingIt() throws {
        let event = try NativeEventScopeFixtures.event(), images = try gallery()
        let desired = Array(images.assets.map(\.id).reversed())
        let intent = try NativeEventGalleryIntent(event: event, gallery: images, action: .order(desired), scope: UUID(), draftVersion: UUID())
        let text = String(decoding: try XCTUnwrap(intent.body), as: UTF8.self)
        XCTAssertTrue(text.contains("expectedAssetIds")); XCTAssertTrue(text.contains("assetIds"))
        XCTAssertFalse(text.contains("approved")); XCTAssertEqual(desired.first, images.assets.last?.id)
        XCTAssertThrowsError(try NativeEventGalleryIntent(event: event, gallery: images, action: .order([desired[0]]), scope: UUID(), draftVersion: UUID()))
    }
    func testMetadataEditCapturesActualAssetRevisionAndTrimsTypedLiteralFields() throws {
        let event = try NativeEventScopeFixtures.event(), images = try gallery()
        let asset = images.assets[0]
        let intent = try NativeEventGalleryIntent(event: event, gallery: images, action: .metadata(asset.id, asset.revision),
            scope: UUID(), draftVersion: UUID(), caption: " <literal> ", alt: " Accessible ")
        let text = String(decoding: try XCTUnwrap(intent.body), as: UTF8.self)
        XCTAssertTrue(text.contains(#""expectedRevision":3"#)); XCTAssertTrue(text.contains(#""caption":"<literal>""#))
        XCTAssertThrowsError(try NativeEventGalleryIntent(event: event, gallery: images, action: .metadata(asset.id, 2),
            scope: UUID(), draftVersion: UUID(), alt: "Accessible"))
    }
    func testGalleryConflictRetainsImmutableChoicesRatherThanRebasing() throws {
        let event = try NativeEventScopeFixtures.event(), images = try gallery()
        let intent = try NativeEventGalleryIntent(event: event, gallery: images, action: .order(images.assets.map(\.id)), scope: UUID(), draftVersion: UUID())
        let reordered = NativeEventImages(assets: Array(images.assets.reversed()), canReorder: true, coverAssetId: images.assets.last?.id)
        XCTAssertThrowsError(try intent.check(event, gallery: reordered))
        XCTAssertEqual(intent.gallery.assets.map(\.id), images.assets.map(\.id))
    }
    func testRoleAndHeldContextChangesRejectGalleryAuthority() throws {
        let event = try NativeEventScopeFixtures.event(), images = try gallery()
        let intent = try NativeEventGalleryIntent(event: event, gallery: images, action: .order(images.assets.map(\.id)), scope: UUID(), draftVersion: UUID())
        XCTAssertThrowsError(try intent.check(NativeEventScopeFixtures.event(role: "coorganizer"), gallery: images))
        XCTAssertThrowsError(try intent.check(NativeEventScopeFixtures.event(held: true), gallery: images))
        XCTAssertThrowsError(try NativeEventGalleryIntent(event: NativeEventScopeFixtures.event(role: nil), gallery: images,
            action: .order(images.assets.map(\.id)), scope: UUID(), draftVersion: UUID()))
    }
    func testLateFileSelectionIsDroppedBeforeReadingAnyURL() throws {
        let store = EventGalleryStore()
        let file = try XCTUnwrap(URL(string: "file:///C:/unread-synthetic-event-image.png"))
        XCTAssertThrowsError(try store.stage(file, context: UUID()))
        XCTAssertNil(store.raster)
    }
    func testAccountAccessClearDropsStaleGalleryRequestsAndMetadata() throws {
        let store = EventGalleryStore()
        let event = try NativeEventScopeFixtures.event(), images = try gallery()
        store.caption = "Draft"; store.alt = "Alt"; store.permission = true
        store.intent = try NativeEventGalleryIntent(event: event, gallery: images, action: .order(images.assets.map(\.id)), scope: UUID(), draftVersion: UUID())
        let context = store.contextVersion
        store.clear()
        XCTAssertNil(store.intent); XCTAssertNil(store.event); XCTAssertNil(store.gallery); XCTAssertNil(store.raster)
        XCTAssertEqual(store.caption, ""); XCTAssertFalse(store.permission); XCTAssertNotEqual(store.contextVersion, context)
    }
    func testNewDraftVersionCannotReplayAnOldAcknowledgedChoice() throws {
        let store = EventGalleryStore()
        let event = try NativeEventScopeFixtures.event(), images = try gallery()
        let intent = try NativeEventGalleryIntent(event: event, gallery: images, action: .order(images.assets.map(\.id)),
            scope: UUID(), draftVersion: store.draftVersion)
        store.caption = "New local edit"
        store.apply(intent)
        XCTAssertNil(store.intent); XCTAssertEqual(store.caption, "New local edit")
    }
    func testNumericAlternativesRequireExplicitValidCoordinatesWithoutImageryConsent() throws {
        XCTAssertThrowsError(try NativeEventFixedPointInput.parse(latitude: "", longitude: ""))
        XCTAssertThrowsError(try NativeEventFixedPointInput.parse(latitude: "91", longitude: "0"))
        XCTAssertThrowsError(try NativeEventFixedPointInput.parse(latitude: "nan", longitude: "-73"))
        let point = try NativeEventFixedPointInput.parse(latitude: " 40.125 ", longitude: "-73.5")
        XCTAssertEqual(point.latitude, 40.125); XCTAssertEqual(point.longitude, -73.5)
    }
    func testExplicitOptionalFalseRemainsInRequestButMatchesServerRequiredOmission() throws {
        var value = EventRouteCheckpoint(title: "Intermediate", kind: .checkpoint, latitude: 40, longitude: -73, radiusMeters: 100, order: 0)
        var request = value; request.optional = false
        XCTAssertTrue(request.matchesReturned(value))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains(#""optional":false"#))
        value.optional = true; XCTAssertFalse(request.matchesReturned(value))
    }
}
