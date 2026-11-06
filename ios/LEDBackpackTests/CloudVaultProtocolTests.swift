import XCTest
import CryptoKit
import BackpackProtocol
@testable import LEDBackpack

private actor CloudTransportFixture: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected cloud test request.") }
        let response = responses.removeFirst()
        guard response.data.count <= maxBytes else { throw BackpackError.invalid("Cloud test response exceeds its budget.") }
        return response
    }
    func history() -> [URLRequest] { requests }
}

@MainActor
private final class CloudAccountFixture: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}

@MainActor
final class CloudVaultProtocolTests: XCTestCase {
    private let origin = "https://catalog.example"
    private let account = "11111111-1111-4111-8111-111111111111"
    private let keyID = "22222222-2222-4222-8222-222222222222"
    private let otherKey = "44444444-4444-4444-8444-444444444444"
    private let itemID = "33333333-3333-4333-8333-333333333333"
    private var scope: CloudVaultScope {
        get throws { CloudVaultScope(origin: try CommunityOrigin.parse(origin), accountID: try XCTUnwrap(UUID(uuidString: account)), revision: UUID()) }
    }
    private func state(generation: Int = 7, revision: Int = 3, enabled: Bool = true, held: Bool = false,
        key: String? = nil) -> CloudVaultState {
        CloudVaultState(protocolVersion: 1, accountId: account, origin: origin, enabled: enabled, deleting: false,
            mode: held ? .userHeld : .managed, generation: generation, revision: revision,
            keyId: enabled ? (key ?? keyID) : nil, migrationId: nil,
            recovery: held ? CloudPasswordWrap(salt: CloudVaultWire.base64(Data(count: 16)), wrappedKey: CloudVaultWire.base64(Data(count: 60))) : nil,
            passkeys: [], controlPublicKey: held ? CloudVaultWire.base64(Data(count: 32)) : nil,
            userHeldEnrollmentAvailable: true, deviceAdoptionAvailable: true, itemLimit: 100,
            maxPlaintextBytes: 5_000_000, legacyMigrationPending: false, legacyMigrationError: nil, legacyItemCount: 0)
    }
    private func item(_ number: Int = 3, held: Bool = false, generation: Int = 7, version: Int = 1,
        bytes: Data = Data("GIF89a-test-transport-only".utf8)) throws -> CloudVaultItem {
        let id = String(format: "33333333-3333-4333-8333-%012d", number)
        let metadata = Data(repeating: 1, count: 28)
        return CloudVaultItem(id: id, accountId: account, origin: origin, keyId: keyID, mode: held ? .userHeld : .managed,
            generation: generation, version: version, byteSize: bytes.count, storageBytes: bytes.count + 100, encrypted: held,
            metadata: held ? .string(CloudVaultWire.base64(metadata)) : .object(["title": .string("Public test fixture")]),
            legacyItemId: nil,
            dataHash: held ? CloudVaultWire.digest(bytes) : CloudVaultWire.digest(Data("stored ciphertext, NOT plaintext".utf8)),
            metadataHash: CloudVaultWire.digest(metadata), updatedAt: "2026-01-01T00:00:00.000Z",
            downloadUrl: try XCTUnwrap(URL(string: "\(origin)/api/v1/cloud/items/\(id)/media?generation=\(generation)&version=\(version)")))
    }
    private func response<T: Encodable>(_ name: String, _ value: T) throws -> CommunityResponse {
        let object = try JSONSerialization.jsonObject(with: CloudVaultWire.json(value))
        return CommunityResponse(status: 200, data: try JSONSerialization.data(withJSONObject: [name: object]))
    }
    private func page(_ values: [CloudVaultItem], page: Int = 1, total: Int? = nil, revision: Int = 3) throws -> CommunityResponse {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CloudVaultWire.json(state(revision: revision))) as? [String: Any])
        object["items"] = try JSONSerialization.jsonObject(with: CloudVaultWire.json(values))
        object["page"] = page; object["limit"] = 100; object["total"] = total ?? values.count
        return CommunityResponse(status: 200, data: try JSONSerialization.data(withJSONObject: object))
    }
    private func client(_ fixture: CloudTransportFixture) throws -> CloudVaultClient {
        CloudVaultClient(scope: try scope, send: { request, limit in try await fixture.send(request, maxBytes: limit) })
    }
    private func fails(file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected an explicit cloud failure.", file: file, line: line) }
        catch {}
    }

    func testCanonicalIdentifiersBinaryAndExactAAD() throws {
        XCTAssertNoThrow(try CloudVaultWire.id(itemID))
        XCTAssertThrowsError(try CloudVaultWire.id("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        for invalid in ["AA==", "+w", "/w", "AB", "AA\n", "a"] {
            XCTAssertThrowsError(try CloudVaultWire.bytes(invalid, min: 1, max: 32))
        }
        XCTAssertEqual(try CloudVaultWire.bytes("_w", min: 1, max: 1), Data([255]))
        XCTAssertEqual(try CloudVaultWire.wrapAAD(account: account, key: keyID),
            "catalog-cloud-wrap-v1\n\(account)\n\(keyID)\npassword\n")
        XCTAssertEqual(try CloudVaultWire.assetAAD(account: account, generation: 7, key: keyID, item: itemID, version: 2, purpose: "data"),
            "catalog-cloud-asset-v1\n\(account)\n7\n\(keyID)\n\(itemID)\n2\ndata")
        XCTAssertThrowsError(try scope.validate(account: account, origin: origin + "/"))
        XCTAssertThrowsError(try scope.validate(account: otherKey, origin: origin))
    }

    func testUnknownLegacyMetadataSurvivesRoundTrip() throws {
        let data = Data(#"{"title":"Test","contentHash":"unknown-legacy-format","custom":{"credits":["One",null,3.5],"flag":true}}"#.utf8)
        let object = try JSONDecoder().decode(CloudJSON.self, from: data)
        XCTAssertEqual(try JSONDecoder().decode(CloudJSON.self, from: CloudVaultWire.json(object)), object)
    }

    func testDevicePinPausesOnResetAndNeverAutomaticallyReenables() throws {
        var pin = CloudDevicePin()
        try pin.accept(state())
        XCTAssertTrue(pin.paused)
        pin.paused = false
        try pin.accept(state(generation: 8, revision: 4, enabled: false))
        XCTAssertTrue(pin.paused); XCTAssertTrue(pin.remoteReset)
        try pin.accept(state(generation: 8, revision: 4, key: otherKey))
        XCTAssertTrue(pin.paused)
    }

    func testPinnedHeldModeRejectsDowngradeRollbackAndSameGenerationKeyReplacement() throws {
        var pin = CloudDevicePin()
        try pin.accept(state(held: true)); pin.paused = false
        XCTAssertThrowsError(try pin.accept(state(revision: 4)))
        XCTAssertTrue(pin.paused); XCTAssertTrue(pin.userHeld)
        XCTAssertThrowsError(try pin.accept(state(generation: 6, held: true)))
        var managed = CloudDevicePin()
        try managed.accept(state()); managed.paused = false
        XCTAssertThrowsError(try managed.accept(state(revision: 4, key: otherKey)))
        XCTAssertTrue(managed.paused)
    }

    func testLedgerPersistsPauseAndRecognizesForeignAccountAndOriginLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try CloudVaultLedger(folder: folder), scope = try self.scope
        let local = UUID()
        var pin = CloudDevicePin()
        pin.links[local.uuidString.lowercased()] = CloudLocalLink(remoteID: itemID, generation: 7, version: 1,
            localHash: CloudVaultWire.digest(Data()), localMetadataHash: CloudVaultWire.digest(Data("metadata".utf8)))
        try ledger.save(pin, scope: scope)
        let reopened = try CloudVaultLedger(folder: folder)
        XCTAssertTrue(try reopened.pin(scope).paused)
        XCTAssertNotNil(try reopened.pin(scope).links[local.uuidString.lowercased()]?.localMetadataHash)
        XCTAssertFalse(try reopened.hasForeignLink(local, scope: scope))
        let other = CloudVaultScope(origin: scope.origin, accountID: try XCTUnwrap(UUID(uuidString: otherKey)), revision: UUID())
        XCTAssertTrue(try reopened.hasForeignLink(local, scope: other))
        let server = CloudVaultScope(origin: try CommunityOrigin.parse("https://other.example"), accountID: scope.accountID, revision: UUID())
        XCTAssertTrue(try reopened.hasForeignLink(local, scope: server))
    }

    func testSnapshotPreservesGrandfathered101ItemsAndBindsLaterPages() async throws {
        let first = try (1...100).map { try item($0) }, last = try item(101)
        let fixture = CloudTransportFixture([try page(first, total: 101), try page([last], page: 2, total: 101)])
        let (_, records) = try await client(fixture).scan()
        XCTAssertEqual(records.count, 101)
        let requests = await fixture.history()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Cloud-Protocol"), "1")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Catalog-Client"))
        }
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "generation" }?.value, "7")
        XCTAssertEqual(query?.first { $0.name == "snapshotRevision" }?.value, "3")
    }

    func testSnapshot409RestartsWithoutReturningPartialRecords() async throws {
        let changed = CommunityResponse(status: 409, data: Data(#"{"error":{"code":"cloud_snapshot_changed","message":"Restart"}}"#.utf8))
        let fixture = CloudTransportFixture([try page([item()], total: 2), changed, try page([], revision: 4)])
        let (snapshot, records) = try await client(fixture).scan()
        XCTAssertTrue(records.isEmpty); XCTAssertEqual(snapshot.revision, 4)
        let requests = await fixture.history()
        let pages = try requests.map { URLComponents(url: try XCTUnwrap($0.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value }
        XCTAssertEqual(pages, ["1", "2", "1"])
    }

    func testIncompleteOrDuplicateSnapshotFailsRatherThanReconciling() async throws {
        let incomplete = CloudTransportFixture([try page([item()], total: 2), try page([], page: 2, total: 2)])
        await fails { _ = try await self.client(incomplete).scan() }
        let repeated = CloudTransportFixture([try page([item(), item()])])
        await fails { _ = try await self.client(repeated).scan() }
    }

    private func media(_ item: CloudVaultItem, bytes: Data, wrongAccount: Bool = false) -> CommunityResponse {
        CommunityResponse(status: 200, data: bytes, headers: [
            "x-catalog-cloud-account": wrongAccount ? otherKey : account, "x-catalog-cloud-generation": String(item.generation),
            "x-catalog-cloud-key-id": keyID, "x-catalog-cloud-encryption": item.mode.rawValue,
            "x-catalog-cloud-item": item.id, "x-catalog-cloud-version": String(item.version)])
    }
    func testManagedPlaintextIsNotComparedToStoredCiphertextHash() async throws {
        let bytes = Data("GIF89a-test-transport-only".utf8), record = try item()
        XCTAssertNotEqual(record.dataHash, CloudVaultWire.digest(bytes))
        let fixture = CloudTransportFixture([media(record, bytes: bytes)])
        let downloaded = try await client(fixture).media(record)
        XCTAssertEqual(downloaded, bytes)
    }
    func testMediaRejectsContextMismatchAndUserHeldCiphertextTampering() async throws {
        let bytes = Data(repeating: 3, count: 32), held = try item(held: true, bytes: bytes)
        let foreign = CloudTransportFixture([media(held, bytes: bytes, wrongAccount: true)])
        await fails { _ = try await self.client(foreign).media(held) }
        let corrupt = CloudTransportFixture([media(held, bytes: Data(repeating: 4, count: 32))])
        await fails { _ = try await self.client(corrupt).media(held) }
    }

    func testProofIsReconstructedAndSignatureCoversExactIntendedPayload() async throws {
        let crypto = CloudVaultCrypto(), challenge = "55555555-5555-4555-8555-555555555555"
        let key = try await crypto.generateVaultKey()
        let payload: [String: CloudJSON] = ["id": .string(itemID), "generation": .integer(7), "version": .integer(2)]
        let encoded = try CloudVaultWire.json(payload), hash = CloudVaultWire.digest(encoded)
        let nonce = CloudVaultWire.base64(Data(repeating: 6, count: 32))
        let text = "catalog-cloud-proof-v1\n\(account)\n7\n\(keyID)\n\(challenge)\n\(nonce)\ndelete-item\n\n\(hash)"
        let proof = CloudProofChallenge(accountId: account, origin: origin, challengeId: challenge, nonce: nonce, keyId: keyID,
            action: "delete-item", generation: 7, migrationId: nil, payloadHash: hash, message: text,
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(90)))
        let fixture = CloudTransportFixture([try response("proof", proof)])
        let signed = try await client(fixture).signed(action: .delete, payload: payload, generation: 7, keyID: keyID, key: key, crypto: crypto)
        XCTAssertEqual(try CloudVaultWire.bytes(signed.payload, max: 45000), encoded)
        let publicKey = try await crypto.controlPublicKey(using: key, info: CloudVaultWire.controlInfo(account: account, key: keyID))
        try await crypto.verifyControl(CloudVaultWire.bytes(signed.proof.signature, min: 64, max: 64),
            message: Data(text.utf8), publicKey: publicKey)
        let history = await fixture.history()
        let request = try XCTUnwrap(history.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Catalog-Client"), "1")
        let malicious = CloudProofChallenge(accountId: account, origin: origin, challengeId: challenge, nonce: nonce, keyId: keyID,
            action: "delete-item", generation: 7, migrationId: nil, payloadHash: hash, message: text + "\nattacker",
            expiresAt: proof.expiresAt)
        let attacker = CloudTransportFixture([try response("proof", malicious)])
        await fails { _ = try await self.client(attacker).signed(action: .delete, payload: payload, generation: 7, keyID: self.keyID, key: key, crypto: crypto) }
    }

    func testManifestUsesSortedIndependentlyVerifiedCiphertextHashes() throws {
        let first = try item(1, held: true), second = try item(2, held: true)
        let text = "catalog-cloud-manifest-v1\n\(account)\n7\n\(keyID)\n2\n" +
            "\(first.id)\t1\t\(first.dataHash)\t\(first.metadataHash)\n" +
            "\(second.id)\t1\t\(second.dataHash)\t\(second.metadataHash)\n"
        XCTAssertEqual(try CloudVaultWire.manifest(account: account, generation: 7, key: keyID, items: [second, first]),
            CloudVaultWire.digest(Data(text.utf8)))
        XCTAssertThrowsError(try CloudVaultWire.manifest(account: account, generation: 7, key: keyID, items: [first, first]))
        XCTAssertThrowsError(try CloudVaultWire.manifest(account: account, generation: 8, key: keyID, items: [first]))
    }

    func testFalseCapabilitiesPreventCloudRequestsAndPublicUploadFallback() async throws {
        let config = CommunityResponse(status: 200, data: Data(#"{"requireEmailVerification":false,"cloudLibraryEncryptionEnabled":false}"#.utf8))
        let fixture = CloudTransportFixture([config])
        let service = CommunityController(vault: CloudAccountFixture(), factory: { _ in fixture })
        service.configure(origin)
        try service.establishSession(CommunityLogin(user: CommunityUser(id: try XCTUnwrap(UUID(uuidString: account)),
            email: "fixture@example.org", displayName: "Public fixture", role: "user", verified: true, authMethods: nil),
            token: "public-test-token-not-a-real-credential", expiresAt: "2099-01-01T00:00:00Z"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CloudVaultStore(folder: folder)
        await store.bind(service)
        XCTAssertFalse(store.available); XCTAssertFalse(store.syncing)
        await fails { try await store.enableExplicitly(createNewManagedAfterReset: true) }
        let requests = await fixture.history()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/config"])
        XCTAssertThrowsError(try service.cloudClient())
    }

    func testManagedOriginalContentHashIsVerifiedAndLegacyUnknownHashIsNotInvented() async throws {
        let bytes = Data("GIF89a-test-transport-only".utf8)
        let declarations: [String?] = [nil, "legacy-unknown-format", CloudVaultWire.digest(bytes), CloudVaultWire.digest(Data("wrong original".utf8))]
        for (index, declaration) in declarations.enumerated() {
            let original = try item()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CloudVaultWire.json(original)) as? [String: Any])
            var metadata: [String: Any] = ["title": "Public test fixture", "legacyCustom": ["retained": true]]
            if let declaration { metadata["contentHash"] = declaration }
            object["metadata"] = metadata
            let record = try JSONDecoder().decode(CloudVaultItem.self, from: JSONSerialization.data(withJSONObject: object))
            let config = CommunityResponse(status: 200, data: Data(#"{"requireEmailVerification":false,"cloudLibraryEncryptionEnabled":true}"#.utf8))
            let fixture = CloudTransportFixture([config, try response("cloud", state()), try response("cloud", state()),
                try response("cloud", state()), try page([record]), media(record, bytes: bytes)])
            let service = CommunityController(vault: CloudAccountFixture(), factory: { _ in fixture })
            service.configure(origin)
            try service.establishSession(CommunityLogin(user: CommunityUser(id: try XCTUnwrap(UUID(uuidString: account)),
                email: "fixture@example.org", displayName: "Public fixture", role: "user", verified: true, authMethods: nil),
                token: "public-test-token-not-a-real-credential", expiresAt: "2099-01-01T00:00:00Z"))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = CloudVaultStore(folder: folder)
            await store.bind(service)
            try await store.enableExplicitly(createNewManagedAfterReset: true)
            if index == 3 {
                await fails { _ = try await store.download(record) }
                XCTAssertEqual(store.items.count, 1)
            } else {
                let result = try await store.download(record)
                XCTAssertEqual(result.data, bytes)
                XCTAssertEqual(result.metadata["contentHash"]?.text, declaration)
                XCTAssertEqual(result.metadata["legacyCustom"], .object(["retained": .bool(true)]))
            }
            let requests = await fixture.history()
            XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }
}
