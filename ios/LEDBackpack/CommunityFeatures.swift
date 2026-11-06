import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import BackpackProtocol

enum CommunityFeature: Equatable { case social, avatars, events }

struct SocialPerson: Decodable, Identifiable {
    let id: UUID
    let displayName: String
    var avatarUrl: URL?
    var avatarPreviewUrl: URL?
    var avatarAnimated: Bool?
    var locationFeaturesAllowed: Bool?
    var mutualLocationFeaturesAllowed: Bool?
    var avatarMature: Bool?
    var avatarMasked: Bool?
}
struct SocialPreferences: Decodable {
    let profile: SocialPerson
    let discoverable, allowRequests, messagingEnabled: Bool
    let encryption: String
}
struct SocialFriendRequest: Decodable, Identifiable {
    let id, senderId, recipientId: UUID
    let status: String
    let createdAt, updatedAt: Double
}
struct SocialFriendsPage: Decodable { let friends: [SocialPerson]; let page, limit: Int }
struct SocialRequestsPage: Decodable {
    let inbound, outbound: [SocialFriendRequest]
    let page, limit: Int
}
struct SocialInvite: Decodable, Identifiable {
    let id: UUID
    let token: String
    let expiresAt: Double
    var expires: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}
struct SocialAvatar: Decodable {
    let userId, version: UUID
    let status: String
    let createdAt: Double
    let avatarUrl, avatarPreviewUrl: URL?
    let avatarAnimated: Bool
    var aiState: String?
    var aiError: String?
    var approvalMode: String?
    var avatarMature: Bool?
    var avatarMasked: Bool?
}
struct OwnedAvatarState: Decodable {
    let avatar: SocialAvatar?
    var uploadsEnabled: Bool?
    var approvalMode: String?
}

