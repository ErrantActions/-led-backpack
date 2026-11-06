import Foundation
import Combine
import BackpackProtocol

enum AdminItemStatus: String, Codable, CaseIterable {
    case pending, approved, rejected
}

struct AdminStatistics: Decodable {
    let generatedAt: String
    let accounts: Accounts
    let items: Items
    let storage: Storage
    let reports: Reports
    let likes: Int
    let activeSessions: Int
    let reviews: Reviews
    struct Accounts: Decodable { let total, admins, enabled, emailVerified: Int }
    struct Items: Decodable {
        let total, active, `private`, shared, approvedShared, pendingShared: Int
        let rejectedShared, deleted, retainedShared: Int
    }
    struct Storage: Decodable { let usedBytes, limitBytes: Int64 }
    struct Reports: Decodable { let open, resolved: Int }
    struct Reviews: Decodable { let queued, failed: Int }
}

struct AdminAccount: Decodable, Identifiable {
    let id: UUID
    let email, displayName, role: String
    let verified, allowMature, trustedReporter, disabled: Bool
    let createdAt: String
    let itemCount: Int
}

struct AdminAccountsPage: Decodable {
    let users: [AdminAccount]
    let page, limit, total: Int
}

struct AdminItem: Decodable, Identifiable {
    let item: CommunityItem
    let status: AdminItemStatus
    let moderationReason, aiState: String
    let aiError: String?
    let aiReview: Review?
    let requiresAdminReview, heldByReports: Bool
    var id: UUID { item.id }
    struct Review: Decodable {
        let flags: [String]
        let audience: String
        let confidence: Double
        let notes: String
    }
    init(from decoder: Decoder) throws {
        item = try CommunityItem(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .visibility) == "shared" else {
            throw BackpackError.invalid("Private artwork must never appear in admin moderation.")
        }
        status = try values.decode(AdminItemStatus.self, forKey: .status)
        moderationReason = try values.decode(String.self, forKey: .moderationReason)
        aiState = try values.decode(String.self, forKey: .aiState)
        aiError = try values.decodeIfPresent(String.self, forKey: .aiError)
        aiReview = try values.decodeIfPresent(Review.self, forKey: .aiReview)
        requiresAdminReview = try values.decode(Bool.self, forKey: .requiresAdminReview)
        heldByReports = try values.decode(Bool.self, forKey: .heldByReports)
    }
    private enum CodingKeys: String, CodingKey {
        case visibility, status, moderationReason, aiState, aiError, aiReview, requiresAdminReview, heldByReports
    }
}

struct AdminItemsPage: Decodable {
    let items: [AdminItem]
    let page, limit, total: Int
}

struct AdminReport: Decodable, Identifiable {
    let id, itemId, reporterId: UUID
    let reason, status: String
    let createdAt: Double
    var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }
}

struct AdminReportsPage: Decodable {
    let reports: [AdminReport]
    let page, limit, total: Int
}

struct AdminSettings: Decodable {
    let reportHideThreshold: Int
    let reporterRule: String
    let appleSignInEnabled: Bool
    let appleDiagnostic: String
}

struct AdminImport: Decodable, Identifiable {
    let id: UUID
    let filename, status, createdAt, updatedAt: String
    let error: String?
    let total, processed, imported, duplicates, skipped, failed: Int
    let results: [Result]
    struct Result: Decodable {
        let name, status: String
        let itemId: UUID?
        let error: String?
    }
}

