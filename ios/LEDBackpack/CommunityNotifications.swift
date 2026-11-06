import SwiftUI
import BackpackProtocol

struct NativeNotificationPreferences: Codable, Equatable {
    var globalEnabled, inAppEnabled, applePushEnabled: Bool
    var categories: Categories
    struct Categories: Codable, Equatable {
        var directMessages, groupMessages, eventMessages, invitations, friendRequests, eventChanges, eventReminders, accountUpdates: Bool
    }
    enum Category: String, CaseIterable, Identifiable {
        case directMessages, groupMessages, eventMessages, invitations, friendRequests, eventChanges, eventReminders, accountUpdates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .directMessages: return "Direct messages"
            case .groupMessages: return "Group messages"
            case .eventMessages: return "Event messages / private questions"
            case .invitations: return "Invitations"
            case .friendRequests: return "Friend requests / acceptances"
            case .eventChanges: return "Event changes"
            case .eventReminders: return "Upcoming event reminders"
            case .accountUpdates: return "Account updates"
            }
        }
        var keyPath: WritableKeyPath<Categories, Bool> {
            switch self {
            case .directMessages: return \.directMessages
            case .groupMessages: return \.groupMessages
            case .eventMessages: return \.eventMessages
            case .invitations: return \.invitations
            case .friendRequests: return \.friendRequests
            case .eventChanges: return \.eventChanges
            case .eventReminders: return \.eventReminders
            case .accountUpdates: return \.accountUpdates
            }
        }
    }
}
struct NativeNotificationSettings: Decodable {
    let revision: Int
    let preferences: NativeNotificationPreferences
    let applePushAvailable: Bool
}
struct NativeNotificationSave: Encodable {
    let expectedRevision: Int
    let globalEnabled, inAppEnabled, applePushEnabled: Bool
    let categories: NativeNotificationPreferences.Categories
    init(_ original: NativeNotificationSettings, choices: NativeNotificationPreferences) {
        expectedRevision = original.revision
        globalEnabled = choices.globalEnabled; inAppEnabled = choices.inAppEnabled; applePushEnabled = choices.applePushEnabled
        categories = choices.categories
    }
}
struct NativeActivityNotice: Decodable, Identifiable {
    let id: UUID
    let type: Kind
    let referenceId, createdAtISO: String
    let readAtISO: String?
    enum Kind: String, Decodable {
        case friendRequest = "friend-request", friendAccepted = "friend-accepted", eventInvite = "event-invite",
            eventUpdated = "event-updated", eventCancelled = "event-cancelled", eventReminder = "event-reminder",
            message, avatarReviewed = "avatar-reviewed"
        var title: String {
            switch self {
            case .friendRequest: return "Friend request"
            case .friendAccepted: return "Friend request accepted"
            case .eventInvite: return "Event invitation"
            case .eventUpdated: return "Event updated"
            case .eventCancelled: return "Event cancelled"
            case .eventReminder: return "Upcoming reviewed event"
            case .message: return "Message activity"
            case .avatarReviewed: return "Avatar screening updated"
            }
        }
    }
    func reference() throws -> UUID {
        let parts = referenceId.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let id = UUID(uuidString: String(parts[0])),
              parts.count == 1 || ((1...63).contains(parts[1].count) && parts[1].utf8.allSatisfy({ (48...57).contains($0) })) else {
            throw BackpackError.invalid("Invalid generic activity reference.")
        }
        return id
    }
}
struct NativeNoticePage: Decodable { let notifications: [NativeActivityNotice]; let unread, total, page, limit: Int }
@MainActor
extension CommunityFeatureClient {
    func notificationSettings() async throws -> NativeNotificationSettings {
        guard notificationPreferencesEnabled else { throw BackpackError.invalid("Notification settings are not advertised by this server.") }
        try check(.notifications)
        let value = try JSONDecoder().decode(NativeNotificationSettings.self, from: await send(.notifications, "notifications/preferences"))
        guard (0...9_007_199_254_740_991).contains(value.revision) else { throw BackpackError.invalid("Invalid notification preferences revision.") }
        return value
    }
    func saveNotificationSettings(_ original: NativeNotificationSettings, choices: NativeNotificationPreferences) async throws -> NativeNotificationSettings {
        guard notificationPreferencesEnabled else { throw BackpackError.invalid("Notification settings became unavailable.") }
        guard !choices.applePushEnabled || original.applePushAvailable else { throw BackpackError.invalid("Apple push is unavailable; no enabled-state fallback.") }
        guard !choices.categories.eventReminders || eventRemindersEnabled else { throw BackpackError.invalid("Event reminders are unavailable; disable that choice or cancel before saving.") }
        let result = try JSONDecoder().decode(NativeNotificationSettings.self, from: await send(.notifications,
            "notifications/preferences", method: "PATCH", body: JSONEncoder().encode(NativeNotificationSave(original, choices: choices))))
        guard result.preferences == choices, result.revision >= original.revision else { throw BackpackError.invalid("The server did not confirm the captured notification choices.") }
        return result
    }
    func notices(page: Int) async throws -> NativeNoticePage {
        guard notificationsEnabled else { throw BackpackError.invalid("Private activity is not enabled.") }
        guard (1...200).contains(page) else { throw BackpackError.invalid("Invalid activity page.") }
        let result = try JSONDecoder().decode(NativeNoticePage.self, from: await send(.notifications, "notifications", query: [
            URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: "24")]))
        guard result.page == page, result.limit == 24, result.notifications.count <= 24 else { throw BackpackError.invalid("Invalid bounded activity page.") }
        for notice in result.notifications {
            _ = try notice.reference(); _ = try CatalogEventTime.parse(notice.createdAtISO)
            if let read = notice.readAtISO { _ = try CatalogEventTime.parse(read) }
        }
        return result
    }
    func noticeAction(_ id: UUID?, remove: Bool = false) async throws {
        guard notificationsEnabled else { throw BackpackError.invalid("Private activity became unavailable.") }
        let path = id.map { "notifications/\($0.uuidString.lowercased())" } ?? "notifications/read-all"
        _ = try await send(.notifications, path, method: remove ? "DELETE" : id == nil ? "POST" : "PATCH",
            body: remove ? nil : Data((id == nil ? "{}" : #"{"read":true}"#).utf8))
    }
}