@MainActor
final class CommunityFeatureClient {
    let instanceID = UUID()
    let origin: CommunityOrigin
    let accountID, revision: UUID
    private let community: CommunityController
    var automaticAvatarUploads: Bool {
        community.config?.avatarsEnabled == true && community.config?.avatarUploadsEnabled == true &&
            community.config?.avatarApprovalMode == "ai"
    }
    var plannerEnabled: Bool { community.config?.eventsEnabled == true }
    var participationReviewEnabled: Bool { community.config?.eventParticipationReviewEnabled == true }
    func exclusiveRouteEnabled(_ event: CatalogEvent) -> Bool {
        community.config?.eventExclusiveGifsEnabled == true && community.config?.eventExclusiveRouteArtworkEnabled == true &&
            event.settings?.exclusiveArtworkReferences == true
    }
    func checkPlanner() throws {
        try check(.events)
        guard plannerEnabled else { throw BackpackError.invalid("The server has not enabled organizer map planning.") }
    }
    func plannerCatalogData(id: UUID? = nil, query: String = "", page: Int = 1) async throws -> Data {
        try checkPlanner()
        guard query.utf16.count <= 120, (1...10000).contains(page) else { throw BackpackError.invalid("Invalid artwork search/page.") }
        let path = id.map { "items/\($0.uuidString.lowercased())" } ?? "items"
        let parameters = id == nil ? [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: "50")] : []
        let result = try await community.request(path, query: parameters, expectedAccountRevision: revision)
        try checkPlanner(); try check()
        return result.data
    }
    func plannerCommunityImage(_ url: URL) async throws -> Data {
        try checkPlanner()
        let result = try await community.download(url, expectedAccountRevision: revision)
        try checkPlanner(); try check()
        return result
    }
    init(_ community: CommunityController) throws {
        try community.checkAccountSession()
        guard community.signedIn, let origin = community.origin, let id = community.user?.id else {
            throw BackpackError.invalid("Sign in and refresh your account first.")
        }
        self.community = community; self.origin = origin; accountID = id; revision = community.accountRevision
    }
    func check(_ feature: CommunityFeature? = nil) throws {
        try community.checkAccountSession()
        guard community.signedIn, community.origin == origin, community.user?.id == accountID,
              community.accountRevision == revision else {
            throw BackpackError.invalid("Account or catalog changed. Reopen this feature.")
        }
        let enabled: Bool
        switch feature {
        case .some(.social): enabled = community.config?.socialEnabled == true
        case .some(.avatars): enabled = community.config?.avatarsEnabled == true
        case .some(.events): enabled = community.config?.eventsEnabled == true
        case .none: enabled = true
        }
        guard enabled else { throw BackpackError.invalid("This server has not enabled this feature.") }
    }
    func send(_ feature: CommunityFeature, _ path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], contentType: String = "application/json", maxBytes: Int = 2_000_000) async throws -> Data {
        try check(feature)
        let automatedAvatarWrite = feature == .avatars && method == "POST" &&
            (path == "social/avatar" || path == "social/avatar/retry")
        if automatedAvatarWrite && !automaticAvatarUploads { throw BackpackError.invalid("Automatic avatar uploads/screening became unavailable.") }
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.contains("?"), !path.contains("#"),
              path.utf8.allSatisfy({ (33...126).contains($0) }),
              (feature == .events ? path == "events" || path.hasPrefix("events/") : path.hasPrefix("social/")) else {
            throw BackpackError.invalid("Invalid feature request path.")
        }
        let result = try await community.request(path, method: method, body: body, query: query,
            contentType: contentType, maxBytes: maxBytes, expectedAccountRevision: revision)
        try Task.checkCancellation(); try check(feature)
        if automatedAvatarWrite && !automaticAvatarUploads { throw BackpackError.invalid("Avatar screening availability changed during the request. Refresh before retrying.") }
        return result.data
    }
    private func paging(_ page: Int) throws -> [URLQueryItem] {
        guard (1...10000).contains(page) else { throw BackpackError.invalid("Invalid social page.") }
        return [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "50")]
    }
    func preferences() async throws -> SocialPreferences {
        let value = try JSONDecoder().decode(SocialPreferences.self, from: await send(.social, "social/me"))
        guard value.profile.id == accountID else { throw BackpackError.invalid("The server returned a different profile.") }
        try validate(value.profile)
        return value
    }
    func saveProfile(name: String, discoverable: Bool, requests: Bool) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.utf16.count) else { throw BackpackError.invalid("Use a profile name of 1 to 80 characters.") }
        struct Body: Encodable { let displayName: String; let discoverable, allowRequests: Bool }
        struct Result: Decodable { let profile: SocialPerson }
        let value = try JSONDecoder().decode(Result.self, from: await send(.social, "social/me", method: "PATCH",
            body: JSONEncoder().encode(Body(displayName: trimmed, discoverable: discoverable, allowRequests: requests))))
        guard value.profile.id == accountID else { throw BackpackError.invalid("The profile update was not bound to this account.") }
    }
    func friends(page: Int) async throws -> SocialFriendsPage {
        let value = try JSONDecoder().decode(SocialFriendsPage.self, from: await send(.social, "social/friends", query: paging(page)))
        guard value.page == page, value.limit == 50, value.friends.count <= 50 else { throw BackpackError.invalid("Invalid friends pagination.") }
        for friend in value.friends {
            try validate(friend)
            guard let own = friend.locationFeaturesAllowed, let mutual = friend.mutualLocationFeaturesAllowed,
                  !mutual || own else { throw BackpackError.invalid("Invalid directional friend consent.") }
        }
        return value
    }
    func requests(page: Int) async throws -> SocialRequestsPage {
        let value = try JSONDecoder().decode(SocialRequestsPage.self, from: await send(.social, "social/requests", query: paging(page)))
        guard value.page == page, value.limit == 50, value.inbound.count + value.outbound.count <= 50 else {
            throw BackpackError.invalid("Invalid friend-request pagination.")
        }
        guard value.inbound.allSatisfy({ $0.recipientId == accountID && $0.status == "pending" }),
              value.outbound.allSatisfy({ $0.senderId == accountID && $0.status == "pending" }),
              Set((value.inbound + value.outbound).map(\.id)).count == value.inbound.count + value.outbound.count else {
            throw BackpackError.invalid("Friend requests were not bound to this account.")
        }
        return value
    }
    func requestFriend(_ id: UUID) async throws {
        guard id != accountID else { throw BackpackError.invalid("Choose another account.") }
        struct Body: Encodable { let userId: String }
        struct Result: Decodable { let request: SocialFriendRequest }
        let value = try JSONDecoder().decode(Result.self, from: await send(.social, "social/requests", method: "POST",
            body: JSONEncoder().encode(Body(userId: id.uuidString.lowercased())))).request
        guard Set([value.senderId, value.recipientId]) == Set([accountID, id]),
              ["pending", "accepted"].contains(value.status) else { throw BackpackError.invalid("The friend request was not bound to these accounts.") }
    }
    func respond(_ id: UUID, accept: Bool) async throws {
        struct Body: Encodable { let accept: Bool }
        struct Result: Decodable { let request: SocialFriendRequest }
        let result = try JSONDecoder().decode(Result.self,
            from: await send(.social, "social/requests/\(id.uuidString.lowercased())/respond", method: "POST",
                body: JSONEncoder().encode(Body(accept: accept))))
        guard result.request.id == id, result.request.recipientId == accountID,
              result.request.status == (accept ? "accepted" : "declined") else {
            throw BackpackError.invalid("The server did not confirm this account's friend-request decision.")
        }
    }
    func unfriend(_ id: UUID) async throws {
        struct Result: Decodable { let removed: Bool }
        let result = try JSONDecoder().decode(Result.self, from: await send(.social, "social/friends/\(id.uuidString.lowercased())", method: "DELETE"))
        guard result.removed else { throw BackpackError.invalid("Friend removal was not confirmed.") }
    }
    func futureLocation(_ id: UUID, enabled: Bool) async throws {
        struct Body: Encodable { let enabled: Bool }
        struct Result: Decodable { let friend: SocialPerson }
        let result = try JSONDecoder().decode(Result.self, from: await send(.social,
            "social/friends/\(id.uuidString.lowercased())/location-permission", method: "PATCH",
            body: JSONEncoder().encode(Body(enabled: enabled))))
        guard result.friend.id == id, result.friend.locationFeaturesAllowed == enabled else {
            throw BackpackError.invalid("Future-feature consent was not confirmed.")
        }
    }
    func createInvite() async throws -> SocialInvite {
        struct Result: Decodable { let invite: SocialInvite }
        let value = try JSONDecoder().decode(Result.self, from: await send(.social, "social/invites", method: "POST", body: Data("{}".utf8))).invite
        guard !value.token.isEmpty, value.token.utf8.count <= 256, value.expiresAt.isFinite else {
            throw BackpackError.invalid("Invalid friend invitation.")
        }
        return value
    }
    func redeem(_ token: String) async throws {
        guard !token.isEmpty, token.utf8.count <= 256 else { throw BackpackError.invalid("Enter a valid friend invite token.") }
        struct Body: Encodable { let token: String }
        struct Result: Decodable { let request: SocialFriendRequest }
        _ = try JSONDecoder().decode(Result.self, from: await send(.social, "social/invites/redeem", method: "POST",
            body: JSONEncoder().encode(Body(token: token))))
    }
    func revokeInvite(_ id: UUID) async throws {
        struct Result: Decodable { let removed: Bool }
        guard try JSONDecoder().decode(Result.self, from: await send(.social, "social/invites/\(id.uuidString.lowercased())", method: "DELETE")).removed else {
            throw BackpackError.invalid("Invite revocation was not confirmed.")
        }
    }
    func block(_ id: UUID) async throws {
        try check(.social); try await community.block(id, expectedRevision: revision); try check(.social)
    }
    func avatar() async throws -> SocialAvatar? {
        try await ownedAvatar().avatar
    }
    func ownedAvatar() async throws -> OwnedAvatarState {
        let state = try JSONDecoder().decode(OwnedAvatarState.self, from: await send(.avatars, "social/avatar"))
        if let value = state.avatar {
            try validate(value)
            if state.approvalMode == "ai", value.approvalMode != "ai" { throw BackpackError.invalid("Automatic avatar metadata was not confirmed.") }
        }
        return state
    }
    func removeAvatar() async throws {
        struct Result: Decodable { let removed: Bool }
        guard try JSONDecoder().decode(Result.self, from: await send(.avatars, "social/avatar", method: "DELETE")).removed else {
            throw BackpackError.invalid("Avatar removal was not confirmed.")
        }
    }
    func uploadAvatar(_ data: Data, publicConsent: Bool, expectedVersion: UUID? = nil) async throws {
        guard publicConsent else { throw BackpackError.invalid("Explicitly consent to public-profile avatar review before uploading.") }
        guard automaticAvatarUploads else { throw BackpackError.invalid("Automatic avatar uploads are not enabled/configured on this server.") }
        let state = try await ownedAvatar()
        guard state.uploadsEnabled == true, state.approvalMode == "ai", state.avatar?.version == expectedVersion else {
            throw BackpackError.invalid("Avatar availability/version changed. Refresh before selecting a replacement.")
        }
        let kind = try NativeAvatarInput.kind(data)
        let boundary = "LEDBackpack-\(UUID().uuidString)"
        guard data.range(of: Data(boundary.utf8)) == nil else { throw BackpackError.invalid("Avatar upload boundary collision. Try again.") }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n{\"public\":true}\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"avatar.\(kind.extensionName)\"\r\nContent-Type: \(kind.mime)\r\n\r\n".utf8))
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        struct Result: Decodable { let avatar: SocialAvatar }
        let value = try JSONDecoder().decode(Result.self, from: await send(.avatars, "social/avatar", method: "POST",
            body: body, contentType: "multipart/form-data; boundary=\(boundary)")).avatar
        guard value.approvalMode == "ai" else { throw BackpackError.invalid("The server did not confirm automatic avatar screening.") }
        try validate(value)
    }
    func retryAvatar(expectedVersion: UUID) async throws {
        guard automaticAvatarUploads else { throw BackpackError.invalid("Automatic avatar screening is not configured.") }
        let state = try await ownedAvatar()
        guard state.uploadsEnabled == true, state.approvalMode == "ai", let avatar = state.avatar,
              avatar.version == expectedVersion, avatar.status == "pending", avatar.aiState == "failed" else {
            throw BackpackError.invalid("Refresh the current failed avatar before retrying; no version is rebased automatically.")
        }
        struct Body: Encodable { let expectedVersion: String }
        struct Result: Decodable { let queued: Bool }
        guard try JSONDecoder().decode(Result.self, from: await send(.avatars, "social/avatar/retry", method: "POST",
            body: JSONEncoder().encode(Body(expectedVersion: expectedVersion.uuidString.lowercased())))).queued else {
            throw BackpackError.invalid("Avatar retry was not confirmed.")
        }
    }
    func setMaturePreference(_ allowed: Bool) async throws {
        try check(.avatars)
        try await community.setMaturePreference(allowed, expectedRevision: revision)
        try check(.avatars)
    }
    private func validate(_ avatar: SocialAvatar) throws {
        guard avatar.userId == accountID, ["pending", "approved", "rejected"].contains(avatar.status) else {
            throw BackpackError.invalid("Invalid owned-avatar context.")
        }
        if avatar.status == "rejected" && (avatar.avatarUrl != nil || avatar.avatarPreviewUrl != nil) {
            throw BackpackError.invalid("Rejected avatars cannot expose media.")
        }
        let masked = avatar.avatarMasked == true
        guard (avatar.avatarUrl == nil) == (avatar.avatarPreviewUrl == nil),
              avatar.status == "rejected" || masked || avatar.avatarUrl != nil,
              !masked || (avatar.avatarMature == true && avatar.avatarUrl == nil && !avatar.avatarAnimated) else {
            throw BackpackError.invalid("Incomplete or incorrectly masked avatar media.")
        }
        if avatar.approvalMode == "ai" {
            guard ["queued", "running", "done", "failed"].contains(avatar.aiState ?? ""), avatar.aiError != nil else {
                throw BackpackError.invalid("Invalid automatic avatar screening state.")
            }
        }
        for url in [avatar.avatarUrl, avatar.avatarPreviewUrl].compactMap({ $0 }) {
            let parts = try avatarPath(url)
            guard parts[4] == avatar.userId.uuidString.lowercased(), parts[5] == avatar.version.uuidString.lowercased() else {
                throw BackpackError.invalid("Avatar version/account mismatch.")
            }
        }
    }
    func validate(_ person: SocialPerson) throws {
        guard (person.avatarUrl == nil) == (person.avatarPreviewUrl == nil) else { throw BackpackError.invalid("Incomplete avatar metadata.") }
        for url in [person.avatarUrl, person.avatarPreviewUrl].compactMap({ $0 }) {
            guard try avatarPath(url)[4] == person.id.uuidString.lowercased() else { throw BackpackError.invalid("Avatar profile mismatch.") }
        }
        if let image = person.avatarUrl, let preview = person.avatarPreviewUrl {
            guard try avatarPath(image)[5] == avatarPath(preview)[5] else { throw BackpackError.invalid("Mixed avatar versions.") }
        }
    }
    func resolvedAvatarURL(_ value: URL) throws -> URL {
        guard let components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              value.baseURL == nil, value.query == nil, value.fragment == nil,
              !value.relativeString.contains("\\"),
              components.percentEncodedPath.utf8.allSatisfy({ (33...126).contains($0) && $0 != 37 }),
              !components.percentEncodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw BackpackError.invalid("Avatar media must use a canonical catalog path without query, fragments or encoded segments.")
        }
        let url: URL
        if value.scheme == nil {
            guard value.host == nil, value.relativeString.hasPrefix("/api/v1/social/avatars/"),
                  !value.relativeString.hasPrefix("//"),
                  let resolved = URL(string: value.relativeString, relativeTo: origin.url)?.absoluteURL else {
                throw BackpackError.invalid("Relative avatar media must be rooted at this catalog's API.")
            }
            url = resolved
        } else { url = value }
        let parts = url.path.split(separator: "/").map(String.init)
        guard origin.contains(url), parts.count == 7,
              Array(parts.prefix(4)) == ["api", "v1", "social", "avatars"],
              let user = UUID(uuidString: parts[4]), user.uuidString.lowercased() == parts[4],
              let version = UUID(uuidString: parts[5]), version.uuidString.lowercased() == parts[5],
              ["image.gif", "image.png", "preview.png"].contains(parts[6]),
              try origin.api(parts.dropFirst(2).joined(separator: "/")) == url else {
            throw BackpackError.invalid("Avatar media must use this catalog's canonical authenticated route.")
        }
        return url
    }
    private func avatarPath(_ url: URL) throws -> [String] {
        try resolvedAvatarURL(url).path.split(separator: "/").map(String.init)
    }
    func avatarMedia(_ url: URL) async throws -> Data {
        let path = try avatarPath(url).dropFirst(2).joined(separator: "/")
        return try await send(.avatars, path, maxBytes: 5_000_000)
    }
}

