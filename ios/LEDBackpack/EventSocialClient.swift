import Foundation
import BackpackProtocol

enum NativeEventSocialSurface { case teams, collection, display, guestbook, recap }
@MainActor
extension CommunityFeatureClient {
    func checkEventSurface(_ surface: NativeEventSocialSurface, event: CatalogEvent? = nil) throws {
        try check(surface == .guestbook ? .eventGuestbook : .events)
        let allowed: Bool
        switch surface {
        case .teams: allowed = teamPalettesAvailable && (event == nil || event?.settings?.eventTeamsEnabled == true)
        case .collection: allowed = collectionsAvailable && (event == nil || event?.settings?.eventCollectionsEnabled == true)
        case .display: allowed = displayPlansAvailable && (event == nil || event?.settings?.eventDisplayPlanningEnabled == true)
        case .guestbook: allowed = guestbookAvailable && (event == nil || event?.settings?.eventGuestbookAvailable == true)
        case .recap: allowed = recapsAvailable && (event == nil || event?.settings?.eventRecapsEnabled == true)
        }
        guard allowed else { throw NativeEventSocialContextFailure.unavailable }
    }
    private func socialEventData(_ surface: NativeEventSocialSurface, _ path: String, method: String = "GET",
                                 body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        try checkEventSurface(surface)
        let data = try await send(surface == .guestbook ? .eventGuestbook : .events, path, method: method, body: body,
                                  query: query, maxBytes: 512_000)
        try checkEventSurface(surface); return data
    }
    func currentSocialEvent(_ context: NativeEventSocialContext, surface: NativeEventSocialSurface,
                            organizer: Bool = false, participant: Bool = true) async throws -> CatalogEvent {
        let current = try await event(context.eventID)
        try checkEventSurface(surface, event: current)
        try context.check(current, participant: participant && !organizer, organizer: organizer)
        return current
    }
    func eventTeams(_ event: CatalogEvent) async throws -> NativeEventTeams {
        try checkEventSurface(.teams, event: event)
        let context = try NativeEventSocialContext(event)
        let value = try JSONDecoder().decode(NativeEventTeams.self, from: await socialEventData(.teams, context.path + "/teams",
            query: [.init(name: "expectedRevision", value: String(context.revision))]))
        try value.validate(context); return value
    }
    func saveEventTeams(_ event: CatalogEvent, snapshot: NativeEventTeams, teams: [NativeEventTeam]) async throws {
        let teams = teams.map { source in
            var value = source; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.colors = value.colors.map { $0.lowercased() }; return value
        }
        let context = try NativeEventSocialContext(event); try snapshot.validate(context)
        _ = try await currentSocialEvent(context, surface: .teams, organizer: true)
        guard snapshot.canManage, teams.count <= 16, Set(teams.map(\.id)).count == teams.count else { throw BackpackError.invalid("Organizer access and at most 16 distinct teams are required.") }
        for team in teams { try team.validate() }
        struct Body: Encodable { let expectedRevision, expectedPaletteRevision: Int; let teams: [NativeEventTeam] }
        struct Receipt: Decodable { let revision: Int; let teams: [NativeEventTeam] }
        let result = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.teams, context.path + "/teams", method: "PUT",
            body: JSONEncoder().encode(Body(expectedRevision: context.revision, expectedPaletteRevision: snapshot.revision, teams: teams))))
        guard result.revision >= snapshot.revision, result.teams == teams else { throw BackpackError.invalid("Palette save was not confirmed.") }
    }
    func chooseEventTeam(_ event: CatalogEvent, snapshot: NativeEventTeams, teamID: UUID, consent: Bool) async throws {
        let context = try NativeEventSocialContext(event); try snapshot.validate(context)
        let current = try await currentSocialEvent(context, surface: .teams)
        guard consent, current.access.canChooseTeam == true, snapshot.revision > 0,
              snapshot.teams.contains(where: { $0.id == teamID }) else { throw BackpackError.invalid("Choose a current named team and explicitly consent.") }
        struct Body: Encodable {
            let teamId: UUID; let consent = true
            let expectedRevision, expectedPaletteRevision, expectedParticipationRevision, expectedOptinRevision: Int
        }
        struct Receipt: Decodable { let revision: Int; let teamId: UUID? }
        let value = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.teams, context.path + "/team", method: "POST",
            body: JSONEncoder().encode(Body(teamId: teamID, expectedRevision: context.revision, expectedPaletteRevision: snapshot.revision,
                expectedParticipationRevision: context.participationRevision, expectedOptinRevision: snapshot.optinRevision))))
        guard value.teamId == teamID, value.revision >= snapshot.optinRevision else { throw BackpackError.invalid("Own team selection was not confirmed.") }
    }
    func withdrawEventTeam(eventID: UUID, revision: Int) async throws -> Int {
        struct Body: Encodable { let expectedOptinRevision: Int }
        struct Receipt: Decodable { let revision: Int; let teamId: UUID? }
        let value = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.teams,
            "events/\(eventID.uuidString.lowercased())/team", method: "DELETE", body: JSONEncoder().encode(Body(expectedOptinRevision: revision))))
        guard value.teamId == nil, value.revision >= revision else { throw BackpackError.invalid("Own team withdrawal was not confirmed.") }
        return value.revision
    }
    func eventCollection(_ event: CatalogEvent) async throws -> NativeEventCollection {
        try checkEventSurface(.collection, event: event)
        let context = try NativeEventSocialContext(event)
        let value = try JSONDecoder().decode(NativeEventCollection.self, from: await socialEventData(.collection, context.path + "/collection-plan", query: context.query))
        try value.validate(context); return value
    }
    func saveEventCollection(_ event: CatalogEvent, snapshot: NativeEventCollection, plan: NativeCollectionPlan) async throws {
        let context = try NativeEventSocialContext(event); try snapshot.validate(context)
        let current = try await currentSocialEvent(context, surface: .collection, organizer: true)
        try plan.validate(event: current)
        struct Body: Encodable {
            let expectedRevision, expectedParticipationRevision, expectedPlanRevision: Int; let plan: NativeCollectionPlan
        }
        struct Receipt: Decodable { let revision: Int; let plan: NativeCollectionPlan }
        let value = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.collection, context.path + "/collection-plan", method: "PUT",
            body: JSONEncoder().encode(Body(expectedRevision: context.revision, expectedParticipationRevision: context.participationRevision,
                expectedPlanRevision: snapshot.revision, plan: plan))))
        guard value.revision >= snapshot.revision, value.plan == plan else { throw BackpackError.invalid("Collection plan save was not confirmed.") }
    }
    func consentEventCollection(_ event: CatalogEvent, snapshot: NativeEventCollection, consent: Bool, cooperative: Bool) async throws {
        let context = try NativeEventSocialContext(event); try snapshot.validate(context)
        _ = try await currentSocialEvent(context, surface: .collection)
        guard consent, snapshot.plan.enabled, snapshot.revision > 0 else { throw BackpackError.invalid("Review a saved enabled hunt and explicitly opt in.") }
        struct Body: Encodable {
            let expectedRevision, expectedParticipationRevision, expectedPlanRevision, expectedOptinRevision: Int
            let enabled = true; let cooperative: Bool
        }
        struct Receipt: Decodable { let revision: Int; let enabled, cooperative: Bool }
        let value = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.collection, context.path + "/collection-plan/consent", method: "POST",
            body: JSONEncoder().encode(Body(expectedRevision: context.revision, expectedParticipationRevision: context.participationRevision,
                expectedPlanRevision: snapshot.revision, expectedOptinRevision: snapshot.optinRevision, cooperative: cooperative))))
        guard value.enabled, value.cooperative == cooperative, value.revision > snapshot.optinRevision else { throw BackpackError.invalid("Separate hunt/cooperative consent was not confirmed.") }
    }
    func withdrawEventPlan(eventID: UUID, surface: NativeEventSocialSurface, optinRevision: Int) async throws -> Int {
        guard surface == .collection || surface == .display else { throw BackpackError.invalid("Invalid own consent withdrawal.") }
        struct Body: Encodable { let expectedOptinRevision: Int }
        struct Receipt: Decodable { let revision: Int; let enabled: Bool }
        let leaf = surface == .collection ? "collection-plan" : "display-plan"
        let result = try JSONDecoder().decode(Receipt.self, from: await socialEventData(surface,
            "events/\(eventID.uuidString.lowercased())/\(leaf)/consent", method: "DELETE",
            body: JSONEncoder().encode(Body(expectedOptinRevision: optinRevision))))
        guard !result.enabled, result.revision >= optinRevision else { throw BackpackError.invalid("Owned consent withdrawal was not confirmed.") }
        return result.revision
    }
    func collectHuntTarget(_ event: CatalogEvent, snapshot: NativeEventCollection, checkpointID: UUID, consent: Bool) async throws {
        let context = try NativeEventSocialContext(event); try snapshot.validate(context)
        let current = try await currentSocialEvent(context, surface: .collection)
        guard consent, snapshot.permitsManualCollection(checkpointID, event: current) else {
            throw BackpackError.invalid("Explicitly select a current hunt target, or finish after all selected targets.")
        }
        struct Body: Encodable {
            let collect = true
            let expectedParticipationRevision: Int; let checkpointId: UUID; let collectionPlanRevision: Int
        }
        let receipt = try JSONDecoder().decode(EventBadgeCollectionReceipt.self, from: await socialEventData(.collection, context.path + "/awards", method: "POST",
            body: JSONEncoder().encode(Body(expectedParticipationRevision: context.participationRevision, checkpointId: checkpointID,
                collectionPlanRevision: snapshot.revision))))
        try receipt.validate()
    }
    func eventDisplayPlan(_ event: CatalogEvent, checkpointID: UUID?) async throws -> NativeEventDisplay {
        try checkEventSurface(.display, event: event)
        let context = try NativeEventSocialContext(event)
        var q = context.query
        if let checkpointID { q.append(.init(name: "checkpointId", value: checkpointID.uuidString.lowercased())) }
        let result = try JSONDecoder().decode(NativeEventDisplay.self, from: await socialEventData(.display, context.path + "/display-plan", query: q))
        try result.validate(context); return result
    }
    func saveEventDisplay(_ event: CatalogEvent, snapshot: NativeEventDisplay, plan: NativeDisplayPlan) async throws {
        var plan = plan
        plan.scenes = plan.scenes.map { source in
            var value = source; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.regroupPrompt = value.regroupPrompt?.trimmingCharacters(in: .whitespacesAndNewlines); return value
        }
        let context = try NativeEventSocialContext(event); try snapshot.validate(context)
        let current = try await currentSocialEvent(context, surface: .display, organizer: true)
        try plan.validate(event: current)
        struct Body: Encodable { let expectedRevision, expectedParticipationRevision, expectedPlanRevision: Int; let plan: NativeDisplayPlan }
        struct Receipt: Decodable { let revision: Int; let plan: NativeDisplayPlan }
        let data = try JSONEncoder().encode(Body(expectedRevision: context.revision, expectedParticipationRevision: context.participationRevision,
            expectedPlanRevision: snapshot.revision, plan: plan))
        guard data.count <= 65536 else { throw BackpackError.invalid("Display plans must fit the 65,536 byte contract.") }
        let result = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.display, context.path + "/display-plan", method: "PUT", body: data))
        guard result.revision >= snapshot.revision, result.plan == plan else { throw BackpackError.invalid("Display plan save was not confirmed.") }
    }
    func consentEventDisplay(_ event: CatalogEvent, snapshot: NativeEventDisplay, consent: Bool) async throws {
        let context = try NativeEventSocialContext(event); try snapshot.validate(context)
        _ = try await currentSocialEvent(context, surface: .display)
        guard consent, snapshot.plan.enabled, snapshot.revision > 0 else { throw BackpackError.invalid("Review a saved enabled plan and explicitly opt in.") }
        struct Body: Encodable {
            let expectedRevision, expectedParticipationRevision, expectedPlanRevision, expectedOptinRevision: Int
            let enabled = true
        }
        struct Receipt: Decodable { let revision: Int; let enabled: Bool }
        let result = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.display, context.path + "/display-plan/consent", method: "POST",
            body: JSONEncoder().encode(Body(expectedRevision: context.revision, expectedParticipationRevision: context.participationRevision,
                expectedPlanRevision: snapshot.revision, expectedOptinRevision: snapshot.optinRevision))))
        guard result.enabled, result.revision >= snapshot.optinRevision else { throw BackpackError.invalid("Display consent was not confirmed.") }
    }
    func guestbookPreferences(_ event: CatalogEvent) async throws -> NativeGuestbookPreferences {
        try checkEventSurface(.guestbook, event: event)
        return try JSONDecoder().decode(NativeGuestbookPreferences.self, from: await socialEventData(.guestbook,
            "events/\(event.id.uuidString.lowercased())/guestbook/preferences"))
    }
    func saveGuestbookPreferences(_ event: CatalogEvent, snapshot: NativeGuestbookPreferences, enabled: Bool) async throws {
        let context = try NativeEventSocialContext(event)
        _ = try await currentSocialEvent(context, surface: .guestbook, organizer: true)
        guard snapshot.canManage else { throw BackpackError.invalid("Current organizer settings access is required.") }
        struct Body: Encodable {
            let expectedRevision, expectedParticipationRevision, expectedPreferencesRevision: Int; let enabled: Bool
        }
        struct Receipt: Decodable { let revision: Int; let enabled: Bool }
        let result = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.guestbook, context.path + "/guestbook/preferences", method: "PATCH",
            body: JSONEncoder().encode(Body(expectedRevision: context.revision, expectedParticipationRevision: context.participationRevision,
                expectedPreferencesRevision: snapshot.revision, enabled: enabled))))
        guard result.enabled == enabled, result.revision >= snapshot.revision else { throw BackpackError.invalid("Guestbook preference change was not confirmed.") }
    }
    func eventGuestbook(_ event: CatalogEvent, page: Int) async throws -> NativeGuestbookPage {
        try checkEventSurface(.guestbook, event: event)
        guard (1...17).contains(page) else { throw BackpackError.invalid("Guestbook pages must be 1–17.") }
        let context = try NativeEventSocialContext(event)
        let result = try JSONDecoder().decode(NativeGuestbookPage.self, from: await socialEventData(.guestbook, context.path + "/guestbook",
            query: context.query + [.init(name: "page", value: String(page))]))
        guard result.page == page, result.posts.count <= 24 else { throw BackpackError.invalid("Invalid guestbook page.") }
        for post in result.posts { try post.validate() }
        let serverNow = try CatalogEventTime.parse(event.serverTime)
        for post in result.posts {
            guard try NativeGuestbookRetention.expiresAt(createdAtISO: post.createdAtISO) > serverNow else {
                throw BackpackError.invalid("A guestbook post exceeded server-clock logical retention. Reload; no content was retained.")
            }
        }
        return result
    }
    func submitGuestbook(_ intent: NativeGuestbookSubmission) async throws -> NativeGuestbookPost {
        _ = try await currentSocialEvent(intent.context, surface: .guestbook)
        struct Receipt: Decodable { let post: NativeGuestbookPost }
        let result = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.guestbook, intent.context.path + "/guestbook",
            method: "POST", body: intent.data)).post
        try result.validate()
        guard result.own else { throw BackpackError.invalid("Guestbook receipt was not owned by the account.") }
        return result
    }
    func moderateGuestbook(_ event: CatalogEvent, post: NativeGuestbookPost, approved: Bool) async throws {
        let context = try NativeEventSocialContext(event)
        _ = try await currentSocialEvent(context, surface: .guestbook, organizer: true)
        guard post.canModerate else { throw BackpackError.invalid("Current organizer moderation is required; admin status is not enough.") }
        struct Body: Encodable {
            let expectedRevision, expectedParticipationRevision, expectedPostRevision: Int; let approved: Bool
        }
        struct Receipt: Decodable { let post: NativeGuestbookPost }
        let result = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.guestbook,
            context.path + "/guestbook/\(post.id.uuidString.lowercased())", method: "PATCH",
            body: JSONEncoder().encode(Body(expectedRevision: context.revision, expectedParticipationRevision: context.participationRevision,
                expectedPostRevision: post.revision, approved: approved)))).post
        try result.validate()
        guard result.id == post.id, result.state == (approved ? "approved" : "rejected"), result.revision >= post.revision else {
            throw BackpackError.invalid("Guestbook moderation was not confirmed.")
        }
    }
    func ownedGuestbook(page: Int) async throws -> NativeOwnedGuestbookPage {
        guard (1...1000).contains(page) else { throw BackpackError.invalid("Invalid owned guestbook page.") }
        let result = try JSONDecoder().decode(NativeOwnedGuestbookPage.self, from: await socialEventData(.guestbook, "social/guestbook-posts",
            query: [.init(name: "page", value: String(page))]))
        guard result.page == page, result.posts.count <= 24, result.posts.allSatisfy({ $0.revision > 0 }) else {
            throw BackpackError.invalid("Invalid owned guestbook receipt page.")
        }
        return result
    }
    func withdrawGuestbook(eventID: UUID, postID: UUID, revision: Int) async throws {
        struct Body: Encodable { let expectedPostRevision: Int }
        struct Receipt: Decodable { let withdrawn: Bool; let revision: Int }
        let value = try JSONDecoder().decode(Receipt.self, from: await socialEventData(.guestbook,
            "events/\(eventID.uuidString.lowercased())/guestbook/\(postID.uuidString.lowercased())", method: "DELETE",
            body: JSONEncoder().encode(Body(expectedPostRevision: revision))))
        guard value.withdrawn, value.revision >= revision else { throw BackpackError.invalid("Owned post withdrawal was not confirmed.") }
    }
    func eventRecap(_ event: CatalogEvent, page: Int) async throws -> NativeEventRecap {
        try checkEventSurface(.recap, event: event)
        guard event.access.canViewRecap == true, event.moderation?.held != true, (1...1000).contains(page) else {
            throw BackpackError.invalid("Current owner-only recap authority is unavailable.")
        }
        let context = try NativeEventSocialContext(event)
        let value = try JSONDecoder().decode(NativeEventRecap.self, from: await socialEventData(.recap, context.path + "/recap",
            query: context.query + [.init(name: "page", value: String(page))]))
        try value.validate(context, page: page); return value
    }
}
