import Foundation
import Combine
import UIKit
import BackpackProtocol

struct CloudPlainItem: Sendable {
    let data: Data
    let metadata: [String: CloudJSON]
}

@MainActor
final class CloudVaultStore: ObservableObject {
    @Published private(set) var state: CloudVaultState?
    @Published private(set) var items: [CloudVaultItem] = []
    @Published private(set) var titles: [String: String] = [:]
    @Published private(set) var categories: [String: String] = [:]
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published private(set) var lastSynchronized: Date?
    @Published private(set) var pin = CloudDevicePin()
    @Published private(set) var available = false
    @Published private(set) var locked = true
    @Published private(set) var migration: CloudMigration?
    @Published private(set) var adoption: CloudAdoption?
    let crypto = CloudVaultCrypto()
    private var ledger: CloudVaultLedger?
    private var cache: CloudVaultKeychain?
    private var client: CloudVaultClient?
    private var keys: [String: CloudVaultKey] = [:]
    private var epoch = UUID()
    private var work: Task<Void, Never>?
    private var pendingLibrary: LocalLibrary?
    private var recipient: CloudVaultAdoptionKey?
    private var receivedQR: CloudAdoptionQR?
    private var config: CommunityConfig?
    private var storageFailure: String?

    init(folder: URL? = nil) {
        do { ledger = try CloudVaultLedger(folder: folder); cache = try CloudVaultKeychain() }
        catch {
            storageFailure = "Private cloud device storage failed: \(error.localizedDescription)"
            failure = storageFailure
        }
    }
    var syncing: Bool { available && !pin.paused }
    func connected(_ localID: UUID) -> CloudVaultItem? {
        guard syncing, let link = pin.links[localID.uuidString.lowercased()], !link.remoteMissing else { return nil }
        return items.first { $0.id == link.remoteID && $0.generation == link.generation }
    }
    func cloudOnly(local: [SavedMedia]) -> [CloudVaultItem] {
        guard syncing else { return [] }
        let linked = Set(local.compactMap { connected($0.id)?.id })
        return items.filter { !linked.contains($0.id) }
    }
    func requiresExplicitCopy(_ item: SavedMedia) throws -> Bool {
        let client = try connection()
        if let link = pin.links[item.id.uuidString.lowercased()] {
            return link.generation != state?.generation || link.remoteMissing
        }
        if let source = item.cloudSource,
           source.accountID != client.scope.accountID || source.server != client.scope.origin.url.absoluteString { return true }
        guard let ledger else { throw BackpackError.invalid("Private cloud device storage is unavailable.") }
        return try ledger.hasForeignLink(item.id, scope: client.scope)
    }
    var canEnroll: Bool { syncing && state?.enabled == true && state?.deleting == false && config?.cloudUserHeldEncryptionEnabled == true && state?.userHeldEnrollmentAvailable == true }
    var canAdopt: Bool { syncing && canEnroll && state?.migrationId == nil && config?.cloudDeviceAdoptionEnabled == true && state?.deviceAdoptionAvailable == true && state?.mode == .userHeld }
    var passkeyRP: String? {
        guard config?.cloudNativePasskeyAssociationConfigured == true, let rp = config?.cloudPasskeyRelyingPartyId,
              rp == client?.scope.origin.url.host, rp == "led.errantactions.com" else { return nil }
        return rp
    }
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { failure = "Finish the current private cloud operation first."; return }
        busy = true; failure = nil
        let current = epoch
        work = Task {
            defer {
                if epoch == current {
                    busy = false; work = nil
                    if let pending = pendingLibrary {
                        pendingLibrary = nil
                        if !Task.isCancelled { requestSynchronization(pending) }
                    }
                }
            }
            do { try await operation() }
            catch { if epoch == current && !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    func requestSynchronization(_ library: LocalLibrary) {
        guard syncing, !locked, state?.migrationId == nil else { return }
        if busy { pendingLibrary = library }
        else { run { try await self.synchronize(library) } }
    }
    func stopWork() { pendingLibrary = nil; work?.cancel() }
    private func checked(_ captured: CloudVaultClient) throws {
        try Task.checkCancellation()
        guard client?.scope == captured.scope, client?.instanceID == captured.instanceID else { throw BackpackError.invalid("Private cloud account changed; response discarded.") }
    }
    private func connection() throws -> CloudVaultClient {
        guard available, ledger != nil, cache != nil, let client else {
            throw BackpackError.invalid("This server has not enabled private cloud protocol 1.")
        }
        return client
    }
    private func savePin() throws {
        let client = try connection()
        guard let ledger else { throw BackpackError.invalid("Cloud device state is unavailable.") }
        try ledger.save(pin, scope: client.scope)
    }
    func bind(_ community: CommunityController) async {
        stopWork(); epoch = UUID(); busy = false
        client = nil; state = nil; items = []; titles = [:]; categories = [:]; keys = [:]; migration = nil
        adoption = nil; recipient = nil; receivedQR = nil; locked = true; available = false
        pin = CloudDevicePin(); config = nil; failure = storageFailure; progress = ""; lastSynchronized = nil
        let binding = epoch
        guard let ledger, cache != nil else { return }
        guard community.signedIn else { pin = CloudDevicePin(); return }
        do {
            try await community.loadConfig()
            guard epoch == binding, !Task.isCancelled else { return }
            config = community.config
            guard config?.cloudLibraryEncryptionEnabled == true else { pin = CloudDevicePin(); return }
            if community.user == nil { try await community.refreshUser() }
            guard epoch == binding, !Task.isCancelled else { return }
            let next = try community.cloudClient()
            client = next; available = true
            pin = try ledger.pin(next.scope)
            try await refresh()
        } catch { if epoch == binding { failure = error.localizedDescription; pin.paused = true } }
    }
    func refresh() async throws {
        let client = try connection()
        let next = try await client.state()
        try checked(client)
        let previousKey = pin.keyID
        let contextChanged = pin.generation != nil && (pin.generation != next.generation || pin.keyID != next.keyId)
        do { try pin.accept(next) }
        catch {
            pin.paused = true; keys = [:]; locked = true; items = []; titles = [:]; categories = [:]
            try savePin(); throw error
        }
        if contextChanged || !next.enabled || next.deleting {
            keys = [:]; locked = true; recipient = nil; receivedQR = nil; adoption = nil
            if let previousKey, let cache { try await cache.remove(scope: cacheScope(client, previousKey)); try checked(client) }
        }
        state = next; try savePin()
        if next.deleting || !next.enabled { items = []; titles = [:]; categories = [:]; keys = [:]; locked = true; return }
        if next.mode == .managed { locked = false }
        else if let keyID = next.keyId, let cache {
            var availableKey = keys[keyID]
            if availableKey == nil { availableKey = try await cache.load(scope: cacheScope(client, keyID)) }
            if let key = availableKey {
                do { try await checkKey(key, keyID: keyID, publicKey: next.controlPublicKey, client: client) }
                catch {
                    let original = error
                    try checked(client)
                    keys.removeValue(forKey: keyID); locked = true; pin.paused = true
                    items = []; titles = [:]; categories = [:]; try savePin()
                    try await cache.remove(scope: cacheScope(client, keyID))
                    try checked(client)
                    throw original
                }
                keys[keyID] = key; locked = false
            } else { locked = true }
        }
        guard !pin.paused else { return }
        let (snapshot, records) = try await client.scan()
        try checked(client)
        try pin.accept(snapshot); state = snapshot; items = records; try savePin()
        guard !pin.paused else { items = []; titles = [:]; categories = [:]; return }
        titles = [:]; categories = [:]
        if !locked {
            for item in records {
                let metadata = try await metadata(item, client: client)
                try checked(client)
                titles[item.id] = metadata["title"]?.text ?? "Private artwork"
                categories[item.id] = metadata["category"]?.text ?? ""
            }
        }
    }
    func pause() throws {
        stopWork(); epoch = UUID(); busy = false
        pin.paused = true; items = []; titles = [:]; categories = [:]
        do { try savePin() }
        catch { throw BackpackError.invalid("Private sync stopped, but its pause setting could not be saved. Do not rely on the pause surviving a restart. \(error.localizedDescription)") }
    }
    func enableExplicitly(createNewManagedAfterReset: Bool) async throws {
        let client = try connection()
        var current = try await client.state()
        try checked(client)
        if !current.enabled {
            if pin.userHeld && !createNewManagedAfterReset {
                throw BackpackError.invalid("Creating a new server-managed library after a user-held reset requires explicit confirmation.")
            }
            current = try await client.enable(generation: current.generation)
            try checked(client)
            pin.userHeld = false
        }
        try pin.accept(current)
        pin.paused = false; pin.remoteReset = false; state = current; try savePin()
        try await refresh()
    }
    private func cacheScope(_ client: CloudVaultClient, _ key: String) throws -> CloudVaultCacheScope {
        try CloudVaultCacheScope(origin: client.scope.origin.url.absoluteString, accountID: client.scope.accountID, vaultKeyID: key)
    }
    private func checkKey(_ key: CloudVaultKey, keyID: String, publicKey: String?, client: CloudVaultClient) async throws {
        guard let publicKey else { throw BackpackError.invalid("User-held library has no control key.") }
        let actual = try await crypto.controlPublicKey(using: key, info: CloudVaultWire.controlInfo(account: client.scope.account, key: keyID))
        try checked(client)
        guard actual == (try CloudVaultWire.bytes(publicKey, min: 32, max: 32)) else {
            throw BackpackError.invalid("This key does not unlock the current library.")
        }
    }
    func unlock(libraryPassword: String) async throws {
        let client = try connection()
        guard let state, state.enabled, state.mode == .userHeld, let keyID = state.keyId, let recovery = state.recovery else {
            throw BackpackError.invalid("No active user-held library is available to unlock.")
        }
        let key = try await crypto.unlockVaultKey(libraryPassword: libraryPassword, recovery: recovery.primitive,
            aad: CloudVaultWire.wrapAAD(account: client.scope.account, key: keyID))
        try await checkKey(key, keyID: keyID, publicKey: state.controlPublicKey, client: client)
        guard let cache else { throw BackpackError.invalid("Device key cache is unavailable.") }
        try await cache.store(key, scope: cacheScope(client, keyID))
        try checked(client)
        keys[keyID] = key; locked = false
        try await refresh()
    }
    private func key(_ keyID: String) throws -> CloudVaultKey {
        guard let key = keys[keyID] else { throw BackpackError.invalid("Unlock this library with its separate recovery password or an enrolled passkey.") }
        return key
    }
    private func validateMetadata(_ object: [String: CloudJSON]) throws {
        let forbidden = Set(["password", "accountpassword", "librarypassword", "recoverypassword", "pw", "key", "vaultkey",
            "token", "authorization", "refreshtoken", "access_token", "refresh_token", "identitytoken", "privatekey", "dek", "prfoutput", "secret"])
        func check(_ value: CloudJSON) throws {
            switch value {
            case .object(let values):
                for (name, value) in values {
                    guard !forbidden.contains(name.lowercased()) else { throw BackpackError.invalid("Private metadata must not contain credentials or encryption secrets.") }
                    try check(value)
                }
            case .array(let values): for value in values { try check(value) }
            default: break
            }
        }
        try check(.object(object))
        guard try CloudVaultWire.json(object).count <= CloudVaultWire.maxMetadata else { throw BackpackError.invalid("Private metadata exceeds 8192 UTF-8 bytes.") }
    }
    private func metadata(_ item: CloudVaultItem, client: CloudVaultClient, overrideKey: CloudVaultKey? = nil) async throws -> [String: CloudJSON] {
        try item.validate(client.scope, generation: item.generation, keyID: item.keyId, mode: item.mode)
        let decoded: CloudJSON
        if item.mode == .userHeld {
            let bytes = try CloudVaultWire.bytes(item.metadata.text ?? "", min: 28, max: CloudVaultWire.maxMetadata + 28)
            let plaintext = try await crypto.open(bytes, using: overrideKey ?? key(item.keyId),
                aad: CloudVaultWire.assetAAD(account: client.scope.account, generation: item.generation,
                    key: item.keyId, item: item.id, version: item.version, purpose: "metadata"))
            try checked(client)
            guard plaintext.count <= CloudVaultWire.maxMetadata else { throw BackpackError.invalid("Decrypted metadata exceeds its budget.") }
            decoded = try JSONDecoder().decode(CloudJSON.self, from: plaintext)
        } else { decoded = item.metadata }
        guard let object = decoded.object else { throw BackpackError.invalid("Private metadata must be a JSON object.") }
        try validateMetadata(object)
        return object
    }
    private func plain(_ item: CloudVaultItem, client: CloudVaultClient, migration: String? = nil,
        overrideKey: CloudVaultKey? = nil) async throws -> CloudPlainItem {
        let object = try await metadata(item, client: client, overrideKey: overrideKey)
        let downloaded = try await client.media(item, migration: migration)
        try checked(client)
        let data: Data
        if item.mode == .userHeld {
            data = try await crypto.open(downloaded, using: overrideKey ?? key(item.keyId),
                aad: CloudVaultWire.assetAAD(account: client.scope.account, generation: item.generation,
                    key: item.keyId, item: item.id, version: item.version, purpose: "data"))
        } else { data = downloaded }
        try checked(client)
        guard (1...CloudVaultWire.maxPlaintext).contains(data.count) else { throw BackpackError.invalid("Private asset exceeds its plaintext budget.") }
        if let hash = object["contentHash"]?.text,
           let bytes = try? CloudVaultWire.bytes(hash, min: 32, max: 32), !bytes.isEmpty,
           hash != CloudVaultWire.digest(data) {
            throw BackpackError.invalid("Private asset content hash mismatch. Local and remote files were retained.")
        }
        return CloudPlainItem(data: data, metadata: object)
    }
    func download(_ item: CloudVaultItem) async throws -> CloudPlainItem {
        let client = try connection()
        guard syncing, !locked, let state, state.enabled, !state.deleting,
              item.generation == state.generation, item.keyId == state.keyId, item.mode == state.mode else {
            throw BackpackError.invalid("Cloud is paused, locked, deleted or changed generation.")
        }
        let result = try await plain(item, client: client)
        guard syncing, state.generation == self.state?.generation, state.keyId == self.state?.keyId else {
            throw BackpackError.invalid("Private cloud was paused or reset while downloading.")
        }
        return result
    }
    func authorizeForBackpack(_ item: CloudVaultItem) async throws {
        let client = try connection()
        guard syncing, !locked, let state, state.enabled, !state.deleting,
              state.generation == item.generation, state.keyId == item.keyId, state.mode == item.mode else {
            throw BackpackError.invalid("Private cloud is paused, locked, deleted or changed. No cached plaintext send is authorized.")
        }
        try item.validate(client.scope, generation: state.generation, keyID: item.keyId, mode: state.mode)
        let currentState = try await client.state()
        try checked(client)
        guard currentState.enabled, !currentState.deleting, currentState.generation == item.generation,
              currentState.keyId == item.keyId, currentState.mode == item.mode else {
            throw BackpackError.invalid("Current private cloud no longer authorizes this selected item/key/generation.")
        }
        let current = try await client.item(item.id)
        try current.validate(client.scope, generation: item.generation, keyID: item.keyId, mode: item.mode)
        try checked(client)
        guard item.matches(current), syncing, !locked,
              self.state?.generation == state.generation, self.state?.keyId == state.keyId else {
            throw BackpackError.invalid("Selected private GIF changed or was paused during authorization; reload explicitly.")
        }
    }
    func downloadForBackpack(_ item: CloudVaultItem) async throws -> CloudPlainItem {
        try await authorizeForBackpack(item)
        let copy = try await download(item)
        let worker = Task.detached { try CommunityUpload.validateGIF(copy.data) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try await authorizeForBackpack(item)
        return copy
    }
    func keepOffline(_ item: CloudVaultItem, library: LocalLibrary) async throws {
        let client = try connection()
        let copy = try await download(item)
        _ = try GIFPreviewDecoder.originalFrameCount(copy.data)
        try await authorizeForBackpack(item)
        try checked(client)
        guard let itemID = UUID(uuidString: item.id) else { throw BackpackError.invalid("Invalid private cloud item identifier.") }
        let saved = try library.savePrivateCloudGIF(copy.data, title: copy.metadata["title"]?.text ?? "Cloud artwork",
            attribution: attribution(copy.metadata), category: copy.metadata["category"]?.text,
            origin: client.scope.origin, accountID: client.scope.accountID, itemID: itemID, assetURL: item.downloadUrl,
            favorite: copy.metadata["favorite"] == .bool(true))
        guard try library.data(saved) == copy.data else {
            throw BackpackError.invalid("The phone copy changed during download. Both copies were retained.")
        }
        pin.links[saved.id.uuidString.lowercased()] = CloudLocalLink(remoteID: item.id, generation: item.generation,
            version: item.version, localHash: CloudVaultWire.digest(copy.data),
            localMetadataHash: CloudVaultWire.digest(try CloudVaultWire.json(localMetadata(saved, data: copy.data))))
        try savePin()
    }
    private func attribution(_ metadata: [String: CloudJSON]) -> Attribution? {
        guard let credit = metadata["attribution"]?.text, let license = metadata["license"]?.text else { return nil }
        return Attribution(source: metadata["sourceUrl"]?.text ?? "", author: credit, license: license, licenseURL: metadata["licenseUrl"]?.text ?? "")
    }
    private func localMetadata(_ item: SavedMedia, data: Data) -> [String: CloudJSON] {
        var object: [String: CloudJSON] = ["title": .string(item.name), "category": .string(item.categoryName),
            "favorite": .bool(item.isFavorite), "contentHash": .string(CloudVaultWire.digest(data))]
        if let credit = item.attribution {
            object["attribution"] = .string(credit.author); object["license"] = .string(credit.license)
            object["sourceUrl"] = .string(credit.source); object["licenseUrl"] = .string(credit.licenseURL)
        }
        return object
    }
    private func merging(_ local: [String: CloudJSON], into remote: [String: CloudJSON], data: Data) -> [String: CloudJSON] {
        var result = remote.merging(local) { _, local in local }
        if result["tags"] == nil { result["tags"] = .array([]) }
        result["contentHash"] = .string(CloudVaultWire.digest(data))
        return result
    }
    private func write(_ data: Data, metadata: [String: CloudJSON], id: String, expectedVersion: Int,
        state: CloudVaultState, client: CloudVaultClient, migration: CloudMigration? = nil, targetKey: CloudVaultKey? = nil) async throws -> CloudVaultItem {
        guard (1...CloudVaultWire.maxPlaintext).contains(data.count), (0..<CloudVaultWire.maxInteger).contains(expectedVersion) else { throw BackpackError.invalid("Invalid private asset size/version.") }
        try validateMetadata(metadata)
        let generation = migration?.generation ?? state.generation
        guard let keyID = migration?.keyId ?? state.keyId else { throw BackpackError.invalid("Cloud has no encryption key.") }
        let mode: CloudEncryptionMode = migration == nil ? state.mode : .userHeld
        let wireData: Data
        let wireMetadata: CloudJSON
        var authorization: CloudSignedOperation?
        if mode == .userHeld {
            let key = try targetKey ?? self.key(keyID)
            wireData = try await crypto.seal(data, using: key,
                aad: CloudVaultWire.assetAAD(account: client.scope.account, generation: generation, key: keyID, item: id, version: expectedVersion + 1, purpose: "data"))
            let meta = try await crypto.seal(CloudVaultWire.json(metadata), using: key,
                aad: CloudVaultWire.assetAAD(account: client.scope.account, generation: generation, key: keyID, item: id, version: expectedVersion + 1, purpose: "metadata"))
            wireMetadata = .string(CloudVaultWire.base64(meta))
            authorization = try await client.signed(action: .write, payload: ["id": .string(id), "generation": .integer(generation),
                "expectedVersion": .integer(expectedVersion), "dataHash": .string(CloudVaultWire.digest(wireData)),
                "metadataHash": .string(CloudVaultWire.digest(meta))], generation: state.generation,
                keyID: keyID, key: key, crypto: crypto, migration: migration?.migrationId)
        } else { wireData = data; wireMetadata = .object(metadata) }
        try checked(client)
        let item = try await client.put(id: id, input: CloudPut(generation: generation, expectedVersion: expectedVersion,
            metadata: wireMetadata, data: CloudVaultWire.base64(wireData), authorization: authorization), mode: mode, migration: migration?.migrationId)
        try checked(client)
        try item.validate(client.scope, generation: generation, keyID: keyID, mode: mode)
        guard item.id == id, item.version == expectedVersion + 1 else { throw BackpackError.invalid("Cloud returned a different write version.") }
        if mode == .userHeld {
            guard item.dataHash == CloudVaultWire.digest(wireData), item.metadata == wireMetadata else { throw BackpackError.invalid("Cloud write receipt differs from uploaded ciphertext.") }
        }
        return item
    }
    func synchronize(_ library: LocalLibrary, selected: Set<UUID>? = nil, allowForeignCopies: Bool = false) async throws {
        let client = try connection()
        lastSynchronized = nil
        try await refresh()
        guard syncing, !locked, let state, state.enabled, state.migrationId == nil, !state.legacyMigrationPending else {
            throw BackpackError.invalid("Private sync is paused, locked or waiting for migration.")
        }
        if selected == nil {
            let linked = Set(pin.links.values.filter { $0.generation == state.generation }.map(\.remoteID))
            for remote in items where !linked.contains(remote.id) {
                let hasLocalSource = library.state.media.contains { media in
                    guard let source = media.cloudSource, source.accountID == client.scope.accountID,
                          source.server == client.scope.origin.url.absoluteString else { return false }
                    let id = source.itemID.uuidString.lowercased()
                    return remote.id == id || remote.legacyItemId == id
                }
                if hasLocalSource { continue }
                try checked(client)
                progress = "Downloading artwork"
                try await keepOffline(remote, library: library)
            }
        }
        for item in library.state.media where selected == nil || selected?.contains(item.id) == true {
            try checked(client)
            let localID = item.id.uuidString.lowercased()
            let bytes = try library.data(item), hash = CloudVaultWire.digest(bytes)
            let local = localMetadata(item, data: bytes)
            let localMetadataHash = CloudVaultWire.digest(try CloudVaultWire.json(local))
            if try requiresExplicitCopy(item) {
                if selected == nil { continue }
                guard allowForeignCopies else { throw BackpackError.invalid("Confirm an independent copy before backing up artwork from another account or a deleted/reset cloud library.") }
            }
            var link = pin.links[localID]
            if let previous = link, previous.generation != state.generation || previous.remoteMissing {
                guard selected != nil, allowForeignCopies else { continue }
                link = nil
            }
            if link == nil, let source = item.cloudSource, source.accountID == client.scope.accountID,
               source.server == client.scope.origin.url.absoluteString,
               let remote = items.first(where: { $0.legacyItemId == source.itemID.uuidString.lowercased() || $0.id == source.itemID.uuidString.lowercased() }) {
                let actual = try await download(remote)
                guard actual.data == bytes else {
                    throw BackpackError.invalid("The existing cloud association contains different artwork. Both copies were retained.")
                }
                try await authorizeForBackpack(remote)
                let saved = try library.applyCloudUpdate(item, original: bytes, data: actual.data,
                    title: actual.metadata["title"]?.text ?? item.name, attribution: attribution(actual.metadata),
                    category: actual.metadata["category"]?.text, favorite: actual.metadata["favorite"] == .bool(true))
                pin.links[localID] = CloudLocalLink(remoteID: remote.id, generation: state.generation, version: remote.version,
                    localHash: hash, localMetadataHash: CloudVaultWire.digest(try CloudVaultWire.json(localMetadata(saved, data: actual.data))))
                try savePin(); continue
            }
            if var current = link {
                if current.remoteMissing { continue }
                guard let remote = items.first(where: { $0.id == current.remoteID }) else {
                    if current.version > 0 { current.remoteMissing = true; pin.links[localID] = current; try savePin(); continue }
                    if current.remoteMissing { continue }
                    let uploaded = try await write(bytes, metadata: merging(local, into: [:], data: bytes), id: current.remoteID,
                        expectedVersion: 0, state: state, client: client)
                    current.version = uploaded.version; current.localHash = hash; current.localMetadataHash = localMetadataHash
                    pin.links[localID] = current; try savePin(); continue
                }
                guard remote.version >= current.version else {
                    throw BackpackError.invalid("Cloud artwork version rolled back. Both copies were retained.")
                }
                if current.version == 0 {
                    let actual = try await plain(remote, client: client)
                    guard actual.data == bytes else { throw BackpackError.invalid("An interrupted upload ID contains different data. Both copies were retained.") }
                    current.version = remote.version
                }
                let locallyChanged = current.localHash != hash ||
                    (current.localMetadataHash != nil && current.localMetadataHash != localMetadataHash)
                if remote.version != current.version && !locallyChanged {
                    let actual = try await download(remote)
                    try await authorizeForBackpack(remote)
                    let saved = try library.applyCloudUpdate(item, original: bytes, data: actual.data,
                        title: actual.metadata["title"]?.text ?? item.name, attribution: attribution(actual.metadata),
                        category: actual.metadata["category"]?.text, favorite: actual.metadata["favorite"] == .bool(true))
                    current.version = remote.version; current.localHash = CloudVaultWire.digest(actual.data)
                    current.localMetadataHash = CloudVaultWire.digest(try CloudVaultWire.json(localMetadata(saved, data: actual.data)))
                    pin.links[localID] = current; try savePin(); continue
                }
                if locallyChanged {
                    guard remote.version == current.version else { throw BackpackError.invalid("Cloud/local edits conflict. Neither copy was overwritten.") }
                    let original = try await plain(remote, client: client)
                    let uploadData = current.localHash == hash ? original.data : bytes
                    let updated = try await write(uploadData, metadata: merging(local, into: original.metadata, data: uploadData), id: current.remoteID,
                        expectedVersion: current.version, state: state, client: client)
                    current.version = updated.version
                }
                current.localHash = hash; current.localMetadataHash = localMetadataHash
                pin.links[localID] = current; try savePin()
            } else {
                let id = UUID().uuidString.lowercased()
                pin.links[localID] = CloudLocalLink(remoteID: id, generation: state.generation, version: 0, localHash: hash,
                    localMetadataHash: localMetadataHash)
                try savePin()
                let uploaded = try await write(bytes, metadata: merging(local, into: [:], data: bytes), id: id, expectedVersion: 0, state: state, client: client)
                pin.links[localID]?.version = uploaded.version; try savePin()
            }
        }
        try await refresh()
        try checked(client)
        progress = ""; lastSynchronized = Date()
    }
    func deleteCloudOnly(confirmation: String) async throws {
        let client = try connection()
        guard let state, confirmation == "DELETE CLOUD" else { throw BackpackError.invalid("Confirm DELETE CLOUD. Local files will be retained.") }
        struct Reply: Decodable { let cloud: CloudVaultState; let message: String }
        let reply: Reply = try await client.call(method: "DELETE", body: CloudVaultWire.json([
            "generation": CloudJSON.integer(state.generation), "confirmation": .string(confirmation)]))
        try checked(client); try reply.cloud.validate(client.scope)
        if let keyID = state.keyId, let cache { try await cache.remove(scope: cacheScope(client, keyID)) }
        try checked(client)
        keys = [:]; locked = true; pin.paused = true; pin.remoteReset = true; items = []; titles = [:]; categories = [:]
        try pin.accept(reply.cloud); self.state = reply.cloud; try savePin()
    }
    func deleteItem(_ item: CloudVaultItem) async throws {
        let client = try connection()
        guard syncing, let state, state.enabled, !state.deleting, state.migrationId == nil,
              item.generation == state.generation, item.keyId == state.keyId, item.mode == state.mode else {
            throw BackpackError.invalid("Enable and reload the current private cloud before deleting.")
        }
        try item.validate(client.scope, generation: state.generation, keyID: item.keyId, mode: state.mode)
        var body: [String: CloudJSON] = ["generation": .integer(item.generation), "version": .integer(item.version)]
        if state.mode == .userHeld {
            let proof = try await client.signed(action: .delete, payload: ["id": .string(item.id), "generation": .integer(item.generation),
                "version": .integer(item.version)], generation: state.generation, keyID: item.keyId, key: key(item.keyId), crypto: crypto)
            body["authorization"] = try JSONDecoder().decode(CloudJSON.self, from: CloudVaultWire.json(proof))
        }
        let _: CommunityMessage = try await client.call("items/\(item.id)", method: "DELETE", body: CloudVaultWire.json(body))
        try checked(client)
        for (id, value) in pin.links where value.remoteID == item.id { pin.links[id]?.remoteMissing = true }
        try savePin(); try await refresh()
    }
    func requestLegacyMigration() async throws {
        let client = try connection()
        guard syncing else { throw BackpackError.invalid("Explicitly enable private cloud first.") }
        struct Reply: Decodable { let cloud: CloudVaultState }
        let _: Reply = try await client.call("legacy-migration", method: "POST", body: Data("{}".utf8))
        try await refresh()
    }

    private func strongPassword(_ password: String, confirmation: String) throws {
        let value = password.precomposedStringWithCanonicalMapping
        guard password == confirmation, value.count >= 20, value.utf8.count <= CloudVaultCrypto.maximumPasswordBytes,
              value.unicodeScalars.filter({ !CharacterSet.whitespacesAndNewlines.contains($0) }).count >= 12,
              Set(value.unicodeScalars).count >= 5 else {
            throw BackpackError.invalid("Use and confirm a separate recovery passphrase of at least 20 characters, with at least 12 non-space characters. It must not be your account password.")
        }
    }
    private func wrapper(_ value: CloudVaultRecoveryWrapper) -> CloudPasswordWrap {
        CloudPasswordWrap(salt: CloudVaultWire.base64(value.salt), wrappedKey: CloudVaultWire.base64(value.combined))
    }
    func replaceRecovery(password: String, confirmation: String) async throws {
        try strongPassword(password, confirmation: confirmation)
        let client = try connection()
        guard let state, state.mode == .userHeld, let keyID = state.keyId else { throw BackpackError.invalid("Unlock the user-held library first.") }
        let key = try self.key(keyID)
        let aad = try CloudVaultWire.wrapAAD(account: client.scope.account, key: keyID)
        let recovery = try await crypto.wrapVaultKey(key, libraryPassword: password, aad: aad)
        let verified = try await crypto.unlockVaultKey(libraryPassword: password, recovery: recovery, aad: aad)
        try await checkKey(verified, keyID: keyID, publicKey: state.controlPublicKey, client: client)
        try await replaceWrappers(CloudWrappers(recovery: wrapper(recovery), passkeys: state.passkeys,
            controlPublicKey: state.controlPublicKey ?? ""), client: client, state: state, key: key)
    }
    private func replaceWrappers(_ wrappers: CloudWrappers, client: CloudVaultClient, state: CloudVaultState, key: CloudVaultKey) async throws {
        guard syncing, state.enabled, state.mode == .userHeld, !state.deleting, state.migrationId == nil else {
            throw BackpackError.invalid("Enable and unlock active cloud before changing wrappers.")
        }
        try wrappers.validate()
        guard wrappers.controlPublicKey == state.controlPublicKey, let keyID = state.keyId else {
            throw BackpackError.invalid("Changing control keys requires a complete migration.")
        }
        let payload = try JSONDecoder().decode([String: CloudJSON].self, from: CloudVaultWire.json(wrappers))
        let signed = try await client.signed(action: .replaceWraps, payload: payload, generation: state.generation,
            keyID: keyID, key: key, crypto: crypto)
        struct Reply: Decodable { let cloud: CloudVaultState }
        let response: Reply = try await client.call("key-wrappers", method: "PUT", body: CloudVaultWire.json(signed))
        try checked(client); try response.cloud.validate(client.scope)
        guard response.cloud.keyId == keyID, response.cloud.mode == .userHeld else { throw BackpackError.invalid("Recovery update changed the library key.") }
        self.state = response.cloud
    }
    func removePasskey(_ credential: String) async throws {
        let client = try connection()
        guard let state, let recovery = state.recovery, let keyID = state.keyId, let control = state.controlPublicKey else {
            throw BackpackError.invalid("Unlock this library before changing its passkeys.")
        }
        try await replaceWrappers(CloudWrappers(recovery: recovery, passkeys: state.passkeys.filter { $0.credentialId != credential },
            controlPublicKey: control), client: client, state: state, key: key(keyID))
    }
        @available(iOS 18.0, *)
        func addPasskey(operation: CloudVaultPasskeyOperation, window: UIWindow, displayName: String) async throws {
            let client = try connection()
            guard let rp = passkeyRP, let state, let keyID = state.keyId, let recovery = state.recovery,
                  let control = state.controlPublicKey, state.mode == .userHeld, state.passkeys.count < 10 else {
                throw BackpackError.invalid("Passkey association/provider support is unavailable, or this library has ten passkeys. Recovery password remains available.")
            }
            let vaultKey = try key(keyID)
            let registrationChallenge = try await crypto.generateCloudChallenge()
            let credential = try await operation.register(rp: rp, account: client.scope.account, name: displayName,
                challenge: registrationChallenge, window: window)
            try checked(client)
            let input = try await crypto.generateCloudChallenge()
            let assertionChallenge = try await crypto.generateCloudChallenge()
            let output = try await operation.evaluate(rp: rp, credential: credential, input: input,
                challenge: assertionChallenge, window: window)
            try checked(client)
            let id = CloudVaultWire.base64(credential)
            let wrapped = try await crypto.wrapVaultKeyWithPRF(vaultKey, prfOutput: output,
                info: CloudVaultWire.passkeyInfo(account: client.scope.account, key: keyID, credential: id),
                aad: CloudVaultWire.wrapAAD(account: client.scope.account, key: keyID, credential: id))
            let verified = try await crypto.unlockVaultKeyWithPRF(wrapped, prfOutput: output,
                info: CloudVaultWire.passkeyInfo(account: client.scope.account, key: keyID, credential: id),
                aad: CloudVaultWire.wrapAAD(account: client.scope.account, key: keyID, credential: id))
            try await checkKey(verified, keyID: keyID, publicKey: control, client: client)
            var values = state.passkeys.filter { $0.credentialId != id }
            values.append(CloudPasskeyWrap(credentialId: id, prfInput: CloudVaultWire.base64(input),
                hkdfSalt: CloudVaultWire.base64(wrapped.hkdfSalt), wrappedKey: CloudVaultWire.base64(wrapped.combined)))
            try await replaceWrappers(CloudWrappers(recovery: recovery, passkeys: values, controlPublicKey: control),
                client: client, state: state, key: vaultKey)
        }

        @available(iOS 18.0, *)
        func unlockPasskey(_ wrapper: CloudPasskeyWrap, operation: CloudVaultPasskeyOperation, window: UIWindow) async throws {
            let client = try connection()
            guard let rp = passkeyRP, let state, let keyID = state.keyId, state.mode == .userHeld,
                  state.passkeys.contains(wrapper) else { throw BackpackError.invalid("This passkey is not enrolled for the current library.") }
            try wrapper.validate()
            let challenge = try await crypto.generateCloudChallenge()
            let output = try await operation.evaluate(rp: rp, credential: CloudVaultWire.bytes(wrapper.credentialId, min: 1, max: 1024),
                input: CloudVaultWire.bytes(wrapper.prfInput, min: 32, max: 32), challenge: challenge, window: window)
            try checked(client)
            let unlocked = try await crypto.unlockVaultKeyWithPRF(CloudVaultPasskeyWrapper(
                hkdfSalt: CloudVaultWire.bytes(wrapper.hkdfSalt, min: 32, max: 32),
                combined: CloudVaultWire.bytes(wrapper.wrappedKey, min: 60, max: 60)), prfOutput: output,
                info: CloudVaultWire.passkeyInfo(account: client.scope.account, key: keyID, credential: wrapper.credentialId),
                aad: CloudVaultWire.wrapAAD(account: client.scope.account, key: keyID, credential: wrapper.credentialId))
            try await checkKey(unlocked, keyID: keyID, publicKey: state.controlPublicKey, client: client)
            guard let cache else { throw BackpackError.invalid("Device key cache is unavailable.") }
            try await cache.store(unlocked, scope: cacheScope(client, keyID))
            try checked(client); keys[keyID] = unlocked; locked = false
            try await refresh()
        }
    func migrate(password: String, confirmation: String) async throws {
        guard canEnroll else { throw BackpackError.invalid("User-held enrollment is not enabled by this server.") }
        let client = try connection()
        try await refresh()
        guard syncing, !locked, let current = state, current.enabled,
              !current.legacyMigrationPending, current.legacyItemCount == 0 else {
            throw BackpackError.invalid("Enable and unlock cloud, and finish legacy encryption before migration.")
        }
        var pending: CloudMigration
        var target: CloudVaultKey
        if let id = current.migrationId {
            pending = try await client.migration(id)
            guard pending.fromGeneration == current.generation else { throw BackpackError.invalid("Migration source changed.") }
            target = try await crypto.unlockVaultKey(libraryPassword: password, recovery: pending.recovery.primitive,
                aad: CloudVaultWire.wrapAAD(account: client.scope.account, key: pending.keyId))
            try await checkKey(target, keyID: pending.keyId, publicKey: pending.controlPublicKey, client: client)
        } else {
            try strongPassword(password, confirmation: confirmation)
            let keyID = UUID().uuidString.lowercased()
            let aad = try CloudVaultWire.wrapAAD(account: client.scope.account, key: keyID)
            let enrollment = try await crypto.createUserHeldVault(libraryPassword: password, aad: aad)
            target = enrollment.key
            let recovered = try await crypto.unlockVaultKey(libraryPassword: confirmation, recovery: enrollment.recovery, aad: aad)
            let control = try await crypto.controlPublicKey(using: target, info: CloudVaultWire.controlInfo(account: client.scope.account, key: keyID))
            let checkedControl = try await crypto.controlPublicKey(using: recovered, info: CloudVaultWire.controlInfo(account: client.scope.account, key: keyID))
            guard control == checkedControl else { throw BackpackError.invalid("Recovery verification failed.") }
            let wraps = CloudWrappers(recovery: wrapper(enrollment.recovery), passkeys: [], controlPublicKey: CloudVaultWire.base64(control))
            let payload: [String: CloudJSON] = ["generation": .integer(current.generation), "keyId": .string(keyID),
                "wrappers": try JSONDecoder().decode(CloudJSON.self, from: CloudVaultWire.json(wraps)), "recoveryVerified": .bool(true)]
            var input: [String: CloudJSON] = ["payload": .string(CloudVaultWire.base64(try CloudVaultWire.json(payload)))]
            if current.mode == .userHeld, let oldID = current.keyId {
                let signed = try await client.signed(action: .startMigration, payload: payload, generation: current.generation,
                    keyID: oldID, key: key(oldID), crypto: crypto)
                input["payload"] = .string(signed.payload)
                input["proof"] = try JSONDecoder().decode(CloudJSON.self, from: CloudVaultWire.json(signed.proof))
            }
            struct Reply: Decodable { let migration: CloudMigration }
            let response: Reply = try await client.call("migrations", method: "POST", body: CloudVaultWire.json(input))
            pending = try await client.migration(response.migration.migrationId)
            guard pending.keyId == keyID, pending.fromGeneration == current.generation else { throw BackpackError.invalid("Migration enrollment returned a different key.") }
        }
        try checked(client)
        guard let cache else { throw BackpackError.invalid("Device key cache is unavailable.") }
        try await cache.store(target, scope: cacheScope(client, pending.keyId))
        try checked(client)
        keys[pending.keyId] = target; migration = pending
        let (sourceState, source) = try await client.scan()
        guard sourceState.generation == current.generation, sourceState.keyId == current.keyId,
              sourceState.migrationId == pending.migrationId else { throw BackpackError.invalid("Migration source snapshot changed.") }
        var fingerprints: [String: (String, [String: CloudJSON])] = [:]
        var staged = Dictionary(uniqueKeysWithValues: pending.items.map { ($0.id, $0) })
        for (index, item) in source.enumerated() {
            progress = "Migrating \(index + 1) / \(source.count)"
            let original = try await plain(item, client: client)
            fingerprints[item.id] = (CloudVaultWire.digest(original.data), original.metadata)
            if let existing = staged[item.id] {
                let previous = try await plain(existing, client: client, migration: pending.migrationId, overrideKey: target)
                if previous.data == original.data && previous.metadata == original.metadata { continue }
            }
            let uploaded = try await write(original.data, metadata: original.metadata, id: item.id,
                expectedVersion: staged[item.id]?.version ?? 0, state: current, client: client, migration: pending, targetKey: target)
            let verified = try await plain(uploaded, client: client, migration: pending.migrationId, overrideKey: target)
            guard verified.data == original.data, verified.metadata == original.metadata else {
                throw BackpackError.invalid("Staged data differs from the verified source. Migration was not committed.")
            }
            staged[item.id] = uploaded
        }
        pending = try await client.migration(pending.migrationId)
        try checked(client); migration = pending
        guard Set(pending.items.map(\.id)) == Set(source.map(\.id)) else { throw BackpackError.invalid("Migration does not contain every source item.") }
        for item in pending.items {
            let verified = try await plain(item, client: client, migration: pending.migrationId, overrideKey: target)
            guard let source = fingerprints[item.id], source.0 == CloudVaultWire.digest(verified.data), source.1 == verified.metadata else {
                throw BackpackError.invalid("Final staged verification changed. No manifest was signed.")
            }
        }
        let manifest = try CloudVaultWire.manifest(account: client.scope.account, generation: pending.generation, key: pending.keyId, items: pending.items)
        let signed = try await client.signed(action: .commitMigration,
            payload: ["migrationId": .string(pending.migrationId), "generation": .integer(current.generation),
                "manifestHash": .string(manifest), "recoveryVerified": .bool(true)], generation: current.generation,
            keyID: pending.keyId, key: target, crypto: crypto, migration: pending.migrationId)
        struct Reply: Decodable { let cloud: CloudVaultState }
        let reply: Reply = try await client.call("migrations/commit", method: "POST", body: CloudVaultWire.json(signed))
        try checked(client); try reply.cloud.validate(client.scope)
        guard reply.cloud.mode == .userHeld, reply.cloud.keyId == pending.keyId, reply.cloud.generation == pending.generation else {
            throw BackpackError.invalid("Migration did not confirm the intended user-held key.")
        }
        for (id, value) in pin.links {
            guard let remote = staged[value.remoteID] else { continue }
            pin.links[id] = CloudLocalLink(remoteID: value.remoteID, generation: pending.generation,
                version: remote.version, localHash: value.localHash, localMetadataHash: value.localMetadataHash,
                remoteMissing: value.remoteMissing)
        }
        pin.generation = reply.cloud.generation; pin.revision = reply.cloud.revision; pin.userHeld = true
        pin.paused = false; pin.remoteReset = false; state = reply.cloud; migration = nil; locked = false
        try savePin(); progress = "Migration verified and committed."
        keys = [pending.keyId: target]
        if let oldID = current.keyId, oldID != pending.keyId {
            try await cache.remove(scope: cacheScope(client, oldID)); try checked(client)
        }
        try await refresh()
    }
    func cancelMigration() async throws {
        let client = try connection()
        guard let id = state?.migrationId ?? migration?.migrationId else { throw BackpackError.invalid("No pending migration.") }
        let pending = try await client.migration(id)
        try checked(client)
        let _: CommunityMessage = try await client.call("migrations/\(id)", method: "DELETE")
        try checked(client)
        if let cache { try await cache.remove(scope: cacheScope(client, pending.keyId)); try checked(client) }
        keys.removeValue(forKey: pending.keyId)
        migration = nil
        try await refresh()
    }
    private func validateAdoption(_ value: CloudAdoption, client: CloudVaultClient, expected: CloudAdoptionQR? = nil) throws {
        try client.scope.validate(account: value.accountId, origin: value.origin); try value.qr.validate(client.scope)
        let expiry = try CloudVaultWire.date(value.expiresAt)
        guard canAdopt, value.pairingId == value.qr.pairingId, ["pending", "approved", "completed", "cancelled"].contains(value.state),
              expiry > Date(), expiry.timeIntervalSinceNow <= 120, value.qr.generation == state?.generation,
              value.qr.keyId == state?.keyId, expected == nil || value.qr == expected else {
            throw BackpackError.invalid("Device adoption expired or changed its pinned recipient/account/key.")
        }
        if let box = value.box { try box.validate() }
    }
    var scannedAdoption: CloudAdoption? {
        guard let receivedQR, adoption?.qr == receivedQR else { return nil }
        return adoption
    }
    func createAdoption(label: String) async throws {
        guard canAdopt else { throw BackpackError.invalid("Device adoption is not enabled by this server.") }
        let client = try connection()
        let key = try await crypto.generateAdoptionKey()
        struct Input: Encodable { let recipientPublicKey: String; let label: String }
        struct Reply: Decodable { let adoption: CloudAdoption }
        let reply: Reply = try await client.call("adoptions", method: "POST",
            body: CloudVaultWire.json(Input(recipientPublicKey: CloudVaultWire.base64(key.publicKeyX963), label: label)))
        try checked(client); try validateAdoption(reply.adoption, client: client)
        guard reply.adoption.qr.recipientPublicKey == CloudVaultWire.base64(key.publicKeyX963) else { throw BackpackError.invalid("Adoption recipient was substituted.") }
        recipient = key; adoption = reply.adoption
    }
    func inspectQR(_ text: String) async throws {
        guard canAdopt, !locked else { throw BackpackError.invalid("Unlock the trusted library before scanning another device.") }
        let client = try connection()
        let data = Data(text.utf8)
        guard data.count <= 4096,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == Set(["protocol", "origin", "accountId", "pairingId", "generation", "keyId", "recipientPublicKey", "challenge"]) else {
            throw BackpackError.invalid("Scan a public adoption QR without tokens, passwords or additional fields.")
        }
        let qr = try JSONDecoder().decode(CloudAdoptionQR.self, from: data)
        try qr.validate(client.scope)
        struct Reply: Decodable { let adoption: CloudAdoption }
        let reply: Reply = try await client.call("adoptions/\(qr.pairingId)")
        try checked(client); try validateAdoption(reply.adoption, client: client, expected: qr)
        guard reply.adoption.state == "pending" else { throw BackpackError.invalid("This QR has already been handled.") }
        receivedQR = qr; adoption = reply.adoption
    }
    func approveAdoption() async throws {
        let client = try connection()
        guard canAdopt, let qr = receivedQR, let state, let keyID = state.keyId, let adoption else {
            throw BackpackError.invalid("Scan and explicitly approve a pending same-account device.")
        }
        try validateAdoption(adoption, client: client, expected: qr)
        let opaqueKey = try key(keyID)
        let sealed = try await crypto.sealVaultKeyForAdoption(opaqueKey,
            recipientPublicKeyX963: CloudVaultWire.bytes(qr.recipientPublicKey, min: 65, max: 65),
            info: Data("catalog-cloud-adopt-v1".utf8), aad: CloudVaultWire.adoptionAAD(qr))
        try checked(client); try validateAdoption(adoption, client: client, expected: qr)
        let box = CloudAdoptionBox(encapsulatedKey: CloudVaultWire.base64(sealed.encapsulatedKey), ciphertext: CloudVaultWire.base64(sealed.ciphertext))
        let payload: [String: CloudJSON] = ["pairingId": .string(qr.pairingId), "recipientPublicKey": .string(qr.recipientPublicKey),
            "challenge": .string(qr.challenge), "box": try JSONDecoder().decode(CloudJSON.self, from: CloudVaultWire.json(box))]
        let signed = try await client.signed(action: .approve, payload: payload, generation: state.generation,
            keyID: keyID, key: opaqueKey, crypto: crypto)
        struct Reply: Decodable { let adoption: CloudAdoption }
        let reply: Reply = try await client.call("adoptions/approve", method: "POST", body: CloudVaultWire.json(signed))
        try checked(client); try validateAdoption(reply.adoption, client: client, expected: qr)
        self.adoption = reply.adoption
    }
    func pollAdoption() async throws {
        let client = try connection()
        guard canAdopt, let current = adoption, let recipient else { throw BackpackError.invalid("Enable cloud and create an adoption QR on this device first.") }
        struct Reply: Decodable { let adoption: CloudAdoption }
        let reply: Reply = try await client.call("adoptions/\(current.pairingId)")
        try checked(client); try validateAdoption(reply.adoption, client: client, expected: current.qr)
        adoption = reply.adoption
        guard reply.adoption.state == "approved", let box = reply.adoption.box, let state, let keyID = state.keyId,
              let publicKey = state.controlPublicKey else { return }
        let key = try await crypto.openVaultKeyFromAdoption(
            CloudVaultHPKEMessage(encapsulatedKey: CloudVaultWire.bytes(box.encapsulatedKey, min: 65, max: 65),
                ciphertext: CloudVaultWire.bytes(box.ciphertext, min: 48, max: 48)),
            recipient: recipient, info: Data("catalog-cloud-adopt-v1".utf8), aad: CloudVaultWire.adoptionAAD(current.qr),
            expectedControlPublicKey: CloudVaultWire.bytes(publicKey, min: 32, max: 32),
            controlInfo: CloudVaultWire.controlInfo(account: client.scope.account, key: keyID))
        try checked(client); try validateAdoption(reply.adoption, client: client, expected: current.qr)
        let bytes = try CloudVaultWire.bytes(box.encapsulatedKey, min: 65, max: 65) + CloudVaultWire.bytes(box.ciphertext, min: 48, max: 48)
        let signed = try await client.signed(action: .complete,
            payload: ["pairingId": .string(current.pairingId), "boxHash": .string(CloudVaultWire.digest(bytes))],
            generation: state.generation, keyID: keyID, key: key, crypto: crypto)
        let completed: Reply = try await client.call("adoptions/complete", method: "POST", body: CloudVaultWire.json(signed))
        try checked(client); try validateAdoption(completed.adoption, client: client, expected: current.qr)
        guard completed.adoption.state == "completed", let cache else { throw BackpackError.invalid("Device adoption did not complete.") }
        try await cache.store(key, scope: cacheScope(client, keyID))
        try checked(client)
        guard canAdopt, current.qr.generation == self.state?.generation, keyID == self.state?.keyId else {
            throw BackpackError.invalid("Cloud changed during device adoption. Unlock the current library again.")
        }
        keys[keyID] = key; locked = false; self.recipient = nil; adoption = completed.adoption
        try await refresh()
    }
    func cancelAdoption() async throws {
        let client = try connection()
        guard let adoption else { return }
        let _: CommunityMessage = try await client.call("adoptions/\(adoption.pairingId)", method: "DELETE")
        try checked(client)
        self.adoption = nil; recipient = nil; receivedQR = nil
    }
}
