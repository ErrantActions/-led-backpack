import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor SynchronizationTransport: CommunityTransport {
    static let origin = "https://catalog.example"
    static let account = "11111111-1111-4111-8111-111111111111"
    static let key = "22222222-2222-4222-8222-222222222222"
    private var records: [String: CloudVaultItem] = [:]
    private var files: [String: Data] = [:]
    private var revision = 1
    private var offline = false
    private var suspendMedia = false
    private var mediaStarted = false
    private var release: CheckedContinuation<Void, Never>?
    private var writes = 0

    func setOffline(_ value: Bool) { offline = value }
    func delayMedia() { suspendMedia = true }
    func isDownloading() -> Bool { mediaStarted }
    func releaseMedia() { suspendMedia = false; release?.resume(); release = nil }
    func writeCount() -> Int { writes }
    func allRecords() -> [CloudVaultItem] { Array(records.values) }
    func state() -> CloudVaultState {
        CloudVaultState(protocolVersion: 1, accountId: Self.account, origin: Self.origin, enabled: true,
            deleting: false, mode: .managed, generation: 1, revision: revision, keyId: Self.key, migrationId: nil,
            recovery: nil, passkeys: [], controlPublicKey: nil, userHeldEnrollmentAvailable: false,
            deviceAdoptionAvailable: false, itemLimit: 100, maxPlaintextBytes: 5_000_000,
            legacyMigrationPending: false, legacyMigrationError: nil, legacyItemCount: 0)
    }
    @discardableResult
    func put(_ bytes: Data, id: String = "33333333-3333-4333-8333-333333333333",
        title: String = "Remote GIF", favorite: Bool = false, category: String = "Pixel art") throws -> CloudVaultItem {
        try put(bytes, id: id, metadata: ["title": .string(title), "category": .string(category),
            "favorite": .bool(favorite), "contentHash": .string(CloudVaultWire.digest(bytes))])
    }
    private func put(_ bytes: Data, id: String, metadata: [String: CloudJSON]) throws -> CloudVaultItem {
        let version = (records[id]?.version ?? 0) + 1
        let record = CloudVaultItem(id: id, accountId: Self.account, origin: Self.origin, keyId: Self.key,
            mode: .managed, generation: 1, version: version, byteSize: bytes.count, storageBytes: bytes.count,
            encrypted: false, metadata: .object(metadata), legacyItemId: nil,
            dataHash: CloudVaultWire.digest(bytes), metadataHash: CloudVaultWire.digest(try CloudVaultWire.json(metadata)),
            updatedAt: "2026-01-01T00:00:00.000Z",
            downloadUrl: try XCTUnwrap(URL(string: "\(Self.origin)/api/v1/cloud/items/\(id)/media?generation=1&version=\(version)")))
        records[id] = record; files[id] = bytes; revision += 1
        return record
    }
    func removeRemote(_ id: String) { records.removeValue(forKey: id); files.removeValue(forKey: id); revision += 1 }
    func restore(_ record: CloudVaultItem, bytes: Data) { records[record.id] = record; files[record.id] = bytes; revision += 1 }
    func putInvalidHash(_ bytes: Data) throws {
        _ = try put(bytes, id: "33333333-3333-4333-8333-333333333333",
            metadata: ["title": .string("Invalid"), "contentHash": .string(CloudVaultWire.digest(Data("wrong".utf8)))])
    }
    private func response<T: Encodable>(_ name: String, _ value: T) throws -> CommunityResponse {
        let object = try JSONSerialization.jsonObject(with: CloudVaultWire.json(value))
        return CommunityResponse(status: 200, data: try JSONSerialization.data(withJSONObject: [name: object]))
    }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        if offline { throw BackpackError.invalid("Fixture offline; changes remain pending.") }
        let path = request.url?.path ?? ""
        if path == "/api/v1/config" {
            return .init(status: 200, data: Data(#"{"requireEmailVerification":false,"cloudLibraryEncryptionEnabled":true}"#.utf8))
        }
        if path == "/api/v1/cloud" { return try response("cloud", state()) }
        if path == "/api/v1/cloud/items" {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CloudVaultWire.json(state())) as? [String: Any])
            object["items"] = try JSONSerialization.jsonObject(with: CloudVaultWire.json(Array(records.values)))
            object["page"] = 1; object["limit"] = 100; object["total"] = records.count
            return .init(status: 200, data: try JSONSerialization.data(withJSONObject: object))
        }
        let components = path.split(separator: "/")
        guard components.count >= 5, components[3] == "items" else {
            throw BackpackError.invalid("Unexpected synchronization fixture request: \(path)")
        }
        let id = String(components[4])
        if request.httpMethod == "PUT" {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let expectedVersion = try XCTUnwrap(body["expectedVersion"] as? Int)
            guard expectedVersion == (records[id]?.version ?? 0) else {
                throw BackpackError.invalid("Fixture write version conflict.")
            }
            let bytes = try CloudVaultWire.bytes(XCTUnwrap(body["data"] as? String), max: CloudVaultWire.maxPlaintext)
            let metadata = try JSONDecoder().decode([String: CloudJSON].self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(body["metadata"])))
            writes += 1
            return try response("item", put(bytes, id: id, metadata: metadata))
        }
        guard let record = records[id], let bytes = files[id] else { throw BackpackError.invalid("Fixture item removed.") }
        if components.last == "media" {
            mediaStarted = true
            if suspendMedia { await withCheckedContinuation { release = $0 } }
            return .init(status: 200, data: bytes, headers: [
                "x-catalog-cloud-account": Self.account, "x-catalog-cloud-generation": "1",
                "x-catalog-cloud-key-id": Self.key, "x-catalog-cloud-encryption": "server-managed",
                "x-catalog-cloud-item": id, "x-catalog-cloud-version": String(record.version)])
        }
        return try response("item", record)
    }
}

