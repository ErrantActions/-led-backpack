import Foundation
import CryptoKit
import CommonCrypto
import Security

enum CloudVaultCryptoError: LocalizedError, Equatable, Sendable {
    case invalidKey, invalidSalt, invalidPassword, invalidWrapper, invalidCiphertext
    case oversizedPlaintext, oversizedContext, invalidPublicKey, invalidCredential, credentialMismatch, invalidScope
    case authenticationFailed, invalidContext, invalidPRFKey, invalidSignature
    case randomFailed(Int32), derivationFailed(Int32), keychainFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "A vault key must contain exactly 32 bytes."
        case .invalidSalt: return "The recovery salt must contain exactly 16 bytes."
        case .invalidPassword: return "Provide a separate library/recovery password of 1-1024 NFC UTF-8 bytes."
        case .invalidWrapper: return "A wrapped vault key must contain exactly 60 bytes."
        case .invalidCiphertext: return "The encrypted message has an invalid length."
        case .oversizedPlaintext: return "The crypto primitive accepts at most 32 MiB of plaintext."
        case .oversizedContext: return "Cryptographic context must not exceed 64 KiB."
        case .invalidPublicKey: return "A P-256 public key must be a valid 65-byte X9.63 point."
        case .invalidCredential: return "A passkey credential identifier must contain 1-1024 bytes."
        case .credentialMismatch: return "The passkey provider returned a different credential."
        case .invalidScope: return "The vault cache scope or service is invalid."
        case .authenticationFailed: return "The encrypted message could not be authenticated."
        case .invalidContext: return "Provide a nonempty cryptographic context."
        case .invalidPRFKey: return "A passkey PRF output and its HKDF salt must each contain exactly 32 bytes."
        case .invalidSignature: return "An Ed25519 public key must contain 32 bytes and its signature 64 bytes."
        case .randomFailed(let status): return "Secure random generation failed (\(status))."
        case .derivationFailed(let status): return "Recovery-key derivation failed (\(status))."
        case .keychainFailed(let status): return "Vault Keychain operation failed (\(status))."
        }
    }
}

struct CloudVaultKey: Sendable {
    fileprivate let material: SymmetricKey
}

struct CloudVaultRecoveryWrapper: Sendable {
    let salt: Data
    let combined: Data
}

struct CloudVaultPasskeyWrapper: Sendable {
    let hkdfSalt: Data
    let combined: Data
}

struct CloudVaultEnrollment: Sendable {
    let key: CloudVaultKey
    let recovery: CloudVaultRecoveryWrapper
}

struct CloudVaultAdoptionKey: Sendable {
    fileprivate let material: P256.KeyAgreement.PrivateKey
    let publicKeyX963: Data
}

struct CloudVaultHPKEMessage: Sendable {
    let encapsulatedKey: Data
    let ciphertext: Data
}

@available(iOS 18.0, *)
struct CloudVaultPRFCapability: Sendable {
    let credentialID: Data
    let isSupported: Bool
}

// An adapter must check the actual provider/credential, not infer PRF support from authentication.
@available(iOS 18.0, *)
protocol CloudVaultPasskeyPRFProvider: Sendable {
    func capability(for credentialID: Data) async throws -> CloudVaultPRFCapability
}

