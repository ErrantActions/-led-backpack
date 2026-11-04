import Foundation
import Combine
import Security
import BackpackProtocol

struct CommunityUser: Codable, Equatable {
    let id: UUID
    let email: String
    let displayName: String
    let role: String
    let verified: Bool
    let authMethods: CommunityAuthMethods?
}

struct CommunityAuthMethods: Codable, Equatable {
    let apple: Bool
    let password: Bool
    let appleOnly: Bool
}

struct CommunityConfig: Decodable {
    let requireEmailVerification: Bool
    let passwordRecoveryAvailable: Bool?
    let privateLibraryEnabled: Bool?
    let accountDeletionRetainsSharedGifs: Bool?
    let appleSignInEnabled: Bool?
    var allowsNativeSignup: Bool { accountDeletionRetainsSharedGifs == false }
}
struct CommunitySession: Codable {
    let token: String
    let expiresAt: String
    let appleUser: String?
}
struct CommunityLogin: Decodable {
    let user: CommunityUser
    let token: String?
    let expiresAt: String
}
struct CommunityMessage: Decodable { let message: String }
struct CommunityMe: Decodable { let user: CommunityUser }

struct CommunityDeletion: Codable, Equatable {
    enum Status: String, Codable { case pending, completed }
    let id: String
    let status: Status
    let statusUrl: URL
    let requestedAt: String
    let completedAt: String?
    let error: String?
    let retainedSharedGifs: Int?
}
struct CommunityDeletionResponse: Decodable { let deletion: CommunityDeletion }

struct CommunityItem: Decodable, Identifiable {
    let id: UUID
    let title: String
    let category: String
    let tags: [String]
    let displayAttribution: String
    let license: String
    let licenseUrl: URL?
    let sourceUrl: URL?
    let pageUrl: URL
    let gifUrl: URL
    let previewUrl: URL
    let width: Int
    let height: Int
    let frameCount: Int
    let byteSize: Int
    let uploader: Uploader
    let likeCount: Int
    let variants: [Variant]
    struct Uploader: Decodable { let id: UUID?; let displayName: String }
    struct Variant: Decodable {
        let width: Int
        let height: Int
        let frameCount: Int
        let byteSize: Int
        let url: URL
    }
    var credit: Attribution {
        Attribution(source: (sourceUrl ?? pageUrl).absoluteString, author: displayAttribution,
            license: license == "original" ? "Original work / catalog download permission" : license,
            licenseURL: (licenseUrl ?? pageUrl).absoluteString)
    }
}
struct CommunityPage: Decodable {
    let items: [CommunityItem]
    let page: Int
    let limit: Int
    let total: Int
}

struct CommunityFailure: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct CommunityOrigin: Equatable, Sendable {
    let url: URL
    static func parse(_ text: String) throws -> CommunityOrigin {
        guard text.utf8.count <= 2048,
              var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port ?? 0) else {
            throw BackpackError.invalid("Enter the catalog's root HTTPS website URL, without a path, credentials or query.")
        }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw BackpackError.invalid("Invalid catalog URL.") }
        return CommunityOrigin(url: url)
    }
    func contains(_ other: URL) -> Bool {
        other.scheme?.lowercased() == "https" &&
        other.host?.lowercased() == url.host?.lowercased() &&
        (other.port ?? 443) == (url.port ?? 443) && other.user == nil && other.password == nil
    }
    func api(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var target = url.appendingPathComponent("api/v1")
        for component in path.split(separator: "/") { target.appendPathComponent(String(component)) }
        guard var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            throw BackpackError.invalid("Could not construct the catalog request.")
        }
        parts.queryItems = query.isEmpty ? nil : query
        guard let result = parts.url else { throw BackpackError.invalid("Invalid catalog request URL.") }
        return result
    }
    func checkReceipt(_ receipt: CommunityDeletion) throws {
        guard receipt.id.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil,
              contains(receipt.statusUrl), receipt.statusUrl.query == nil, receipt.statusUrl.fragment == nil,
              receipt.statusUrl.path == "/api/v1/account-deletions/\(receipt.id)" else {
            throw BackpackError.invalid("Deletion was accepted, but the server returned an invalid status receipt.")
        }
    }
}

struct CommunityResponse: Sendable { let status: Int; let data: Data }
protocol CommunityTransport: Sendable {
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse
}