enum NativeAvatarInput {
    struct Kind { let extensionName, mime: String }
    static func kind(_ data: Data) throws -> Kind {
        guard !data.isEmpty, data.count <= 5_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let raw = CGImageSourceGetType(source), let type = UTType(raw as String) else {
            throw BackpackError.invalid("Choose a PNG/JPEG/WebP still or GIF up to 5 MB.")
        }
        let count = CGImageSourceGetCount(source)
        guard (1...120).contains(count), type == .gif || count == 1 else { throw BackpackError.invalid("Avatars support still images or GIFs with 1 to 120 frames.") }
        let kind: Kind
        if type == .gif { kind = Kind(extensionName: "gif", mime: "image/gif") }
        else if type == .png { kind = Kind(extensionName: "png", mime: "image/png") }
        else if type == .jpeg { kind = Kind(extensionName: "jpg", mime: "image/jpeg") }
        else if type == .webP { kind = Kind(extensionName: "webp", mime: "image/webp") }
        else { throw BackpackError.invalid("This avatar image format is not supported.") }
        var pixels = 0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            guard (1...4096).contains(width), (1...4096).contains(height) else { throw BackpackError.invalid("Avatar dimensions must be at most 4096 pixels.") }
            pixels += width * height
            guard pixels <= 40_000_000,
                  CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1] as CFDictionary) != nil else {
                throw BackpackError.invalid("Avatar decoding or pixel-budget validation failed.")
            }
        }
        return kind
    }
}

