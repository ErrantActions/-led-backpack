import Foundation
import BackpackProtocol

struct NativeOrganizerChatPermission {
    let newMessagesAllowed: Bool
    let canManageOwnContact: Bool
}
struct NativeOrganizerChatContext: Decodable {
    struct Organizer: Decodable { let id: UUID; let acceptsQuestions: Bool? }
    let organizers: [Organizer]
    func newMessageAllowed(account: UUID, peer: UUID) throws -> Bool {
        guard account != peer, Set(organizers.map(\.id)).count == organizers.count else {
            throw BackpackError.invalid("Invalid current organizer/recipient context.")
        }
        if organizers.contains(where: { $0.id == account }) { return true }
        guard let organizer = organizers.first(where: { $0.id == peer }) else {
            throw BackpackError.invalid("The actual direct recipient is not a current event organizer.")
        }
        return organizer.acceptsQuestions == true
    }
}
@MainActor
extension CommunityFeatureClient {
    func organizerChatPermission(peer: UUID, eventID: UUID?) async throws -> NativeOrganizerChatPermission {
        guard let eventID else { return .init(newMessagesAllowed: true, canManageOwnContact: false) }
        let data = try await send(.events, "events/\(eventID.uuidString.lowercased())")
        struct Envelope: Decodable { let event: CatalogEvent }
        struct Contacts: Decodable { let event: NativeOrganizerChatContext }
        let event = try JSONDecoder().decode(Envelope.self, from: data).event
        let contacts = try JSONDecoder().decode(Contacts.self, from: data).event
        try event.validate()
        guard event.id == eventID, !event.cancelled, event.moderation?.held != true else { throw BackpackError.invalid("Event chat access is unavailable.") }
        return try .init(newMessagesAllowed: contacts.newMessageAllowed(account: accountID, peer: peer),
            canManageOwnContact: event.access.role != nil)
    }
    func organizerContact(_ event: UUID) async throws -> NativeMessageRequestPreference {
        let value = try JSONDecoder().decode(NativeMessageRequestPreference.self, from: await send(.events,
            "events/\(event.uuidString.lowercased())/contact-preferences"))
        try value.validate(); return value
    }
    func saveOrganizerContact(_ event: UUID, original: NativeMessageRequestPreference, enabled: Bool) async throws -> NativeMessageRequestPreference {
        try original.validate()
        struct Body: Encodable { let expectedRevision: Int; let enabled: Bool }
        let value = try JSONDecoder().decode(NativeMessageRequestPreference.self, from: await send(.events,
            "events/\(event.uuidString.lowercased())/contact-preferences", method: "PATCH",
            body: JSONEncoder().encode(Body(expectedRevision: original.revision, enabled: enabled))))
        try value.validate()
        guard value.enabled == enabled, value.revision == original.revision + (enabled == original.enabled ? 0 : 1) else { throw BackpackError.invalid("Organizer question preference was not confirmed.") }
        return value
    }
}
