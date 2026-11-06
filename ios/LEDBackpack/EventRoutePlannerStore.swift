import Foundation
import Combine
import BackpackProtocol

extension EventRouteCheckpoint {
    var artwork: RouteArtworkReference? {
        if let gifItemId { return .community(gifItemId) }
        if let exclusiveGifId { return .exclusive(exclusiveGifId) }
        return nil
    }
}
extension EventRouteReward {
    var artwork: RouteArtworkReference? {
        if let gifItemId { return .community(gifItemId) }
        if let exclusiveGifId { return .exclusive(exclusiveGifId) }
        return nil
    }
}

@MainActor
final class EventRoutePlannerStore: ObservableObject {
    @Published var draft: EventRouteDraft?
    @Published private(set) var choices: [RouteArtworkReference: RouteArtworkChoice] = [:]
    @Published private(set) var unavailable: Set<RouteArtworkReference> = []
    @Published private(set) var latest: CatalogEvent?
    @Published private(set) var conflict = false
    @Published private(set) var readOnly = false
    @Published private(set) var structureLocked = false
    @Published private(set) var loadingArtwork = false
    @Published private(set) var saving = false
    let session = CommunityFeatureSession()
    private var scope: UUID?
    func bind(_ community: CommunityController, event: CatalogEvent) {
        session.bind(community)
        scope = session.client?.instanceID
        do {
            guard let client = session.client else { throw BackpackError.invalid("Refresh your account first.") }
            try client.checkPlanner()
            guard event.organizers.contains(where: { $0.id == client.accountID && $0.eventRole == .owner }) else {
                throw BackpackError.invalid("This route draft belongs to a different account.")
            }
            draft = try EventRouteDraft(event)
            readOnly = false; conflict = false; structureLocked = false; latest = event
            resolveArtwork()
        } catch { readOnly = true; report(error) }
    }
    func report(_ error: Error) { session.run { _ in throw error } }
    func clear() {
        session.clear(); draft = nil; choices = [:]; unavailable = []; latest = nil; scope = nil; readOnly = true
        loadingArtwork = false; saving = false; conflict = false; structureLocked = false
    }
    private func readCurrent(_ client: CommunityFeatureClient, id: UUID) async throws -> CatalogEvent {
        let event: CatalogEvent
        do { event = try await client.event(id) }
        catch let error as CommunityFailure where [403, 404].contains(error.status) {
            readOnly = true; draft = nil; latest = nil; choices = [:]; unavailable = []
            throw error
        }
        try session.checked(client); try client.checkPlanner()
        latest = event
        guard !event.cancelled, event.access.role == .owner, event.access.canManageRoute else {
            readOnly = true; draft = nil; choices = [:]; unavailable = []
            throw BackpackError.invalid("Route owner permission is unavailable. Planning data was cleared; nothing was saved.")
        }
        return event
    }
    func refreshPermission() {
        guard let draft, !session.busy else { return }
        session.run(expected: scope) { client in
            let event = try await self.readCurrent(client, id: draft.original.id)
            self.conflict = event.revision != draft.original.revision
        }
    }
    func reloadDiscardingDraft(reviewedRevision: Int) {
        guard let latest, latest.revision == reviewedRevision else {
            report(BackpackError.invalid("The server version changed again. Review it before discarding your draft.")); return
        }
        do {
            draft = try EventRouteDraft(latest); conflict = false; readOnly = false; structureLocked = false
            choices = [:]; unavailable = []; resolveArtwork()
        } catch { readOnly = true; report(error) }
    }
    func resolveArtwork() {
        guard let draft else { return }
        loadingArtwork = true
        let references = Set(draft.checkpoints.compactMap(\.artwork) + draft.rewards.compactMap(\.artwork))
        session.run(expected: scope, { client in
            defer { self.loadingArtwork = false }
            let current = try await self.readCurrent(client, id: draft.original.id)
            self.conflict = current.revision != draft.original.revision
            var resolved: [RouteArtworkReference: RouteArtworkChoice] = [:]
            var missing: Set<RouteArtworkReference> = []
            if client.exclusiveRouteEnabled(current) {
                let items = try await client.routeExclusives(current)
                for item in items {
                    resolved[.exclusive(item.id)] = RouteArtworkChoice(reference: .exclusive(item.id), title: item.title, previewURL: item.previewUrl)
                }
            }
            for reference in references {
                switch reference {
                case .community(let id):
                    do {
                        let value = try await client.routeCommunityItem(id)
                        if value.eligible {
                            resolved[reference] = RouteArtworkChoice(reference: reference, title: value.item.title, previewURL: value.item.previewUrl)
                        } else { missing.insert(reference) }
                    } catch let error as CommunityFailure where error.status == 404 { missing.insert(reference) }
                case .exclusive:
                    if resolved[reference] == nil { missing.insert(reference) }
                }
            }
            try self.session.checked(client)
            self.choices = resolved; self.unavailable = missing; self.loadingArtwork = false
        }, success: {})
    }
    func save(done: @escaping () -> Void) {
        guard let draft, !readOnly, !conflict else {
            report(BackpackError.invalid("Review current permissions and explicitly reload a changed event before saving.")); return
        }
        let references = Set(draft.checkpoints.compactMap(\.artwork) + draft.rewards.compactMap(\.artwork))
        guard !loadingArtwork, references.allSatisfy({ choices[$0] != nil && !unavailable.contains($0) }) else {
            report(BackpackError.invalid("Replace or remove unavailable artwork before saving. Sources are never substituted.")); return
        }
        guard !structureLocked || draft.fixedGeometryMatchesOriginal else {
            report(BackpackError.invalid("Explicitly restore the captured locked geometry before saving artwork/reward repairs.")); return
        }
        saving = true
        session.run(expected: scope, { client in
            defer { self.saving = false }
            let current = try await self.readCurrent(client, id: draft.original.id)
            guard current.revision == draft.original.revision else {
                self.conflict = true
                throw CommunityFailure(status: 409, code: "event_revision_conflict", message: "The event changed. Your draft is retained; review and reload explicitly.")
            }
            do {
                if draft.checkpoints.contains(where: { $0.exclusiveGifId != nil }) || draft.rewards.contains(where: { $0.exclusiveGifId != nil }) {
                    guard client.exclusiveRouteEnabled(current) else { throw BackpackError.invalid("Protected artwork references are no longer available.") }
                }
                _ = try await client.saveRoute(draft)
            } catch let error as CommunityFailure where error.status == 409 {
                if error.code == "event_route_locked" { self.structureLocked = true }
                else { self.conflict = true; self.latest = nil }
                throw error
            }
        }, success: done)
    }
    func operationEnded() {
        saving = false
        if session.failure != nil { loadingArtwork = false }
    }
    func remember(_ choice: RouteArtworkChoice) { choices[choice.reference] = choice; unavailable.remove(choice.reference) }
    func artworkLabel(_ reference: RouteArtworkReference?) -> String {
        guard let reference else { return "No artwork" }
        guard let choice = choices[reference], !unavailable.contains(reference) else {
            switch reference { case .community: return "Unavailable community artwork"; case .exclusive: return "Unavailable event-exclusive artwork" }
        }
        switch reference { case .community: return "\(choice.title) (community)"; case .exclusive: return "\(choice.title) (event-exclusive)" }
    }
}
