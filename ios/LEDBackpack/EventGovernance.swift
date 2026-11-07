import Foundation
import BackpackProtocol

struct NativeEventModeration: Codable, Equatable {
    let revision: Int
    let held: Bool
    func validate() throws {
        guard (0...9_007_199_254_740_991).contains(revision), !held || revision > 0 else {
            throw BackpackError.invalid("Invalid actual moderation revision; no first-hold default is inferred.")
        }
    }
}

// A case authorizes this bounded definition only, never Event access or membership.
struct NativeEventReviewContext: Decodable, Identifiable {
    let id: UUID
    let revision: Int
    let visibility: String
    let contentWithheld: Bool
    let moderation: NativeEventModeration
    let definition: Definition?
    struct Definition: Decodable {
        let title, description, startsAtISO, endsAtISO, timezone: String
        let capacity: Int
        let location: CatalogEventLocation
        let cancelled: Bool
        let kind: String?
    }
    private enum CodingKeys: String, CodingKey { case id, revision, visibility, contentWithheld, moderation }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); revision = try c.decode(Int.self, forKey: .revision)
        visibility = try c.decode(String.self, forKey: .visibility)
        contentWithheld = try c.decode(Bool.self, forKey: .contentWithheld)
        moderation = try c.decode(NativeEventModeration.self, forKey: .moderation)
        try moderation.validate()
        guard revision > 0, ["private", "public", "unlisted"].contains(visibility),
              contentWithheld == (visibility == "private") else {
            throw BackpackError.invalid("Invalid withheld event review context.")
        }
        definition = contentWithheld ? nil : try Definition(from: decoder)
        if let definition {
            try CatalogEventInput(title: definition.title, description: definition.description,
                startsAtISO: definition.startsAtISO, endsAtISO: definition.endsAtISO, timezone: definition.timezone,
                visibility: visibility, capacity: definition.capacity, location: definition.location, expectedRevision: revision).validate()
        }
    }
}
enum NativeEventReportCategory: String, Codable, CaseIterable, Hashable { case spam, harassment, threat, safety, other }
enum NativeEventReviewAction: String, Codable, CaseIterable, Hashable { case hold, release, resolve }
struct NativeOwnEventReport: Decodable, Identifiable {
    let id, eventId: UUID
    let reportedEventRevision, revision: Int
    let category: NativeEventReportCategory
    let details: String
    let resolved: Bool
    let createdAtISO, expiresAtISO: String
    func validate() throws {
        guard reportedEventRevision > 0, revision > 0, (1...1000).contains(details.utf16.count),
              try CatalogEventTime.parse(expiresAtISO) > CatalogEventTime.parse(createdAtISO) else {
            throw BackpackError.invalid("Invalid event report retention/revision.")
        }
    }
    func expired(at date: Date) throws -> Bool { try date >= CatalogEventTime.parse(expiresAtISO) }
}
struct NativeStaffEventReport: Decodable, Identifiable {
    let own: NativeOwnEventReport
    let reporterId: UUID?
    let context: NativeEventReviewContext
    let review: Review?
    var id: UUID { own.id }
    struct Review: Decodable { let action: NativeEventReviewAction; let note, atISO: String }
    private enum CodingKeys: String, CodingKey { case reporterId, context, review }
    init(from decoder: Decoder) throws {
        own = try NativeOwnEventReport(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reporterId = try c.decodeIfPresent(UUID.self, forKey: .reporterId)
        context = try c.decode(NativeEventReviewContext.self, forKey: .context)
        review = try c.decodeIfPresent(Review.self, forKey: .review)
        try own.validate()
        guard context.id == own.eventId else { throw BackpackError.invalid("Case context belongs to another event.") }
    }
}
struct NativeEventReportPage<T: Decodable>: Decodable {
    let reports: [T]
    let page, limit: Int
    let hasMore: Bool
}
struct NativeEventHoldPage: Decodable {
    let events: [NativeEventReviewContext]
    let page, limit: Int
    let hasMore: Bool
}
struct NativeEventReportIntent {
    let eventID: UUID
    let eventRevision: Int
    let data: Data
    init(event: CatalogEvent, category: NativeEventReportCategory?, details: String, consent: Bool) throws {
        let text = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.settings?.eventReportsEnabled == true, let category, consent,
              (1...1000).contains(text.utf16.count), event.revision > 0 else {
            throw BackpackError.invalid("Choose a category, deliberately type 1–1000 characters and explicitly consent.")
        }
        struct Body: Encodable {
            let expectedRevision: Int
            let category: NativeEventReportCategory
            let details: String
            let consent: Bool
        }
        eventID = event.id; eventRevision = event.revision
        data = try JSONEncoder().encode(Body(expectedRevision: event.revision, category: category, details: text, consent: true))
    }
}
struct NativeEventCaseIntent {
    let reportID: UUID
    let data: Data
    init(report: NativeStaffEventReport, action: NativeEventReviewAction, note: String) throws {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1000).contains(text.utf16.count) else { throw BackpackError.invalid("Deliberately type a 1–1000 character note.") }
        try report.context.moderation.validate()
        struct Body: Encodable {
            let expectedRevision, expectedEventRevision, expectedModerationRevision: Int
            let action: NativeEventReviewAction
            let note: String
        }
        reportID = report.id
        data = try JSONEncoder().encode(Body(expectedRevision: report.own.revision,
            expectedEventRevision: report.context.revision, expectedModerationRevision: report.context.moderation.revision,
            action: action, note: text))
    }
}
enum NativeFormerOwnerRole: String, Codable, CaseIterable, Hashable { case coorganizer, none }
struct NativeEventOwnershipReceipt: Decodable {
    let transferred: Bool
    let formerOwnerRole: NativeFormerOwnerRole
    let membershipRetained: Bool
    let event: CatalogEvent?
    func validate(eventID: UUID, formerAccount: UUID, choice: NativeFormerOwnerRole?) throws {
        guard transferred, formerOwnerRole == (choice ?? .coorganizer) else { throw BackpackError.invalid("Ownership receipt did not acknowledge the captured role choice.") }
        if let event {
            try event.validate()
            let actual = event.organizers.first { $0.id == formerAccount }?.eventRole
            guard event.id == eventID, event.access.role != .owner, event.access.member == membershipRetained,
                  (formerOwnerRole == .none ? actual == nil && event.access.role == nil && !event.access.canManage :
                    actual == .coorganizer && event.access.role == .coorganizer) else {
                throw BackpackError.invalid("Ownership receipt contains stale former-owner privileges.")
            }
        }
    }
}
struct NativeEventOwnershipAudit: Decodable, Identifiable {
    let id: UUID
    let fromUserId, toUserId: UUID?
    let formerOwnerRole: NativeFormerOwnerRole
    let reason: String
    let eventRevision: Int
    let occurredAtISO: String
}
struct NativeEventOwnershipPage: Decodable {
    let entries: [NativeEventOwnershipAudit]
    let page, limit: Int
    let hasMore: Bool
}