struct AdminModeration: Encodable {
    let status: AdminItemStatus
    let reason, title, category: String
    let tags: [String]
    let audience: String?
    let safetyReviewed: Bool?
    func validate() throws {
        guard (1...120).contains(title.utf16.count),
              title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              CommunityCategory(rawValue: category) != nil,
              tags.count <= 12, tags.allSatisfy({ (1...32).contains($0.utf16.count) &&
                  $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              reason.utf16.count <= 1000 else {
            throw BackpackError.invalid("Provide valid classification and a reason of at most 1,000 characters.")
        }
        guard status != .rejected || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackpackError.invalid("Rejection requires a reason.")
        }
        guard (audience == nil && safetyReviewed == nil) ||
                (["general", "mature"].contains(audience ?? "") && safetyReviewed == true),
              status != .approved || safetyReviewed == true else {
            throw BackpackError.invalid("Review content safety and choose its audience before approving.")
        }
    }
}

enum AdminAccountAction: String, CaseIterable, Identifiable {
    case promote, enable, disable, trust, untrust
    var id: String { rawValue }
    var label: String {
        switch self {
        case .promote: return "Promote to admin"
        case .enable: return "Enable account"
        case .disable: return "Disable account"
        case .trust: return "Trust reporter"
        case .untrust: return "Remove reporter trust"
        }
    }
}

@MainActor
final class CommunityAdminClient {
    let instanceID = UUID()
    private let community: CommunityController
    let origin: CommunityOrigin
    let accountID, revision: UUID
    init(_ community: CommunityController) throws {
        try community.checkAdminSession()
        guard community.isAdmin, let origin = community.origin, let id = community.user?.id else {
            throw CommunityFailure(status: 403, code: "admin_required", message: "Sign in with an admin account.")
        }
        self.community = community; self.origin = origin; accountID = id; revision = community.accountRevision
    }
    func check() throws {
        try community.checkAdminSession()
        guard community.isAdmin, community.origin == origin, community.user?.id == accountID,
              community.accountRevision == revision else {
            throw CommunityFailure(status: 403, code: "admin_scope_changed",
                message: "Admin access or account/server changed. Refresh your account.")
        }
    }
    private func send(_ path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], bodyFile: URL? = nil, boundary: String? = nil) async throws -> Data {
        try check()
        let result = try await community.request(path, method: method, body: body, query: query,
            contentType: boundary.map { "multipart/form-data; boundary=\($0)" } ?? "application/json",
            communityUpload: bodyFile != nil, bodyFile: bodyFile)
        try Task.checkCancellation()
        try check()
        return result.data
    }
    private func pagination(_ page: Int) throws -> [URLQueryItem] {
        guard (1...10000).contains(page) else { throw BackpackError.invalid("Invalid admin page.") }
        return [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "24")]
    }
    private func validatePage(_ page: Int, limit: Int, total: Int, requested: Int, count: Int) throws {
        guard page == requested, limit == 24, total >= 0, count <= limit else {
            throw BackpackError.invalid("The server returned invalid admin pagination.")
        }
    }
    func statistics() async throws -> AdminStatistics {
        try JSONDecoder().decode(AdminStatistics.self, from: await send("admin/stats"))
    }
    func accounts(page: Int, query: String, role: String) async throws -> AdminAccountsPage {
        guard query.utf16.count <= 120, ["", "user", "admin", "moderator"].contains(role) else {
            throw BackpackError.invalid("Use an account search of at most 120 characters and a supported role.")
        }
        var parameters = try pagination(page)
        if !query.isEmpty { parameters.append(URLQueryItem(name: "q", value: query)) }
        if !role.isEmpty { parameters.append(URLQueryItem(name: "role", value: role)) }
        let result = try JSONDecoder().decode(AdminAccountsPage.self,
            from: await send("admin/users", query: parameters))
        try validatePage(result.page, limit: result.limit, total: result.total, requested: page, count: result.users.count)
        return result
    }
    func update(_ account: AdminAccount, action: AdminAccountAction) async throws {
        try check()
        guard account.id != accountID, account.role != "admin" else {
            throw BackpackError.invalid("Your own account and existing admins are protected.")
        }
        struct Body: Encodable { var role: String?; var disabled: Bool?; var trustedReporter: Bool? }
        var body = Body()
        switch action {
        case .promote:
            guard !account.disabled, community.config?.requireEmailVerification == false || account.verified else {
                throw BackpackError.invalid("Enable the account and satisfy email verification before promoting it.")
            }
            body.role = "admin"
        case .enable: body.disabled = false
        case .disable: body.disabled = true
        case .trust: body.trustedReporter = true
        case .untrust: body.trustedReporter = false
        }
        _ = try JSONDecoder().decode(CommunityMessage.self,
            from: await send("admin/users/\(account.id.uuidString.lowercased())/role",
                method: "POST", body: JSONEncoder().encode(body)))
    }
    func items(page: Int, status: AdminItemStatus) async throws -> AdminItemsPage {
        let parameters = try pagination(page) + [URLQueryItem(name: "visibility", value: "shared"),
            URLQueryItem(name: "status", value: status.rawValue)]
        let result = try JSONDecoder().decode(AdminItemsPage.self, from: await send("admin/items", query: parameters))
        try validatePage(result.page, limit: result.limit, total: result.total, requested: page, count: result.items.count)
        return result
    }
    func item(_ id: UUID) async throws -> AdminItem {
        struct Result: Decodable { let item: AdminItem }
        let value = try JSONDecoder().decode(Result.self, from: await send("items/\(id.uuidString.lowercased())")).item
        guard value.id == id else { throw BackpackError.invalid("The server returned a different moderation item.") }
        return value
    }
    func moderate(_ id: UUID, change: AdminModeration) async throws {
        try change.validate()
        struct Result: Decodable { let item: AdminItem }
        let value = try JSONDecoder().decode(Result.self,
            from: await send("admin/items/\(id.uuidString.lowercased())",
                method: "PATCH", body: JSONEncoder().encode(change))).item
        guard value.id == id, value.status == change.status else {
            throw BackpackError.invalid("The server did not confirm the requested moderation change. Refresh before retrying.")
        }
    }
    func review(_ id: UUID) async throws {
        _ = try JSONDecoder().decode(CommunityMessage.self,
            from: await send("admin/items/\(id.uuidString.lowercased())/review", method: "POST", body: Data("{}".utf8)))
    }
    func delete(_ id: UUID) async throws {
        _ = try JSONDecoder().decode(CommunityMessage.self,
            from: await send("items/\(id.uuidString.lowercased())", method: "DELETE"))
    }
    func reports(page: Int) async throws -> AdminReportsPage {
        let value = try JSONDecoder().decode(AdminReportsPage.self,
            from: await send("admin/reports", query: pagination(page)))
        try validatePage(value.page, limit: value.limit, total: value.total, requested: page, count: value.reports.count)
        return value
    }
    func resolve(_ id: UUID) async throws {
        struct Body: Encodable { let status = "resolved" }
        _ = try JSONDecoder().decode(CommunityMessage.self,
            from: await send("admin/reports/\(id.uuidString.lowercased())",
                method: "PATCH", body: JSONEncoder().encode(Body())))
    }
    func settings() async throws -> AdminSettings {
        let value = try JSONDecoder().decode(AdminSettings.self, from: await send("admin/settings"))
        guard (2...50).contains(value.reportHideThreshold) else {
            throw BackpackError.invalid("The server returned an invalid report threshold.")
        }
        return value
    }
    func setThreshold(_ threshold: Int) async throws {
        guard (2...50).contains(threshold) else { throw BackpackError.invalid("Choose a threshold from 2 to 50.") }
        struct Body: Encodable { let reportHideThreshold: Int }
        let data = try await send("admin/settings", method: "PATCH",
            body: JSONEncoder().encode(Body(reportHideThreshold: threshold)))
        struct Result: Decodable { let reportHideThreshold: Int }
        guard try JSONDecoder().decode(Result.self, from: data).reportHideThreshold == threshold else {
            throw BackpackError.invalid("The server did not confirm the report threshold. Refresh settings.")
        }
    }
    func imports() async throws -> [AdminImport] {
        struct Result: Decodable { let imports: [AdminImport] }
        return try JSONDecoder().decode(Result.self, from: await send("admin/imports")).imports
    }
    func importStatus(_ id: UUID) async throws -> AdminImport {
        struct Result: Decodable { let `import`: AdminImport }
        let value = try JSONDecoder().decode(Result.self,
            from: await send("admin/imports/\(id.uuidString.lowercased())")).import
        guard value.id == id else { throw BackpackError.invalid("The server returned a different import.") }
        return value
    }
    func upload(_ file: AdminArchiveFile) async throws -> AdminImport {
        struct Result: Decodable { let `import`: AdminImport }
        return try JSONDecoder().decode(Result.self, from: await send("admin/imports", method: "POST",
            bodyFile: file.url, boundary: file.boundary)).import
    }
    func uploadZIP(_ source: URL) async throws -> AdminImport {
        try check()
        let file = try await AdminArchiveBuilder.shared.prepare(source)
        let result: AdminImport
        do { result = try await upload(file) }
        catch {
            do { try await AdminArchiveBuilder.shared.remove(file) }
            catch let cleanup {
                throw BackpackError.invalid("ZIP upload failed: \(error.localizedDescription) Cleanup also failed: \(cleanup.localizedDescription). Check recent imports before retrying.")
            }
            throw error
        }
        do { try await AdminArchiveBuilder.shared.remove(file) }
        catch {
            throw BackpackError.invalid("The ZIP was accepted, but its temporary file could not be removed: \(error.localizedDescription). Check recent imports; do not upload again.")
        }
        try check()
        return result
    }
}

