import Foundation
import CryptoKit
import BackpackProtocol

enum CloudVaultWire {
    static let maxPlaintext = 5_000_000
    static let maxCiphertext = 5_000_028
    static let maxMetadata = 8192
    static let maxInteger = 9_007_199_254_740_991

    static func id(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else {
            throw BackpackError.invalid("Cloud identifiers must be canonical lowercase UUIDs.")
        }
    }
    static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func bytes(_ text: String, min: Int = 0, max: Int) throws -> Data {
        guard text.utf8.count <= ((max + 2) / 3) * 4,
              text.range(of: "^[A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            throw BackpackError.invalid("Cloud binary fields must use canonical unpadded base64url.")
        }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)),
              (min...max).contains(data.count), base64(data) == text else {
            throw BackpackError.invalid("Invalid cloud binary length or encoding.")
        }
        return data
    }
    static func digest(_ bytes: Data) -> String { base64(Data(SHA256.hash(data: bytes))) }
    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        throw BackpackError.invalid("Invalid cloud timestamp.")
    }
    static func wrapAAD(account: String, key: String, credential: String? = nil) throws -> String {
        try id(account); try id(key)
        if let credential { _ = try bytes(credential, min: 1, max: 1024) }
        return ["catalog-cloud-wrap-v1", account, key, credential == nil ? "password" : "passkey", credential ?? ""].joined(separator: "\n")
    }
    static func passkeyInfo(account: String, key: String, credential: String) throws -> Data {
        Data(("catalog-cloud-prf-kek-v1\n" + (try wrapAAD(account: account, key: key, credential: credential))).utf8)
    }
    static func controlInfo(account: String, key: String) throws -> Data {
        try id(account); try id(key)
        return Data(["catalog-cloud-control-v1", account, key].joined(separator: "\n").utf8)
    }
    static func assetAAD(account: String, generation: Int, key: String, item: String, version: Int, purpose: String) throws -> String {
        try id(account); try id(key); try id(item)
        guard (1...maxInteger).contains(generation), (1...maxInteger).contains(version), ["data", "metadata"].contains(purpose) else {
            throw BackpackError.invalid("Invalid cloud encryption context.")
        }
        return ["catalog-cloud-asset-v1", account, String(generation), key, item, String(version), purpose].joined(separator: "\n")
    }
    static func adoptionAAD(_ qr: CloudAdoptionQR) throws -> String {
        try id(qr.accountId); try id(qr.pairingId); try id(qr.keyId)
        guard (1...maxInteger).contains(qr.generation) else { throw BackpackError.invalid("Invalid adoption generation.") }
        return ["catalog-cloud-adopt-v1", qr.accountId, qr.pairingId, String(qr.generation), qr.keyId].joined(separator: "\n")
    }
    static func manifest(account: String, generation: Int, key: String, items: [CloudVaultItem]) throws -> String {
        try id(account); try id(key)
        guard (1...maxInteger).contains(generation), Set(items.map(\.id)).count == items.count else {
            throw BackpackError.invalid("Invalid verified migration manifest.")
        }
        var text = "catalog-cloud-manifest-v1\n\(account)\n\(generation)\n\(key)\n\(items.count)\n"
        for item in items.sorted(by: { $0.id < $1.id }) {
            try id(item.id)
            guard item.accountId == account, item.generation == generation, item.keyId == key, item.mode == .userHeld,
                  (1...maxInteger).contains(item.version) else { throw BackpackError.invalid("Manifest contains a different encryption context.") }
            _ = try bytes(item.dataHash, min: 32, max: 32); _ = try bytes(item.metadataHash, min: 32, max: 32)
            text += "\(item.id)\t\(item.version)\t\(item.dataHash)\t\(item.metadataHash)\n"
        }
        return digest(Data(text.utf8))
    }
}