private final class CommunityRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class CommunityHTTP: CommunityTransport {
    private let origin: CommunityOrigin
    private let session: URLSession
    init(origin: CommunityOrigin) {
        self.origin = origin
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: CommunityRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        guard let url = request.url, origin.contains(url) else {
            throw BackpackError.invalid("Catalog requests cannot leave the configured HTTPS server.")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackpackError.invalid("Invalid catalog HTTP response.") }
        guard !(300...399).contains(http.statusCode) else {
            throw BackpackError.invalid("The catalog redirected the request. Configure its final HTTPS URL instead.")
        }
        guard response.expectedContentLength <= Int64(maxBytes) else {
            throw BackpackError.invalid("Catalog response exceeds the app's size limit.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw BackpackError.invalid("Catalog response exceeds the app's size limit.") }
            data.append(byte)
        }
        try Task.checkCancellation()
        return CommunityResponse(status: http.statusCode, data: data)
    }
}

@MainActor
protocol CommunityVault {
    func read(_ key: String) throws -> Data?
    func save(_ data: Data, key: String) throws
    func remove(_ key: String) throws
}

@MainActor
struct CommunityKeychain: CommunityVault {
    private let service = "LEDBackpack.community"
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    func read(_ key: String) throws -> Data? {
        var value = query(key)
        value[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(value as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else {
            throw BackpackError.invalid("Catalog Keychain read failed (\(status)).")
        }
        return bytes
    }
    func save(_ data: Data, key: String) throws {
        let value = query(key)
        var status = SecItemUpdate(value as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = value
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BackpackError.invalid("Catalog Keychain save failed (\(status)).") }
    }
    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackpackError.invalid("Catalog Keychain removal failed (\(status)).")
        }
    }
}

@MainActor
final class CommunityController: ObservableObject {
    @Published private(set) var origin: CommunityOrigin?
    @Published private(set) var user: CommunityUser?
    @Published private(set) var config: CommunityConfig?
    @Published private(set) var deletion: CommunityDeletion?
    @Published private(set) var setupError: String?
    @Published private(set) var accountRevision = UUID()
    private var session: CommunitySession?
    private var transport: (any CommunityTransport)?
    private let vault: any CommunityVault
    private let factory: (CommunityOrigin) -> any CommunityTransport
    var signedIn: Bool { session != nil }
    private var sessionKey: String { "session|\(origin?.url.absoluteString ?? "")" }
    private var deletionKey: String { "deletion|\(origin?.url.absoluteString ?? "")" }