@MainActor
final class CommunityFeatureSession: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var denied = false
    @Published private(set) var failure: String?
    @Published private(set) var client: CommunityFeatureClient?
    private var operation: Task<Void, Never>?
    private var stamp = UUID()
    func bind(_ community: CommunityController) {
        clear()
        do { client = try CommunityFeatureClient(community); denied = false }
        catch { denied = true; failure = error.localizedDescription }
    }
    func clear() {
        operation?.cancel(); operation = nil; stamp = UUID(); client = nil; busy = false; failure = nil
    }
    func checked(_ value: CommunityFeatureClient) throws {
        try Task.checkCancellation(); try value.check()
        guard client === value, !denied else { throw BackpackError.invalid("Feature scope changed.") }
    }
    func run(expected: UUID? = nil, _ work: @escaping @MainActor (CommunityFeatureClient) async throws -> Void,
        success: @escaping @MainActor () -> Void = {}) {
        guard let client, !denied, expected == nil || expected == client.instanceID else {
            failure = "Account or feature scope changed. Refresh first."; return
        }
        operation?.cancel(); let current = UUID(); stamp = current; busy = true; failure = nil
        operation = Task {
            do { try await work(client); try checked(client); guard stamp == current else { return }; busy = false; success() }
            catch {
                guard stamp == current, !Task.isCancelled else { return }
                if let error = error as? CommunityFailure, [401, 403].contains(error.status) { clear(); denied = true }
                failure = error.localizedDescription; busy = false
            }
        }
    }
}
