import XCTest
import CryptoKit
import Security
@testable import LEDBackpack

@available(iOS 18.0, *)
private struct VaultPRFProvider: CloudVaultPasskeyPRFProvider {
    let response: CloudVaultPRFCapability
    func capability(for credentialID: Data) async throws -> CloudVaultPRFCapability { response }
}

final class CloudVaultCryptoTests: XCTestCase {
    private let userID = "11111111-1111-4111-8111-111111111111"
    private let keyID = "22222222-2222-4222-8222-222222222222"
    private let itemID = "33333333-3333-4333-8333-333333333333"
    private let fixturePassword = "PUBLIC-FIXTURE cafe\u{301}, preserve spaces "
    private var recoveryAAD: String { ["catalog-cloud-wrap-v1", userID, keyID, "password", ""].joined(separator: "\n") }
    private var assetAAD: String { ["catalog-cloud-asset-v1", userID, "7", keyID, itemID, "2", "data"].joined(separator: "\n") }
    private var passkeyAAD: String { ["catalog-cloud-wrap-v1", userID, keyID, "passkey", "PUBLIC_CREDENTIAL_A"].joined(separator: "\n") }
    private var passkeyInfo: Data { Data(("catalog-cloud-prf-kek-v1\n" + passkeyAAD).utf8) }
    private var controlInfo: Data { Data(["catalog-cloud-control-v1", userID, keyID].joined(separator: "\n").utf8) }