struct AdminArchiveFile: Sendable {
    let url: URL
    let boundary: String
}

actor AdminArchiveBuilder {
    static let shared = AdminArchiveBuilder()
    static let maxBytes = 250 * 1024 * 1024
    func prepare(_ source: URL) throws -> AdminArchiveFile {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, source.pathExtension.lowercased() == "zip" else {
            throw BackpackError.invalid("Choose a ZIP containing community GIFs.")
        }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, (1...Self.maxBytes).contains(size) else {
            throw BackpackError.invalid("Choose a nonempty ZIP no larger than 250 MiB.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("community-import-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
            attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else {
            throw BackpackError.invalid("Could not create a protected ZIP upload file.")
        }
        do {
            let boundary = "LEDBackpack-\(UUID().uuidString)"
            guard let input = InputStream(url: source), let output = OutputStream(url: file, append: false) else {
                throw BackpackError.invalid("Could not open the ZIP upload streams.")
            }
            input.open(); output.open()
            defer { input.close(); output.close() }
            func write(_ data: Data) throws {
                try data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        throw BackpackError.invalid("Could not access the ZIP upload bytes.")
                    }
                    var offset = 0
                    while offset < data.count {
                        let count = output.write(base.advanced(by: offset), maxLength: data.count - offset)
                        guard count > 0 else { throw output.streamError ?? BackpackError.invalid("Could not write the ZIP upload file.") }
                        offset += count
                    }
                }
            }
            let name = String(source.deletingPathExtension().lastPathComponent.unicodeScalars.map {
                (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) ? String($0) : "_"
            }.joined().prefix(100)) + ".zip"
            try write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/zip\r\n\r\n".utf8))
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            var total = 0
            let marker = Data(boundary.utf8)
            var tail = Data()
            while true {
                try Task.checkCancellation()
                let count = input.read(&buffer, maxLength: 1_048_576)
                guard count >= 0 else { throw input.streamError ?? BackpackError.invalid("Could not read the ZIP.") }
                if count == 0 { break }
                total += count
                guard total <= Self.maxBytes else { throw BackpackError.invalid("The ZIP exceeds 250 MiB.") }
                var window = tail
                window.append(contentsOf: buffer.prefix(count))
                guard window.range(of: marker) == nil else {
                    throw BackpackError.invalid("ZIP upload boundary collision. Select the package again.")
                }
                tail = Data(window.suffix(marker.count - 1))
                try write(Data(buffer.prefix(count)))
            }
            guard total == size else { throw BackpackError.invalid("The ZIP changed while it was being prepared. Select it again.") }
            try write(Data("\r\n--\(boundary)--\r\n".utf8))
            return AdminArchiveFile(url: file, boundary: boundary)
        } catch {
            do { try FileManager.default.removeItem(at: file) }
            catch let cleanup { throw BackpackError.invalid("ZIP preparation failed: \(error.localizedDescription) Cleanup also failed: \(cleanup.localizedDescription)") }
            throw error
        }
    }
    func remove(_ file: AdminArchiveFile) throws { try FileManager.default.removeItem(at: file.url) }
}