enum CloudJSON: Codable, Equatable, Sendable {
    case string(String), integer(Int), number(Double), bool(Bool), object([String: CloudJSON]), array([CloudJSON]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self), result.isFinite { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([String: CloudJSON].self) { self = .object(result) }
        else { self = .array(try value.decode([CloudJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        }
    }
    var text: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: CloudJSON]? { if case .object(let value) = self { return value }; return nil }
}

enum CloudEncryptionMode: String, Codable, Sendable { case managed = "server-managed", userHeld = "user-held" }

struct CloudPasswordWrap: Codable, Equatable, Sendable {
    var version = 1
    var method = "password"
    var kdf = "PBKDF2-HMAC-SHA256"
    var iterations = 600_000
    let salt: String
    let wrappedKey: String
    func validate() throws {
        guard version == 1, method == "password", kdf == "PBKDF2-HMAC-SHA256", iterations == 600_000 else {
            throw BackpackError.invalid("Unsupported cloud recovery wrapper.")
        }
        _ = try CloudVaultWire.bytes(salt, min: 16, max: 16)
        _ = try CloudVaultWire.bytes(wrappedKey, min: 60, max: 60)
    }
    var primitive: CloudVaultRecoveryWrapper {
        get throws { try validate(); return try CloudVaultRecoveryWrapper(salt: CloudVaultWire.bytes(salt, min: 16, max: 16),
            combined: CloudVaultWire.bytes(wrappedKey, min: 60, max: 60)) }
    }
}
struct CloudPasskeyWrap: Codable, Equatable, Sendable {
    var version = 1
    var method = "passkey"
    let credentialId: String
    let prfInput: String
    let hkdfSalt: String
    let wrappedKey: String
    func validate() throws {
        guard version == 1, method == "passkey" else { throw BackpackError.invalid("Unsupported passkey wrapper.") }
        _ = try CloudVaultWire.bytes(credentialId, min: 1, max: 1024)
        _ = try CloudVaultWire.bytes(prfInput, min: 32, max: 32)
        _ = try CloudVaultWire.bytes(hkdfSalt, min: 32, max: 32)
        _ = try CloudVaultWire.bytes(wrappedKey, min: 60, max: 60)
    }
}
struct CloudWrappers: Codable, Sendable {
    let recovery: CloudPasswordWrap
    let passkeys: [CloudPasskeyWrap]
    let controlPublicKey: String
    func validate() throws {
        try recovery.validate()
        guard passkeys.count <= 10, Set(passkeys.map(\.credentialId)).count == passkeys.count else {
            throw BackpackError.invalid("Too many or duplicate passkey wrappers.")
        }
        for value in passkeys { try value.validate() }
        _ = try CloudVaultWire.bytes(controlPublicKey, min: 32, max: 32)
    }
}

struct CloudVaultScope: Equatable, Sendable {
    let origin: CommunityOrigin
    let accountID: UUID
    let revision: UUID
    var account: String { accountID.uuidString.lowercased() }
    func validate(account: String, origin: String) throws {
        try CloudVaultWire.id(account)
        guard account == self.account, origin == self.origin.url.absoluteString else {
            throw BackpackError.invalid("The private cloud response belongs to a different account or server.")
        }
    }
}

struct CloudVaultState: Codable, Sendable {
    let protocolVersion: Int
    let accountId: String
    let origin: String
    let enabled: Bool
    let deleting: Bool
    let mode: CloudEncryptionMode
    let generation: Int
    let revision: Int
    let keyId: String?
    let migrationId: String?
    let recovery: CloudPasswordWrap?
    let passkeys: [CloudPasskeyWrap]
    let controlPublicKey: String?
    let userHeldEnrollmentAvailable: Bool
    let deviceAdoptionAvailable: Bool
    let itemLimit: Int
    let maxPlaintextBytes: Int
    let legacyMigrationPending: Bool
    let legacyMigrationError: String?
    let legacyItemCount: Int
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case accountId, origin, enabled, deleting, mode, generation, revision, keyId, migrationId, recovery, passkeys,
             controlPublicKey, userHeldEnrollmentAvailable, deviceAdoptionAvailable, itemLimit, maxPlaintextBytes,
             legacyMigrationPending, legacyMigrationError, legacyItemCount
    }
    func validate(_ scope: CloudVaultScope) throws {
        try scope.validate(account: accountId, origin: origin)
        guard protocolVersion == 1, (1...CloudVaultWire.maxInteger).contains(generation),
              (0...CloudVaultWire.maxInteger).contains(revision), itemLimit == 100,
              maxPlaintextBytes == CloudVaultWire.maxPlaintext, (0...CloudVaultWire.maxInteger).contains(legacyItemCount) else {
            throw BackpackError.invalid("Unsupported or invalid private cloud state.")
        }
        if let keyId { try CloudVaultWire.id(keyId) }
        if let migrationId { try CloudVaultWire.id(migrationId) }
        if enabled && keyId == nil { throw BackpackError.invalid("Enabled cloud has no key identifier.") }
        if mode == .userHeld && enabled {
            guard let recovery, let controlPublicKey else { throw BackpackError.invalid("User-held cloud is missing recovery material.") }
            try CloudWrappers(recovery: recovery, passkeys: passkeys, controlPublicKey: controlPublicKey).validate()
        }
    }
}

struct CloudVaultItem: Codable, Identifiable, Sendable {
    let id: String
    let accountId: String
    let origin: String
    let keyId: String
    let mode: CloudEncryptionMode
    let generation: Int
    let version: Int
    let byteSize: Int
    let storageBytes: Int
    let encrypted: Bool
    let metadata: CloudJSON
    let legacyItemId: String?
    let dataHash: String
    let metadataHash: String
    let updatedAt: String
    let downloadUrl: URL
    func matches(_ other: CloudVaultItem) -> Bool {
        id == other.id && accountId == other.accountId && origin == other.origin &&
        keyId == other.keyId && mode == other.mode && generation == other.generation &&
        version == other.version && byteSize == other.byteSize && encrypted == other.encrypted &&
        metadata == other.metadata && dataHash == other.dataHash && metadataHash == other.metadataHash &&
        updatedAt == other.updatedAt && downloadUrl == other.downloadUrl && legacyItemId == other.legacyItemId
    }
    func validate(_ scope: CloudVaultScope, generation: Int, keyID: String, mode: CloudEncryptionMode) throws {
        try scope.validate(account: accountId, origin: origin)
        try CloudVaultWire.id(id); try CloudVaultWire.id(keyId)
        if let legacyItemId { try CloudVaultWire.id(legacyItemId) }
        guard self.generation == generation, (1...CloudVaultWire.maxInteger).contains(self.generation), keyId == keyID, self.mode == mode,
              (1...CloudVaultWire.maxInteger).contains(version), encrypted == (mode == .userHeld),
              (1...(mode == .userHeld ? CloudVaultWire.maxCiphertext : CloudVaultWire.maxPlaintext)).contains(byteSize),
              (byteSize...CloudVaultWire.maxInteger).contains(storageBytes) else { throw BackpackError.invalid("Cloud item context/version/size changed.") }
        _ = try CloudVaultWire.bytes(dataHash, min: 32, max: 32)
        _ = try CloudVaultWire.bytes(metadataHash, min: 32, max: 32)
        _ = try CloudVaultWire.date(updatedAt)
        if mode == .userHeld {
            guard let ciphertext = metadata.text else { throw BackpackError.invalid("User-held metadata was returned as plaintext.") }
            let bytes = try CloudVaultWire.bytes(ciphertext, min: 28, max: CloudVaultWire.maxMetadata + 28)
            guard CloudVaultWire.digest(bytes) == metadataHash else { throw BackpackError.invalid("Cloud metadata digest mismatch.") }
        } else {
            guard metadata.object != nil, try CloudVaultWire.json(metadata).count <= CloudVaultWire.maxMetadata else {
                throw BackpackError.invalid("Invalid managed cloud metadata.")
            }
        }
    }
}

struct CloudProofRef: Codable, Sendable { let challengeId: String; let signature: String }
struct CloudSignedOperation: Codable, Sendable { let payload: String; let proof: CloudProofRef }
struct CloudProofChallenge: Codable, Sendable {
    let accountId: String, origin: String, challengeId: String, nonce: String, keyId: String, action: String
    let generation: Int
    let migrationId: String?
    let payloadHash: String, message: String, expiresAt: String
}
struct CloudPut: Codable, Sendable {
    let generation: Int
    let expectedVersion: Int
    let metadata: CloudJSON
    let data: String
    let authorization: CloudSignedOperation?
}
struct CloudMigration: Codable, Sendable {
    let accountId: String, origin: String, migrationId: String, keyId: String
    let fromGeneration: Int, generation: Int
    let recovery: CloudPasswordWrap
    let passkeys: [CloudPasskeyWrap]
    let controlPublicKey: String, manifestHash: String
    let items: [CloudVaultItem]
    let page: Int, limit: Int, total: Int
}
struct CloudAdoptionBox: Codable, Sendable {
    var version = 1
    var suite = "P256_SHA256_AES_GCM_256"
    let encapsulatedKey: String
    let ciphertext: String
    func validate() throws {
        guard version == 1, suite == "P256_SHA256_AES_GCM_256" else { throw BackpackError.invalid("Unsupported adoption encryption.") }
        _ = try CloudVaultWire.bytes(encapsulatedKey, min: 65, max: 65)
        _ = try CloudVaultWire.bytes(ciphertext, min: 48, max: 48)
    }
}
struct CloudAdoptionQR: Codable, Equatable, Sendable {
    let protocolName: String
    let origin: String
    let accountId: String
    let pairingId: String
    let generation: Int
    let keyId: String
    let recipientPublicKey: String
    let challenge: String
    enum CodingKeys: String, CodingKey { case protocolName = "protocol"; case origin, accountId, pairingId, generation, keyId, recipientPublicKey, challenge }
    func validate(_ scope: CloudVaultScope) throws {
        try scope.validate(account: accountId, origin: origin)
        try CloudVaultWire.id(pairingId); try CloudVaultWire.id(keyId)
        guard protocolName == "catalog-cloud-adopt-v1", (1...CloudVaultWire.maxInteger).contains(generation) else {
            throw BackpackError.invalid("Unsupported adoption QR.")
        }
        _ = try CloudVaultWire.bytes(recipientPublicKey, min: 65, max: 65)
        _ = try CloudVaultWire.bytes(challenge, min: 32, max: 32)
    }
}
struct CloudAdoption: Codable, Sendable {
    let accountId: String, origin: String, pairingId: String, state: String, label: String, expiresAt: String
    let qr: CloudAdoptionQR
    let box: CloudAdoptionBox?
}
