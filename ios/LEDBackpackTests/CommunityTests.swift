import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor CommunityStub: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected test request.") }
        let response = responses.removeFirst()
        guard response.data.count <= maxBytes else { throw BackpackError.invalid("Test response exceeds limit.") }
        return response
    }
    func history() -> [URLRequest] { requests }
}

private actor DeferredCommunityStub: CommunityTransport {
    private var initial: [CommunityResponse]
    private var response: CheckedContinuation<CommunityResponse, Error>?
    private var notification: CheckedContinuation<Void, Never>?
    private var started = false
    init(_ initial: [CommunityResponse] = []) { self.initial = initial }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        if !initial.isEmpty { return initial.removeFirst() }
        started = true; notification?.resume(); notification = nil
        return try await withCheckedThrowingContinuation { response = $0 }
    }
    func waitForRequest() async {
        if started { return }
        await withCheckedContinuation { notification = $0 }
    }
    func finish(_ value: CommunityResponse) {
        response?.resume(returning: value)
        response = nil
    }
}

@MainActor
private final class CommunityMemoryVault: CommunityVault {
    var values: [String: Data] = [:]
    var events: [String] = []
    var failWrites = false
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws {
        if failWrites { throw BackpackError.invalid("Vault unavailable") }
        values[key] = data; events.append("save:\(key)")
    }
    func remove(_ key: String) throws { values[key] = nil; events.append("remove:\(key)") }
}

@MainActor
final class CommunityTests: XCTestCase {
    private let root = "https://catalog.example"
    private let token = "test-only-opaque-bearer-not-a-real-credential"
    private let receiptID = "9bdc44d9-a300-46aa-8062-c120d6d87ddd"
    func testDefaultCatalogPreservesOverridesAndExplicitDisable() throws {
        var preferences = Preferences()
        XCTAssertEqual(preferences.effectiveCommunityURL, "https://led.errantactions.com")
        preferences.communityURL = "https://custom.example"
        XCTAssertEqual(preferences.effectiveCommunityURL, "https://custom.example")
        preferences.communityURL = ""
        XCTAssertNil(preferences.effectiveCommunityURL)
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertNil(restored.effectiveCommunityURL)
    }
    private func response(_ value: String, status: Int = 200) -> CommunityResponse {
        CommunityResponse(status: status, data: Data(value.utf8))
    }
    private func login(verified: Bool = false, role: String = "user") -> CommunityResponse {
        response("""
        {"user":{"id":"223609c9-cc77-4818-8951-0c55acdaab4e","email":"test@example.org","displayName":"Rider","role":"\(role)","verified":\(verified)},"token":"\(token)","expiresAt":"2099-01-01T00:00:00.000Z"}
        """)
    }
    private func receipt(status: String = "pending", origin: String? = nil, http: Int = 202) -> CommunityResponse {
        response("""
        {"deletion":{"id":"\(receiptID)","status":"\(status)","statusUrl":"\(origin ?? root)/api/v1/account-deletions/\(receiptID)","requestedAt":"2026-01-01T00:00:00.000Z","completedAt":null,"error":null}}
        """, status: http)
    }
    private func client(_ stub: any CommunityTransport, vault: CommunityMemoryVault) -> CommunityController {
        let value = CommunityController(vault: vault, factory: { _ in stub })
        value.configure(root)
        return value
    }

    func testHTTPSRootAndReceiptOriginAreStrict() throws {
        let origin = try CommunityOrigin.parse(root)
        XCTAssertEqual(try CommunityOrigin.parse("\(root):443"), origin)
        for invalid in ["http://catalog.example", "\(root)/api/v1", "\(root)?token=bad",
            "https://user:password@catalog.example", "\(root)#fragment"] {
            XCTAssertThrowsError(try CommunityOrigin.parse(invalid))
        }
        XCTAssertFalse(origin.contains(try XCTUnwrap(URL(string: "https://another.example/media/a.gif"))))
        XCTAssertFalse(origin.contains(try XCTUnwrap(URL(string: "http://catalog.example/media/a.gif"))))
        XCTAssertFalse(origin.contains(try XCTUnwrap(URL(string: "https://catalog.example:8443/media/a.gif"))))
        let data = receipt(origin: "https://another.example").data
        let foreign = try JSONDecoder().decode(CommunityDeletionResponse.self, from: data).deletion
        XCTAssertThrowsError(try origin.checkReceipt(foreign))
    }

