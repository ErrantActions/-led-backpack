import XCTest
import CryptoKit
import BackpackProtocol
@testable import LEDBackpack

private actor CatalogManifestFixtureTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var requests: [URLRequest] = []
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected catalog manifest fixture request.") }
        let response = replies.removeFirst()
        if armed {
            armed = false
            await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
        }
        guard response.data.count <= maxBytes else { throw BackpackError.invalid("Fixture exceeded the requested network byte bound.") }
        return response
    }
    func suspendNext() { armed = true }
    func waitUntilHeld() async { if held == nil { await withCheckedContinuation { ready = $0 } } }
    func resume() { held?.resume(); held = nil }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class CatalogManifestFixtureVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class CatalogManifestTests: XCTestCase {
    private let itemID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let accountID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let base = "https://catalog.example.invalid"
    private func gif() -> Data {
        var data = Data("GIF89a".utf8)
        data.append(contentsOf: [1,0,1,0,0x80,0,0,0,0,0,255,255,255,
            0x21,0xf9,4,1,0,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0,0x3b])
        return data
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func entry(kind: String = "original", width: Int = 1, height: Int = 1) -> [String: Any] {
        let name = kind == "original" ? "original.gif" : "\(width)x\(height).gif"
        return ["kind": kind, "name": name, "url": "\(base)/media/\(itemID.uuidString.lowercased())/\(name)",
            "width": width, "height": height, "frameCount": 1, "byteSize": gif().count, "sha256": hash(gif())]
    }
    private func manifest(files: [[String: Any]]? = nil, overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["version": 1, "itemId": itemID.uuidString.lowercased(), "integrityOnly": true,
            "serverTimeISO": "2026-11-06T20:12:24.198Z", "files": files ?? [entry()]]
        value.merge(overrides) { _, new in new }; return try json(value)
    }
    private func item(variant: Bool = false) throws -> CommunityItem {
        let prefix = "\(base)/media/\(itemID.uuidString.lowercased())"
        let variants: [[String: Any]] = variant ? [["width": 32, "height": 48, "frameCount": 1,
            "byteSize": gif().count, "url": prefix + "/32x48.gif"]] : []
        return try JSONDecoder().decode(CommunityItem.self, from: json([
            "id": itemID.uuidString.lowercased(), "title": "Synthetic original", "category": "other", "tags": [],
            "displayAttribution": "Fixture", "license": "unspecified", "pageUrl": "\(base)/items/\(itemID.uuidString.lowercased())",
            "gifUrl": prefix + "/original.gif", "previewUrl": prefix + "/preview.png",
            "width": 1, "height": 1, "frameCount": 1, "byteSize": gif().count,
            "uploader": ["id": accountID.uuidString.lowercased(), "displayName": "Fixture"], "likeCount": 0, "variants": variants]))
    }
    private func selected(_ bytes: Data, variant: Bool = false) throws -> NativeCatalogDownloadManifest.File {
        let value = try JSONDecoder().decode(NativeCatalogDownloadManifest.self, from: bytes)
        let record = try item(variant: variant)
        let selection = try XCTUnwrap(variant ? record.recordedFiles.last : record.recordedFiles.first)
        return try value.selectedFile(item: record, selected: selection, origin: CommunityOrigin.parse(base))
    }
    private func reply(_ data: Data, status: Int = 200) -> CommunityResponse { .init(status: status, data: data) }
    private func detail() throws -> Data {
        let prefix = "\(base)/media/\(itemID.uuidString.lowercased())"
        return try json(["item": [
            "id": itemID.uuidString.lowercased(), "title": "Synthetic original", "category": "other", "tags": [],
            "displayAttribution": "Fixture", "license": "unspecified", "pageUrl": "\(base)/items/\(itemID.uuidString.lowercased())",
            "gifUrl": prefix + "/original.gif", "previewUrl": prefix + "/preview.png",
            "width": 1, "height": 1, "frameCount": 1, "byteSize": gif().count,
            "uploader": ["id": accountID.uuidString.lowercased(), "displayName": "Fixture"], "likeCount": 0, "variants": []] as [String: Any]])
    }
    private func setup(enabled: Bool, guest: Bool = false, responses: [CommunityResponse]) async throws -> (CommunityController, CatalogManifestFixtureTransport) {
        let user: [String: Any] = ["id": accountID.uuidString.lowercased(), "email": "fixture@example.invalid",
            "displayName": "Fixture", "role": "user", "verified": true, "allowMature": false]
        var replies: [CommunityResponse] = []
        if !guest { replies.append(reply(try json(["user": user, "token": "synthetic-manifest-session", "expiresAt": "2099-01-01T00:00:00Z"]))) }
        var config: [String: Any] = ["requireEmailVerification": false]
        if enabled { config["catalogDownloadManifestEnabled"] = true }
        replies.append(reply(try json(config))); replies += responses
        let transport = CatalogManifestFixtureTransport(replies)
        let community = CommunityController(vault: CatalogManifestFixtureVault(), factory: { _ in transport })
        community.configure(base)
        if !guest { try await community.signIn(email: "fixture@example.invalid", password: "synthetic-password") }
        try await community.loadConfig(); return (community, transport)
    }
    func testMissingCapabilityDoesNotBecomeTrustedDigest() throws {
        let config = try JSONDecoder().decode(CommunityConfig.self, from: json(["requireEmailVerification": false]))
        XCTAssertNil(config.catalogDownloadManifestEnabled)
        XCTAssertTrue(NativeCatalogDownloadIntegrity.checksumUnavailable.message.contains("not checksum-verified"))
    }
    func testValidOriginalManifestBindsCurrentRecordedFile() throws {
        XCTAssertEqual(try selected(manifest()).sha256, hash(gif()))
    }
    func testValidRecordedRectangleIsNotRotatedOrInvented() throws {
        let value = try selected(manifest(files: [entry(), entry(kind: "variant", width: 32, height: 48)]), variant: true)
        XCTAssertEqual(value.name, "32x48.gif"); XCTAssertEqual(value.width, 32); XCTAssertEqual(value.height, 48)
    }
    func testUnknownManifestVersionFailsClosed() {
        XCTAssertThrowsError(try selected(manifest(overrides: ["version": 2])))
    }
    func testDifferentManifestItemCannotAuthorizeSelection() {
        XCTAssertThrowsError(try selected(manifest(overrides: ["itemId": accountID.uuidString.lowercased()])))
    }
    func testManifestCannotClaimMoreThanTransferIntegrity() {
        XCTAssertThrowsError(try selected(manifest(overrides: ["integrityOnly": false])))
    }
    func testMissingOrInvalidServerTimeIsNotInvented() {
        XCTAssertThrowsError(try selected(manifest(overrides: ["serverTimeISO": "unknown"])))
    }
    func testManifestRequiresOneStoredOriginal() {
        XCTAssertThrowsError(try selected(manifest(files: [])))
        XCTAssertThrowsError(try selected(manifest(files: [entry(kind: "variant")])))
    }
    func testTwoOriginalsCannotBecomeMultipleNativeSources() {
        XCTAssertThrowsError(try selected(manifest(files: [entry(), entry()])))
    }
    func testManifestFileCountNeverExceedsSix() {
        XCTAssertThrowsError(try selected(manifest(files: Array(repeating: entry(), count: 7))))
    }
    func testDuplicateVariantNamesAndURLsAreRejected() {
        XCTAssertThrowsError(try selected(manifest(files: [entry(), entry(kind: "variant", width: 32, height: 48),
            entry(kind: "variant", width: 32, height: 48)]), variant: true))
    }
    func testManifestCannotRedirectFileToAnotherOrigin() {
        var file = entry(); file["url"] = "https://other.invalid/media/\(itemID.uuidString.lowercased())/original.gif"
        XCTAssertThrowsError(try selected(manifest(files: [file])))
    }
    func testPercentEncodedPathAliasIsNotCanonicalMedia() {
        var file = entry(); file["url"] = "\(base)/media/\(itemID.uuidString.lowercased())/%6friginal.gif"
        XCTAssertThrowsError(try selected(manifest(files: [file])))
    }
    func testFilenameQueryAndFragmentAliasesAreRejected() {
        for suffix in ["?download=1", "#original"] {
            var file = entry(); file["url"] = "\(base)/media/\(itemID.uuidString.lowercased())/original.gif" + suffix
            XCTAssertThrowsError(try selected(manifest(files: [file])))
        }
    }
    func testPreviewCannotMasqueradeAsOriginalGIF() {
        var file = entry(); file["name"] = "preview.png"; file["url"] = "\(base)/media/\(itemID.uuidString.lowercased())/preview.png"
        XCTAssertThrowsError(try selected(manifest(files: [file])))
    }
    func testManifestDescriptorBoundsIncludePreDecodePixelBudget() {
        let changes: [[String: Any]] = [["width": 0], ["height": 4097], ["byteSize": 5_000_001],
                                       ["frameCount": 121], ["width": 4096, "height": 4096, "frameCount": 3]]
        for change in changes {
            var file = entry(); file.merge(change) { _, new in new }
            XCTAssertThrowsError(try selected(manifest(files: [file])))
        }
    }
    func testDigestMustBeExactlyLowercaseHex64() {
        for hash in [String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "g", count: 64)] {
            var file = entry(); file["sha256"] = hash
            XCTAssertThrowsError(try selected(manifest(files: [file])))
        }
    }
    func testManifestCannotOmitAnActuallyRecordedExport() {
        XCTAssertThrowsError(try selected(manifest(), variant: true))
    }
    func testManifestDescriptorMustMatchCurrentItemByteSizeAndFrames() {
        let changes: [[String: Any]] = [["byteSize": gif().count + 1], ["frameCount": 2]]
        for change in changes {
            var file = entry(); file.merge(change) { _, new in new }
            XCTAssertThrowsError(try selected(manifest(files: [file])))
        }
    }
    func testActualGIFBytesDecodeOnlyAfterTrustedSizeAndHashMatch() throws {
        let file = try selected(manifest())
        XCTAssertNoThrow(try file.descriptor.verify(gif()))
    }
    func testDigestMismatchFailsBeforeAttemptingGIFDecode() throws {
        let file = try selected(manifest())
        XCTAssertThrowsError(try file.descriptor.verify(Data(repeating: 0, count: gif().count))) {
            XCTAssertTrue($0.localizedDescription.contains("checksum"))
        }
    }
    func testMatchingHashDoesNotMakeMalformedMediaDecodable() throws {
        let bytes = Data(repeating: 0, count: gif().count)
        var file = entry(); file["sha256"] = hash(bytes)
        let declared = try selected(manifest(files: [file]))
        XCTAssertThrowsError(try declared.descriptor.verify(bytes))
    }
    func testAdvertisedManifestPathChecksCurrentDigestBeforeAndAfterDownload() async throws {
        let (community, transport) = try await setup(enabled: true, responses: [
            reply(detail()), reply(manifest()), reply(gif()), reply(detail()), reply(manifest())])
        let file = try XCTUnwrap(item().recordedFiles.first)
        let result = try await community.downloadCatalogFile(itemID: itemID, file: file)
        XCTAssertEqual(result.data, gif()); XCTAssertEqual(result.integrity, .manifestSHA256)
        let history = await transport.history()
        XCTAssertEqual(history.filter { $0.url?.path.hasSuffix("/download-manifest") == true }.count, 2)
        XCTAssertTrue(history.filter { $0.url?.path.hasSuffix("/download-manifest") == true }.allSatisfy { $0.url?.query == nil })
    }
    func testAbsentFlagPreservesLegacyCopyButNeverCallsItChecksumVerified() async throws {
        let (community, transport) = try await setup(enabled: false, responses: [reply(detail()), reply(gif()), reply(detail())])
        let result = try await community.downloadCatalogFile(itemID: itemID, file: XCTUnwrap(item().recordedFiles.first))
        XCTAssertEqual(result.integrity, .checksumUnavailable)
        let history = await transport.history()
        XCTAssertFalse(history.contains { $0.url?.path.hasSuffix("/download-manifest") == true })
    }
    func testManifestBusyNeverSilentlyFallsBackToUnverifiedMedia() async throws {
        let error = try json(["error": ["code": "manifest_busy", "message": "Busy"]])
        let (community, transport) = try await setup(enabled: true, responses: [reply(detail()), reply(error, status: 503)])
        do {
            _ = try await community.downloadCatalogFile(itemID: itemID, file: XCTUnwrap(item().recordedFiles.first))
            XCTFail("Advertised manifest failure must surface")
        } catch { XCTAssertEqual((error as? CommunityFailure)?.code, "manifest_busy") }
        let history = await transport.history()
        XCTAssertFalse(history.contains { $0.url?.path.hasPrefix("/media/") == true })
    }
    func testLateAccountSwitchDiscardsCapturedDownload() async throws {
        let (community, transport) = try await setup(enabled: true, responses: [reply(detail())])
        let file = try XCTUnwrap(item().recordedFiles.first)
        await transport.suspendNext()
        let operation = Task { try await community.downloadCatalogFile(itemID: itemID, file: file) }
        await transport.waitUntilHeld(); try community.forgetLocalSession(); await transport.resume()
        do { _ = try await operation.value; XCTFail("Old-account bytes cannot be accepted") } catch {}
    }
    func testLateMatureViewerPolicyChangeDiscardsCapturedDownload() async throws {
        let me = try json(["user": ["id": accountID.uuidString.lowercased(), "email": "fixture@example.invalid",
            "displayName": "Fixture", "role": "user", "verified": true, "allowMature": true] as [String: Any]])
        let (community, transport) = try await setup(enabled: true, responses: [reply(detail()), reply(me)])
        let file = try XCTUnwrap(item().recordedFiles.first)
        await transport.suspendNext()
        let operation = Task { try await community.downloadCatalogFile(itemID: itemID, file: file) }
        await transport.waitUntilHeld()
        try await community.setMaturePreference(true, expectedRevision: community.accountRevision)
        await transport.resume()
        do { _ = try await operation.value; XCTFail("Late policy result cannot be accepted") } catch {}
    }
    func testCapabilityLossRejectsLateResultInsteadOfDowngradingVerification() async throws {
        let config = try json(["requireEmailVerification": false, "catalogDownloadManifestEnabled": false])
        let (community, transport) = try await setup(enabled: true, responses: [reply(detail()), reply(config)])
        let file = try XCTUnwrap(item().recordedFiles.first)
        await transport.suspendNext()
        let operation = Task { try await community.downloadCatalogFile(itemID: itemID, file: file) }
        await transport.waitUntilHeld(); try await community.loadConfig(); await transport.resume()
        do { _ = try await operation.value; XCTFail("Capability changes cannot downgrade an in-flight download") } catch {}
    }
    func testChangedPostIOManifestDigestRejectsOtherwiseMatchingBytes() async throws {
        var changed = entry(); changed["sha256"] = String(repeating: "0", count: 64)
        let (community, _) = try await setup(enabled: true, responses: [
            reply(detail()), reply(manifest()), reply(gif()), reply(detail()), reply(manifest(files: [changed]))])
        do {
            _ = try await community.downloadCatalogFile(itemID: itemID, file: XCTUnwrap(item().recordedFiles.first))
            XCTFail("No changed manifest acceptance or silent retry")
        } catch {}
    }
    func testOfficialGuestManifestBrowsingDoesNotGainAccountOrAdminAccess() async throws {
        let (community, transport) = try await setup(enabled: true, guest: true, responses: [
            reply(detail()), reply(manifest()), reply(gif()), reply(detail()), reply(manifest())])
        let result = try await community.downloadCatalogFile(itemID: itemID, file: XCTUnwrap(item().recordedFiles.first))
        XCTAssertEqual(result.integrity, .manifestSHA256); XCTAssertFalse(community.isAdmin)
        let history = await transport.history()
        XCTAssertTrue(history.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertFalse(history.contains { $0.url?.path.contains("/admin/") == true })
    }
}