@MainActor
private final class SynchronizationAccount: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}

@MainActor
final class CloudSynchronizationTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    private func gif(_ text: String = "A") throws -> Data {
        let size = PanelSize(width: 16, height: 16)
        return try MediaCodec.encode([.black(size), MediaCodec.text(text, size: size)], delays: [0.1, 0.1])
    }
    private func setup(_ transport: SynchronizationTransport, consent: Bool = true) async throws
        -> (LocalLibrary, CloudVaultStore, CommunityController) {
        let service = CommunityController(vault: SynchronizationAccount(), factory: { _ in transport })
        service.configure(SynchronizationTransport.origin)
        try service.establishSession(CommunityLogin(user: CommunityUser(id: XCTUnwrap(UUID(uuidString: SynchronizationTransport.account)),
            email: "fixture@example.invalid", displayName: "Fixture", role: "user", verified: true, authMethods: nil),
            token: "generated-sync-fixture-not-a-real-token", expiresAt: "2099-01-01T00:00:00Z"))
        let library = try LocalLibrary(folder: folder)
        let ledger = try CloudVaultLedger(folder: folder)
        var pin = CloudDevicePin()
        try pin.accept(await transport.state()); pin.paused = !consent
        try ledger.save(pin, scope: CloudVaultScope(origin: CommunityOrigin.parse(SynchronizationTransport.origin),
            accountID: XCTUnwrap(UUID(uuidString: SynchronizationTransport.account)), revision: service.accountRevision))
        let store = CloudVaultStore(folder: folder)
        await store.bind(service)
        XCTAssertNil(store.failure)
        return (library, store, service)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synchronization fixture timed out.")
    }

    func testRemoteGIFAutomaticallyDownloadsOnceWithFavoritesAndOfflineBytes() async throws {
        let transport = SynchronizationTransport(), bytes = try gif()
        _ = try await transport.put(bytes, favorite: true)
        let (library, store, _) = try await setup(transport)
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNil(store.failure); XCTAssertNotNil(store.lastSynchronized)
        let saved = try XCTUnwrap(library.state.media.first)
        XCTAssertTrue(saved.isFavorite); XCTAssertEqual(saved.categoryName, "Pixel art")
        XCTAssertEqual(try library.data(saved), bytes)
        try await store.synchronize(library)
        XCTAssertEqual(library.state.media.count, 1)
        XCTAssertTrue(store.cloudOnly(local: library.state.media).isEmpty)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
        await transport.setOffline(true)
        XCTAssertEqual(try library.data(saved), bytes)
    }

    func testLocalImportsAndOrganizationAutomaticallyUploadWithoutPerGIFAction() async throws {
        let transport = SynchronizationTransport()
        let (library, store, _) = try await setup(transport)
        try library.add(name: "Local", data: gif())
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNil(store.failure)
        let saved = try XCTUnwrap(library.state.media.first)
        try library.organize(saved.id, category: "Rides", favorite: true)
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNil(store.failure)
        let records = await transport.allRecords()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.version, 2)
        XCTAssertEqual(records.first?.metadata.object?["favorite"], .bool(true))
        XCTAssertEqual(records.first?.metadata.object?["category"], .string("Rides"))
    }

    func testRemoteVersionUpdatesSameLocalIdentityAndSurvivesRestart() async throws {
        let transport = SynchronizationTransport(), first = try gif(), second = try gif("B")
        let remote = try await transport.put(first)
        let (library, store, service) = try await setup(transport)
        try await store.synchronize(library)
        let saved = try XCTUnwrap(library.state.media.first)
        _ = try await transport.put(second, id: remote.id, title: "Changed remotely", favorite: true, category: "Rides")
        try await store.synchronize(library)
        let updated = try XCTUnwrap(library.state.media.first)
        XCTAssertEqual(updated.id, saved.id); XCTAssertEqual(updated.name, "Changed remotely")
        XCTAssertTrue(updated.isFavorite); XCTAssertEqual(updated.categoryName, "Rides")
        XCTAssertEqual(try library.data(updated), second)
        let reloaded = try LocalLibrary(folder: folder), restarted = CloudVaultStore(folder: folder)
        await restarted.bind(service)
        try await restarted.synchronize(reloaded)
        XCTAssertEqual(reloaded.state.media.count, 1)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testConcurrentRemoteAndLocalEditsRetainBothAndNeverClaimSynchronized() async throws {
        let transport = SynchronizationTransport(), bytes = try gif()
        let remote = try await transport.put(bytes)
        let (library, store, _) = try await setup(transport)
        try await store.synchronize(library)
        let saved = try XCTUnwrap(library.state.media.first)
        try library.organize(saved.id, category: "Local choice", favorite: true)
        _ = try await transport.put(gif("B"), id: remote.id, title: "Remote choice")
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNotNil(store.failure); XCTAssertNil(store.lastSynchronized)
        XCTAssertEqual(library.state.media.first?.category, "Local choice")
        XCTAssertEqual(try library.data(saved), bytes)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testOfflineChangesRetryWithoutLosingLocalImport() async throws {
        let transport = SynchronizationTransport()
        let (library, store, _) = try await setup(transport)
        try library.add(name: "Offline import", data: gif())
        await transport.setOffline(true)
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNotNil(store.failure); XCTAssertNil(store.lastSynchronized)
        XCTAssertEqual(library.state.media.count, 1)
        await transport.setOffline(false)
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNil(store.failure); XCTAssertNotNil(store.lastSynchronized)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 1)
    }

    func testNoSyncBeforeConsentAndResumeAutomaticallyReconciles() async throws {
        let transport = SynchronizationTransport()
        _ = try await transport.put(gif())
        let (library, store, _) = try await setup(transport, consent: false)
        store.requestSynchronization(library)
        XCTAssertFalse(store.busy); XCTAssertTrue(library.state.media.isEmpty)
        try await store.enableExplicitly(createNewManagedAfterReset: false)
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNil(store.failure); XCTAssertEqual(library.state.media.count, 1)
    }

    func testPauseDuringDownloadDiscardsResults() async throws {
        let transport = SynchronizationTransport()
        _ = try await transport.put(gif())
        let (library, store, _) = try await setup(transport)
        await transport.delayMedia()
        store.requestSynchronization(library)
        try await waitUntil { await transport.isDownloading() }
        try store.pause()
        await transport.releaseMedia()
        try await waitUntil { !store.busy }
        XCTAssertTrue(library.state.media.isEmpty); XCTAssertFalse(store.syncing)
        XCTAssertNil(store.lastSynchronized)
    }

    func testAccountRebindDuringDownloadDiscardsResults() async throws {
        let transport = SynchronizationTransport()
        _ = try await transport.put(gif())
        let (library, store, _) = try await setup(transport)
        await transport.delayMedia()
        store.requestSynchronization(library)
        try await waitUntil { await transport.isDownloading() }
        let guest = CommunityController(vault: SynchronizationAccount(), factory: { _ in transport })
        guest.configure(SynchronizationTransport.origin)
        await store.bind(guest)
        await transport.releaseMedia()
        XCTAssertTrue(library.state.media.isEmpty); XCTAssertFalse(store.available)
    }

    func testRemovedRemoteDoesNotReuploadOrDeleteLocalOriginal() async throws {
        let transport = SynchronizationTransport(), bytes = try gif()
        let remote = try await transport.put(bytes)
        let (library, store, _) = try await setup(transport)
        try await store.synchronize(library)
        let saved = try XCTUnwrap(library.state.media.first)
        await transport.removeRemote(remote.id)
        try await store.synchronize(library)
        XCTAssertEqual(try library.data(saved), bytes)
        XCTAssertTrue(store.pin.links[saved.id.uuidString.lowercased()]?.remoteMissing == true)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testRemovedLocalDownloadIsNotSilentlyRestoredOrDeletedRemotely() async throws {
        let transport = SynchronizationTransport()
        _ = try await transport.put(gif())
        let (library, store, _) = try await setup(transport)
        try await store.synchronize(library)
        try library.delete(XCTUnwrap(library.state.media.first))
        try await store.synchronize(library)
        XCTAssertTrue(library.state.media.isEmpty)
        XCTAssertEqual(store.cloudOnly(local: library.state.media).count, 1)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testCloudUpdateRejectsChangedLocalSnapshot() async throws {
        let library = try LocalLibrary(folder: folder), bytes = try gif()
        try library.add(name: "Original", data: bytes)
        let saved = try XCTUnwrap(library.state.media.first)
        try library.organize(saved.id, category: "Edited while downloading", favorite: true)
        XCTAssertThrowsError(try library.applyCloudUpdate(saved, original: bytes, data: gif("B"), title: "Remote",
            attribution: nil, category: nil, favorite: false))
        XCTAssertEqual(try library.data(saved), bytes)
        XCTAssertEqual(library.state.media.first?.category, "Edited while downloading")
    }

    func testStorageLimitRetainsCloudItemsAndReportsIncompleteSync() async throws {
        let transport = SynchronizationTransport()
        _ = try await transport.put(gif())
        let (library, store, _) = try await setup(transport)
        let bytes = try gif()
        for index in 0..<100 { try library.add(name: "Local \(index)", data: bytes) }
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNotNil(store.failure); XCTAssertNil(store.lastSynchronized)
        XCTAssertEqual(library.state.media.count, 100)
        XCTAssertEqual(store.cloudOnly(local: library.state.media).count, 1)
    }

    func testForeignOwnedCopyIsNotUploadedIntoCurrentAccount() async throws {
        let transport = SynchronizationTransport()
        let (library, store, _) = try await setup(transport)
        let id = UUID()
        _ = try library.savePrivateCloudGIF(gif(), title: "Other account", attribution: nil, category: nil,
            origin: CommunityOrigin.parse(SynchronizationTransport.origin), accountID: UUID(), itemID: id,
            assetURL: XCTUnwrap(URL(string: "\(SynchronizationTransport.origin)/api/v1/cloud/items/\(id.uuidString.lowercased())/media")))
        try await store.synchronize(library)
        XCTAssertEqual(library.state.media.count, 1)
        let writes = await transport.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testInvalidRemoteContentHashCannotCreatePhoneArtwork() async throws {
        let transport = SynchronizationTransport()
        try await transport.putInvalidHash(gif())
        let (library, store, _) = try await setup(transport)
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNotNil(store.failure); XCTAssertNil(store.lastSynchronized)
        XCTAssertTrue(library.state.media.isEmpty)
    }

    func testRemoteItemVersionRollbackCannotReplaceNewerPhoneArtwork() async throws {
        let transport = SynchronizationTransport(), first = try gif(), second = try gif("B")
        let old = try await transport.put(first)
        let (library, store, _) = try await setup(transport)
        try await store.synchronize(library)
        _ = try await transport.put(second)
        try await store.synchronize(library)
        await transport.restore(old, bytes: first)
        store.requestSynchronization(library)
        try await waitUntil { !store.busy }
        XCTAssertNotNil(store.failure); XCTAssertNil(store.lastSynchronized)
        XCTAssertEqual(try library.data(XCTUnwrap(library.state.media.first)), second)
    }
}
