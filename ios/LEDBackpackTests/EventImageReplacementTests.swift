import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

private actor ReplacementTestTransport: CommunityTransport {
    var responses: [CommunityResponse]
    var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected replacement mock request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class ReplacementTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class EventImageReplacementTests: XCTestCase {
    private let eventID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let userID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private func image(_ id: UUID = UUID(), revision: Int = 3, approved: Bool = true) throws -> NativeEventImage {
        try JSONDecoder().decode(NativeEventImage.self, from: Data(#"{"id":"\#(id)","caption":"Caption","alt":"Accessible description","byteSize":100,"revision":\#(revision),"approved":\#(approved),"createdAt":"2026-11-01T00:00:00Z","url":"https://catalog.example/api/v1/events/\#(eventID.uuidString.lowercased())/assets/\#(id.uuidString.lowercased())/image.png"}"#.utf8))
    }
    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
    private func intent(_ gallery: NativeEventImages, at: Int = 0) throws -> EventImageReplacementIntent {
        try EventImageReplacementIntent(eventID: eventID, asset: gallery.assets[at], gallery: gallery,
            bytes: png(), caption: " New caption ", alt: " New alt ", permission: true)
    }
    private func setup(_ response: CommunityResponse, manage: Bool = true) async throws -> (CommunityFeatureClient, ReplacementTestTransport) {
        let login = CommunityResponse(status: 200, data: Data(#"{"user":{"id":"\#(userID)","email":"test@example.invalid","displayName":"Test","role":"admin","verified":true},"token":"synthetic-replacement-session","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8))
        let config = CommunityResponse(status: 200, data: Data(#"{"requireEmailVerification":false,"eventsEnabled":true}"#.utf8))
        let role = manage ? #""owner""# : "null"
        let organizers = manage ? #"{"id":"\#(userID)","displayName":"Test","eventRole":"owner"}"# : ""
        let event = CommunityResponse(status: 200, data: Data(#"{"event":{"id":"\#(eventID)","title":"Synthetic event","description":"","startsAtISO":"2026-11-10T15:00:00Z","endsAtISO":"2026-11-10T17:00:00Z","timezone":"UTC","visibility":"public","serverTime":"2026-11-01T00:00:00Z","capacity":20,"revision":4,"cancelled":false,"location":{"label":"Fixed venue","latitude":40,"longitude":-73,"radiusMeters":100},"status":"scheduled","rsvpStatus":null,"organizers":[\#(organizers)],"access":{"role":\#(role),"invited":false,"member":\#(manage),"canManage":\#(manage),"canManageRoute":\#(manage),"canRsvp":true,"canViewProgress":false}}}"#.utf8))
        let stub = ReplacementTestTransport([login, config, event, response])
        let controller = CommunityController(vault: ReplacementTestVault(), factory: { _ in stub })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "synthetic-password")
        try await controller.loadConfig()
        return (try CommunityFeatureClient(controller), stub)
    }
    func testFullTwentyImageSnapshotCapturesExactRevisionOrderAndMetadataFirst() throws {
        let assets = try (0..<20).map { _ in try image() }
        let gallery = NativeEventImages(assets: assets, canReorder: true, coverAssetId: assets[0].id)
        let value = try intent(gallery, at: 12)
        XCTAssertEqual(value.expectedIDs, assets.map(\.id)); XCTAssertEqual(value.previousID, assets[12].id)
        let file = try XCTUnwrap(value.data.range(of: Data("name=\"file\"".utf8)))
        let text = try XCTUnwrap(String(data: value.data.prefix(file.lowerBound), encoding: .utf8))
        XCTAssertTrue(text.contains(#""expectedRevision":3"#)); XCTAssertTrue(text.contains(#""permissionAttested":true"#))
        XCTAssertTrue(text.contains(#""expectedAssetIds""#)); XCTAssertTrue(text.contains(#""caption":"New caption""#))
        XCTAssertLessThan(try XCTUnwrap(value.data.range(of: Data("name=\"metadata\"".utf8))?.lowerBound), file.lowerBound)
        let start = try XCTUnwrap(value.data.range(of: Data("\r\n\r\n".utf8))).upperBound
        let end = try XCTUnwrap(value.data.range(of: Data("\r\n--".utf8), in: start..<value.data.endIndex)).lowerBound
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: value.data.subdata(in: start..<end)) as? [String: Any])
        XCTAssertEqual(metadata["expectedAssetIds"] as? [String], assets.map { $0.id.uuidString.lowercased() })
    }
    func testImmutableCoverIdentityPositionAndApprovalMustBeConfirmed() throws {
        let first = try image(), second = try image(), replacement = try image(approved: false)
        let gallery = NativeEventImages(assets: [first, second], canReorder: true, coverAssetId: first.id)
        let value = try intent(gallery)
        try value.verify(NativeEventImages(assets: [replacement, second], canReorder: true, coverAssetId: replacement.id), newID: replacement.id)
        XCTAssertThrowsError(try value.verify(gallery, newID: first.id))
        XCTAssertThrowsError(try value.verify(NativeEventImages(assets: [second, replacement], canReorder: true, coverAssetId: second.id), newID: replacement.id))
        XCTAssertThrowsError(try value.verify(NativeEventImages(assets: [try image(replacement.id), second], canReorder: true, coverAssetId: replacement.id), newID: replacement.id))
    }
    func testConflictRetainsCapturedBytesAndDoesNotAutomaticallyRebaseOrRetry() async throws {
        let old = try image(), gallery = NativeEventImages(assets: [old], canReorder: true, coverAssetId: old.id)
        let value = try intent(gallery), data = value.data
        let (client, stub) = try await setup(CommunityResponse(status: 409, data: Data(#"{"error":{"code":"event_asset_conflict","message":"Image/order changed"}}"#.utf8)))
        do { _ = try await client.replaceEventImage(value); XCTFail("Expected conflict") }
        catch let error as CommunityFailure { XCTAssertEqual(error.status, 409) }
        XCTAssertEqual(value.data, data); XCTAssertEqual(value.expectedIDs, [old.id])
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 4); XCTAssertEqual(requests[3].httpBody, data)
        XCTAssertEqual(requests[3].url?.path, "/api/v1/events/\(eventID.uuidString.lowercased())/assets/\(old.id.uuidString.lowercased())/replace")
    }
    func testAdminCannotReplaceWithoutCurrentEventOrganizerAccess() async throws {
        let old = try image(), gallery = NativeEventImages(assets: [old], canReorder: true, coverAssetId: old.id)
        let (client, stub) = try await setup(CommunityResponse(status: 200, data: Data()), manage: false)
        do { _ = try await client.replaceEventImage(intent(gallery)); XCTFail("No admin bypass") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 3)
    }
    func testRasterAndPermissionLimitsRejectUnsafeInput() throws {
        _ = try EventImageReplacementIntent.raster(png())
        XCTAssertThrowsError(try EventImageReplacementIntent.raster(Data("GIF89a".utf8)))
        XCTAssertThrowsError(try EventImageReplacementIntent.raster(Data(repeating: 0, count: 5_000_001)))
        let old = try image(), gallery = NativeEventImages(assets: [old], canReorder: true, coverAssetId: old.id)
        XCTAssertThrowsError(try EventImageReplacementIntent(eventID: eventID, asset: old, gallery: gallery, bytes: png(), caption: "", alt: "Alt", permission: false))
        XCTAssertThrowsError(try EventImageReplacementIntent(eventID: eventID, asset: old, gallery: gallery, bytes: png(), caption: "", alt: String(repeating: "a", count: 501), permission: true))
        XCTAssertThrowsError(try NativeEventImages(assets: [old, old], canReorder: true, coverAssetId: old.id).validate())
    }
    func testAcceptedReceiptCannotReuseOldIdentityOrPublicApproval() async throws {
        let old = try image(), gallery = NativeEventImages(assets: [old], canReorder: true, coverAssetId: old.id)
        let response = CommunityResponse(status: 201, data: Data(#"{"asset":{"id":"\#(old.id)","caption":"New","alt":"New","byteSize":100,"approved":true,"revision":4,"createdAt":"2026-11-01T00:00:00Z","url":"https://catalog.example/api/v1/events/\#(eventID)/assets/\#(old.id)/image.png"},"replacedAssetId":"\#(old.id)"}"#.utf8))
        let (client, _) = try await setup(response)
        do { _ = try await client.replaceEventImage(intent(gallery)); XCTFail("Invalid receipt must not succeed") } catch {}
    }
}
