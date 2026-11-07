import Foundation
import Combine
import BackpackProtocol

enum NativePlaylistOrder: String, Codable, CaseIterable { case inOrder = "in-order", shuffle }
struct NativePlaylistEntry: Codable, Equatable {
    var itemId: UUID
    var durationMilliseconds: Int
}
struct NativePublicPlaylistContent: Codable, Equatable {
    var order = NativePlaylistOrder.inOrder
    var entries: [NativePlaylistEntry] = []
    func validate(maxEntries: Int = 100) throws {
        guard (1...maxEntries).contains(entries.count),
              entries.allSatisfy({ (1000...600000).contains($0.durationMilliseconds) }) else {
            throw BackpackError.invalid("Choose 1–\(maxEntries) currently public GIFs, each 1–600 seconds.")
        }
    }
}
struct NativePlaylistSchedule: Codable, Equatable {
    var enabled = false
    var time = "18:00"
    var timezone = TimeZone.current.identifier
    var days = [0, 1, 2, 3, 4, 5, 6]
    func validate() throws {
        guard time.range(of: "^(?:[01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil,
              timezone.utf16.count <= 100, TimeZone(identifier: timezone) != nil,
              (1...7).contains(days.count), Set(days).count == days.count,
              days.allSatisfy({ (0...6).contains($0) }) else {
            throw BackpackError.invalid("Choose HH:MM, a valid timezone and distinct selected weekdays.")
        }
    }
    func occurrence(at date: Date) -> String? {
        guard enabled, let zone = TimeZone(identifier: timezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, days.contains(weekday - 1),
              let hour = c.hour, let minute = c.minute, String(format: "%02d:%02d", hour, minute) == time else { return nil }
        return "\(timezone):\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0):\(time)"
    }
}
struct NativePlaylistContent: Codable, Equatable {
    var title = ""
    var description = ""
    var entries: [NativePlaylistEntry] = []
    var order = NativePlaylistOrder.inOrder
    var schedule: NativePlaylistSchedule?
    var publicReferences: NativePublicPlaylistContent { .init(order: order, entries: entries) }
    private enum CodingKeys: String, CodingKey { case title, description, entries, order, schedule }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .title)
        try c.encode(description.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .description)
        try c.encode(entries, forKey: .entries); try c.encode(order, forKey: .order)
        if let schedule { try c.encode(schedule, forKey: .schedule) } else { try c.encodeNil(forKey: .schedule) }
    }
    func validate() throws {
        guard (1...120).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count),
              description.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 1000 else {
            throw BackpackError.invalid("Use a private title of 1–120 and private description up to 1,000 characters.")
        }
        try publicReferences.validate(); try schedule?.validate()
    }
}
struct NativePlaylistItem: Decodable, Identifiable {
    let id: UUID
    let title: String
    let gifUrl, previewUrl: URL
    let nativeSize: String
}
struct NativeHydratedPlaylistEntry: Decodable {
    let durationMilliseconds: Int
    let available: Bool
    let item: NativePlaylistItem?
    func validate() throws {
        guard (1000...600000).contains(durationMilliseconds), available == (item != nil) else {
            throw BackpackError.invalid("Unavailable artwork must not expose item metadata.")
        }
    }
}
struct NativePlaylistPickerPage: Decodable {
    let items: [NativePlaylistItem]
    let hasMore: Bool
    let nextAfter: UUID?
}
struct NativePlaylistSummary: Decodable, Identifiable {
    let id: UUID
    let revision: Int
    let title, description: String
    let entryCount: Int
    let order: NativePlaylistOrder
    let schedule: NativePlaylistSchedule?
}
struct NativeOwnerPlaylistPage: Decodable {
    let playlists: [NativePlaylistSummary]
    let page: Int
    let hasMore: Bool
}
struct NativeOwnerPlaylist: Decodable {
    let id: UUID
    let revision: Int
    let title, description: String
    let entries: [NativePlaylistEntry]
    let order: NativePlaylistOrder
    let schedule: NativePlaylistSchedule?
    let hydratedEntries: [NativeHydratedPlaylistEntry]
    let scheduleExecutionVerified, privateCloudIncluded: Bool
    var content: NativePlaylistContent {
        .init(title: title, description: description, entries: entries, order: order, schedule: schedule)
    }
    func validate() throws {
        try content.validate()
        guard revision > 0, !scheduleExecutionVerified, !privateCloudIncluded,
              entries.count == hydratedEntries.count else {
            throw BackpackError.invalid("Invalid private playlist revision/physical-runtime claim.")
        }
        for (reference, entry) in zip(entries, hydratedEntries) {
            try entry.validate()
            guard reference.durationMilliseconds == entry.durationMilliseconds,
                  entry.item == nil || entry.item?.id == reference.itemId else {
                throw BackpackError.invalid("Playlist hydration changed the saved reference/order.")
            }
        }
    }
    func sceneSnapshot() throws -> NativePublicPlaylistContent {
        try validate(); try content.publicReferences.validate(maxEntries: 24)
        guard hydratedEntries.allSatisfy(\.available) else { throw BackpackError.invalid("Remove unavailable GIF references before copying a scene.") }
        return content.publicReferences
    }
}
struct NativePublishedPlaylistID: Hashable { let value: UUID }
struct NativePublishedPlaylistReceipt: Decodable, Identifiable {
    let id: UUID
    let url: URL
    let expiresAtISO: String
    let privateScheduleIncluded, privateCloudIncluded: Bool
    var publishedID: NativePublishedPlaylistID { .init(value: id) }
    func validate(origin: CommunityOrigin) throws {
        guard !privateScheduleIncluded, !privateCloudIncluded, origin.contains(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == parts.path,
              parts.path.range(of: "^/playlist-share/[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw BackpackError.invalid("Invalid public-only snapshot/share origin.")
        }
        _ = try CatalogEventTime.parse(expiresAtISO)
    }
}
struct NativePublicPlaylistSnapshot: Decodable {
    let title, description: String
    let order: NativePlaylistOrder
    let entries: [NativeHydratedPlaylistEntry]
    let expiresAtISO: String
    let privateScheduleIncluded, privateCloudIncluded: Bool
    func validate() throws {
        guard !privateScheduleIncluded, !privateCloudIncluded, (1...100).contains(entries.count),
              (1...120).contains(title.utf16.count), description.utf16.count <= 1000 else {
            throw BackpackError.invalid("Invalid public-only snapshot; private content is never displayed.")
        }
        _ = try CatalogEventTime.parse(expiresAtISO)
        for entry in entries { try entry.validate() }
    }
}
struct NativePlaylistPublishDraft: Equatable {
    var title = ""
    var description = ""
    var consent = false
    var expiresInHours = 24
    func validate() throws {
        guard consent, (1...120).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count),
              description.utf16.count <= 1000, (1...168).contains(expiresInHours) else {
            throw BackpackError.invalid("Enter separate public text, explicit public consent and an expiry of 1–168 hours.")
        }
    }
}
/// No file bytes or physical playback; the parent must reauthorize media on use.
struct NativePlaylistPreviewRequest {
    let id = UUID()
    let accountID, accountEpoch, playlistID: UUID
    let revision: Int
    let content: NativePublicPlaylistContent
    let hydratedEntries: [NativeHydratedPlaylistEntry]
    let requestStarted: ContinuousClock.Instant
    var expired: Bool { requestStarted.duration(to: ContinuousClock().now) >= .seconds(30) }
}
struct NativeForegroundScheduleState {
    private(set) var armed = false
    private(set) var lastOccurrence: String?
    private var occurrences = Set<String>()
    mutating func arm(explicitConsent: Bool) { armed = explicitConsent; lastOccurrence = nil; occurrences = [] }
    mutating func stop() { armed = false; lastOccurrence = nil; occurrences = [] }
    mutating func due(schedule: NativePlaylistSchedule?, at date: Date, foreground: Bool) -> Bool {
        guard foreground, armed, let occurrence = schedule?.occurrence(at: date), !occurrences.contains(occurrence) else { return false }
        occurrences.insert(occurrence); lastOccurrence = occurrence; return true
    }
}
@MainActor
extension CommunityFeatureClient {
    func ownerPlaylists(page: Int) async throws -> NativeOwnerPlaylistPage {
        guard (1...5).contains(page) else { throw BackpackError.invalid("Playlist page must be 1–5.") }
        let result = try JSONDecoder().decode(NativeOwnerPlaylistPage.self, from: await send(.playlists, "playlists",
            query: [.init(name: "page", value: String(page))]))
        guard result.page == page, result.playlists.count <= 24 else { throw BackpackError.invalid("Invalid owner playlist page.") }
        return result
    }
    func playlistItems(query: String, after: UUID? = nil) async throws -> NativePlaylistPickerPage {
        guard query.utf16.count <= 120 else { throw BackpackError.invalid("Keep artwork searches within 120 characters.") }
        var q = [URLQueryItem(name: "q", value: query)]
        if let after { q.append(.init(name: "after", value: after.uuidString.lowercased())) }
        let result = try JSONDecoder().decode(NativePlaylistPickerPage.self, from: await send(.playlists, "playlists/items", query: q))
        guard result.items.count <= 24, Set(result.items.map(\.id)).count == result.items.count,
              !result.hasMore || result.nextAfter != nil else { throw BackpackError.invalid("Invalid public artwork picker page.") }
        return result
    }
    func ownerPlaylist(_ id: UUID) async throws -> NativeOwnerPlaylist {
        struct Result: Decodable { let playlist: NativeOwnerPlaylist }
        let value = try JSONDecoder().decode(Result.self, from: await send(.playlists, "playlists/\(id.uuidString.lowercased())")).playlist
        guard value.id == id else { throw BackpackError.invalid("Wrong owner playlist returned.") }
        try value.validate(); return value
    }
    func saveOwnerPlaylist(_ content: NativePlaylistContent, original: NativeOwnerPlaylist?) async throws -> UUID {
        try content.validate()
        struct Body: Encodable { let expectedRevision: Int; let playlist: NativePlaylistContent }
        struct Receipt: Decodable { let id: UUID; let revision: Int }
        let path = original.map { "playlists/\($0.id.uuidString.lowercased())" } ?? "playlists"
        let data: Data
        if let original { data = try JSONEncoder().encode(Body(expectedRevision: original.revision, playlist: content)) }
        else { data = try JSONEncoder().encode(content) }
        let receipt = try JSONDecoder().decode(Receipt.self, from: await send(.playlists, path,
            method: original == nil ? "POST" : "PUT", body: data))
        guard receipt.revision > 0, original == nil || receipt.id == original?.id else { throw BackpackError.invalid("Invalid playlist save receipt.") }
        return receipt.id
    }
    func deleteOwnerPlaylist(_ value: NativeOwnerPlaylist) async throws {
        struct Body: Encodable { let expectedRevision: Int }
        struct Receipt: Decodable { let deleted: Bool }
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.playlists, "playlists/\(value.id.uuidString.lowercased())",
            method: "DELETE", body: JSONEncoder().encode(Body(expectedRevision: value.revision))))
        guard result.deleted else { throw BackpackError.invalid("Playlist deletion was not confirmed.") }
    }
    func publishOwnerPlaylist(_ value: NativeOwnerPlaylist, draft: NativePlaylistPublishDraft) async throws -> NativePublishedPlaylistReceipt {
        try value.validate(); try draft.validate()
        guard value.hydratedEntries.allSatisfy(\.available) else { throw BackpackError.invalid("Unavailable references cannot be published.") }
        struct Body: Encodable {
            let expectedRevision: Int; let publicTitle, publicDescription: String
            let consent = true; let expiresInHours: Int
        }
        let result = try JSONDecoder().decode(NativePublishedPlaylistReceipt.self, from: await send(.playlists,
            "playlists/\(value.id.uuidString.lowercased())/share", method: "POST",
            body: JSONEncoder().encode(Body(expectedRevision: value.revision,
                publicTitle: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                publicDescription: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
                expiresInHours: draft.expiresInHours))))
        try result.validate(origin: origin)
        guard result.id != value.id else { throw BackpackError.invalid("A public snapshot cannot use a private playlist ID.") }
        return result
    }
    func revokeOwnerPlaylistShares(_ value: NativeOwnerPlaylist) async throws {
        struct Body: Encodable { let expectedRevision: Int }
        struct Receipt: Decodable { let revoked: Bool }
        let result = try JSONDecoder().decode(Receipt.self, from: await send(.playlists,
            "playlists/\(value.id.uuidString.lowercased())/shares", method: "DELETE",
            body: JSONEncoder().encode(Body(expectedRevision: value.revision))))
        guard result.revoked else { throw BackpackError.invalid("Snapshot revocation was not confirmed.") }
    }
    func publishedPlaylistSnapshot(_ receipt: NativePublishedPlaylistReceipt) async throws -> NativePublicPlaylistSnapshot {
        try receipt.validate(origin: origin)
        guard let token = receipt.url.path.split(separator: "/").last else { throw BackpackError.invalid("Invalid public snapshot URL.") }
        let value = try JSONDecoder().decode(NativePublicPlaylistSnapshot.self, from: await send(.playlists,
            "playlist-shares/\(token)", maxBytes: 512_000))
        try value.validate()
        guard value.expiresAtISO == receipt.expiresAtISO else { throw BackpackError.invalid("Public snapshot expiry changed; no local extension is permitted.") }
        return value
    }
}