enum AdminTool: String, CaseIterable, Identifiable {
    case statistics = "Statistics", accounts = "Accounts", moderation = "GIF moderation"
    case reports = "Reports", settings = "Safety settings", imports = "ZIP imports"
    var id: String { rawValue }
}

@MainActor
final class CommunityAdminStore: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var denied = false
    @Published private(set) var failure: String?
    @Published private(set) var message: String?
    @Published private(set) var statistics: AdminStatistics?
    @Published private(set) var accounts: AdminAccountsPage?
    @Published private(set) var items: AdminItemsPage?
    @Published private(set) var reports: AdminReportsPage?
    @Published private(set) var settings: AdminSettings?
    @Published private(set) var imports: [AdminImport] = []
    @Published private(set) var selectedImport: AdminImport?
    @Published private(set) var selectedItem: AdminItem?
    private var client: CommunityAdminClient?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    var contextID: UUID? { client?.instanceID }

    func bind(_ community: CommunityController) {
        if let client, (try? client.check()) != nil { return }
        clear()
        do { client = try CommunityAdminClient(community); denied = false }
        catch { denied = true; failure = error.localizedDescription }
    }
    func clear() {
        operation?.cancel(); operation = nil; operationID = UUID()
        client = nil; busy = false
        statistics = nil; accounts = nil; items = nil; reports = nil; settings = nil
        imports = []; selectedImport = nil; selectedItem = nil; failure = nil; message = nil
    }
    func checked(_ value: CommunityAdminClient) throws {
        try Task.checkCancellation()
        try value.check()
        guard client === value, !denied else {
            throw BackpackError.invalid("Discarded an admin response after access changed.")
        }
    }
    func run(_ work: @escaping @MainActor (CommunityAdminClient) async throws -> String?,
        expectedScope: UUID? = nil,
        success: @escaping @MainActor () -> Void = {}) {
        operation?.cancel()
        let stamp = UUID(); operationID = stamp
        guard let client, !denied, expectedScope == nil || expectedScope == client.instanceID else {
            busy = false; operation = nil
            failure = "Admin context changed or access is unavailable. Refresh your account and reopen administration."
            return
        }
        busy = true; failure = nil; message = nil
        operation = Task {
            do {
                let result = try await work(client)
                try checked(client)
                guard stamp == operationID else { return }
                message = result; busy = false; success()
            } catch {
                guard stamp == operationID, !Task.isCancelled else { return }
                if let error = error as? CommunityFailure, [401, 403].contains(error.status) {
                    clear(); denied = true
                }
                failure = error.localizedDescription; busy = false
            }
        }
    }
    func load(_ tool: AdminTool, page: Int, query: String, role: String, status: AdminItemStatus) {
        switch tool {
        case .accounts: accounts = nil
        case .moderation: items = nil
        case .reports: reports = nil
        default: break
        }
        run { client in
            switch tool {
            case .statistics:
                let value = try await client.statistics(); try self.checked(client); self.statistics = value
            case .accounts:
                let value = try await client.accounts(page: page, query: query, role: role)
                try self.checked(client); self.accounts = value
            case .moderation:
                let value = try await client.items(page: page, status: status)
                try self.checked(client); self.items = value
            case .reports:
                let value = try await client.reports(page: page)
                try self.checked(client); self.reports = value
            case .settings:
                let value = try await client.settings(); try self.checked(client); self.settings = value
            case .imports:
                let value = try await client.imports(); try self.checked(client); self.imports = value
                self.selectedImport = nil
            }
            return nil
        }
    }
    func openItem(_ id: UUID) {
        run { client in
            let value = try await client.item(id)
            try self.checked(client); self.selectedItem = value
            return nil
        }
    }
    func closeItem() { selectedItem = nil }
    func openImport(_ id: UUID) {
        run { client in
            let value = try await client.importStatus(id)
            try self.checked(client); self.selectedImport = value
            return nil
        }
    }
    func importZIP(_ source: URL, expectedScope: UUID?) {
        run({ client in
            let value = try await client.uploadZIP(source)
            try self.checked(client); self.selectedImport = value
            self.imports.removeAll { $0.id == value.id }; self.imports.insert(value, at: 0)
            return "Package accepted for community screening. Refresh its status; do not upload it again."
        }, expectedScope: expectedScope)
    }
}
