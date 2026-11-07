import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor ArtworkTransport: CommunityTransport {
    var replies: [CommunityResponse]
    var requests: [URLRequest] = []
    var late: (@MainActor @Sendable () -> Void)?
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func setLate(_ action: @escaping @MainActor @Sendable () -> Void) { late = action }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected artwork fixture request.") }
        let value = replies.removeFirst()
        if request.url?.path.hasPrefix("/api/v1/admin/artwork") == true { await late?() }
        guard value.data.count <= maxBytes else { throw BackpackError.invalid("Artwork fixture exceeded byte budget.") }
        return value
    }
    func history() -> [URLRequest] { requests }
}
@MainActor private final class ArtworkVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class AdminArtworkTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let jobID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let itemID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private var base: String { "https://catalog.example" }
    private func origin() throws -> CommunityOrigin { try .parse(base) }
    private func gif(_ size: Int = 64) throws -> Data {
        try MediaCodec.encode([PixelFrame.black(PanelSize(width: size, height: size))], delays: [0.03], loopCount: nil)
    }
    private func object(status: String = "completed", settings: NativeArtworkSettings = .init(),
        source: UUID? = nil, parent: UUID? = nil) throws -> [String: Any] {
        let data = try gif()
        return ["id":jobID.uuidString.lowercased(),"sourceItemId":source.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
            "parentJobId":parent.map { $0.uuidString.lowercased() as Any } ?? NSNull(),"status":status,
            "settings":try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)),
            "error":NSNull(),"createdAt":"2026-11-06T12:00:00Z","updatedAt":"2026-11-06T12:00:00Z",
            "expiresAt":"2026-11-07T12:00:00Z","inputBytes":data.count,"resultBytes":status == "completed" ? data.count : 0,
            "inputUrl":["staging","cancelled"].contains(status) ? NSNull() : "\(base)/api/v1/admin/artwork/\(jobID.uuidString.lowercased())/input.gif",
            "resultUrl":status == "completed" ? "\(base)/api/v1/admin/artwork/\(jobID.uuidString.lowercased())/result.gif" : NSNull()]
    }
    private func decode(_ object: [String: Any]) throws -> NativeArtworkJob {
        try JSONDecoder().decode(NativeArtworkJob.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func reply(_ object: Any, status: Int = 200) throws -> CommunityResponse {
        .init(status: status, data: try JSONSerialization.data(withJSONObject: object))
    }
    private func setup(_ replies: [CommunityResponse] = [], role: String = "admin", enabled: Bool = true) async throws -> (CommunityController, ArtworkTransport) {
        let login = #"{"user":{"id":"\#(owner)","email":"artwork@example.invalid","displayName":"Synthetic admin","role":"\#(role)","verified":true},"token":"synthetic-artwork-bearer","expiresAt":"2099-01-01T00:00:00Z"}"#
        let config = #"{"requireEmailVerification":false,"artworkToolsEnabled":\#(enabled),"aiArtworkRedrawEnabled":false}"#
        let transport = ArtworkTransport([.init(status: 200, data: Data(login.utf8)), .init(status: 200, data: Data(config.utf8))] + replies)
        let controller = CommunityController(vault: ArtworkVault(), factory: { _ in transport })
        controller.configure(base)
        try await controller.signIn(email: "artwork@example.invalid", password: "synthetic-password")
        try await controller.loadConfig(); return (controller, transport)
    }
    private func scope(_ community: CommunityController) throws -> AccountServiceScope {
        try .init(community, capability: .artwork, admin: true)
    }
    func testSettingsDefaultsAndExactBoundaryNormalization() throws {
        let defaults = try NativeArtworkSettings().validated(redraw: false)
        XCTAssertEqual(defaults.mode, .cleanup); XCTAssertEqual(defaults.tolerance, 16)
        var value = defaults; value.prompt = "  explicit prompt  "; value.tolerance = 64
        XCTAssertEqual(try value.validated(redraw: false).prompt, "explicit prompt")
        value.tolerance = 65; XCTAssertThrowsError(try value.validated(redraw: false))
        value.tolerance = 0; value.prompt = String(repeating: "x", count: 1001)
        XCTAssertThrowsError(try value.validated(redraw: true))
    }
    func testRedrawIsIndependentlyUnavailableNotFakeDeterministicAI() throws {
        var value = NativeArtworkSettings(); value.mode = .redraw
        XCTAssertThrowsError(try value.validated(redraw: false))
        XCTAssertEqual(try value.validated(redraw: true).mode, .redraw)
    }
    func testJobRejectsUnknownStatus() throws {
        var value = try object(); value["status"] = "published"
        XCTAssertThrowsError(try decode(value))
    }
    func testJobRetentionAndSizeBoundsAreExact() throws {
        let valid = try decode(object()); try valid.validate(origin: origin())
        var value = try object(); value["expiresAt"] = "2026-11-08T12:00:00Z"
        XCTAssertThrowsError(try decode(value).validate(origin: origin()))
        value = try object(); value["inputBytes"] = 5_000_001
        XCTAssertThrowsError(try decode(value).validate(origin: origin()))
    }
    func testMediaRejectsForeignQueryUserinfoAndWrongJobAliases() throws {
        for url in ["https://foreign.example/input.gif", "\(base)/api/v1/admin/artwork/\(jobID)/input.gif?token=x",
            "https://name@catalog.example/api/v1/admin/artwork/\(jobID)/input.gif",
            "\(base)/api/v1/admin/artwork/\(itemID)/input.gif"] {
            var value = try object(); value["inputUrl"] = url
            XCTAssertThrowsError(try decode(value).validate(origin: origin()))
        }
    }
    func testCompletedNeedsResultButLegacyMissingInputIsTruthful() throws {
        var value = try object(); value["resultUrl"] = NSNull()
        XCTAssertThrowsError(try decode(value).validate(origin: origin()))
        value = try object(); value["inputUrl"] = NSNull(); value["inputBytes"] = 0
        XCTAssertNoThrow(try decode(value).validate(origin: origin()))
    }
    func testSourceBodyUsesExactlyOneCanonicalLowercaseLocatorAndSettings() throws {
        let bytes = try NativeArtworkSource.community(itemID).body(settings: .init())
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["sourceItemId","settings"])
        XCTAssertEqual(value["sourceItemId"] as? String, itemID.uuidString.lowercased())
        let branch = try XCTUnwrap(JSONSerialization.jsonObject(with: NativeArtworkSource.result(jobID).body(settings: .init())) as? [String: Any])
        XCTAssertEqual(Set(branch.keys), ["sourceJobId","settings"])
    }
    func testMultipartIsMetadataFirstAndContainsNoPublicationGrant() throws {
        let upload = try NativeArtworkUpload.inspect(gif(1))
        let body = try upload.multipart(settings: .init(), boundary: "Artwork-0123456789")
        let metadata = try XCTUnwrap(body.range(of: Data("name=\"metadata\"".utf8)))
        let file = try XCTUnwrap(body.range(of: Data("name=\"file\"".utf8)))
        XCTAssertLessThan(metadata.lowerBound, file.lowerBound)
        XCTAssertNil(body.range(of: Data("sharingAttested".utf8)))
        XCTAssertNil(body.range(of: Data("visibility".utf8)))
        XCTAssertNotNil(body.range(of: upload.data))
    }
    func testMultipartRejectsInvalidOrCollidingBoundary() throws {
        let upload = try NativeArtworkUpload.inspect(gif(1))
        XCTAssertThrowsError(try upload.multipart(settings: .init(), boundary: "x\r\nbad"))
        var settings = NativeArtworkSettings(); settings.prompt = "Artwork-0123456789"
        XCTAssertThrowsError(try upload.multipart(settings: settings, boundary: "Artwork-0123456789"))
    }
    func testCorruptAndResourceExhaustingInputIsRejectedWithoutRepair() {
        XCTAssertThrowsError(try NativeArtworkUpload.inspect(Data([1,2,3])))
        XCTAssertThrowsError(try NativeArtworkUpload.inspect(Data(repeating: 0, count: 5_000_001)))
    }
    func testDisabledCapabilityAndNonadminScopesCannotSend() async throws {
        let (disabled, transport) = try await setup(enabled: false)
        XCTAssertThrowsError(try scope(disabled))
        let (user, _) = try await setup(role: "user")
        XCTAssertThrowsError(try scope(user))
        let (admin, _) = try await setup()
        XCTAssertThrowsError(try AccountServiceScope(admin, capability: .artwork))
        let history = await transport.history(); XCTAssertEqual(history.count, 2)
    }
    func testArtworkScopeCannotReachCloudPrivateLibrariesOrOtherAdminTools() async throws {
        let (community, transport) = try await setup(), client = try scope(community)
        for path in ["cloud","admin/users","social/peer-reports","admin/artwork/../users"] {
            do { _ = try await client.bytes(path); XCTFail("No cross-scope grant") } catch {}
        }
        do { _ = try await client.bytes("items", method: "POST"); XCTFail("No community publication from artwork scope") } catch {}
        let history = await transport.history(); XCTAssertEqual(history.count, 2)
    }
    func testOwnedListRejectsDuplicateJobsInsteadOfSilentlyDeduplicating() async throws {
        let job = try object()
        let (community, _) = try await setup([reply(["jobs":[job,job]])])
        do { _ = try await scope(community).artworkJobs(); XCTFail("Duplicate list") } catch {}
    }
    func testCreateCommunityJobUsesActualMutationAuthAndNoUploadPolicy() async throws {
        let job = try object(status: "queued", source: itemID)
        let (community, transport) = try await setup([reply(["job":job], status: 202)])
        let result = try await scope(community).createArtwork(source: .community(itemID), upload: nil, settings: .init())
        XCTAssertEqual(result.sourceItemId, itemID)
        let history = await transport.history(), request = try XCTUnwrap(history.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/admin/artwork")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-artwork-bearer")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Catalog-Upload-Policy"))
    }
    func testCreateRejectsWrongStatusEvenForSuccessShapedBody() async throws {
        let (community, _) = try await setup([reply(["job":object(status: "queued", source: itemID)], status: 200)])
        do { _ = try await scope(community).createArtwork(source: .community(itemID), upload: nil, settings: .init()); XCTFail("Expected202") } catch {}
    }
    func testCreateRequiresExactlyOneExplicitSource() async throws {
        let (community, transport) = try await setup(), client = try scope(community)
        let upload = try NativeArtworkUpload.inspect(gif(1))
        do { _ = try await client.createArtwork(source: nil, upload: nil, settings: .init()); XCTFail("No source") } catch {}
        do { _ = try await client.createArtwork(source: .community(itemID), upload: upload, settings: .init()); XCTFail("Two sources") } catch {}
        let history = await transport.history(); XCTAssertEqual(history.count, 2)
    }
    func testBranchRequiresCurrentCompletedOwnedResult() async throws {
        let (community, transport) = try await setup([reply(["job":object(status: "running")])])
        do { _ = try await scope(community).createArtwork(source: .result(jobID), upload: nil, settings: .init()); XCTFail("Not ready") } catch {}
        let history = await transport.history(); XCTAssertEqual(history.count, 3)
        XCTAssertFalse(history.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/v1/admin/artwork" })
    }
    func testUploadStaysPrivateEditingInputWithExactMetadataAndFileOrder() async throws {
        let job = try object(status: "queued")
        let (community, transport) = try await setup([reply(["job":job], status: 202)])
        _ = try await scope(community).createArtwork(source: nil, upload: NativeArtworkUpload.inspect(gif(1)), settings: .init())
        let history = await transport.history(), request = try XCTUnwrap(history.last)
        XCTAssertEqual(request.url?.path, "/api/v1/admin/artwork/upload")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Catalog-Upload-Policy"))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertLessThan(try XCTUnwrap(body.range(of: Data("name=\"metadata\"".utf8))).lowerBound,
            try XCTUnwrap(body.range(of: Data("name=\"file\"".utf8))).lowerBound)
    }
    func testAdvertisedRedrawFalseStopsBeforeAnyJobSubmission() async throws {
        let (community, transport) = try await setup()
        var settings = NativeArtworkSettings(); settings.mode = .redraw
        do { _ = try await scope(community).createArtwork(source: .community(itemID), upload: nil, settings: settings); XCTFail("No fake AI") } catch {}
        let history = await transport.history(); XCTAssertEqual(history.count, 2)
    }
    func testMediaUsesCanonicalAuthenticatedRoutesAndBeforeAfterProof() async throws {
        let payload = try object(), bytes = try gif(), selected = try decode(payload)
        let (community, transport) = try await setup([reply(["job":payload]), .init(status: 200, data: bytes), reply(["job":payload])])
        let media = try await scope(community).artworkMedia(selected, input: false)
        XCTAssertEqual(media.data, bytes)
        let history = await transport.history()
        XCTAssertEqual(history[3].url?.path, "/api/v1/admin/artwork/\(jobID.uuidString.lowercased())/result.gif")
        XCTAssertEqual(history.count, 5)
    }
    func testWrongCanvasAndChangedPostReadStateRejectResult() async throws {
        var descriptor = try object(), changed = try object()
        let small = try gif(1)
        descriptor["resultBytes"] = small.count
        let (community, _) = try await setup([reply(["job":descriptor]), .init(status: 200, data: small)])
        do { _ = try await scope(community).artworkMedia(decode(descriptor), input: false); XCTFail("Not64x64") }
        catch { XCTAssertTrue(error.localizedDescription.contains("64")) }
        changed["error"] = "State changed"
        let good = try object(), bytes = try gif()
        let (second, _) = try await setup([reply(["job":good]), .init(status: 200, data: bytes), reply(["job":changed])])
        do { _ = try await scope(second).artworkMedia(decode(good), input: false); XCTFail("Late state") }
        catch { XCTAssertTrue(error.localizedDescription.contains("after I/O")) }
    }
    func testLateAccountChangeCannotAdoptOwnedJobs() async throws {
        let (community, transport) = try await setup([reply(["jobs":[object()]])])
        let client = try scope(community)
        await transport.setLate { community.configure("https://changed.example") }
        do { _ = try await client.artworkJobs(); XCTFail("Old account/origin") } catch {}
    }
    func testCancelRemoveIsExplicitAndChecksActualReceipt() async throws {
        let payload = try object(), selected = try decode(payload)
        let (community, transport) = try await setup([reply(["job":payload]), reply(["message":"Artwork job cancelled/removed; source GIF is unchanged"])])
        try await scope(community).removeArtwork(selected)
        let history = await transport.history()
        XCTAssertEqual(history.last?.httpMethod, "DELETE")
        XCTAssertNil(history.last?.httpBody)
    }
    func testStoreClearInvalidatesContextAndDropsPrivateDraftState() async throws {
        let (community, _) = try await setup()
        let store = AdminArtworkStore(); store.bind(community)
        let before = store.context
        store.submit(.init(), consent: false)
        XCTAssertNotNil(store.failure)
        store.clear()
        XCTAssertNotEqual(store.context, before); XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertNil(store.selected); XCTAssertNil(store.upload); XCTAssertNil(store.input); XCTAssertNil(store.result)
        XCTAssertFalse(store.busy); XCTAssertFalse(store.uncertainSubmission)
    }
}
