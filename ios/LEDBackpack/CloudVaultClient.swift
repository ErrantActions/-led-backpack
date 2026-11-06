import Foundation
import BackpackProtocol

struct CloudVaultPage: Decodable, Sendable {
    let state: CloudVaultState
    let items: [CloudVaultItem]
    let page: Int, limit: Int, total: Int
    init(from decoder: Decoder) throws {
        state = try CloudVaultState(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([CloudVaultItem].self, forKey: .items)
        page = try values.decode(Int.self, forKey: .page)
        limit = try values.decode(Int.self, forKey: .limit)
        total = try values.decode(Int.self, forKey: .total)
    }
    private enum CodingKeys: String, CodingKey { case items, page, limit, total }
}
enum CloudProofAction: String, Codable, Sendable {
    case startMigration = "start-migration", commitMigration = "commit-migration", replaceWraps = "replace-wraps"
    case write = "write-item", delete = "delete-item", approve = "approve-adoption", complete = "complete-adoption"
}

struct CloudVaultClient: Sendable {
    let instanceID = UUID()
    let scope: CloudVaultScope
    let send: @Sendable (URLRequest, Int) async throws -> CommunityResponse

    func call<T: Decodable>(_ path: String = "", method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], mode: CloudEncryptionMode? = nil) async throws -> T {
        let response = try await request(path, method: method, body: body, query: query, mode: mode)
        return try JSONDecoder().decode(T.self, from: response.data)
    }
    private func request(_ path: String, method: String, body: Data?, query: [URLQueryItem],
        mode: CloudEncryptionMode?, maxBytes: Int = 2_000_000) async throws -> CommunityResponse {
        try Task.checkCancellation()
        guard (body?.count ?? 0) <= 7_000_000 else { throw BackpackError.invalid("Cloud request exceeds its body budget.") }
        var request = URLRequest(url: try scope.origin.api("cloud" + (path.isEmpty ? "" : "/" + path), query: query), timeoutInterval: 60)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("1", forHTTPHeaderField: "X-Catalog-Cloud-Protocol")
        if method != "GET" { request.setValue("1", forHTTPHeaderField: "X-Catalog-Client") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let mode { request.setValue(mode.rawValue, forHTTPHeaderField: "X-Catalog-Cloud-Encryption") }
        let response = try await send(request, maxBytes)
        try Task.checkCancellation()
        guard (200...299).contains(response.status) else {
            struct Failure: Decodable { let error: Detail; struct Detail: Decodable { let code: String; let message: String } }
            if let error = try? JSONDecoder().decode(Failure.self, from: response.data) {
                throw CommunityFailure(status: response.status, code: error.error.code, message: error.error.message)
            }
            throw BackpackError.invalid("Private cloud request failed (HTTP \(response.status)).")
        }
        return response
    }
    func state() async throws -> CloudVaultState {
        struct Reply: Decodable { let cloud: CloudVaultState }
        let response: Reply = try await call()
        try response.cloud.validate(scope)
        return response.cloud
    }
    func enable(generation: Int) async throws -> CloudVaultState {
        struct Input: Encodable { let generation: Int }
        struct Reply: Decodable { let cloud: CloudVaultState }
        let response: Reply = try await call("enable", method: "POST", body: CloudVaultWire.json(Input(generation: generation)))
        try response.cloud.validate(scope)
        return response.cloud
    }
    func scan() async throws -> (CloudVaultState, [CloudVaultItem]) {
        for attempt in 0..<3 {
            do {
                var result: [CloudVaultItem] = []
                var ids = Set<String>()
                var snapshot: CloudVaultState?
                var expectedTotal: Int?
                for page in 1...10000 {
                    var query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "100")]
                    if let snapshot {
                        query += [URLQueryItem(name: "generation", value: String(snapshot.generation)),
                            URLQueryItem(name: "snapshotRevision", value: String(snapshot.revision))]
                    }
                    let response: CloudVaultPage = try await call("items", query: query)
                    try response.state.validate(scope)
                    guard response.page == page, response.limit == 100, response.items.count <= 100,
                          (0...CloudVaultWire.maxInteger).contains(response.total), let keyID = response.state.keyId else { throw BackpackError.invalid("Invalid cloud snapshot page.") }
                    if let snapshot {
                        guard snapshot.generation == response.state.generation, snapshot.revision == response.state.revision,
                              snapshot.keyId == keyID, snapshot.mode == response.state.mode, expectedTotal == response.total else {
                            throw BackpackError.invalid("Private cloud snapshot changed between pages.")
                        }
                    } else { snapshot = response.state; expectedTotal = response.total }
                    for item in response.items {
                        try item.validate(scope, generation: response.state.generation, keyID: keyID, mode: response.state.mode)
                        guard ids.insert(item.id).inserted else { throw BackpackError.invalid("Cloud snapshot repeats an item.") }
                        result.append(item)
                    }
                    if result.count == response.total { return (response.state, result) }
                    guard !response.items.isEmpty, result.count < response.total else { throw BackpackError.invalid("Incomplete cloud snapshot.") }
                }
                throw BackpackError.invalid("Cloud snapshot exceeds protocol pagination.")
            } catch let error as CommunityFailure where error.code == "cloud_snapshot_changed" && attempt < 2 { continue }
        }
        throw BackpackError.invalid("Cloud snapshot could not be completed.")
    }
    func item(_ id: String, migration: String? = nil) async throws -> CloudVaultItem {
        try CloudVaultWire.id(id)
        if let migration { try CloudVaultWire.id(migration) }
        struct Reply: Decodable { let item: CloudVaultItem }
        let response: Reply = try await call((migration.map { "migrations/\($0)/" } ?? "") + "items/\(id)")
        return response.item
    }
    func media(_ item: CloudVaultItem, migration: String? = nil) async throws -> Data {
        try item.validate(scope, generation: item.generation, keyID: item.keyId, mode: item.mode)
        if let migration { try CloudVaultWire.id(migration) }
        let path = (migration.map { "migrations/\($0)/" } ?? "") + "items/\(item.id)/media"
        let query = [URLQueryItem(name: "generation", value: String(item.generation)), URLQueryItem(name: "version", value: String(item.version))]
        let expected = try scope.origin.api("cloud/" + path, query: query)
        guard item.downloadUrl == expected else { throw BackpackError.invalid("Cloud download URL does not match the captured item context.") }
        let response = try await request(path, method: "GET", body: nil, query: query, mode: nil, maxBytes: CloudVaultWire.maxCiphertext)
        let expectedHeaders = ["account": scope.account, "generation": String(item.generation), "key-id": item.keyId,
            "encryption": item.mode.rawValue, "item": item.id, "version": String(item.version)]
        for (name, value) in expectedHeaders where response.headers["x-catalog-cloud-" + name] != value {
            throw BackpackError.invalid("Private cloud media context headers do not match.")
        }
        guard response.data.count == item.byteSize else { throw BackpackError.invalid("Cloud media byte count changed.") }
        if item.encrypted && CloudVaultWire.digest(response.data) != item.dataHash { throw BackpackError.invalid("Cloud ciphertext digest mismatch.") }
        return response.data
    }
    func put(id: String, input: CloudPut, mode: CloudEncryptionMode, migration: String? = nil) async throws -> CloudVaultItem {
        try CloudVaultWire.id(id)
        if let migration { try CloudVaultWire.id(migration) }
        struct Reply: Decodable { let item: CloudVaultItem }
        let response: Reply = try await call((migration.map { "migrations/\($0)/" } ?? "") + "items/\(id)",
            method: "PUT", body: CloudVaultWire.json(input), mode: mode)
        return response.item
    }
    func signed(action: CloudProofAction, payload: [String: CloudJSON], generation: Int, keyID: String,
        key: CloudVaultKey, crypto: CloudVaultCrypto, migration: String? = nil) async throws -> CloudSignedOperation {
        try CloudVaultWire.id(keyID)
        if let migration { try CloudVaultWire.id(migration) }
        let encoded = try CloudVaultWire.json(payload)
        guard encoded.count <= 45_000, (1...CloudVaultWire.maxInteger).contains(generation) else {
            throw BackpackError.invalid("Invalid cloud signed-operation intent.")
        }
        struct Input: Encodable { let action: CloudProofAction; let payloadHash: String; let migrationId: String? }
        struct Reply: Decodable { let proof: CloudProofChallenge }
        let hash = CloudVaultWire.digest(encoded)
        let response: Reply = try await call("proofs", method: "POST",
            body: CloudVaultWire.json(Input(action: action, payloadHash: hash, migrationId: migration)))
        let proof = response.proof
        try scope.validate(account: proof.accountId, origin: proof.origin)
        try CloudVaultWire.id(proof.challengeId)
        _ = try CloudVaultWire.bytes(proof.nonce, min: 32, max: 32)
        let expected = ["catalog-cloud-proof-v1", scope.account, String(generation), keyID,
            proof.challengeId, proof.nonce, action.rawValue, migration ?? "", hash].joined(separator: "\n")
        let expiry = try CloudVaultWire.date(proof.expiresAt)
        guard proof.generation == generation, proof.keyId == keyID, proof.action == action.rawValue,
              proof.migrationId == migration, proof.payloadHash == hash, proof.message == expected,
              expiry > Date(), expiry.timeIntervalSinceNow <= 120 else {
            throw BackpackError.invalid("Cloud proof challenge does not match the independently captured intent.")
        }
        let signature = try await crypto.signControl(Data(expected.utf8), using: key,
            info: CloudVaultWire.controlInfo(account: scope.account, key: keyID))
        return CloudSignedOperation(payload: CloudVaultWire.base64(encoded),
            proof: CloudProofRef(challengeId: proof.challengeId, signature: CloudVaultWire.base64(signature)))
    }
    func migration(_ id: String) async throws -> CloudMigration {
        try CloudVaultWire.id(id)
        struct Reply: Decodable { let migration: CloudMigration }
        var first: CloudMigration?
        var items: [CloudVaultItem] = []
        var ids = Set<String>()
        for page in 1...10000 {
            let reply: Reply = try await call("migrations/\(id)", query: [
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "100")])
            let value = reply.migration
            try scope.validate(account: value.accountId, origin: value.origin)
            try CloudVaultWire.id(value.keyId)
            try CloudWrappers(recovery: value.recovery, passkeys: value.passkeys, controlPublicKey: value.controlPublicKey).validate()
            guard value.migrationId == id, value.page == page, value.limit == 100, (0...CloudVaultWire.maxInteger).contains(value.total),
                  (1..<CloudVaultWire.maxInteger).contains(value.fromGeneration),
                  value.items.count <= 100, value.generation == value.fromGeneration + 1 else {
                throw BackpackError.invalid("Invalid staged migration context.")
            }
            if let first {
                guard first.keyId == value.keyId, first.generation == value.generation, first.total == value.total,
                      first.fromGeneration == value.fromGeneration else { throw BackpackError.invalid("Migration changed during listing.") }
            } else { first = value }
            for item in value.items {
                try item.validate(scope, generation: value.generation, keyID: value.keyId, mode: .userHeld)
                guard ids.insert(item.id).inserted else { throw BackpackError.invalid("Migration repeats an item.") }
                items.append(item)
            }
            if items.count == value.total {
                return CloudMigration(accountId: value.accountId, origin: value.origin, migrationId: value.migrationId,
                    keyId: value.keyId, fromGeneration: value.fromGeneration, generation: value.generation, recovery: value.recovery,
                    passkeys: value.passkeys, controlPublicKey: value.controlPublicKey, manifestHash: value.manifestHash,
                    items: items, page: 1, limit: 100, total: value.total)
            }
            guard !value.items.isEmpty, items.count < value.total else { throw BackpackError.invalid("Incomplete staged migration listing.") }
        }
        throw BackpackError.invalid("Migration exceeds pagination limits.")
    }
}