    convenience init() { self.init(vault: CommunityKeychain()) }
    init(vault: any CommunityVault,
        factory: @escaping (CommunityOrigin) -> any CommunityTransport = { CommunityHTTP(origin: $0) }) {
        self.vault = vault; self.factory = factory
    }
    func configure(_ text: String?, reload: Bool = false) {
        do {
            let next = try text.map(CommunityOrigin.parse)
            guard next != origin || reload else {
                if next == nil { setupError = nil }
                return
            }
            accountRevision = UUID()
            origin = next; session = nil; user = nil; config = nil; deletion = nil; setupError = nil
            transport = next.map(factory)
            guard next != nil else { return }
            do {
                if let bytes = try vault.read(sessionKey) {
                    let saved = try JSONDecoder().decode(CommunitySession.self, from: bytes)
                    try validateSession(saved)
                    session = saved
                }
            } catch {
                session = nil; user = nil
                setupError = error.localizedDescription
            }
            do {
                if let bytes = try vault.read(deletionKey) {
                    let saved = try JSONDecoder().decode(CommunityDeletion.self, from: bytes)
                    try next?.checkReceipt(saved)
                    deletion = saved
                }
            } catch { setupError = [setupError, error.localizedDescription].compactMap { $0 }.joined(separator: " ") }
        } catch {
            accountRevision = UUID()
            origin = nil; transport = nil; session = nil; user = nil; config = nil; deletion = nil
            setupError = error.localizedDescription
        }
    }
    func reloadLocalState() {
        guard let origin else { return }
        configure(origin.url.absoluteString, reload: true)
    }
    private func validateSession(_ value: CommunitySession) throws {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        guard let expiry = fractional.date(from: value.expiresAt) ?? ordinary.date(from: value.expiresAt),
              expiry > Date(), (16...1024).contains(value.token.utf8.count),
              value.token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw BackpackError.invalid("The catalog session is expired or invalid. Sign in again.")
        }
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], authenticated: Bool = true, allowServerChange: Bool = false,
        contentType: String = "application/json") async throws -> CommunityResponse {
        guard let origin, let transport else { throw BackpackError.invalid("Configure a catalog HTTPS URL first.") }
        let requestToken = authenticated ? session?.token : nil
        var request = URLRequest(url: try origin.api(path, query: query), timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("1", forHTTPHeaderField: "X-Catalog-Client")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if authenticated, let session {
            try validateSession(session)
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        }
        let response = try await transport.send(request, maxBytes: 2_000_000)
        guard allowServerChange || self.origin == origin else {
            throw BackpackError.invalid("The catalog server changed during the request. Retry on the selected server.")
        }
        guard allowServerChange || !authenticated || session?.token == requestToken else {
            throw BackpackError.invalid("The catalog account changed during the request. Refresh using the current account.")
        }
        guard (200...299).contains(response.status) else {
            struct Envelope: Decodable {
                let error: Detail
                struct Detail: Decodable { let code: String; let message: String }
            }
            let error = try? JSONDecoder().decode(Envelope.self, from: response.data)
            throw CommunityFailure(status: response.status, code: error?.error.code ?? "http_error",
                message: error?.error.message ?? "Catalog request failed (HTTP \(response.status)).")
        }
        return response
    }
    func loadConfig() async throws {
        config = try JSONDecoder().decode(CommunityConfig.self, from: await request("config", authenticated: false).data)
    }
    func signIn(email: String, password: String) async throws {
        struct Body: Encodable { let email: String; let password: String; let transport = "bearer" }
        let body = try JSONEncoder().encode(Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password))
        let result = try JSONDecoder().decode(CommunityLogin.self, from: await request("auth/login", method: "POST", body: body, authenticated: false).data)
        try establishSession(result)
    }
    func establishSession(_ result: CommunityLogin, appleUser: String? = nil) throws {
        guard let token = result.token else { throw BackpackError.invalid("The server did not return a native bearer session.") }
        let saved = CommunitySession(token: token, expiresAt: result.expiresAt, appleUser: appleUser)
        try validateSession(saved)
        try vault.save(JSONEncoder().encode(saved), key: sessionKey)
        accountRevision = UUID()
        session = saved; user = result.user; setupError = nil
    }
    func signUp(email: String, password: String, displayName: String) async throws -> String {
        try await loadConfig()
        guard config?.allowsNativeSignup == true else {
            throw BackpackError.invalid("Native signup is unavailable while this server retains shared GIFs after account deletion, or its deletion policy is unknown. You can browse as a guest or sign in to an existing account.")
        }
        struct Body: Encodable { let email: String; let password: String; let displayName: String }
        let body = try JSONEncoder().encode(Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)))
        let response = try await request("auth/signup", method: "POST", body: body, authenticated: false)
        let message = try JSONDecoder().decode(CommunityMessage.self, from: response.data).message
        if response.status == 201 { try await signIn(email: email, password: password) }
        return message
    }
    func refreshUser() async throws {
        guard signedIn else { return }
        do { user = try JSONDecoder().decode(CommunityMe.self, from: await request("auth/me").data).user }
        catch let error as CommunityFailure where error.status == 401 {
            try clearCredentials()
            throw error
        }
    }
    func forgotPassword(email: String) async throws -> String {
        struct Body: Encodable { let email: String }
        let body = try JSONEncoder().encode(Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines)))
        return try JSONDecoder().decode(CommunityMessage.self,
            from: await request("auth/forgot-password", method: "POST", body: body, authenticated: false).data).message
    }
    private func clearCredentials() throws {
        accountRevision = UUID()
        session = nil; user = nil
        try vault.remove(sessionKey)
    }
    func forgetLocalSession() throws {
        try clearCredentials()
        setupError = nil
    }
    private func clearCredentials(for server: CommunityOrigin, matching token: String) throws {
        let key = "session|\(server.url.absoluteString)"
        if origin == server, session?.token == token {
            accountRevision = UUID(); session = nil; user = nil
            try vault.remove(key)
        } else if let bytes = try vault.read(key) {
            let saved = try JSONDecoder().decode(CommunitySession.self, from: bytes)
            if saved.token == token { try vault.remove(key) }
        }
    }
    func signOut() async throws {
        guard let server = origin else { throw BackpackError.invalid("No catalog is configured.") }
        guard let token = session?.token else { throw BackpackError.invalid("No active catalog session to sign out.") }
        var failure: Error?
        do { _ = try await request("auth/logout", method: "POST", body: Data("{}".utf8), allowServerChange: true) }
        catch { failure = error }
        try clearCredentials(for: server, matching: token)
        if let failure {
            throw BackpackError.invalid("Signed out on this iPhone, but server logout could not be confirmed. \(failure.localizedDescription)")
        }
    }
    func deleteAccount(password: String, confirmation: String) async throws {
        guard signedIn else { throw BackpackError.invalid("Sign in before deleting your account.") }
        guard confirmation == "DELETE", !password.isEmpty else { throw BackpackError.invalid("Enter your password and type DELETE to confirm.") }
        struct Body: Encodable { let password: String; let confirmation: String }
        let body = try JSONEncoder().encode(Body(password: password, confirmation: confirmation))
        try await eraseAccount(body)
    }
    func deleteAccount(appleDeletionToken: String, confirmation: String) async throws {
        guard signedIn, confirmation == "DELETE", !appleDeletionToken.isEmpty else {
            throw BackpackError.invalid("Fresh Apple reauthentication and DELETE confirmation are required.")
        }
        struct Body: Encodable { let appleDeletionToken: String; let confirmation: String }
        try await eraseAccount(JSONEncoder().encode(Body(appleDeletionToken: appleDeletionToken, confirmation: confirmation)))
    }
    private func eraseAccount(_ body: Data) async throws {
        guard let server = origin else { throw BackpackError.invalid("No catalog is configured.") }
        guard let token = session?.token else { throw BackpackError.invalid("Sign in before deleting your account.") }
        let revision = accountRevision
        let accepted = try await request("auth/me", method: "DELETE", body: body, allowServerChange: true)
        guard accepted.status == 200 || accepted.status == 202 else { throw BackpackError.invalid("Unexpected account deletion response.") }
        do {
            let receipt = try JSONDecoder().decode(CommunityDeletionResponse.self, from: accepted.data).deletion
            try server.checkReceipt(receipt)
            guard (accepted.status == 200 && receipt.status == .completed) ||
                  (accepted.status == 202 && receipt.status == .pending) else {
                throw BackpackError.invalid("The deletion status and HTTP receipt disagree.")
            }

            if origin == server, accountRevision == revision { deletion = receipt }
            try vault.save(JSONEncoder().encode(receipt), key: "deletion|\(server.url.absoluteString)")
        } catch {
            let failure = error
            try clearCredentials(for: server, matching: token)
            throw BackpackError.invalid("Deletion was accepted and that session's credentials were cleared, but its receipt could not be saved. \(failure.localizedDescription)")
        }
        try clearCredentials(for: server, matching: token)
    }
    func updateAppleLinkedUser(_ value: CommunityUser) { user = value }
    var appleUserForCredentialCheck: String? { session?.appleUser }

    func refreshDeletion() async throws {
        guard let deletion else { throw BackpackError.invalid("No deletion receipt is stored on this iPhone.") }
        try origin?.checkReceipt(deletion)
        let response = try await request("account-deletions/\(deletion.id)", authenticated: false)
        let receipt = try JSONDecoder().decode(CommunityDeletionResponse.self, from: response.data).deletion
        guard receipt.id == deletion.id else { throw BackpackError.invalid("Deletion receipt changed unexpectedly.") }
        try origin?.checkReceipt(receipt)
        try vault.save(JSONEncoder().encode(receipt), key: deletionKey)
        self.deletion = receipt
    }
    func items(query: String, category: String, page: Int) async throws -> CommunityPage {
        guard query.utf16.count <= 120, (1...10000).contains(page) else {
            throw BackpackError.invalid("Use a search up to 120 characters and a valid page.")
        }
        var fields = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "24")]
        if !query.isEmpty { fields.append(URLQueryItem(name: "q", value: query)) }
        if !category.isEmpty { fields.append(URLQueryItem(name: "category", value: category)) }
        do {
            let result = try JSONDecoder().decode(CommunityPage.self, from: await request("items", query: fields).data)
            guard result.page == page, (1...100).contains(result.limit), result.items.count <= result.limit, result.total >= 0 else {
                throw BackpackError.invalid("The catalog returned invalid pagination.")
            }
            return result
        }
        catch let error as CommunityFailure where error.status == 401 {
            throw CommunityFailure(status: error.status, code: error.code,
                message: "Your catalog sign-in ended. Open Account to sign in again or sign out and browse as a guest.")
        }
    }
    func download(_ url: URL) async throws -> Data {
        guard let origin, origin.contains(url), url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/media/"), let transport else {
            throw BackpackError.invalid("Media must come from this catalog's HTTPS server.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        if let session {
            try validateSession(session)
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        }
        let response = try await transport.send(request, maxBytes: 5_000_000)
        guard self.origin == origin else { throw BackpackError.invalid("The catalog server changed during the download.") }
        guard response.status == 200 else { throw BackpackError.invalid("Catalog media is unavailable (HTTP \(response.status)).") }
        return response.data
    }
    func like(_ id: UUID) async throws -> Int {
        guard signedIn else { throw BackpackError.invalid("Sign in to like community artwork.") }
        struct Body: Encodable { let liked = true }
        struct Result: Decodable { let likeCount: Int }
        let body = try JSONEncoder().encode(Body())
        return try JSONDecoder().decode(Result.self,
            from: await request("items/\(id.uuidString.lowercased())/like", method: "POST", body: body).data).likeCount
    }
    func report(_ id: UUID, reason: String) async throws {
        guard signedIn else { throw BackpackError.invalid("Sign in to report community artwork.") }
        guard (4...1000).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) else {
            throw BackpackError.invalid("Describe the concern in 4-1000 characters.")
        }
        struct Body: Encodable { let reason: String }
        _ = try await request("items/\(id.uuidString.lowercased())/reports", method: "POST", body: JSONEncoder().encode(Body(reason: reason)))
    }
    func block(_ id: UUID) async throws {
        guard signedIn else { throw BackpackError.invalid("Sign in to block an uploader.") }
        struct Body: Encodable { let userId: String }
        _ = try await request("blocks", method: "POST", body: JSONEncoder().encode(Body(userId: id.uuidString.lowercased())))
    }

    func uploadGIF(_ data: Data, metadata: CommunityUploadMetadata) async throws -> CommunitySubmission {
        guard signedIn else { throw BackpackError.invalid("Sign in before uploading to the community.") }
        try await loadConfig()
        guard config?.privateLibraryEnabled == true else {
            throw BackpackError.invalid("This server has not confirmed private-library uploads. Upload was not sent.")
        }
        try metadata.validate()
        try CommunityUpload.validateGIF(data)
        let boundary = "LEDBackpack-\(UUID().uuidString)"
        let body = try CommunityUpload.multipart(data, metadata: metadata, boundary: boundary)
        let response = try await request("items", method: "POST", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)")
        guard response.status == 201 else { throw BackpackError.invalid("Unexpected GIF upload response.") }
        struct Result: Decodable { let item: CommunitySubmission }
        let item = try JSONDecoder().decode(Result.self, from: response.data).item
        guard item.visibility == "private", item.status == "pending", item.aiState == "disabled" else {
            throw BackpackError.invalid("The server accepted the GIF but did not confirm private storage without AI review. Check My uploads before retrying.")
        }
        return item
    }

    func myUploads() async throws -> [CommunitySubmission] {
        guard signedIn else { throw BackpackError.invalid("Sign in to view your uploads.") }
        struct Result: Decodable { let items: [CommunitySubmission] }
        return try JSONDecoder().decode(Result.self, from: await request("me/items").data).items
    }

    func cloudItems() async throws -> [CommunityCloudItem] {
        try await cloudPage(page: 1).items
    }

    func cloudPage(page: Int) async throws -> CommunityCloudPage {
        guard signedIn else { throw BackpackError.invalid("Sign in to open your private cloud library.") }
        guard (1...10000).contains(page) else { throw BackpackError.invalid("Invalid cloud library page.") }
        let query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "100")]
        let result = try JSONDecoder().decode(CommunityCloudPage.self, from: await request("me/items", query: query).data)
        guard result.items.count <= 100, result.page == nil || result.page == page,
              result.limit == nil || (1...100).contains(result.limit ?? 0),
              result.total == nil || (result.total ?? -1) >= result.items.count else {
            throw BackpackError.invalid("Invalid cloud library pagination returned by the server.")
        }
        return result
    }

    func deleteUpload(_ id: UUID) async throws {
        guard signedIn else { throw BackpackError.invalid("Sign in to delete an upload.") }
        guard user?.role == "admin" else { throw BackpackError.invalid("Only catalog admins can delete individual server GIFs.") }
        _ = try await request("items/\(id.uuidString.lowercased())", method: "DELETE")
    }

    func submitUpload(_ id: UUID, sharingAttested: Bool) async throws -> CommunitySubmission {
        guard signedIn, sharingAttested else { throw BackpackError.invalid("Sign in and explicitly confirm publication permission first.") }
        struct Body: Encodable { let sharingAttested: Bool }
        struct Result: Decodable { let item: CommunitySubmission }
        let body = try JSONEncoder().encode(Body(sharingAttested: true))
        let response = try await request("items/\(id.uuidString.lowercased())/submit", method: "POST", body: body)
        let item = try JSONDecoder().decode(Result.self, from: response.data).item
        guard item.visibility == "shared" else { throw BackpackError.invalid("Sharing consent was sent, but the server did not confirm shared visibility. Refresh My uploads.") }
        return item
    }
}
