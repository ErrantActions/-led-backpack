import XCTest
import CryptoKit
import UIKit
import BackpackProtocol
@testable import LEDBackpack

private actor AccountParityTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var requests: [URLRequest] = []
    private var suspendNext = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected account fixture request.") }
        let reply = replies.removeFirst()
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { continuation in
                suspended = continuation; ready?.resume(); ready = nil
            }
        }
        guard reply.data.count <= maxBytes else { throw BackpackError.invalid("Fixture response exceeds requested byte budget.") }
        return reply
    }
    func armSuspension() { suspendNext = true }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func resume() { suspended?.resume(); suspended = nil }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class AccountParityVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class AccountNativeParityTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let itemID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let other = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let token = String(repeating: "A", count: 43)
    private let allCapabilities = #""unverifiedDeviceTagsEnabled":true,"firmwareCatalogEnabled":true,"firmwareMaxUploadBytes":16777216,"deviceResearchEnabled":true,"adminBulkModerationEnabled":true,"uploadAbuseMonitoringEnabled":true,"avatarsEnabled":true,"avatarUploadsEnabled":true,"avatarApprovalMode":"ai","avatarCropsEnabled":true,"socialEnabled":true,"viewerMediaPreferencesEnabled":true,"nativeSizeFiltersEnabled":true"#
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(type, from: data(json)) }
    private func gif() -> Data {
        var bytes = Data("GIF89a".utf8)
        bytes.append(contentsOf: [1,0,1,0,0x80,0,0,0,0,0,255,255,255])
        bytes.append(contentsOf: [0x21,0xff,11]); bytes.append(Data("NETSCAPE2.0".utf8)); bytes.append(contentsOf: [3,1,7,0,0])
        for delay in [UInt8(0), UInt8(3)] {
            bytes.append(contentsOf: [0x21,0xf9,4,9,delay,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0])
        }
        bytes.append(0x3b); return bytes
    }
    private func firmwareJSON(published: Bool = true, revision: Int = 3, verified: Bool = false) -> String {
        let binary = Data([0,1,2])
        return #"{"id":"\#(itemID)","revision":\#(revision),"device":"generic-panel","deviceName":"Generic panel","hardwareRevision":"R1","version":"1.0","kind":"custom","title":"Synthetic release","releaseNotes":"Never flash","tags":["custom"],"sourceUrl":"","sha256":"\#(digest(binary))","byteSize":3,"published":\#(published),"createdAtISO":"2026-11-01T00:00:00Z","downloadUrl":"/api/v1/firmware/\#(itemID.uuidString.lowercased())/download?expectedRevision=\#(revision)","compatibilityVerified":\#(verified),"signatureVerified":false,"flashingSupportedByBackend":false}"#
    }
    private func deviceJSON(revision: Int = 3, verified: Bool = false) -> String {
        #"{"id":"\#(itemID)","revision":\#(revision),"nickname":"Private label","model":"Generic model","matrix":null,"ownerCardEnabled":false,"transferPending":false,"claimStatus":"unverified-tag","physicalOwnershipVerified":\#(verified),"hardwareIdentityVerified":false,"flashingCompatibilityVerified":false}"#
    }
    private func moderationJSON(visibility: String = "shared", reason: String = "Original reason") -> String {
        let base = "https://catalog.example.invalid"
        return #"{"id":"\#(itemID)","title":"Synthetic community GIF","category":"other","tags":[],"displayAttribution":"Fixture credit","license":"unspecified","licenseUrl":null,"sourceUrl":null,"pageUrl":"\#(base)/items/\#(itemID)","gifUrl":"\#(base)/media/\#(itemID)/original.gif","previewUrl":"\#(base)/media/\#(itemID)/preview.png","width":1,"height":1,"frameCount":2,"byteSize":\#(gif().count),"uploader":{"id":"\#(account)","displayName":"Fixture"},"likeCount":0,"variants":[],"visibility":"\#(visibility)","status":"pending","moderationReason":"\#(reason)","aiState":"done","aiError":"","aiReview":null,"requiresAdminReview":true,"heldByReports":false,"quarantined":false}"#
    }
    private func setup(flags: String? = nil, role: String = "admin", replies: [CommunityResponse] = []) async throws -> (CommunityController, AccountParityTransport) {
        let login = #"{"user":{"id":"\#(account)","email":"fixture@example.invalid","displayName":"Fixture","role":"\#(role)","verified":true,"allowMature":false},"token":"synthetic-account-session","expiresAt":"2099-01-01T00:00:00Z"}"#
        let config = #"{"requireEmailVerification":false\#((flags ?? allCapabilities).isEmpty ? "" : "," + (flags ?? allCapabilities))}"#
        let transport = AccountParityTransport([.init(status: 200, data: data(login)), .init(status: 200, data: data(config))] + replies)
        let controller = CommunityController(vault: AccountParityVault(), factory: { _ in transport })
        controller.configure("https://catalog.example.invalid")
        try await controller.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        try await controller.loadConfig(); return (controller, transport)
    }
    func testCropFullOrientedFrame() throws {
        XCTAssertEqual(try NativeAvatarCrop().rectangle(width: 32, height: 48), CGRect(x: 0, y: 0, width: 32, height: 48))
    }
    func testCropRejectsNegativeAndOverHundredPercent() {
        XCTAssertThrowsError(try NativeAvatarCrop(leftPercent: -1).validate())
        XCTAssertThrowsError(try NativeAvatarCrop(widthPercent: 101).validate())
    }
    func testCropRejectsRectangleOutsideSource() {
        XCTAssertThrowsError(try NativeAvatarCrop(leftPercent: 60, widthPercent: 50).validate())
    }
    func testCropRejectsSubpixelAndEmptyDimensions() {
        XCTAssertThrowsError(try NativeAvatarCrop(widthPercent: 1).rectangle(width: 1, height: 48))
        XCTAssertThrowsError(try NativeAvatarCrop().rectangle(width: 0, height: 48))
    }
    func testCropFloorsEachPercentageWithoutRounding() throws {
        XCTAssertEqual(try NativeAvatarCrop(leftPercent: 10, topPercent: 25, widthPercent: 50, heightPercent: 50)
            .rectangle(width: 33, height: 47), CGRect(x: 3, y: 11, width: 16, height: 23))
    }
    func testCropUsesOrientedRectangleWithoutRotationGuess() throws {
        let crop = NativeAvatarCrop(widthPercent: 50)
        XCTAssertEqual(try crop.rectangle(width: 48, height: 32).width, 24)
        XCTAssertEqual(try crop.rectangle(width: 32, height: 48).width, 16)
    }
    func testViewerPreferencesDecodeLegacyDocumentedDefaults() throws {
        let value = try decode(ViewerMediaPreferences.self, #"{"revision":0,"animationsEnabled":true,"dataSaving":false}"#)
        try value.validate(); XCTAssertEqual(value.revision, 0)
    }
    func testViewerZeroRevisionIsPreservedNotInvented() throws {
        let value = ViewerMediaPreferences(revision: 0, animationsEnabled: false, dataSaving: true)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains(#""revision":0"#))
    }
    func testViewerNegativeRevisionFails() {
        XCTAssertThrowsError(try ViewerMediaPreferences(revision: -1, animationsEnabled: true, dataSaving: false).validate())
    }
    func testViewerAutomaticMotionHonorsReducedMotion() {
        let value = ViewerMediaPreferences(revision: 1, animationsEnabled: true, dataSaving: false)
        XCTAssertFalse(value.permitsAnimation(reducedMotion: true, manual: false))
    }
    func testViewerDataSavingRequiresExplicitPlay() {
        let value = ViewerMediaPreferences(revision: 1, animationsEnabled: true, dataSaving: true)
        XCTAssertFalse(value.permitsAnimation(reducedMotion: false, manual: false))
    }
    func testViewerManualPlayOverridesMotionPreferenceNotVisibility() {
        XCTAssertTrue(ViewerMediaPreferences(revision: 0, animationsEnabled: false, dataSaving: true).permitsAnimation(reducedMotion: true, manual: true))
    }
    func testAdvertisedSizesAndLegacyRemainDistinct() {
        XCTAssertEqual(NativeMatrixSize.advertised.map(\.id), ["16x16","32x32","48x48","64x64"])
        XCTAssertEqual(NativeMatrixSize.legacy.id, "96x128"); XCTAssertFalse(NativeMatrixSize.advertised.contains(.legacy))
    }
    func testExactRectangleNeverMatchesRotatedSize() {
        XCTAssertNotEqual(NativeMatrixSize(width: 32, height: 48), NativeMatrixSize(width: 48, height: 32))
    }
    func testNativeAnyFilterSendsExactOriginalMode() throws {
        let value = NativeMatrixFilter(sizes: [.init(width: 32, height: 48)])
        XCTAssertEqual(try value.query().first(where: { $0.name == "panelSizes" })?.value, "32x48")
        XCTAssertEqual(try value.query().first(where: { $0.name == "sizeMode" })?.value, "native")
    }
    func testAvailableAllFilterDoesNotInventVariants() throws {
        let value = NativeMatrixFilter(sizes: Set(NativeMatrixSize.advertised), mode: .available, match: .all)
        XCTAssertEqual(try value.query().first(where: { $0.name == "sizeMatch" })?.value, "all")
        XCTAssertEqual(try value.query().first(where: { $0.name == "sizeMode" })?.value, "available")
    }
    func testSizeFilterRejectsMoreThanSixteenDistinctSizes() {
        let value = NativeMatrixFilter(sizes: Set((1...17).map { NativeMatrixSize(width: $0, height: 1) }))
        XCTAssertThrowsError(try value.query())
    }
    func testSizeBoundsRejectZeroAnd4097() {
        XCTAssertThrowsError(try NativeMatrixSize(width: 0, height: 1).validate())
        XCTAssertThrowsError(try NativeMatrixSize(width: 1, height: 4097).validate())
    }
    func testCatalogOriginalUsesPerFileByteBounds() throws {
        let url = try XCTUnwrap(URL(string: "https://catalog.example.invalid/media/original.gif"))
        let value = NativeCatalogFile(url: url, width: 1, height: 1, frameCount: 2, byteSize: 1, sha256: nil, original: true)
        XCTAssertThrowsError(try value.verify(gif()))
    }
    func testCatalogDigestMismatchFailsBeforeDecode() throws {
        let url = try XCTUnwrap(URL(string: "https://catalog.example.invalid/media/original.gif"))
        XCTAssertThrowsError(try NativeCatalogFile(url: url, width: 1, height: 1, frameCount: 2,
            byteSize: gif().count, sha256: String(repeating: "0", count: 64), original: true).verify(gif()))
    }
    func testCatalogSourceDimensionsCannotBeRelabeledAsNative() throws {
        let url = try XCTUnwrap(URL(string: "https://catalog.example.invalid/media/original.gif"))
        XCTAssertThrowsError(try NativeCatalogFile(url: url, width: 32, height: 48, frameCount: 2,
            byteSize: gif().count, sha256: digest(gif()), original: true).verify(gif()))
    }
    func testCatalogFrameCountMustMatchManifest() throws {
        let url = try XCTUnwrap(URL(string: "https://catalog.example.invalid/media/original.gif"))
        XCTAssertThrowsError(try NativeCatalogFile(url: url, width: 1, height: 1, frameCount: 1,
            byteSize: gif().count, sha256: nil, original: true).verify(gif()))
    }
    func testCatalogUnknownMediaDoesNotGainImagePermission() throws {
        let url = try XCTUnwrap(URL(string: "https://catalog.example.invalid/media/original.gif"))
        XCTAssertThrowsError(try NativeCatalogFile(url: url, width: 1, height: 1, frameCount: 1,
            byteSize: nil, sha256: nil, original: true).verify(data("<html>not an image</html>")))
    }
    func testFirmwareManifestDecodesRelativeRevisionURL() throws {
        let value = try decode(AccountFirmware.self, firmwareJSON())
        try value.validate(admin: false); XCTAssertEqual(value.downloadUrl.scheme, nil); XCTAssertEqual(value.revision, 3)
    }
    func testFirmwareMetadataCannotClaimAuthenticityOrCompatibility() throws {
        XCTAssertThrowsError(try decode(AccountFirmware.self, firmwareJSON(verified: true)).validate(admin: true))
    }
    func testFirmwareDraftRequiresCurrentAdminReadScope() throws {
        let value = try decode(AccountFirmware.self, firmwareJSON(published: false))
        XCTAssertThrowsError(try value.validate(admin: false)); XCTAssertNoThrow(try value.validate(admin: true))
    }
    func testFirmwareExactBytesSizeAndChecksum() throws {
        let value = try decode(AccountFirmware.self, firmwareJSON())
        XCTAssertNoThrow(try value.verify(Data([0,1,2])))
        XCTAssertThrowsError(try value.verify(Data([0,1,3])))
        XCTAssertThrowsError(try value.verify(Data([0,1])))
    }
    func testFirmwareReservedAndDuplicateTagsRejected() {
        var value = AccountFirmwareMetadata(device: "panel", deviceName: "Panel", hardwareRevision: "R1",
            version: "1", title: "Draft")
        value.tags = ["stock"]; XCTAssertThrowsError(try value.validate())
        value.tags = ["safe", "safe"]; XCTAssertThrowsError(try value.validate())
    }
    func testFirmwareSourceRejectsCredentialsAndHTTP() {
        var value = AccountFirmwareMetadata(device: "panel", deviceName: "Panel", hardwareRevision: "R1",
            version: "1", title: "Draft")
        value.sourceUrl = "https://name:secret@example.invalid"; XCTAssertThrowsError(try value.validate())
        value.sourceUrl = "http://example.invalid"; XCTAssertThrowsError(try value.validate())
    }
    func testFirmwareFilterBoundsAndExactHardwareVersion() throws {
        let value = AccountFirmwareFilter(device: "panel", hardwareRevision: "R2", version: "custom-1")
        XCTAssertEqual(try value.query(offset: 24).first(where: { $0.name == "hardwareRevision" })?.value, "R2")
        XCTAssertThrowsError(try value.query(offset: 10001))
    }
    func testDeviceUnverifiedStateAndUnknownMatrixStayHonest() throws {
        let value = try decode(AccountDevice.self, deviceJSON()); try value.validate()
        XCTAssertNil(value.matrix); XCTAssertFalse(value.ownerCardEnabled)
    }
    func testDeviceVerifiedClaimRejectedRatherThanTrusted() throws {
        XCTAssertThrowsError(try decode(AccountDevice.self, deviceJSON(verified: true)).validate())
    }
    func testDeviceUnknownMatrixEncodesExplicitNull() throws {
        let bytes = try JSONEncoder().encode(AccountDeviceMetadata(nickname: "Private", model: "Generic", matrix: nil))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""matrix":null"#))
    }
    func testDevicePrivateLabelsRejectControlCharactersAndOversize() {
        XCTAssertThrowsError(try AccountDeviceMetadata(nickname: "Line\nBreak", model: "Generic", matrix: nil).validate())
        XCTAssertThrowsError(try AccountDeviceMetadata(nickname: String(repeating: "a", count: 81), model: "Generic", matrix: nil).validate())
    }
    func testTagLinkRequiresCanonicalConfiguredFragment() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example.invalid")
        XCTAssertEqual(try AccountDeviceTagLink.token("https://catalog.example.invalid/device-card#tag=\(token)", origin: origin), token)
    }
    func testTagCannotUseIdentifierHashCrossOriginOrAlias() throws {
        let origin = try CommunityOrigin.parse("https://catalog.example.invalid")
        for value in ["serial-123", String(repeating: "a", count: 64),
                      "https://other.invalid/device-card#tag=\(token)", "https://catalog.example.invalid/device-card?tag=\(token)"] {
            XCTAssertThrowsError(try AccountDeviceTagLink.token(value, origin: origin))
        }
    }
    func testDeviceCardImageRequiresMatchingNarrowTagScope() throws {
        let value = try decode(AccountDeviceCard.self, #"{"owner":{"id":"\#(other)","displayName":"Minimal owner","canRequestFriendship":false,"avatarUrl":"/image.gif","avatarPreviewUrl":"/preview.png"},"claimStatus":"unverified-tag","physicalOwnershipVerified":false,"hardwareIdentityVerified":false,"deviceMetadataIncluded":false,"friendshipCreated":false}"#)
        XCTAssertThrowsError(try value.validate(token: token))
    }
    func testResearchObservationEncodesOnlyTargetAndExplicitConsent() throws {
        let bytes = try JSONEncoder().encode(GenericResearchObservation(targetId: itemID, consent: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["targetId", "consent"])
        XCTAssertEqual(object["targetId"] as? String, itemID.uuidString.lowercased())
    }
    func testResearchCuratedLabelsRejectRawAddressAndUnknownKind() {
        XCTAssertThrowsError(try GenericResearchMetadata(model: "AA:BB:CC:DD:EE:FF", hardwareRevision: "R1", firmwareVersion: "1").validate())
        XCTAssertThrowsError(try GenericResearchMetadata(model: "Generic", hardwareRevision: "R1", firmwareVersion: "1", kind: "verified").validate())
    }
    func testBulkRequiresExactDistinctIDsReasonAndConfirmation() {
        XCTAssertThrowsError(try CommunityBulkRequest(ids: [itemID,itemID], action: "delete", reason: "Reason", confirmation: "DELETE").validate())
        XCTAssertThrowsError(try CommunityBulkRequest(ids: [itemID], action: "delete", reason: "Reason", confirmation: "QUARANTINE").validate())
        XCTAssertThrowsError(try CommunityBulkRequest(ids: [itemID], action: "quarantine", reason: " ", confirmation: "QUARANTINE").validate())
    }
    func testBulkReceiptMustMatchExactSelectionAndCleanup() {
        let request = CommunityBulkRequest(ids: [itemID], action: "delete", reason: "Reason", confirmation: "DELETE")
        XCTAssertTrue(String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self).contains(itemID.uuidString.lowercased()))
        XCTAssertThrowsError(try CommunityBulkReceipt(action: "delete", affected: 1, ids: [other], cleanupPending: 1).validate(request))
        XCTAssertThrowsError(try CommunityBulkReceipt(action: "delete", affected: 1, ids: [itemID], cleanupPending: 0).validate(request))
    }
    func testContentBlindAlertDecodesActualISOTimeNotEpochGuess() throws {
        let value = try decode(ContentBlindUploadAlert.self, #"{"id":"\#(itemID)","userId":"\#(account)","displayName":"Fixture","reason":"upload-rate","attempts":10,"invalid":0,"duplicates":0,"rate":10,"createdAt":"2026-11-01T00:00:00.000Z","blockedUntil":"2026-11-01T01:00:00.000Z","reviewedAt":null,"releasedAt":null,"active":true}"#)
        XCTAssertNoThrow(try value.validate()); XCTAssertNil(ContentBlindUploadAlert.date("unknown"))
    }
    func testAbsentSourceCapabilitiesFailClosedOnProductionLikeConfig() async throws {
        let (controller, _) = try await setup(flags: "")
        for capability in [AccountServiceCapability.devices, .firmware, .research, .bulk, .alerts] {
            XCTAssertThrowsError(try AccountServiceScope(controller, capability: capability))
        }
    }
    func testNonAdminCannotCreateBulkOrFirmwareAdminScope() async throws {
        let (controller, _) = try await setup(role: "user")
        XCTAssertThrowsError(try AccountServiceScope(controller, capability: .bulk, admin: true))
        XCTAssertThrowsError(try AccountServiceScope(controller, capability: .firmware, admin: true))
    }
    func testScopedDeviceServiceCannotReadPrivateCloudOrAdmin() async throws {
        let (controller, transport) = try await setup()
        let scope = try AccountServiceScope(controller, capability: .devices)
        do { _ = try await scope.bytes("cloud/items"); XCTFail("No cross-domain route grant") } catch {}
        let history = await transport.history(); XCTAssertEqual(history.count, 2)
    }
    func testOldAccountScopeCannotSurviveSignOut() async throws {
        let (controller, _) = try await setup()
        let scope = try AccountServiceScope(controller, capability: .devices)
        try controller.forgetLocalSession()
        XCTAssertThrowsError(try scope.check())
    }
    func testLateDeviceReadDiscardedAfterViewerPolicyChange() async throws {
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: data(#"{"devices":[]}"#))])
        let scope = try AccountServiceScope(controller, capability: .devices)
        await transport.armSuspension()
        let work = Task { try await scope.devices() }
        await transport.waitUntilSuspended()
        controller.applyViewerPreferences(.init(revision: 1, animationsEnabled: false, dataSaving: true))
        await transport.resume()
        do { _ = try await work.value; XCTFail("Late policy response must be discarded") } catch {}
    }
    func testDeviceMutationCarriesCapturedRevisionAndExpectedAccount() async throws {
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: data(#"{"device":\#(deviceJSON(revision: 4))}"#))])
        let scope = try AccountServiceScope(controller, capability: .devices)
        _ = try await scope.changeDevice(decode(AccountDevice.self, deviceJSON()), action: "revoke")
        let history = await transport.history()
        let request = try XCTUnwrap(history.last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Expected-Account"), account.uuidString.lowercased())
        XCTAssertTrue(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(#""expectedRevision":3"#))
    }
    func testFirmwareDownloadBindsRevisionAndChecksBeforeAndAfter() async throws {
        let detail = data(#"{"firmware":\#(firmwareJSON())}"#)
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: detail),
            .init(status: 200, data: Data([0,1,2])), .init(status: 200, data: detail)])
        let scope = try AccountServiceScope(controller, capability: .firmware)
        let bytes = try await scope.downloadFirmware(decode(AccountFirmware.self, firmwareJSON()))
        XCTAssertEqual(bytes, Data([0,1,2]))
        let history = await transport.history()
        XCTAssertTrue(history.contains { $0.url?.query == "expectedRevision=3" })
        XCTAssertFalse(history.contains { $0.url?.path.contains("flash") == true })
    }
    func testResearchNetworkSubmissionNeverIncludesRawConnectionOrProvenance() async throws {
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: data(#"{"accepted":true,"counted":false}"#))])
        let target = GenericResearchTarget(id: itemID, model: "Generic", hardwareRevision: "R1", firmwareVersion: "1", kind: "unknown", reportCount: nil)
        let result = try await AccountServiceScope(controller, capability: .research).observeResearch(target, consent: true)
        XCTAssertFalse(result.counted)
        let history = await transport.history()
        let request = try XCTUnwrap(history.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["targetId", "consent"])
    }
    func testAvatarCropUploadPreservesAllOriginalGIFBytesAndMetadataOrder() async throws {
        let avatar = #"{"userId":"\#(account)","version":"\#(itemID)","status":"pending","createdAt":1,"avatarUrl":"/api/v1/social/avatars/\#(account.uuidString.lowercased())/\#(itemID.uuidString.lowercased())/image.gif","avatarPreviewUrl":"/api/v1/social/avatars/\#(account.uuidString.lowercased())/\#(itemID.uuidString.lowercased())/preview.png","avatarAnimated":true,"aiState":"queued","aiError":"","approvalMode":"ai"}"#
        let (controller, transport) = try await setup(replies: [
            .init(status: 200, data: data(#"{"avatar":null,"uploadsEnabled":true,"approvalMode":"ai","cropsEnabled":true}"#)),
            .init(status: 202, data: data(#"{"avatar":\#(avatar)}"#))])
        try await CommunityFeatureClient(controller).uploadAvatar(gif(), publicConsent: true, crop: NativeAvatarCrop())
        let history = await transport.history()
        let request = try XCTUnwrap(history.last)
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: gif()))
        let metadata = try XCTUnwrap(body.range(of: data("name=\"metadata\"")))
        let file = try XCTUnwrap(body.range(of: data("name=\"file\"")))
        XCTAssertLessThan(metadata.lowerBound, file.lowerBound)
        XCTAssertTrue(String(decoding: body.prefix(file.lowerBound), as: UTF8.self).contains("leftPercent"))
    }
    func testViewerConflictNeverRetriesOrChangesSavedState() async throws {
        let (controller, transport) = try await setup(replies: [.init(status: 409, data: data(#"{"error":{"code":"media_preferences_changed","message":"Reload"}}"#))])
        do {
            try await controller.saveViewerPreferences(.init(revision: 7, animationsEnabled: true, dataSaving: false), animations: false, dataSaving: true)
            XCTFail("Conflict must surface")
        } catch {}
        XCTAssertNil(controller.user?.mediaPreferences)
        let history = await transport.history(); XCTAssertEqual(history.count, 3)
    }
    func testDeviceTagAvatarHeaderNeverBecomesGeneralProfileGrant() async throws {
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: gif())])
        let scope = try AccountServiceScope(controller, capability: .devices)
        _ = try await scope.bytes("social/avatars/\(other.uuidString.lowercased())/\(itemID.uuidString.lowercased())/image.gif", tag: token)
        let history = await transport.history()
        let request = try XCTUnwrap(history.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Device-Tag"), token)
        do { _ = try await scope.bytes("social/profile/\(other)", tag: token); XCTFail("No directory grant") } catch {}
    }
    func testAdminScopeRejectsRoleDowngradeWithoutAccountSwitch() async throws {
        let me = data(#"{"user":{"id":"\#(account)","email":"fixture@example.invalid","displayName":"Fixture","role":"user","verified":true,"allowMature":false}}"#)
        let (controller, _) = try await setup(replies: [.init(status: 200, data: me)])
        let scope = try AccountServiceScope(controller, capability: .bulk, admin: true)
        try await controller.refreshUser(); XCTAssertThrowsError(try scope.check())
    }
    func testAdminDecoderRefusesPrivateCloudModeration() {
        XCTAssertThrowsError(try decode(AdminItem.self, moderationJSON(visibility: "private")))
    }
    func testGuestCatalogDoesNotCreateAnAdminAccountOrSession() async throws {
        let transport = AccountParityTransport([.init(status: 200, data: data(#"{"items":[],"page":1,"limit":24,"total":0}"#))])
        let controller = CommunityController(vault: AccountParityVault(), factory: { _ in transport })
        controller.configure("https://catalog.example.invalid")
        _ = try await controller.items(query: "", category: "", page: 1)
        let history = await transport.history()
        let request = try XCTUnwrap(history.last)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertFalse(controller.isAdmin)
    }
    func testAvatarRejectsUnknownRasterAndPrivateEnvelope() {
        XCTAssertThrowsError(try NativeAvatarInput.kind(data("%PDF-1.7")))
        XCTAssertThrowsError(try NativeAvatarInput.kind(data("encrypted-private-envelope")))
    }
    func testAvatarInheritedByteBudgetCannotBeBypassedByCrop() {
        XCTAssertThrowsError(try NativeAvatarSelection(bytes: Data(repeating: 0, count: 5_000_001), expectedVersion: nil, scope: UUID()))
    }
    func testImmutableAvatarPreviewNeverReencodesOriginalAnimation() throws {
        let bytes = gif()
        let value = try NativeAvatarSelection(bytes: bytes, expectedVersion: itemID, scope: account)
        _ = try value.preview(crop: NativeAvatarCrop())
        XCTAssertEqual(value.bytes, bytes); XCTAssertEqual(value.expectedVersion, itemID)
    }
    func testAvatarReplacementRefusesChangedCurrentVersionBeforePost() async throws {
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: data(#"{"avatar":null,"uploadsEnabled":true,"approvalMode":"ai","cropsEnabled":true}"#))])
        do {
            try await CommunityFeatureClient(controller).uploadAvatar(gif(), publicConsent: true, expectedVersion: itemID)
            XCTFail("Stale selected avatar version must not POST")
        } catch {}
        let history = await transport.history(); XCTAssertEqual(history.last?.httpMethod, "GET")
    }
    func testMatureOffPreferenceIsSavedForAdminWithoutRoleBypass() async throws {
        let response = data(#"{"user":{"id":"\#(account)","email":"fixture@example.invalid","displayName":"Fixture","role":"admin","verified":true,"allowMature":false}}"#)
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: response)])
        let policy = controller.avatarPolicyRevision
        try await controller.setMaturePreference(false, expectedRevision: controller.accountRevision)
        XCTAssertEqual(controller.user?.allowMature, false); XCTAssertNotEqual(policy, controller.avatarPolicyRevision)
        let history = await transport.history(), request = try XCTUnwrap(history.last)
        XCTAssertTrue(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(#""allowMature":false"#))
    }
    func testMaturePreferenceReceiptForAnotherAccountFailsClosed() async throws {
        let response = data(#"{"user":{"id":"\#(other)","email":"other@example.invalid","displayName":"Other","role":"admin","verified":true,"allowMature":true}}"#)
        let (controller, _) = try await setup(replies: [.init(status: 200, data: response)])
        do {
            try await controller.setMaturePreference(true, expectedRevision: controller.accountRevision)
            XCTFail("Another account cannot supply the saved preference")
        } catch {}
        XCTAssertEqual(controller.user?.id, account); XCTAssertEqual(controller.user?.allowMature, false)
    }
    func testMatureMaskedOwnedAvatarNeverExposesMedia() async throws {
        let response = data(#"{"avatar":{"userId":"\#(account)","version":"\#(itemID)","status":"approved","createdAt":1,"avatarUrl":null,"avatarPreviewUrl":null,"avatarAnimated":false,"avatarMature":true,"avatarMasked":true,"approvalMode":"ai","aiState":"done","aiError":""},"uploadsEnabled":true,"approvalMode":"ai","cropsEnabled":true}"#)
        let (controller, _) = try await setup(replies: [.init(status: 200, data: response)])
        let owned = try await CommunityFeatureClient(controller).ownedAvatar()
        XCTAssertNil(owned.avatar?.avatarUrl); XCTAssertNil(owned.avatar?.avatarPreviewUrl)
        XCTAssertEqual(owned.avatar?.avatarMasked, true)
    }
    func testAdminCannotReadAnotherOwnersPendingAvatarThroughOwnedState() async throws {
        let response = data(#"{"avatar":{"userId":"\#(other)","version":"\#(itemID)","status":"pending","createdAt":1,"avatarUrl":"/api/v1/social/avatars/\#(other.uuidString.lowercased())/\#(itemID.uuidString.lowercased())/image.gif","avatarPreviewUrl":"/api/v1/social/avatars/\#(other.uuidString.lowercased())/\#(itemID.uuidString.lowercased())/preview.png","avatarAnimated":true,"approvalMode":"ai","aiState":"queued","aiError":""}}"#)
        let (controller, _) = try await setup(replies: [.init(status: 200, data: response)])
        do { _ = try await CommunityFeatureClient(controller).ownedAvatar(); XCTFail("No pending-avatar admin grant") } catch {}
    }
    func testFirmwareRevisionChangeAfterReadDiscardsDownloadedBinary() async throws {
        let before = data(#"{"firmware":\#(firmwareJSON())}"#), after = data(#"{"firmware":\#(firmwareJSON(revision: 4))}"#)
        let (controller, transport) = try await setup(replies: [.init(status: 200, data: before),
            .init(status: 200, data: Data([0,1,2])), .init(status: 200, data: after)])
        do {
            _ = try await AccountServiceScope(controller, capability: .firmware).downloadFirmware(decode(AccountFirmware.self, firmwareJSON()))
            XCTFail("No stale firmware binary result")
        } catch {}
        let history = await transport.history(); XCTAssertEqual(history.count, 5)
    }
    func testResearchWithoutConsentNeverSendsAnyObservation() async throws {
        let (controller, transport) = try await setup()
        let target = GenericResearchTarget(id: itemID, model: "Generic", hardwareRevision: "R1", firmwareVersion: "1", kind: "stock", reportCount: nil)
        do { _ = try await AccountServiceScope(controller, capability: .research).observeResearch(target, consent: false); XCTFail("No implicit consent") } catch {}
        let history = await transport.history(); XCTAssertEqual(history.count, 2)
    }
    func testResearchDoesNotRelabelReportsAsUniqueDevicesOrStoreProvenance() throws {
        let page = try decode(GenericResearchPage.self, #"{"targets":[],"total":0,"reportsAreUniqueDevices":true,"hardwareVerified":false,"provenanceStored":false}"#)
        XCTAssertThrowsError(try page.validate(admin: false))
    }
    func testModerationPreflightSnapshotDetectsChangedCurrentStateWithoutInventingRevision() throws {
        let original = try decode(AdminItem.self, moderationJSON())
        let changed = try decode(AdminItem.self, moderationJSON(reason: "Changed reason"))
        XCTAssertNotEqual(try original.moderationSnapshot, try changed.moderationSnapshot)
        XCTAssertNil(original.moderationVersion)
    }
    func testContentBlindAlertRejectsNegativeCounterInsteadOfDefaulting() throws {
        let value = try decode(ContentBlindUploadAlert.self, #"{"id":"\#(itemID)","userId":"\#(account)","displayName":"Fixture","reason":"invalid-media","attempts":-1,"invalid":0,"duplicates":0,"rate":0,"createdAt":"2026-11-01T00:00:00.000Z","blockedUntil":"2026-11-01T01:00:00.000Z","reviewedAt":null,"releasedAt":null,"active":true}"#)
        XCTAssertThrowsError(try value.validate())
    }
    func testAvatarNewSelectionHasDistinctPreviewIdentityButSameImmutableBytes() throws {
        let first = try NativeAvatarSelection(bytes: gif(), expectedVersion: itemID, scope: account)
        let second = try NativeAvatarSelection(bytes: gif(), expectedVersion: itemID, scope: account)
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(first.bytes, second.bytes)
        XCTAssertNotEqual(NativeAvatarCrop(), NativeAvatarCrop(widthPercent: 50))
    }
}
