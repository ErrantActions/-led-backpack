import Foundation
import Combine
import BackpackProtocol

enum AccountServiceCapability: Equatable {
    case devices, firmware, research, bulk, alerts, artwork
    func enabled(_ config: CommunityConfig?) -> Bool {
        switch self {
        case .devices: return config?.unverifiedDeviceTagsEnabled == true
        case .firmware: return config?.firmwareCatalogEnabled == true
        case .research: return config?.deviceResearchEnabled == true
        case .bulk: return config?.adminBulkModerationEnabled == true
        case .alerts: return config?.uploadAbuseMonitoringEnabled == true
        case .artwork: return config?.artworkToolsEnabled == true
        }
    }
}

@MainActor
final class AccountServiceScope {
    let community: CommunityController
    let accountID, revision: UUID
    let origin: CommunityOrigin
    let capability: AccountServiceCapability
    let admin: Bool
    init(_ community: CommunityController, capability: AccountServiceCapability, admin: Bool = false) throws {
        try community.checkAccountSession()
        guard let id = community.user?.id, let origin = community.origin else { throw BackpackError.invalid("Sign in and refresh your account.") }
        self.community = community; accountID = id; revision = community.accountRevision
        self.origin = origin; self.capability = capability; self.admin = admin
        try check()
    }
    func check() throws {
        try Task.checkCancellation()
        try community.checkAccountSession()
        guard community.signedIn, community.user?.id == accountID, community.accountRevision == revision,
              community.origin == origin, capability.enabled(community.config), !admin || community.isAdmin,
              capability != .artwork || admin else {
            throw BackpackError.invalid("Current account, role or server capability changed. Reload; no action was retried.")
        }
        if admin { try community.checkAdminSession() }
    }
    func send<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], maxBytes: Int = 2_000_000, contentType: String = "application/json",
        tag: String? = nil, expectedStatus: Int? = nil) async throws -> T {
        let data = try await bytes(path, method: method, body: body, query: query, maxBytes: maxBytes, contentType: contentType, tag: tag, expectedStatus: expectedStatus)
        return try JSONDecoder().decode(type, from: data)
    }
    func bytes(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [],
        maxBytes: Int = 2_000_000, contentType: String = "application/json", tag: String? = nil, expectedStatus: Int? = nil) async throws -> Data {
        try check()
        guard !path.contains(".."), !path.contains("\\"), !path.contains("?"), !path.contains("#") else { throw BackpackError.invalid("Invalid account service path.") }
        let allowed: Bool
        switch capability {
        case .devices: allowed = path == "devices" || path.hasPrefix("devices/") || (tag != nil && path.hasPrefix("social/avatars/"))
        case .firmware: allowed = admin ? path == "admin/firmware" || path.hasPrefix("admin/firmware/") : path == "firmware" || path.hasPrefix("firmware/")
        case .research: allowed = admin ? path == "admin/device-research" || path.hasPrefix("admin/device-research/") : path.hasPrefix("device-research/")
        case .bulk: allowed = path == "admin/items" || path == "admin/items/bulk"
        case .alerts: allowed = path == "admin/upload-alerts" || path.hasPrefix("admin/upload-alerts/")
        case .artwork: allowed = admin && ((path == "items" && method == "GET") || path == "admin/artwork" || path.hasPrefix("admin/artwork/"))
        }
        guard allowed, !path.hasPrefix("admin/") || admin else { throw BackpackError.invalid("This scope does not grant that endpoint.") }
        let policy = community.avatarPolicyRevision
        let result = try await community.request(path, method: method, body: body, query: query, contentType: contentType,
            maxBytes: maxBytes, expectedAccountRevision: revision, expectedAccountID: accountID, deviceTag: tag)
        try check()
        guard policy == community.avatarPolicyRevision, !community.avatarPolicyChanging else { throw BackpackError.invalid("Viewer content preferences changed. Discarding the response.") }
        if let expectedStatus, result.status != expectedStatus { throw BackpackError.invalid("Unexpected account-service receipt status. Reconcile current state before any deliberate retry.") }
        return result.data
    }
}

@MainActor
final class AccountServiceSession: ObservableObject {
    @Published private(set) var scope: AccountServiceScope?
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var stamp = UUID()
    func bind(_ community: CommunityController, _ capability: AccountServiceCapability, admin: Bool = false) {
        clear()
        do { scope = try AccountServiceScope(community, capability: capability, admin: admin) }
        catch { failure = error.localizedDescription }
    }
    func clear() { task?.cancel(); task = nil; scope = nil; stamp = UUID(); busy = false; failure = nil; message = nil }
    func checked(_ scope: AccountServiceScope) throws {
        try scope.check()
        guard self.scope === scope else { throw BackpackError.invalid("The displayed account scope changed.") }
    }
    func run(_ work: @escaping @MainActor (AccountServiceScope) async throws -> String?) {
        guard let scope, !busy else { return }
        let stamp = UUID(); self.stamp = stamp; busy = true; failure = nil; message = nil
        task = Task {
            do {
                let result = try await work(scope); try checked(scope)
                guard self.stamp == stamp else { return }; message = result
            } catch {
                guard self.stamp == stamp, !Task.isCancelled else { return }
                failure = "\(error.localizedDescription) Reload current state after conflicts or an uncertain receipt; no silent retry."
            }
            if self.stamp == stamp { busy = false }
        }
    }
}
