import Foundation
import CryptoKit
import DeviceCheck
import BackpackProtocol

struct NativeIntegrityChallenge: Decodable {
    let `protocol`, id, nonce, message, expiresAt, origin, purpose, keyId, sessionHash, scopeHash, method, path, bodyHash: String
    let userId: UUID?
    let lifetimeSeconds: Int
}
enum NativeIntegrityBinding {
    static func lifetime(method: String, path: String) -> Int {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if method == "POST" && (["/api/v1/items", "/api/v1/admin/imports", "/api/v1/social/avatar",
            "/api/v1/admin/artwork/upload"].contains(route) ||
            route.range(of: "^/api/v1/events/[a-fA-F0-9-]+/(assets|exclusive-gifs)$", options: .regularExpression) != nil) { return 360 }
        if method == "PUT" && route.range(of: "^/api/v1/cloud/(migrations/[a-fA-F0-9-]+/)?items/[a-fA-F0-9-]+$", options: .regularExpression) != nil { return 360 }
        return 120
    }
    static func digest(_ bytes: Data) -> String { base64URL(Data(SHA256.hash(data: bytes))) }
    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func canonicalDigest(_ value: String) -> Bool {
        guard value.count == 43, let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=") else { return false }
        return bytes.count == 32 && base64URL(bytes) == value
    }
    static func canonicalKey(_ value: String) -> Bool {
        guard value.count == 44, let bytes = Data(base64Encoded: value) else { return false }
        return bytes.count == 32 && bytes.base64EncodedString() == value
    }
    static func json(_ array: [Any]) throws -> Data { try JSONSerialization.data(withJSONObject: array, options: [.withoutEscapingSlashes]) }
    static func enrollmentHash(_ key: String) throws -> String {
        guard canonicalKey(key) else { throw BackpackError.invalid("App Attest returned a noncanonical key identifier.") }
        return digest(try json(["led-backpack.app-integrity.enroll.v1", key]))
    }
    static func validatedHash(_ value: NativeIntegrityChallenge, origin: CommunityOrigin, account: UUID?, token: String,
        key: String, purpose: String, method: String, path: String, bodyHash: String, now: Date = Date()) throws -> Data {
        let session = digest(Data(token.utf8))
        let user: Any
        if let account { user = account.uuidString.lowercased() } else { user = NSNull() }
        let scope = digest(try json([user, session]))
        let expires = try CatalogEventTime.parse(value.expiresAt)
        guard value.protocol == "app-attest-v1", value.origin == origin.url.absoluteString,
              UUID(uuidString: value.id) != nil, canonicalDigest(value.nonce), canonicalKey(key),
              value.keyId == key, value.purpose == purpose, value.userId == account, value.sessionHash == session,
              value.scopeHash == scope, value.method == method, value.path == path, value.bodyHash == bodyHash,
              canonicalDigest(bodyHash), value.lifetimeSeconds == (purpose == "enroll" ? 120 : lifetime(method: method, path: path)),
              expires > now, expires.timeIntervalSince(now) <= Double(value.lifetimeSeconds + 30) else {
            throw BackpackError.invalid("App Attest challenge does not match the captured account/origin/key/request or lifetime.")
        }
        let bytes = try json(["led-backpack.app-integrity.v1", value.origin, value.id, value.nonce, purpose, key,
            user, session, scope, method, path, bodyHash])
        guard Data(value.message.utf8) == bytes else { throw BackpackError.invalid("Refusing to sign arbitrary server challenge text.") }
        return Data(SHA256.hash(data: bytes))
    }
}
@MainActor
protocol NativeAttestProvider {
    var supported: Bool { get }
    func generateKey() async throws -> String
    func attest(_ key: String, hash: Data) async throws -> Data
    func assert(_ key: String, hash: Data) async throws -> Data
}
@MainActor
final class OfficialNativeAttest: NativeAttestProvider {
    var supported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String {
        guard supported else { throw BackpackError.invalid("Official App Attest is unavailable on this device; simulator proofs are not fabricated.") }
        return try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { key, error in
                if let error { continuation.resume(throwing: error) }
                else if let key { continuation.resume(returning: key) }
                else { continuation.resume(throwing: BackpackError.invalid("App Attest returned neither a key nor an error.")) }
            }
        }
    }
    func attest(_ key: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(key, clientDataHash: hash) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: BackpackError.invalid("App Attest returned no attestation.")) }
            }
        }
    }
    func assert(_ key: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateAssertion(key, clientDataHash: hash) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: BackpackError.invalid("App Attest returned no assertion.")) }
            }
        }
    }
}
@MainActor
final class NativeAppIntegrity {
    struct Key: Codable { let id: String; var enrolled: Bool; var uncertain: Bool }
    struct GuestSession: Codable { let token, expiresAt: String }
    private let provider: any NativeAttestProvider
    private let cache: any CommunityVault
    private var tail: Task<Void, Never>?
    var supported: Bool { provider.supported }
    init() { provider = OfficialNativeAttest(); cache = CommunityKeychain() }
    init(provider: any NativeAttestProvider, cache: any CommunityVault) { self.provider = provider; self.cache = cache }
    private func storage(_ origin: CommunityOrigin, _ account: UUID?, token: String = "") -> String {
        "app-attest|\(origin.url.absoluteString)|\(account?.uuidString.lowercased() ?? "guest|" + NativeIntegrityBinding.digest(Data(token.utf8)))"
    }
    private func guestStorage(_ origin: CommunityOrigin) -> String { "app-attest-guest|\(origin.url.absoluteString)" }
    func keyID(origin: CommunityOrigin, account: UUID) throws -> String? {
        guard let bytes = try cache.read(storage(origin, account)) else { return nil }
        return try JSONDecoder().decode(Key.self, from: bytes).id
    }
    func perform(_ request: URLRequest, origin: CommunityOrigin, account: UUID, token: String,
        transport: any CommunityTransport, maxBytes: Int, check: @escaping @MainActor () throws -> Void) async throws -> CommunityResponse {
        try await queue(check: check) {
            try await self.execute(request, origin: origin, account: account, token: token, transport: transport, maxBytes: maxBytes, check: check)
        }
    }
    func performGuest(_ original: URLRequest, origin: CommunityOrigin, transport: any CommunityTransport,
        maxBytes: Int, check: @escaping @MainActor () throws -> Void) async throws -> CommunityResponse {
        try await queue(check: check) {
            let session = try await self.guestSession(origin, transport: transport)
            try check()
            var request = original
            guard request.value(forHTTPHeaderField: "Authorization") == nil else { throw BackpackError.invalid("Guest integrity cannot carry authenticated credentials.") }
            request.setValue(session.token, forHTTPHeaderField: "X-Catalog-Integrity-Session")
            return try await self.execute(request, origin: origin, account: nil, token: session.token,
                transport: transport, maxBytes: maxBytes, check: check)
        }
    }
    func adoptGuestKey(origin: CommunityOrigin, account: UUID) throws {
        guard let data = try cache.read(guestStorage(origin)) else { return }
        let session = try JSONDecoder().decode(GuestSession.self, from: data)
        let source = storage(origin, nil, token: session.token)
        if let bytes = try cache.read(source) {
            let key = try JSONDecoder().decode(Key.self, from: bytes)
            guard key.enrolled, !key.uncertain else { throw BackpackError.invalid("An unconfirmed guest key cannot become account identity.") }
            if try cache.read(storage(origin, account)) == nil { try cache.save(bytes, key: storage(origin, account)) }
            try cache.remove(source)
        }
        try cache.remove(guestStorage(origin))
    }
    private func guestSession(_ origin: CommunityOrigin, transport: any CommunityTransport) async throws -> GuestSession {
        if let data = try cache.read(guestStorage(origin)) {
            let session = try JSONDecoder().decode(GuestSession.self, from: data)
            guard NativeIntegrityBinding.canonicalDigest(session.token) else { throw BackpackError.invalid("Stored guest integrity token is invalid; no scope fallback.") }
            if try CatalogEventTime.parse(session.expiresAt) > Date() { return session }
            try cache.remove(storage(origin, nil, token: session.token)); try cache.remove(guestStorage(origin))
        }
        var request = URLRequest(url: try origin.api("app-integrity/sessions"))
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.httpShouldHandleCookies = false
        request.setValue("1", forHTTPHeaderField: "X-Catalog-Client"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request, maxBytes: 4096)
        guard response.status == 200 else { throw CommunityFailure(status: response.status, code: "integrity_guest_unavailable", message: "Guest integrity bootstrap was not confirmed; no login fallback.") }
        struct Reply: Decodable { let `protocol`, token, expiresAt: String }
        let reply = try JSONDecoder().decode(Reply.self, from: response.data)
        let expiry = try CatalogEventTime.parse(reply.expiresAt)
        guard reply.protocol == "app-attest-v1", NativeIntegrityBinding.canonicalDigest(reply.token),
              expiry > Date(), expiry.timeIntervalSinceNow <= 86430 else { throw BackpackError.invalid("Invalid server guest integrity token/lifetime.") }
        let value = GuestSession(token: reply.token, expiresAt: reply.expiresAt)
        try cache.save(JSONEncoder().encode(value), key: guestStorage(origin)); return value
    }
    private func queue(check: @escaping @MainActor () throws -> Void,
        work: @escaping @MainActor () async throws -> CommunityResponse) async throws -> CommunityResponse {
        guard supported else { throw BackpackError.invalid("A real supported App Attest device is required; no simulator/header fallback.") }
        let previous = tail
        let job = Task {
            await previous?.value
            try Task.checkCancellation(); try check()
            return try await work()
        }
        tail = Task { _ = await job.result }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
    private func execute(_ original: URLRequest, origin: CommunityOrigin, account: UUID?, token: String,
        transport: any CommunityTransport, maxBytes: Int, check: @escaping @MainActor () throws -> Void) async throws -> CommunityResponse {
        guard let url = original.url, origin.contains(url), url.fragment == nil, original.httpBodyStream == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.percentEncodedPath.hasPrefix("/api/v1/"),
              !parts.percentEncodedPath.contains("\\"),
              !parts.percentEncodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !["%2e", "%2f", "%5c"].contains(where: { parts.percentEncodedPath.lowercased().contains($0) }),
              (account != nil ? original.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" &&
                original.value(forHTTPHeaderField: "X-Catalog-Integrity-Session") == nil :
                original.value(forHTTPHeaderField: "Authorization") == nil && original.value(forHTTPHeaderField: "X-Catalog-Integrity-Session") == token) else {
            throw BackpackError.invalid("Unsupported integrity request target/stream/token. No key or proof generated.")
        }
        let path = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        let method = original.httpMethod ?? "GET"
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method),
              method != "GET" || (original.httpBody ?? Data()).isEmpty else {
            throw BackpackError.invalid("Unsupported integrity HTTP method/body.")
        }
        let digest = NativeIntegrityBinding.digest(original.httpBody ?? Data())
        let slot = storage(origin, account, token: token)
        var key: Key
        if let bytes = try cache.read(slot) { key = try JSONDecoder().decode(Key.self, from: bytes) }
        else {
            key = Key(id: try await provider.generateKey(), enrolled: false, uncertain: false)
            try check()
            guard NativeIntegrityBinding.canonicalKey(key.id) else { throw BackpackError.invalid("Invalid official App Attest key.") }
            try cache.save(JSONEncoder().encode(key), key: slot)
        }
        guard !key.uncertain else { throw BackpackError.invalid("Attestation enrollment was not confirmed. Fresh-account key recovery is required; no replay/fallback.") }
        if !key.enrolled {
            try check()
            let projection = try NativeIntegrityBinding.enrollmentHash(key.id)
            let challenge = try await challenge(key: key.id, purpose: "enroll", method: "POST", path: "/api/v1/app-integrity/enroll",
                bodyHash: projection, origin: origin, token: token, transport: transport, guest: account == nil)
            try check()
            let hash = try NativeIntegrityBinding.validatedHash(challenge, origin: origin, account: account, token: token,
                key: key.id, purpose: "enroll", method: "POST", path: "/api/v1/app-integrity/enroll", bodyHash: projection)
            key.uncertain = true; try cache.save(JSONEncoder().encode(key), key: slot)
            let attestation = try await provider.attest(key.id, hash: hash)
            try check()
            guard !attestation.isEmpty, attestation.count <= 32768 else { throw BackpackError.invalid("Attestation exceeds the actual wire bound.") }
            let body = try JSONSerialization.data(withJSONObject: ["challengeId": challenge.id, "keyId": key.id,
                "attestation": NativeIntegrityBinding.base64URL(attestation)])
            struct Enrollment: Decodable { let `protocol`, keyId, environment: String; let enforcementReady: Bool }
            let reply = try JSONDecoder().decode(Enrollment.self, from: await bootstrap("enroll", body: body, origin: origin, token: token, transport: transport, guest: account == nil))
            guard reply.protocol == "app-attest-v1", reply.keyId == key.id, reply.environment == "production", !reply.enforcementReady else {
                throw BackpackError.invalid("Unexpected App Attest enrollment contract; no claimed activation.")
            }
            try check(); key.enrolled = true; key.uncertain = false; try cache.save(JSONEncoder().encode(key), key: slot)
        }
        let challenge = try await challenge(key: key.id, purpose: "request", method: method, path: path, bodyHash: digest,
            origin: origin, token: token, transport: transport, guest: account == nil)
        try check()
        let hash = try NativeIntegrityBinding.validatedHash(challenge, origin: origin, account: account, token: token,
            key: key.id, purpose: "request", method: method, path: path, bodyHash: digest)
        let assertion = try await provider.assert(key.id, hash: hash)
        let encoded = NativeIntegrityBinding.base64URL(assertion)
        guard !assertion.isEmpty, encoded.count <= 4096 else { throw BackpackError.invalid("App Attest assertion exceeds the real header bound.") }
        try check(); try Task.checkCancellation()
        var request = original
        request.setValue(key.id, forHTTPHeaderField: "X-Catalog-App-Attest-Key-Id")
        request.setValue(challenge.id, forHTTPHeaderField: "X-Catalog-App-Attest-Challenge-Id")
        request.setValue(encoded, forHTTPHeaderField: "X-Catalog-App-Attest-Assertion")
        let response = try await transport.send(request, maxBytes: maxBytes)
        try check(); return response
    }
    private func challenge(key: String, purpose: String, method: String, path: String, bodyHash: String,
        origin: CommunityOrigin, token: String, transport: any CommunityTransport, guest: Bool) async throws -> NativeIntegrityChallenge {
        var object = ["purpose": purpose, "keyId": key]
        if purpose == "request" { object["method"] = method; object["path"] = path; object["bodyHash"] = bodyHash }
        return try JSONDecoder().decode(NativeIntegrityChallenge.self, from: await bootstrap("challenges",
            body: JSONSerialization.data(withJSONObject: object), origin: origin, token: token, transport: transport, guest: guest))
    }
    private func bootstrap(_ action: String, body: Data, origin: CommunityOrigin, token: String, transport: any CommunityTransport, guest: Bool) async throws -> Data {
        var request = URLRequest(url: try origin.api("app-integrity/\(action)"))
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue(guest ? token : "Bearer \(token)", forHTTPHeaderField: guest ? "X-Catalog-Integrity-Session" : "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Catalog-Client"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request, maxBytes: 65536)
        guard (200...299).contains(response.status) else { throw CommunityFailure(status: response.status,
            code: "integrity_bootstrap_unavailable", message: "Official-app integrity bootstrap/enrollment was not confirmed.") }
        return response.data
    }
}