    private func hex(_ text: String) throws -> Data {
        guard text.count.isMultiple(of: 2) else { throw CloudVaultCryptoError.invalidCiphertext }
        var result = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else { throw CloudVaultCryptoError.invalidCiphertext }
            result.append(byte); index = end
        }
        return result
    }

    // Exact public cloud-crypto-v1.json backend vectors; no real user material.
    private func recoveryFixture() throws -> CloudVaultRecoveryWrapper {
        CloudVaultRecoveryWrapper(salt: try hex("101112131415161718191a1b1c1d1e1f"),
            combined: try hex("090909090909090909090909554764c6280220fb855951ffcca7988bd6eea6c5b684d7d813536166b3b25aa78d1b94bc23ae2e29a5787c314e2e158a"))
    }

    private func assetFixture() throws -> Data {
        try hex("000102030405060708090a0b175794578ca6e252c315d2d9feb93d3fc294ce78b92f065c7e2ebdd1483b459e215ee1a88f9441dd26843bacdcc671b02bab32f6772d59ba2602c575b29d")
    }

    private func expectFailure(_ expected: CloudVaultCryptoError? = nil,
        file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected an explicit crypto failure.", file: file, line: line)
        } catch {
            if let expected { XCTAssertEqual(error as? CloudVaultCryptoError, expected, file: file, line: line) }
        }
    }

    func testIndependentAES256GCMFixtureAndCombinedLayout() async throws {
        let crypto = CloudVaultCrypto()
        let key = try await crypto.importVaultKey(Data((0..<32).map(UInt8.init)))
        let fixture = try assetFixture()
        let plaintext = try await crypto.open(fixture, using: key, aad: assetAAD)
        XCTAssertEqual(plaintext, Data("PUBLIC INTEROPERABILITY FIXTURE, NOT USER DATA".utf8))
        let message = Data([0, 1, 2, 0, 255])
        let first = try await crypto.seal(message, using: key, aad: assetAAD)
        let second = try await crypto.seal(message, using: key, aad: assetAAD)
        XCTAssertEqual(first.count, 12 + message.count + 16)
        XCTAssertNotEqual(first.prefix(12), second.prefix(12))
        let opened = try await crypto.open(first, using: key, aad: assetAAD)
        XCTAssertEqual(opened, message)
        let empty = try await crypto.seal(Data(), using: key, aad: assetAAD)
        let openedEmpty = try await crypto.open(empty, using: key, aad: assetAAD)
        XCTAssertTrue(openedEmpty.isEmpty)
    }

    func testPBKDF2FixtureUsesNFCWithoutTrimmingOrAccountPassword() async throws {
        let crypto = CloudVaultCrypto()
        let fixture = try recoveryFixture()
        XCTAssertEqual(fixture.combined.count, 60)
        let derived = try await crypto.deriveRecoveryWrappingKey(libraryPassword: fixturePassword, salt: fixture.salt)
        XCTAssertEqual(derived.withUnsafeBytes { Data($0) },
            try hex("6085c2a2afed5e5e48693bcac15dd4cd9b01a2dfac126c1d9e8a92aca0c19e96"))
        let decomposed = try await crypto.unlockVaultKey(libraryPassword: fixturePassword, recovery: fixture, aad: recoveryAAD)
        let composed = try await crypto.unlockVaultKey(libraryPassword: "PUBLIC-FIXTURE caf\u{e9}, preserve spaces ", recovery: fixture, aad: recoveryAAD)
        let ciphertext = try assetFixture()
        let first = try await crypto.open(ciphertext, using: decomposed, aad: assetAAD)
        let second = try await crypto.open(ciphertext, using: composed, aad: assetAAD)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, Data("PUBLIC INTEROPERABILITY FIXTURE, NOT USER DATA".utf8))
        XCTAssertTrue(recoveryAAD.hasSuffix("\n"))
        XCTAssertFalse(assetAAD.hasSuffix("\n"))
        await expectFailure(.authenticationFailed) {
            _ = try await crypto.unlockVaultKey(libraryPassword: "PUBLIC-FIXTURE caf\u{e9}, preserve spaces", recovery: fixture, aad: self.recoveryAAD)
        }
        await expectFailure(.authenticationFailed) {
            _ = try await crypto.unlockVaultKey(libraryPassword: self.fixturePassword, recovery: fixture, aad: String(self.recoveryAAD.dropLast()))
        }
        await expectFailure(.authenticationFailed) {
            _ = try await crypto.unlockVaultKey(libraryPassword: self.fixturePassword, recovery: fixture, aad: "wrong-context")
        }
    }

    @MainActor
    func testPasswordOnlyEnrollmentCallsSeparateCryptoActor() async throws {
        let crypto = CloudVaultCrypto()
        let enrolled = try await crypto.createUserHeldVault(libraryPassword: "separate recovery password", aad: recoveryAAD)
        let other = try await crypto.createUserHeldVault(libraryPassword: "separate recovery password", aad: recoveryAAD)
        XCTAssertEqual(enrolled.recovery.salt.count, 16)
        XCTAssertEqual(enrolled.recovery.combined.count, 60)
        XCTAssertNotEqual(enrolled.recovery.salt, other.recovery.salt)
        let recovered = try await crypto.unlockVaultKey(libraryPassword: "separate recovery password", recovery: enrolled.recovery, aad: recoveryAAD)
        let message = Data("password unlock needs no passkey".utf8)
        let encrypted = try await crypto.seal(message, using: enrolled.key, aad: assetAAD)
        let opened = try await crypto.open(encrypted, using: recovered, aad: assetAAD)
        XCTAssertEqual(opened, message)
        await expectFailure(.authenticationFailed) { _ = try await crypto.open(encrypted, using: other.key, aad: self.assetAAD) }
        await expectFailure(.invalidPassword) {
            _ = try await crypto.createUserHeldVault(libraryPassword: "", aad: self.recoveryAAD)
        }
    }

    func testAESAuthenticationFailuresNeverReturnPlaintext() async throws {
        let crypto = CloudVaultCrypto()
        let key = try await crypto.importVaultKey(Data((0..<32).map(UInt8.init)))
        let wrongKey = try await crypto.generateVaultKey()
        let fixture = try assetFixture()
        await expectFailure(.authenticationFailed) { _ = try await crypto.open(fixture, using: key, aad: "different") }
        await expectFailure(.authenticationFailed) { _ = try await crypto.open(fixture, using: wrongKey, aad: self.assetAAD) }
        for offset in [0, 12, fixture.count - 1] {
            var changed = fixture
            changed[offset] ^= 1
            await expectFailure(.authenticationFailed) { _ = try await crypto.open(changed, using: key, aad: self.assetAAD) }
        }
    }

    func testPrimitiveLengthsAndSafetyBudgets() async throws {
        let crypto = CloudVaultCrypto()
        for size in [0, 31, 33] {
            await expectFailure(.invalidKey) { _ = try await crypto.importVaultKey(Data(repeating: 0, count: size)) }
        }
        let key = try await crypto.generateVaultKey()
        await expectFailure(.invalidCiphertext) { _ = try await crypto.open(Data(repeating: 0, count: 27), using: key, aad: self.assetAAD) }
        await expectFailure(.invalidCiphertext) {
            _ = try await crypto.open(Data(repeating: 0, count: CloudVaultCrypto.maximumPlaintextBytes + 29), using: key, aad: self.assetAAD)
        }
        await expectFailure(.oversizedPlaintext) {
            _ = try await crypto.seal(Data(repeating: 0, count: CloudVaultCrypto.maximumPlaintextBytes + 1), using: key, aad: self.assetAAD)
        }
        await expectFailure(.oversizedContext) {
            _ = try await crypto.seal(Data(), using: key, aad: String(repeating: "a", count: CloudVaultCrypto.maximumContextBytes + 1))
        }
        let boundary = String(repeating: "a", count: CloudVaultCrypto.maximumContextBytes)
        let encrypted = try await crypto.seal(Data(), using: key, aad: boundary)
        XCTAssertEqual(encrypted.count, 28)
        await expectFailure(.invalidPassword) {
            _ = try await crypto.wrapVaultKey(key, libraryPassword: String(repeating: "a", count: 1025), aad: self.recoveryAAD)
        }
        await expectFailure(.invalidContext) { _ = try await crypto.seal(Data(), using: key, aad: "") }
        let fixture = try recoveryFixture()
        await expectFailure(.invalidSalt) {
            _ = try await crypto.unlockVaultKey(libraryPassword: self.fixturePassword,
                recovery: CloudVaultRecoveryWrapper(salt: Data(repeating: 0, count: 15), combined: fixture.combined), aad: self.recoveryAAD)
        }
        await expectFailure(.invalidWrapper) {
            _ = try await crypto.unlockVaultKey(libraryPassword: self.fixturePassword,
                recovery: CloudVaultRecoveryWrapper(salt: fixture.salt, combined: fixture.combined.dropLast()), aad: self.recoveryAAD)
        }
    }

    func testHPKEP256BaseModeSeparatesEncapsulatedKeyAndCiphertext() async throws {
        let crypto = CloudVaultCrypto()
        let recipient = try await crypto.generateAdoptionKey()
        let another = try await crypto.generateAdoptionKey()
        XCTAssertEqual(recipient.publicKeyX963.count, 65)
        XCTAssertEqual(recipient.publicKeyX963.first, 4)
        let info = Data("catalog-cloud-adopt-v1".utf8)
        let adoptionAAD = ["catalog-cloud-adopt-v1", userID, "44444444-4444-4444-8444-444444444444", "7", keyID].joined(separator: "\n")
        let plaintext = Data((0..<32).map(UInt8.init))
        let message = try await crypto.sealAdoption(plaintext, recipientPublicKeyX963: recipient.publicKeyX963, info: info, aad: adoptionAAD)
        XCTAssertEqual(message.encapsulatedKey.count, 65)
        XCTAssertEqual(message.ciphertext.count, plaintext.count + 16)
        let opened = try await crypto.openAdoption(message, recipient: recipient, info: info, aad: adoptionAAD)
        XCTAssertEqual(opened, plaintext)
        await expectFailure { _ = try await crypto.openAdoption(message, recipient: another, info: info, aad: adoptionAAD) }
        await expectFailure { _ = try await crypto.openAdoption(message, recipient: recipient, info: Data("different".utf8), aad: adoptionAAD) }
        await expectFailure { _ = try await crypto.openAdoption(message, recipient: recipient, info: info, aad: "different") }
        var tampered = message.ciphertext; tampered[tampered.count - 1] ^= 1
        await expectFailure {
            _ = try await crypto.openAdoption(CloudVaultHPKEMessage(encapsulatedKey: message.encapsulatedKey, ciphertext: tampered),
                recipient: recipient, info: info, aad: adoptionAAD)
        }
        await expectFailure(.invalidPublicKey) {
            _ = try await crypto.sealAdoption(plaintext, recipientPublicKeyX963: Data(repeating: 0, count: 64), info: info, aad: "")
        }
        await expectFailure(.oversizedContext) {
            _ = try await crypto.sealAdoption(plaintext, recipientPublicKeyX963: recipient.publicKeyX963,
                info: Data(repeating: 0, count: CloudVaultCrypto.maximumContextBytes + 1), aad: "")
        }
        await expectFailure(.invalidCiphertext) {
            _ = try await crypto.openAdoption(CloudVaultHPKEMessage(encapsulatedKey: message.encapsulatedKey, ciphertext: Data(repeating: 0, count: 15)),
                recipient: recipient, info: info, aad: "")
        }
    }

    func testPasskeyHKDFMatchesBackendFixtureAndUnlocksSameVaultKey() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("PRF unlock is optional and requires iOS 18; password unlock covers iOS 17.") }
        let crypto = CloudVaultCrypto()
        let prf = SymmetricKey(data: try hex("0606060606060606060606060606060606060606060606060606060606060606"))
        let salt = try hex("0808080808080808080808080808080808080808080808080808080808080808")
        let derived = try await crypto.derivePasskeyWrappingKey(prfOutput: prf, hkdfSalt: salt, info: passkeyInfo)
        XCTAssertEqual(derived.withUnsafeBytes { Data($0) },
            try hex("913cc37f751a9c1d99309876ae92f895d854748cb569d4687f15826b0d880800"))
        let original = try await crypto.importVaultKey(Data((0..<32).map(UInt8.init)))
        let wrapped = try await crypto.wrapVaultKeyWithPRF(original, prfOutput: prf, info: passkeyInfo, aad: passkeyAAD)
        XCTAssertEqual(wrapped.hkdfSalt.count, 32)
        XCTAssertEqual(wrapped.combined.count, 60)
        let recovered = try await crypto.unlockVaultKeyWithPRF(wrapped, prfOutput: prf, info: passkeyInfo, aad: passkeyAAD)
        let ciphertext = try assetFixture()
        let opened = try await crypto.open(ciphertext, using: recovered, aad: assetAAD)
        XCTAssertEqual(opened, Data("PUBLIC INTEROPERABILITY FIXTURE, NOT USER DATA".utf8))
        // Supplemental public Node/OpenSSL fixture uses the backend PRF/info bytes and nonce 07*12.
        let fixed = CloudVaultPasskeyWrapper(hkdfSalt: salt,
            combined: try hex("0707070707070707070707077b81f62e398cd467c20948f1a96b8dd72d0495c39420e324d5b0c8d11c662d57150174ba83a6269ce51e88e1da9f43ef"))
        let fixedKey = try await crypto.unlockVaultKeyWithPRF(fixed, prfOutput: prf, info: passkeyInfo, aad: passkeyAAD)
        let fixedPlaintext = try await crypto.open(ciphertext, using: fixedKey, aad: assetAAD)
        XCTAssertEqual(fixedPlaintext, opened)
        await expectFailure(.invalidPRFKey) {
            _ = try await crypto.derivePasskeyWrappingKey(prfOutput: SymmetricKey(data: Data(repeating: 0, count: 31)),
                hkdfSalt: salt, info: self.passkeyInfo)
        }
        await expectFailure(.invalidPRFKey) {
            _ = try await crypto.derivePasskeyWrappingKey(prfOutput: prf, hkdfSalt: Data(repeating: 0, count: 31), info: self.passkeyInfo)
        }
        await expectFailure(.authenticationFailed) {
            _ = try await crypto.unlockVaultKeyWithPRF(fixed, prfOutput: prf, info: self.passkeyInfo, aad: self.passkeyAAD + "\n")
        }
    }

    func testTypedAdoptionKeepsVaultKeyOpaqueAndChecksDerivedControlKey() async throws {
        let crypto = CloudVaultCrypto()
        let original = try await crypto.importVaultKey(Data((0..<32).map(UInt8.init)))
        let recipient = try await crypto.generateAdoptionKey()
        let publicKey = try await crypto.controlPublicKey(using: original, info: controlInfo)
        let info = Data("catalog-cloud-adopt-v1".utf8), aad = "public-test-adoption-context"
        let box = try await crypto.sealVaultKeyForAdoption(original, recipientPublicKeyX963: recipient.publicKeyX963, info: info, aad: aad)
        XCTAssertEqual(box.encapsulatedKey.count, 65); XCTAssertEqual(box.ciphertext.count, 48)
        let restored = try await crypto.openVaultKeyFromAdoption(box, recipient: recipient, info: info, aad: aad,
            expectedControlPublicKey: publicKey, controlInfo: controlInfo)
        let plain = try await crypto.open(assetFixture(), using: restored, aad: assetAAD)
        XCTAssertEqual(plain, Data("PUBLIC INTEROPERABILITY FIXTURE, NOT USER DATA".utf8))
        await expectFailure(.authenticationFailed) {
            _ = try await crypto.openVaultKeyFromAdoption(box, recipient: recipient, info: info, aad: aad,
                expectedControlPublicKey: Data(repeating: 0, count: 32), controlInfo: self.controlInfo)
        }
    }

    func testControlPossessionPublicKeyAndSignatureMatchIndependentVectors() async throws {
        let crypto = CloudVaultCrypto()
        let key = try await crypto.importVaultKey(Data((0..<32).map(UInt8.init)))
        let publicKey = try await crypto.controlPublicKey(using: key, info: controlInfo)
        XCTAssertEqual(publicKey, try hex("de6513036f10b212755fa97dbf39e73003d5aaf8bd219ea359178fa6790e3b1d"))
        let fixtureSigner = try Curve25519.Signing.PrivateKey(rawRepresentation:
            hex("6d9886d9be538966ef6d681084dc83d24004e17970844def6bb96cf54b11eb65"))
        XCTAssertEqual(fixtureSigner.publicKey.rawRepresentation, publicKey)
        let message = Data("PUBLIC CONTROL-PROOF FIXTURE".utf8)
        let signature = try await crypto.signControl(message, using: key, info: controlInfo)
        XCTAssertEqual(signature.count, 64)
        XCTAssertEqual(signature, try hex("425ca8f770d61b80aabab4e7b2776a9b49c4de0ad380c1d314525f38467af44b1dc0224145b3f1467383e1761a6033b6937b5eba9fdf9b33f9cdf9a336a3d80b"))
        try await crypto.verifyControl(signature, message: message, publicKey: publicKey)
        await expectFailure(.authenticationFailed) {
            _ = try await crypto.verifyControl(signature, message: Data("different".utf8), publicKey: publicKey)
        }
        let otherPublic = try await crypto.controlPublicKey(using: key, info: Data("different-control-context".utf8))
        await expectFailure(.authenticationFailed) { try await crypto.verifyControl(signature, message: message, publicKey: otherPublic) }
        await expectFailure(.invalidSignature) { try await crypto.verifyControl(Data(signature.dropLast()), message: message, publicKey: publicKey) }
    }

    func testPRFHooksRequireCredentialBoundProviderSupport() async throws {
        let crypto = CloudVaultCrypto()
        if #available(iOS 18.0, *) {
            XCTAssertTrue(CloudVaultCrypto.passkeyPRFPlatformAvailable)
            let id = Data([1, 2, 3])
            let supported = VaultPRFProvider(response: CloudVaultPRFCapability(credentialID: id, isSupported: true))
            let unsupported = VaultPRFProvider(response: CloudVaultPRFCapability(credentialID: id, isSupported: false))
            let wrong = VaultPRFProvider(response: CloudVaultPRFCapability(credentialID: Data([4]), isSupported: true))
            let yes = try await crypto.supportsPasskeyPRF(credentialID: id, provider: supported)
            let no = try await crypto.supportsPasskeyPRF(credentialID: id, provider: unsupported)
            XCTAssertTrue(yes); XCTAssertFalse(no)
            await expectFailure(.credentialMismatch) { _ = try await crypto.supportsPasskeyPRF(credentialID: id, provider: wrong) }
            await expectFailure(.invalidCredential) { _ = try await crypto.supportsPasskeyPRF(credentialID: Data(), provider: supported) }
        } else {
            XCTAssertFalse(CloudVaultCrypto.passkeyPRFPlatformAvailable)
        }
    }

    func testKeychainCacheIsDeviceOnlyAndIsolatedByOriginAccountAndVaultKey() async throws {
        let crypto = CloudVaultCrypto()
        let account = UUID(), otherAccount = UUID()
        let scope = try CloudVaultCacheScope(origin: "https://CATALOG.example:443/", accountID: account, vaultKeyID: "key-one")
        let same = try CloudVaultCacheScope(origin: "https://catalog.example", accountID: account, vaultKeyID: "key-one")
        let otherUser = try CloudVaultCacheScope(origin: "https://catalog.example", accountID: otherAccount, vaultKeyID: "key-one")
        let otherServer = try CloudVaultCacheScope(origin: "https://other.example", accountID: account, vaultKeyID: "key-one")
        let otherKey = try CloudVaultCacheScope(origin: "https://catalog.example", accountID: account, vaultKeyID: "key-two")
        XCTAssertEqual(scope, same)
        XCTAssertThrowsError(try CloudVaultCacheScope(origin: "http://catalog.example", accountID: account, vaultKeyID: "key-one"))
        XCTAssertThrowsError(try CloudVaultCacheScope(origin: "https://catalog.example", accountID: account, vaultKeyID: ""))
        let service = "LEDBackpack.cloudVault.tests.\(UUID().uuidString)"
        let cache = try CloudVaultKeychain(service: service)
        let scopes = [scope, otherUser, otherServer, otherKey]
        do {
            let key = try await crypto.generateVaultKey()
            try await cache.store(key, scope: scope)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecReturnAttributes as String: true]
            var attributes: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &attributes), errSecSuccess)
            XCTAssertEqual((attributes as? [String: Any])?[kSecAttrAccessible as String] as? String,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            let loaded = try await cache.load(scope: same)
            let restored = try XCTUnwrap(loaded)
            let bytes = Data("scoped key cache".utf8)
            let message = try await crypto.seal(bytes, using: key, aad: assetAAD)
            let opened = try await crypto.open(message, using: restored, aad: assetAAD)
            XCTAssertEqual(opened, bytes)
            let replacement = try await crypto.generateVaultKey()
            try await cache.store(replacement, scope: scope)
            let updated = try await cache.load(scope: scope)
            let updatedKey = try XCTUnwrap(updated)
            let updatedMessage = try await crypto.seal(bytes, using: replacement, aad: assetAAD)
            let updatedPlaintext = try await crypto.open(updatedMessage, using: updatedKey, aad: assetAAD)
            XCTAssertEqual(updatedPlaintext, bytes)
            for other in [otherUser, otherServer, otherKey] {
                let missing = try await cache.load(scope: other)
                XCTAssertNil(missing)
            }
            try await cache.store(key, scope: otherUser)
            try await cache.remove(scope: scope)
            let removed = try await cache.load(scope: scope)
            let retained = try await cache.load(scope: otherUser)
            XCTAssertNil(removed); XCTAssertNotNil(retained)
            for value in scopes { try await cache.remove(scope: value) }
        } catch {
            let original = error
            for value in scopes {
                do { try await cache.remove(scope: value) }
                catch { XCTFail("Isolated vault test Keychain cleanup failed.") }
            }
            throw original
        }
    }
}