actor CloudVaultCrypto {
    static let pbkdf2Iterations = 600_000
    static let maximumPlaintextBytes = 32 * 1024 * 1024
    static let maximumContextBytes = 65_536
    static let maximumPasswordBytes = 1024

    static var passkeyPRFPlatformAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    func generateVaultKey() throws -> CloudVaultKey {
        try Task.checkCancellation()
        return CloudVaultKey(material: SymmetricKey(data: try randomBytes(count: 32)))
    }

    func generateCloudChallenge() throws -> Data {
        try Task.checkCancellation()
        return try randomBytes(count: 32)
    }

    func importVaultKey(_ bytes: Data) throws -> CloudVaultKey {
        guard bytes.count == 32 else { throw CloudVaultCryptoError.invalidKey }
        return CloudVaultKey(material: SymmetricKey(data: bytes))
    }

    func createUserHeldVault(libraryPassword: String, aad: String) throws -> CloudVaultEnrollment {
        try validatePassword(libraryPassword)
        let key = try generateVaultKey()
        return CloudVaultEnrollment(key: key, recovery: try wrapVaultKey(key, libraryPassword: libraryPassword, aad: aad))
    }

    func seal(_ plaintext: Data, using key: CloudVaultKey, aad: String) throws -> Data {
        try Task.checkCancellation()
        guard plaintext.count <= Self.maximumPlaintextBytes else { throw CloudVaultCryptoError.oversizedPlaintext }
        let context = try aadBytes(aad)
        let nonce = try AES.GCM.Nonce(data: randomBytes(count: 12))
        let box = try AES.GCM.seal(plaintext, using: key.material, nonce: nonce, authenticating: context)
        guard let combined = box.combined else { throw CloudVaultCryptoError.invalidCiphertext }
        try Task.checkCancellation()
        return combined
    }

    func open(_ combined: Data, using key: CloudVaultKey, aad: String) throws -> Data {
        try Task.checkCancellation()
        guard (28...(Self.maximumPlaintextBytes + 28)).contains(combined.count) else {
            throw CloudVaultCryptoError.invalidCiphertext
        }
        let context = try aadBytes(aad)
        let box = try AES.GCM.SealedBox(combined: combined)
        do {
            let plaintext = try AES.GCM.open(box, using: key.material, authenticating: context)
            try Task.checkCancellation()
            return plaintext
        } catch CryptoKitError.authenticationFailure {
            throw CloudVaultCryptoError.authenticationFailed
        }
    }

    func wrapVaultKey(_ key: CloudVaultKey, libraryPassword: String, aad: String) throws -> CloudVaultRecoveryWrapper {
        let salt = try randomBytes(count: 16)
        let wrappingKey = try deriveRecoveryWrappingKey(libraryPassword: libraryPassword, salt: salt)
        return CloudVaultRecoveryWrapper(salt: salt, combined: try wrappedBytes(key, wrappingKey: wrappingKey, aad: aad))
    }

    func unlockVaultKey(libraryPassword: String, recovery: CloudVaultRecoveryWrapper, aad: String) throws -> CloudVaultKey {
        guard recovery.combined.count == 60 else { throw CloudVaultCryptoError.invalidWrapper }
        let wrappingKey = try deriveRecoveryWrappingKey(libraryPassword: libraryPassword, salt: recovery.salt)
        return try unwrappedKey(recovery.combined, wrappingKey: wrappingKey, aad: aad)
    }

    @available(iOS 18.0, *)
    func derivePasskeyWrappingKey(prfOutput: SymmetricKey, hkdfSalt: Data, info: Data) throws -> SymmetricKey {
        try Task.checkCancellation()
        guard prfOutput.bitCount == 256, hkdfSalt.count == 32 else { throw CloudVaultCryptoError.invalidPRFKey }
        try validateInfo(info)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: prfOutput, salt: hkdfSalt, info: info, outputByteCount: 32)
    }

    // The caller must supply a fresh, credential-checked PRF assertion; its output is never cached.
    @available(iOS 18.0, *)
    func wrapVaultKeyWithPRF(_ key: CloudVaultKey, prfOutput: SymmetricKey, info: Data, aad: String) throws -> CloudVaultPasskeyWrapper {
        let salt = try randomBytes(count: 32)
        let wrappingKey = try derivePasskeyWrappingKey(prfOutput: prfOutput, hkdfSalt: salt, info: info)
        return CloudVaultPasskeyWrapper(hkdfSalt: salt, combined: try wrappedBytes(key, wrappingKey: wrappingKey, aad: aad))
    }

    @available(iOS 18.0, *)
    func unlockVaultKeyWithPRF(_ wrapper: CloudVaultPasskeyWrapper, prfOutput: SymmetricKey, info: Data, aad: String) throws -> CloudVaultKey {
        guard wrapper.combined.count == 60 else { throw CloudVaultCryptoError.invalidWrapper }
        let wrappingKey = try derivePasskeyWrappingKey(prfOutput: prfOutput, hkdfSalt: wrapper.hkdfSalt, info: info)
        return try unwrappedKey(wrapper.combined, wrappingKey: wrappingKey, aad: aad)
    }

    // Vault-key possession proofs are separate from account authentication and passkey credentials.
    func controlPublicKey(using key: CloudVaultKey, info: Data) throws -> Data {
        try controlSigner(key, info: info).publicKey.rawRepresentation
    }

    func signControl(_ message: Data, using key: CloudVaultKey, info: Data) throws -> Data {
        try validateInfo(message)
        return try controlSigner(key, info: info).signature(for: message)
    }

    func verifyControl(_ signature: Data, message: Data, publicKey: Data) throws {
        try Task.checkCancellation()
        try validateInfo(message)
        guard signature.count == 64, publicKey.count == 32 else { throw CloudVaultCryptoError.invalidSignature }
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard verifier.isValidSignature(signature, for: message) else { throw CloudVaultCryptoError.authenticationFailed }
    }

    func generateAdoptionKey() throws -> CloudVaultAdoptionKey {
        try Task.checkCancellation()
        let key = P256.KeyAgreement.PrivateKey()
        return CloudVaultAdoptionKey(material: key, publicKeyX963: key.publicKey.x963Representation)
    }

    func sealAdoption(_ plaintext: Data, recipientPublicKeyX963: Data, info: Data, aad: String) throws -> CloudVaultHPKEMessage {
        try Task.checkCancellation()
        guard plaintext.count <= Self.maximumPlaintextBytes else { throw CloudVaultCryptoError.oversizedPlaintext }
        try validatePublicKey(recipientPublicKeyX963)
        try validateInfo(info)
        let context = try aadBytes(aad)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKeyX963)
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info)
        let ciphertext = try sender.seal(plaintext, authenticating: context)
        try Task.checkCancellation()
        return CloudVaultHPKEMessage(encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
    }

    func openAdoption(_ message: CloudVaultHPKEMessage, recipient: CloudVaultAdoptionKey, info: Data, aad: String) throws -> Data {
        try Task.checkCancellation()
        try validatePublicKey(message.encapsulatedKey)
        guard (16...(Self.maximumPlaintextBytes + 16)).contains(message.ciphertext.count) else {
            throw CloudVaultCryptoError.invalidCiphertext
        }

        try validateInfo(info)
        let context = try aadBytes(aad)
        var receiver = try HPKE.Recipient(privateKey: recipient.material, ciphersuite: .P256_SHA256_AES_GCM_256,
            info: info, encapsulatedKey: message.encapsulatedKey)
        do {
            let plaintext = try receiver.open(message.ciphertext, authenticating: context)
            try Task.checkCancellation()
            return plaintext
        } catch CryptoKitError.authenticationFailure {
            throw CloudVaultCryptoError.authenticationFailed
        }
    }

    func sealVaultKeyForAdoption(_ key: CloudVaultKey, recipientPublicKeyX963: Data, info: Data, aad: String) throws -> CloudVaultHPKEMessage {
        var bytes = key.material.withUnsafeBytes { Data($0) }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try sealAdoption(bytes, recipientPublicKeyX963: recipientPublicKeyX963, info: info, aad: aad)
    }

    func openVaultKeyFromAdoption(_ message: CloudVaultHPKEMessage, recipient: CloudVaultAdoptionKey,
        info: Data, aad: String, expectedControlPublicKey: Data, controlInfo: Data) throws -> CloudVaultKey {
        var bytes = try openAdoption(message, recipient: recipient, info: info, aad: aad)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let key = try importVaultKey(bytes)
        guard expectedControlPublicKey.count == 32, try controlPublicKey(using: key, info: controlInfo) == expectedControlPublicKey else {
            throw CloudVaultCryptoError.authenticationFailed
        }
        return key
    }

    @available(iOS 18.0, *)
    func supportsPasskeyPRF(credentialID: Data, provider: any CloudVaultPasskeyPRFProvider) async throws -> Bool {
        guard (1...1024).contains(credentialID.count) else { throw CloudVaultCryptoError.invalidCredential }
        try Task.checkCancellation()
        let capability = try await provider.capability(for: credentialID)
        try Task.checkCancellation()
        guard capability.credentialID == credentialID else { throw CloudVaultCryptoError.credentialMismatch }
        return capability.isSupported
    }

    private func aadBytes(_ aad: String) throws -> Data {
        guard !aad.isEmpty else { throw CloudVaultCryptoError.invalidContext }
        guard aad.utf8.count <= Self.maximumContextBytes else { throw CloudVaultCryptoError.oversizedContext }
        return Data(aad.utf8)
    }

    private func validateInfo(_ info: Data) throws {
        guard !info.isEmpty else { throw CloudVaultCryptoError.invalidContext }
        guard info.count <= Self.maximumContextBytes else { throw CloudVaultCryptoError.oversizedContext }
    }

    private func wrappedBytes(_ key: CloudVaultKey, wrappingKey: SymmetricKey, aad: String) throws -> Data {
        var bytes = key.material.withUnsafeBytes { Data($0) }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let combined = try seal(bytes, using: CloudVaultKey(material: wrappingKey), aad: aad)
        guard combined.count == 60 else { throw CloudVaultCryptoError.invalidWrapper }
        return combined
    }

    private func unwrappedKey(_ combined: Data, wrappingKey: SymmetricKey, aad: String) throws -> CloudVaultKey {
        var bytes = try open(combined, using: CloudVaultKey(material: wrappingKey), aad: aad)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try importVaultKey(bytes)
    }

    private func controlSigner(_ key: CloudVaultKey, info: Data) throws -> Curve25519.Signing.PrivateKey {
        try Task.checkCancellation()
        try validateInfo(info)
        let seed = HKDF<SHA256>.deriveKey(inputKeyMaterial: key.material, salt: Data(repeating: 0, count: 32),
            info: info, outputByteCount: 32)
        var bytes = seed.withUnsafeBytes { Data($0) }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    }

    private func validatePassword(_ password: String) throws {
        let count = password.precomposedStringWithCanonicalMapping.utf8.count
        guard (1...Self.maximumPasswordBytes).contains(count) else { throw CloudVaultCryptoError.invalidPassword }
    }

    func deriveRecoveryWrappingKey(libraryPassword: String, salt: Data) throws -> SymmetricKey {
        try Task.checkCancellation()
        try validatePassword(libraryPassword)
        guard salt.count == 16 else { throw CloudVaultCryptoError.invalidSalt }
        var password = Array(libraryPassword.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer {
            _ = password.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), passwordBytes.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(Self.pbkdf2Iterations),
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw CloudVaultCryptoError.derivationFailed(status) }
        try Task.checkCancellation()
        return SymmetricKey(data: derived)
    }

    private func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard status == errSecSuccess else { throw CloudVaultCryptoError.randomFailed(status) }
        return bytes
    }

    private func validatePublicKey(_ bytes: Data) throws {
        guard bytes.count == 65, bytes.first == 4 else { throw CloudVaultCryptoError.invalidPublicKey }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: bytes)
    }
}