@MainActor
extension CommunityFeatureClient {
    func checkEventOwner(_ event: CatalogEvent) throws {
        try check(.events)
        guard event.access.role == .owner, event.access.canManage,
              event.organizers.contains(where: { $0.id == accountID && $0.eventRole == .owner }) else {
            throw CommunityFailure(status: 403, code: "event_owner_required", message: "Only this event's actual current owner may use owner tools; clear stale management context.")
        }
    }
    func transferEventOwnership(_ event: CatalogEvent, target: UUID, formerRole: NativeFormerOwnerRole?) async throws -> NativeEventOwnershipReceipt {
        try checkEventOwner(event)
        guard !event.cancelled, eventOwnershipAuditAvailable, event.organizers.contains(where: { $0.id == target && $0.eventRole == .coorganizer }),
              formerRole == nil || (eventOwnershipAuditAvailable && event.settings?.formerOwnerRoleChoiceEnabled == true) else {
            throw BackpackError.invalid("Choose a current co-organizer and an advertised former-owner role.")
        }
        func declineKnownEventRSVP(_ id: UUID) async throws {
            struct Body: Encodable { let status = "declined" }
            struct Receipt: Decodable { let event: CatalogEvent?; let declined: Bool }
            let receipt = try JSONDecoder().decode(Receipt.self, from: await send(.events,
                "events/\(id.uuidString.lowercased())/rsvp", method: "POST", body: JSONEncoder().encode(Body())))
            guard receipt.declined, receipt.event == nil || receipt.event?.id == id else {
                throw BackpackError.invalid("Known RSVP decline was not acknowledged. No event view was requested.")
            }
        }
        struct Body: Encodable { let userId: String; let expectedRevision: Int; let formerOwnerRole: NativeFormerOwnerRole? }
        let receipt = try JSONDecoder().decode(NativeEventOwnershipReceipt.self, from: await send(.events,
            "events/\(event.id.uuidString.lowercased())/ownership", method: "POST",
            body: JSONEncoder().encode(Body(userId: target.uuidString.lowercased(), expectedRevision: event.revision, formerOwnerRole: formerRole))))
        try receipt.validate(eventID: event.id, formerAccount: accountID, choice: formerRole)
        return receipt
    }
    func ownershipAudit(_ event: CatalogEvent, page: Int) async throws -> NativeEventOwnershipPage {
        try checkEventOwner(event)
        guard eventOwnershipAuditAvailable, event.settings?.ownershipAuditEnabled == true else { throw BackpackError.invalid("Ownership history is not advertised by this server.") }
        let value = try JSONDecoder().decode(NativeEventOwnershipPage.self, from: await send(.events,
            "events/\(event.id.uuidString.lowercased())/ownership/audit", query: try eventGovernancePage(page)))
        try validateGovernancePage(value.page, limit: value.limit, count: value.entries.count, requested: page)
        for entry in value.entries {
            guard entry.eventRevision > 0, ["explicit-transfer", "account-erasure-succession"].contains(entry.reason) else {
                throw BackpackError.invalid("Invalid ownership history.")
            }
            _ = try CatalogEventTime.parse(entry.occurredAtISO)
        }
        let current = try await self.event(event.id)
        try checkEventOwner(current)
        guard current.revision == event.revision else { throw BackpackError.invalid("Current ownership/revision changed during audit read. Clear the old history and explicitly reload.") }
        return value
    }
    func submitEventReport(_ intent: NativeEventReportIntent) async throws -> NativeOwnEventReport {
        guard eventReportsAvailable else { throw BackpackError.invalid("Event reporting is not available on this server.") }
        struct Receipt: Decodable { let report: NativeOwnEventReport }
        let report = try JSONDecoder().decode(Receipt.self, from: await send(.events,
            "events/\(intent.eventID.uuidString.lowercased())/reports", method: "POST", body: intent.data)).report
        try report.validate()
        guard report.eventId == intent.eventID, report.reportedEventRevision == intent.eventRevision else { throw BackpackError.invalid("Report receipt changed its captured event/revision.") }
        return report
    }
    func ownEventReports(page: Int) async throws -> NativeEventReportPage<NativeOwnEventReport> {
        let result = try JSONDecoder().decode(NativeEventReportPage<NativeOwnEventReport>.self,
            from: await send(.eventGovernance, "social/event-reports", query: try eventGovernancePage(page)))
        try validateGovernancePage(result.page, limit: result.limit, count: result.reports.count, requested: page)
        for report in result.reports { try report.validate() }
        return result
    }
    func withdrawEventReport(_ report: NativeOwnEventReport) async throws {
        struct Body: Encodable { let expectedRevision: Int }
        struct Receipt: Decodable { let withdrawn, moderationUnchanged: Bool }
        let receipt = try JSONDecoder().decode(Receipt.self, from: await send(.eventGovernance,
            "social/event-reports/\(report.id.uuidString.lowercased())", method: "DELETE",
            body: JSONEncoder().encode(Body(expectedRevision: report.revision))))
        guard receipt.withdrawn, receipt.moderationUnchanged else { throw BackpackError.invalid("Withdrawal did not confirm unchanged moderation.") }
    }
    func staffEventReports(page: Int) async throws -> NativeEventReportPage<NativeStaffEventReport> {
        let result = try JSONDecoder().decode(NativeEventReportPage<NativeStaffEventReport>.self,
            from: await send(.eventGovernance, "admin/event-reports", query: try eventGovernancePage(page)))
        try validateGovernancePage(result.page, limit: result.limit, count: result.reports.count, requested: page)
        return result
    }
    func reviewEventReport(_ intent: NativeEventCaseIntent) async throws -> NativeStaffEventReport {
        struct Receipt: Decodable { let report: NativeStaffEventReport }
        return try JSONDecoder().decode(Receipt.self, from: await send(.eventGovernance,
            "admin/event-reports/\(intent.reportID.uuidString.lowercased())", method: "PATCH", body: intent.data)).report
    }
    func heldEvents(page: Int) async throws -> NativeEventHoldPage {
        let result = try JSONDecoder().decode(NativeEventHoldPage.self,
            from: await send(.eventGovernance, "admin/event-moderation", query: try eventGovernancePage(page)))
        try validateGovernancePage(result.page, limit: result.limit, count: result.events.count, requested: page)
        guard result.events.allSatisfy({ $0.moderation.held && $0.moderation.revision > 0 }) else { throw BackpackError.invalid("Held queue must describe actual existing moderation.") }
        return result
    }
    func releaseHeldEvent(_ context: NativeEventReviewContext) async throws -> NativeEventReviewContext {
        guard context.moderation.held, context.moderation.revision > 0 else { throw BackpackError.invalid("Only an existing held state can be released.") }
        struct Body: Encodable { let expectedEventRevision, expectedModerationRevision: Int; let action = "release" }
        struct Receipt: Decodable { let event: NativeEventReviewContext }
        let value = try JSONDecoder().decode(Receipt.self, from: await send(.eventGovernance,
            "admin/event-moderation/\(context.id.uuidString.lowercased())", method: "PATCH",
            body: JSONEncoder().encode(Body(expectedEventRevision: context.revision, expectedModerationRevision: context.moderation.revision)))).event
        guard value.id == context.id, !value.moderation.held, value.moderation.revision > context.moderation.revision else {
            throw BackpackError.invalid("Release was not acknowledged; refresh before retrying.")
        }
        return value
    }
    private func eventGovernancePage(_ page: Int) throws -> [URLQueryItem] {
        guard (1...10000).contains(page) else { throw BackpackError.invalid("Invalid event governance page.") }
        return [.init(name: "page", value: String(page)), .init(name: "limit", value: "24")]
    }
    private func validateGovernancePage(_ page: Int, limit: Int, count: Int, requested: Int) throws {
        guard page == requested, limit == 24, count <= 24 else { throw BackpackError.invalid("Invalid event governance pagination.") }
    }
}