    func testImmediateSignupDoesNotFakeEmailVerification() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([response(#"{"requireEmailVerification":false,"accountDeletionRetainsSharedGifs":false}"#),
            response(#"{"message":"Created"}"#, status: 201), login()])
        let service = client(stub, vault: vault)
        _ = try await service.signUp(email: "test@example.org", password: "example test password", displayName: "Rider")
        XCTAssertEqual(service.config?.requireEmailVerification, false)
        XCTAssertTrue(service.signedIn)
        XCTAssertEqual(service.user?.verified, false)
        let requests = await stub.history()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST"])
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        let payload = try XCTUnwrap(requests[2].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
        XCTAssertEqual(object["transport"], "bearer")
        XCTAssertEqual(vault.values.count, 1)
    }

    func testVerificationSignupDoesNotCreateASession() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([response(#"{"requireEmailVerification":true,"accountDeletionRetainsSharedGifs":false}"#),
            response(#"{"message":"Check email"}"#, status: 202)])
        let service = client(stub, vault: vault)
        let message = try await service.signUp(email: "test@example.org", password: "example test password", displayName: "Rider")
        XCTAssertEqual(message, "Check email")
        XCTAssertFalse(service.signedIn)
        XCTAssertTrue(vault.values.isEmpty)
    }

    func testDeletionRetainsReceiptClearsCredentialsAndPollsWithoutBearer() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login(), receipt(), receipt(status: "completed", http: 200)])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        try await service.deleteAccount(password: "example test password", confirmation: "DELETE")
        XCTAssertFalse(service.signedIn)
        XCTAssertNil(service.user)
        XCTAssertEqual(service.deletion?.status, .pending)
        XCTAssertNil(vault.values["session|\(root)"])
        XCTAssertNotNil(vault.values["deletion|\(root)"])
        let saved = try XCTUnwrap(vault.events.firstIndex(of: "save:deletion|\(root)"))
        let removed = try XCTUnwrap(vault.events.firstIndex(of: "remove:session|\(root)"))
        XCTAssertLessThan(saved, removed)
        try await service.refreshDeletion()
        XCTAssertEqual(service.deletion?.status, .completed)
        let requests = await stub.history()
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(requests[2].httpShouldHandleCookies)
    }

    func testWrongDeletionPasswordKeepsTheExistingSession() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login(), response(#"{"error":{"code":"invalid_password","message":"Wrong password"}}"#, status: 401)])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        do {
            try await service.deleteAccount(password: "wrong", confirmation: "DELETE")
            XCTFail("Wrong password must fail")
        } catch { XCTAssertEqual(error.localizedDescription, "Wrong password") }
        XCTAssertTrue(service.signedIn)
        XCTAssertNotNil(vault.values["session|\(root)"])
    }

    func testImmediateDeletionAndOwnerTransferFailureAreDistinct() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login(),
            response(#"{"error":{"code":"owner_transfer_required","message":"Transfer ownership first"}}"#, status: 409),
            receipt(status: "completed", http: 200)])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        do {
            try await service.deleteAccount(password: "example test password", confirmation: "DELETE")
            XCTFail("Owner protection must surface")
        } catch let error as CommunityFailure {
            XCTAssertEqual(error.code, "owner_transfer_required")
        }
        XCTAssertTrue(service.signedIn)
        XCTAssertNil(service.deletion)
        try await service.deleteAccount(password: "example test password", confirmation: "DELETE")
        XCTAssertFalse(service.signedIn)
        XCTAssertEqual(service.deletion?.status, .completed)
    }

    func testInvalidConfirmationDoesNotSendADeletionRequest() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login()])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        do {
            try await service.deleteAccount(password: "example test password", confirmation: "delete")
            XCTFail("Explicit confirmation is required")
        } catch { XCTAssertTrue(error.localizedDescription.contains("DELETE")) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(service.signedIn)
    }

    func testBadReceiptStillClearsRevokedCredentials() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login(), receipt(origin: "https://another.example")])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        do {
            try await service.deleteAccount(password: "example test password", confirmation: "DELETE")
            XCTFail("Foreign receipt must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Deletion was accepted")) }
        XCTAssertFalse(service.signedIn)
        XCTAssertNil(vault.values["session|\(root)"])
        XCTAssertNil(service.deletion)
    }

    func testReceiptSaveFailureDoesNotRetainSession() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login(), receipt()])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        vault.failWrites = true
        do {
            try await service.deleteAccount(password: "example test password", confirmation: "DELETE")
            XCTFail("Unstored receipt must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be saved")) }
        XCTAssertFalse(service.signedIn)
        XCTAssertNil(vault.values["session|\(root)"])
        XCTAssertEqual(service.deletion?.status, .pending)
    }

    func testCredentialIsNotSavedOnAnotherServerAfterAnInflightLogin() async throws {
        let vault = CommunityMemoryVault()
        let stub = DeferredCommunityStub()
        let service = client(stub, vault: vault)
        let operation = Task { try await service.signIn(email: "test@example.org", password: "example test password") }
        await stub.waitForRequest()
        service.configure("https://other.example")
        await stub.finish(login())
        do { try await operation.value; XCTFail("Changed server must reject old login") }
        catch { XCTAssertTrue(error.localizedDescription.contains("server changed")) }
        XCTAssertFalse(service.signedIn)
        XCTAssertTrue(vault.values.isEmpty)
    }

    func testOldDeletionDoesNotEraseANewServerSession() async throws {
        let vault = CommunityMemoryVault()
        let old = DeferredCommunityStub([login()])
        let other = CommunityStub([login()])
        let service = CommunityController(vault: vault, factory: { origin in
            if origin.url.host == "catalog.example" { return old }
            return other
        })
        service.configure(root)
        try await service.signIn(email: "test@example.org", password: "example test password")
        let operation = Task { try await service.deleteAccount(password: "example test password", confirmation: "DELETE") }
        await old.waitForRequest()
        service.configure("https://other.example")
        try await service.signIn(email: "test@example.org", password: "example test password")
        await old.finish(receipt())
        try await operation.value
        XCTAssertTrue(service.signedIn)
        XCTAssertNotNil(vault.values["session|https://other.example"])
        XCTAssertNil(vault.values["session|\(root)"])
        XCTAssertNotNil(vault.values["deletion|\(root)"])
    }

    func testDeletionReceiptRestoresIndependentlyOfBadSavedCredentials() async throws {
        let vault = CommunityMemoryVault()
        vault.values["session|\(root)"] = Data("invalid session".utf8)
        let saved = try JSONDecoder().decode(CommunityDeletionResponse.self, from: receipt().data).deletion
        vault.values["deletion|\(root)"] = try JSONEncoder().encode(saved)
        let stub = CommunityStub([receipt(status: "completed", http: 200)])
        let service = client(stub, vault: vault)
        XCTAssertFalse(service.signedIn)
        XCTAssertNotNil(service.setupError)
        XCTAssertEqual(service.deletion?.id, receiptID)
        XCTAssertEqual(service.origin?.url.absoluteString, root)
        try await service.refreshDeletion()
        XCTAssertEqual(service.deletion?.status, .completed)
        let requests = await stub.history()
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testInvalidServerConfigurationDoesNotKeepUsingOldCredentials() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login()])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        service.configure("http://insecure.example")
        XCTAssertNil(service.origin)
        XCTAssertFalse(service.signedIn)
        XCTAssertNil(service.user)
        XCTAssertNotNil(service.setupError)
        do { _ = try await service.request("config"); XCTFail("Invalid origin must not send requests") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Configure")) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 1)
    }

    func testRejectedAuthDoesNotAutomaticallyRetryAsGuestOrAnotherOrigin() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login(), response(#"{"error":{"code":"unauthorized","message":"Session ended"}}"#, status: 401)])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        do { _ = try await service.items(query: "", category: "memes", page: 1); XCTFail("Auth failure must surface") }
        catch { XCTAssertTrue(error.localizedDescription.contains("sign-in ended")) }
        do { _ = try await service.download(XCTUnwrap(URL(string: "https://another.example/media/secret.gif"))); XCTFail("Foreign media must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("this catalog")) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 2)
    }

    func testCommunityMutationsUseCanonicalIDsAndCustomHeader() async throws {
        let vault = CommunityMemoryVault()
        let stub = CommunityStub([login(), response(#"{"likeCount":4}"#),
            response(#"{"message":"Reported"}"#), response(#"{"message":"Blocked"}"#)])
        let service = client(stub, vault: vault)
        try await service.signIn(email: "test@example.org", password: "example test password")
        let id = try XCTUnwrap(UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef"))
        let count = try await service.like(id)
        XCTAssertEqual(count, 4)
        try await service.report(id, reason: "Rights concern")
        try await service.block(id)
        let requests = await stub.history()
        XCTAssertTrue(try XCTUnwrap(requests[1].url?.path).contains(id.uuidString.lowercased()))
        XCTAssertTrue(try XCTUnwrap(requests[2].url?.path).contains(id.uuidString.lowercased()))
        let body = try XCTUnwrap(requests[3].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["userId"], id.uuidString.lowercased())
        for request in requests.dropFirst() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Client"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        }
    }

        func testNativeUploadUsesBearerAndOrderedMultipartThenLoadsOwnStatus() async throws {
            let item = #"{"id":"abcdefab-1234-4567-89ab-abcdefabcdef","title":"Test","visibility":"private","status":"pending","moderationReason":"","aiState":"disabled","aiError":null}"#
            let stub = CommunityStub([login(role: "admin"),
                response(#"{"requireEmailVerification":false,"privateLibraryEnabled":true,"accountDeletionRetainsSharedGifs":true}"#),
                response("{\"item\":\(item)}", status: 201),
                response("{\"items\":[\(item)]}"), response(#"{"message":"Deleted"}"#)])
            let service = client(stub, vault: CommunityMemoryVault())
            try await service.signIn(email: "test@example.org", password: "example test password")
            let size = PanelSize(width: 16, height: 16)
            let gif = try MediaCodec.encode([.black(size), MediaCodec.text("A", size: size)], delays: [0.1, 0.1])
            let metadata = CommunityUploadMetadata(title: "Test", category: "memes", tags: [],
                attribution: "Test creator", license: .original, ownershipAttested: true)
            let uploaded = try await service.uploadGIF(gif, metadata: metadata)
            XCTAssertEqual(uploaded.status, "pending")
            let uploads = try await service.myUploads()
            XCTAssertEqual(uploads.count, 1)
            try await service.deleteUpload(uploaded.id)
            let requests = await stub.history()
            let upload = requests[2]
            XCTAssertEqual(upload.httpMethod, "POST")
            XCTAssertEqual(upload.url?.path, "/api/v1/items")
            XCTAssertEqual(upload.value(forHTTPHeaderField: "X-Catalog-Client"), "1")
            XCTAssertEqual(upload.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertTrue(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=LEDBackpack-") == true)
            let data = try XCTUnwrap(upload.httpBody)
            let meta = try XCTUnwrap(data.range(of: Data("name=\"metadata\"".utf8)))
            let file = try XCTUnwrap(data.range(of: Data("name=\"file\"".utf8)))
            XCTAssertLessThan(meta.lowerBound, file.lowerBound)
            XCTAssertEqual(requests[3].url?.path, "/api/v1/me/items")
            XCTAssertEqual(requests[4].httpMethod, "DELETE")
        }

        func testUploadRequiresAnAccountAndSurfacesServerRejection() async throws {
            let stub = CommunityStub([login(),
                response(#"{"requireEmailVerification":false,"privateLibraryEnabled":true,"accountDeletionRetainsSharedGifs":true}"#),
                response(#"{"error":{"code":"duplicate","message":"Already uploaded"}}"#, status: 409)])
            let service = client(stub, vault: CommunityMemoryVault())
            let metadata = CommunityUploadMetadata(title: "Test", category: "memes", tags: [],
                attribution: "Test creator", license: .original, ownershipAttested: true)
            do { _ = try await service.uploadGIF(Data(), metadata: metadata); XCTFail("Guest upload must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Sign in")) }
            try await service.signIn(email: "test@example.org", password: "example test password")
            let size = PanelSize(width: 16, height: 16)
            let gif = try MediaCodec.encode([.black(size), MediaCodec.text("A", size: size)], delays: [0.1, 0.1])
            do { _ = try await service.uploadGIF(gif, metadata: metadata); XCTFail("Duplicate must fail") }
            catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 409) }
            let requests = await stub.history()
            XCTAssertEqual(requests.count, 3)
        }

    func testRetentionOrUnknownPolicyBlocksSignupBeforeCredentialsArePosted() async throws {
        for policy in [#"{"requireEmailVerification":false,"accountDeletionRetainsSharedGifs":true}"#,
                       #"{"requireEmailVerification":false}"#] {
            let stub = CommunityStub([response(policy)])
            let service = client(stub, vault: CommunityMemoryVault())
            do {
                _ = try await service.signUp(email: "test@example.org", password: "example test password", displayName: "Rider")
                XCTFail("Retention or unknown policy must gate native signup")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Native signup")) }
            let requests = await stub.history()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.path, "/api/v1/config")
            XCTAssertNil(requests.first?.httpBody)
            XCTAssertFalse(service.signedIn)
        }
    }

    func testOrdinaryUsersCannotDeleteIndividualUploads() async throws {
        let stub = CommunityStub([login()])
        let service = client(stub, vault: CommunityMemoryVault())
        try await service.signIn(email: "test@example.org", password: "example test password")
        do { try await service.deleteUpload(UUID()); XCTFail("Deletion must be admin-only") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Only catalog admins")) }
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 1)
    }

    func testSharingIsASeparateExplicitRequest() async throws {
        let item = #"{"id":"abcdefab-1234-4567-89ab-abcdefabcdef","title":"Test","visibility":"shared","status":"pending","moderationReason":"","aiState":"queued","aiError":null}"#
        let stub = CommunityStub([login(), response("{\"item\":\(item)}")])
        let service = client(stub, vault: CommunityMemoryVault())
        try await service.signIn(email: "test@example.org", password: "example test password")
        let id = try XCTUnwrap(UUID(uuidString: "abcdefab-1234-4567-89ab-abcdefabcdef"))
        do { _ = try await service.submitUpload(id, sharingAttested: false); XCTFail("Consent is required") }
        catch { XCTAssertTrue(error.localizedDescription.contains("confirm publication")) }
        let shared = try await service.submitUpload(id, sharingAttested: true)
        XCTAssertEqual(shared.visibility, "shared")
        let requests = await stub.history()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.path, "/api/v1/items/\(id.uuidString.lowercased())/submit")
        let body = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        XCTAssertEqual(object, ["sharingAttested": true])
    }

    func testDeletedUploaderAndRetentionReceiptDecodeWithoutInventingIdentity() throws {
        let item = Data("""
        {"id":"abcdefab-1234-4567-89ab-abcdefabcdef","title":"Retained","category":"memes","tags":[],
        "displayAttribution":"Original creator","license":"original","licenseUrl":null,"sourceUrl":null,
        "pageUrl":"https://catalog.example/items/abcdefab-1234-4567-89ab-abcdefabcdef",
        "gifUrl":"https://catalog.example/media/a/original.gif","previewUrl":"https://catalog.example/media/a/preview.png",
        "width":64,"height":64,"frameCount":2,"byteSize":1000,"variants":[],"likeCount":0,
        "uploader":{"id":null,"displayName":"Deleted account"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(CommunityItem.self, from: item)
        XCTAssertNil(decoded.uploader.id)
        XCTAssertEqual(decoded.uploader.displayName, "Deleted account")
        XCTAssertEqual(decoded.displayAttribution, "Original creator")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt(status: "completed", http: 200).data) as? [String: Any])
        var deletion = try XCTUnwrap(object["deletion"] as? [String: Any])
        deletion["retainedSharedGifs"] = 2
        object["deletion"] = deletion
        let result = try JSONDecoder().decode(CommunityDeletionResponse.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(result.deletion.retainedSharedGifs, 2)
        XCTAssertEqual(result.deletion.status, .completed)
    }
}