struct CloudVaultCacheScope: Equatable, Sendable {
    let origin: CommunityOrigin
    let accountID: UUID
    let vaultKeyID: String

    init(origin: String, accountID: UUID, vaultKeyID: String) throws {
        self.origin = try CommunityOrigin.parse(origin)
        guard (1...256).contains(vaultKeyID.utf8.count) else { throw CloudVaultCryptoError.invalidScope }
        self.accountID = accountID
        self.vaultKeyID = vaultKeyID
    }

    fileprivate func keychainAccount() throws -> String {
        let metadata = [origin.url.absoluteString, accountID.uuidString.lowercased(), vaultKeyID]
        return SHA256.hash(data: try JSONEncoder().encode(metadata)).map { String(format: "%02x", $0) }.joined()
    }
}

actor CloudVaultKeychain {
    private let service: String

    init(service: String = "LEDBackpack.cloudVault.cache.v1") throws {
        guard (1...256).contains(service.utf8.count) else { throw CloudVaultCryptoError.invalidScope }
        self.service = service
    }

    func store(_ key: CloudVaultKey, scope: CloudVaultCacheScope) throws {
        try Task.checkCancellation()
        let query = try query(scope)
        var data = key.material.withUnsafeBytes { Data($0) }
        defer { data.resetBytes(in: 0..<data.count) }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (name, value) in attributes { item[name] = value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainFailed(status) }
    }

    func load(scope: CloudVaultCacheScope) throws -> CloudVaultKey? {
        try Task.checkCancellation()
        var query = try query(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudVaultCryptoError.keychainFailed(status) }
        guard let bytes = result as? Data, bytes.count == 32 else { throw CloudVaultCryptoError.invalidKey }
        return CloudVaultKey(material: SymmetricKey(data: bytes))
    }

    func remove(scope: CloudVaultCacheScope) throws {
        try Task.checkCancellation()
        let status = SecItemDelete(try query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudVaultCryptoError.keychainFailed(status)
        }
    }

    private func query(_ scope: CloudVaultCacheScope) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: try scope.keychainAccount(),
            kSecAttrSynchronizable as String: false]
    }
}
