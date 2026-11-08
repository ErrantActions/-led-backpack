import Foundation
import BackpackProtocol

enum GentlePlanPattern: String, Codable, CaseIterable {
    case solid, gentlePulse = "gentle-pulse", alternate
}
enum GentlePlanPolicy {
    static func validate(colors: [String], period: Int = 4000) throws {
        guard (1...4).contains(colors.count), (2000...60000).contains(period),
              colors.allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }) else {
            throw BackpackError.invalid("Use 1–4 #RRGGBB colors and a 2–60 second gentle period.")
        }
    }
}
enum NativeEventSocialContextFailure: LocalizedError {
    case changed, denied, unavailable
    var errorDescription: String? {
        switch self {
        case .changed: return "Event/review revisions changed. Reload deliberately; no stale action was retried."
        case .denied: return "Current event role, participation review, cancellation or moderation does not permit this action."
        case .unavailable: return "This server/event has not enabled this capability. Nothing was activated."
        }
    }
}
struct NativeEventSocialContext: Equatable {
    let eventID: UUID
    let revision, participationRevision: Int
    init(_ event: CatalogEvent) throws {
        guard let participation = event.participationRevision, participation > 0 else {
            throw BackpackError.invalid("The server did not supply a current participation revision.")
        }
        eventID = event.id; revision = event.revision; participationRevision = participation
    }
    var path: String { "events/\(eventID.uuidString.lowercased())" }
    var query: [URLQueryItem] {
        [URLQueryItem(name: "expectedRevision", value: String(revision)),
         URLQueryItem(name: "expectedParticipationRevision", value: String(participationRevision))]
    }
    func check(_ event: CatalogEvent, participant: Bool = false, organizer: Bool = false) throws {
        guard event.moderation?.held != true, !event.cancelled,
              !organizer || event.access.canManage,
              !participant || (event.requiresReconfirmation == false &&
                  (event.access.canManage || event.rsvpStatus == .going)) else {
            throw NativeEventSocialContextFailure.denied
        }
        guard try Self(event) == self else { throw NativeEventSocialContextFailure.changed }
    }
    func check(eventID: UUID, eventRevision: Int, participationRevision: Int) throws {
        guard self.eventID == eventID, revision == eventRevision, self.participationRevision == participationRevision else {
            throw BackpackError.invalid("The response belongs to a different event/review revision.")
        }
    }
}
struct NativeEventTeam: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var colors = ["#55CCAA"]
    var pattern = GentlePlanPattern.solid
    var periodMilliseconds = 4000
    func validate() throws {
        guard (1...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) else {
            throw BackpackError.invalid("Name each team using 1–80 characters.")
        }
        try GentlePlanPolicy.validate(colors: colors, period: periodMilliseconds)
    }
}
struct NativeEventTeams: Decodable {
    let eventId: UUID
    let eventRevision, participationRevision, revision, optinRevision: Int
    let teams: [NativeEventTeam]
    let ownTeamId: UUID?
    let canManage, participantRosterIncluded, synchronizedPlaybackVerified: Bool
    func validate(_ context: NativeEventSocialContext) throws {
        try context.check(eventID: eventId, eventRevision: eventRevision, participationRevision: participationRevision)
        guard revision >= 0, optinRevision >= 0, teams.count <= 16,
              Set(teams.map(\.id)).count == teams.count, !participantRosterIncluded, !synchronizedPlaybackVerified,
              ownTeamId == nil || teams.contains(where: { $0.id == ownTeamId }) else {
            throw BackpackError.invalid("Invalid palette/own choice or unexpected roster/playback claim.")
        }
        for team in teams { try team.validate() }
    }
}
struct NativeCollectionPlan: Codable, Equatable {
    var enabled = false
    var checkpointIds: [UUID] = []
    var cooperativeGoal: Int? = nil
    var celebrationColors = ["#55CCAA"]
    var celebrationPattern = GentlePlanPattern.solid
    private enum CodingKeys: String, CodingKey { case enabled, checkpointIds, cooperativeGoal, celebrationColors, celebrationPattern }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(checkpointIds, forKey: .checkpointIds)
        if let cooperativeGoal { try c.encode(cooperativeGoal, forKey: .cooperativeGoal) }
        else { try c.encodeNil(forKey: .cooperativeGoal) }
        try c.encode(celebrationColors, forKey: .celebrationColors); try c.encode(celebrationPattern, forKey: .celebrationPattern)
    }
    func validate(event: CatalogEvent) throws {
        guard checkpointIds.count <= 50, Set(checkpointIds).count == checkpointIds.count,
              !enabled || (event.visibility == "public" && event.route?.published == true && !checkpointIds.isEmpty),
              checkpointIds.allSatisfy({ id in event.route?.checkpoints.contains(where: { $0.id == id && $0.kind == .checkpoint }) == true }),
              cooperativeGoal == nil || (5...10000).contains(cooperativeGoal ?? 0) else {
            throw BackpackError.invalid("Choose current published checkpoint targets and an optional goal of 5–10,000. Enabled hunts require a public event.")
        }
        try GentlePlanPolicy.validate(colors: celebrationColors)
    }
}
struct NativeEventCollection: Decodable {
    struct Checkpoint: Decodable, Identifiable {
        let id: UUID
        let title: String
        let collected: Bool
    }
    let eventId: UUID
    let eventRevision, participationRevision, revision, optinRevision: Int
    let plan: NativeCollectionPlan
    let ownEnabled, ownCooperativeConsent, ownCompleted, cooperativeReached, canManage: Bool
    let contributorIdentitiesIncluded, exactContributorCountIncluded, certified, gpsUsed: Bool
    let checkpoints: [Checkpoint]
    func validate(_ context: NativeEventSocialContext) throws {
        try context.check(eventID: eventId, eventRevision: eventRevision, participationRevision: participationRevision)
        guard revision >= 0, optinRevision >= 0, checkpoints.count <= 50,
              Set(checkpoints.map(\.id)).count == checkpoints.count,
              checkpoints.allSatisfy({ plan.checkpointIds.contains($0.id) }),
              !contributorIdentitiesIncluded, !exactContributorCountIncluded, !certified, !gpsUsed,
              !ownCooperativeConsent || ownEnabled, !ownCompleted || ownEnabled else {
            throw BackpackError.invalid("Invalid private collection/cooperative response.")
        }
    }
    func permitsManualCollection(_ checkpointID: UUID, event: CatalogEvent) -> Bool {
        guard ownEnabled, plan.enabled, event.route?.published == true else { return false }
        return checkpoints.contains(where: { $0.id == checkpointID && !$0.collected }) ||
            (ownCompleted && event.route?.checkpoints.contains(where: { $0.id == checkpointID && $0.kind == .finish }) == true)
    }
    var ownCollectedTargetCount: Int { checkpoints.filter(\.collected).count }
    func remainingTargets(event: CatalogEvent) -> [EventRouteCheckpoint] {
        (event.route?.checkpoints ?? []).filter { permitsManualCollection($0.id, event: event) }
            .sorted { $0.order < $1.order }
    }
    func requireClaimReadback(_ checkpointID: UUID, event: CatalogEvent, previous: NativeEventCollection) throws {
        try validate(NativeEventSocialContext(event))
        guard eventId == previous.eventId, eventRevision == previous.eventRevision,
              participationRevision == previous.participationRevision, revision == previous.revision,
              optinRevision == previous.optinRevision, plan == previous.plan, ownEnabled,
              previous.permitsManualCollection(checkpointID, event: event) else {
            throw BackpackError.invalid("Private hunt context changed before receipt/read-back; no confirmed collection.")
        }
        if event.route?.checkpoints.contains(where: { $0.id == checkpointID && $0.kind == .finish }) == true {
            guard ownCompleted else { throw BackpackError.invalid("Finish prerequisites are no longer confirmed.") }
        } else {
            guard checkpoints.contains(where: { $0.id == checkpointID && $0.collected }) else {
                throw BackpackError.invalid("The selected private target was not confirmed by current hunt read-back.")
            }
        }
    }
}
struct NativeDisplayScene: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case opening, closing, restStop = "rest-stop" }
    var id = UUID()
    var name = ""
    var kind = Kind.opening
    var checkpointId: UUID?
    var regroupPrompt: String?
    var offsetSeconds = 0
    var durationSeconds = 30
    var colors = ["#55CCAA"]
    var pattern = GentlePlanPattern.solid
    var periodMilliseconds = 4000
    var playlist: NativePublicPlaylistContent?
    func validate(event: CatalogEvent) throws {
        guard (1...100).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count),
              (-3600...3600).contains(offsetSeconds), (2...600).contains(durationSeconds),
              (regroupPrompt?.utf16.count ?? 0) <= 200,
              (kind == .restStop ? event.route?.checkpoints.contains(where: { $0.id == checkpointId }) == true :
                checkpointId == nil && regroupPrompt == nil) else {
            throw BackpackError.invalid("Review scene name, timing and named manual rest-stop checkpoint.")
        }
        try GentlePlanPolicy.validate(colors: colors, period: periodMilliseconds)
        try playlist?.validate(maxEntries: 24)
    }
}
struct NativeDisplayPlan: Codable, Equatable {
    var enabled = false
    var scenes: [NativeDisplayScene] = []
    func validate(event: CatalogEvent) throws {
        guard scenes.count <= 24, Set(scenes.map(\.id)).count == scenes.count else {
            throw BackpackError.invalid("Use at most 24 distinct named scenes.")
        }
        for scene in scenes { try scene.validate(event: event) }
    }
}
struct NativeDisplayCue: Decodable, Identifiable {
    let id: UUID
    let name: String
    let kind: NativeDisplayScene.Kind
    let checkpointId: UUID?
    let regroupPrompt: String?
    let offsetSeconds, durationSeconds, periodMilliseconds: Int
    let colors: [String]
    let pattern: GentlePlanPattern
    let playlist: NativePublicPlaylistContent?
    let manuallySelected: Bool
    let startsAtISO: String?
    let phaseMilliseconds: Double?
}
struct NativeEventDisplay: Decodable {
    struct ScenePlaylist: Decodable {
        let sceneId: UUID
        let order: NativePlaylistOrder
        let entries: [NativeHydratedPlaylistEntry]
    }
    let eventId: UUID
    let eventRevision, participationRevision, revision, optinRevision: Int
    let plan: NativeDisplayPlan
    let ownEnabled, canManage, gpsUsed, synchronizedPlaybackVerified, safetyMonitoring: Bool
    let serverTimeISO: String
    let cues: [NativeDisplayCue]
    let scenePlaylists: [ScenePlaylist]
    func validate(_ context: NativeEventSocialContext) throws {
        try context.check(eventID: eventId, eventRevision: eventRevision, participationRevision: participationRevision)
        _ = try CatalogEventTime.parse(serverTimeISO)
        guard revision >= 0, optinRevision >= 0, !gpsUsed, !synchronizedPlaybackVerified, !safetyMonitoring,
              ownEnabled || cues.isEmpty, cues.count <= 24,
              Set(cues.map(\.id)).count == cues.count,
              scenePlaylists.count <= 24, Set(scenePlaylists.map(\.sceneId)).count == scenePlaylists.count else {
            throw BackpackError.invalid("Invalid display plan consent/privacy context.")
        }
        let serverTime = try CatalogEventTime.parse(serverTimeISO)
        for cue in cues {
            guard let scene = plan.scenes.first(where: { $0.id == cue.id }),
                  cue.name == scene.name, cue.kind == scene.kind, cue.colors == scene.colors,
                  cue.pattern == scene.pattern, cue.durationSeconds == scene.durationSeconds,
                  cue.offsetSeconds == scene.offsetSeconds,
                  cue.periodMilliseconds == scene.periodMilliseconds, cue.checkpointId == scene.checkpointId,
                  cue.regroupPrompt == scene.regroupPrompt, cue.playlist == scene.playlist,
                  cue.manuallySelected == (scene.kind == .restStop) else {
                throw BackpackError.invalid("Cue is not part of the current authorized saved scene.")
            }
            if !cue.manuallySelected {
                guard let start = cue.startsAtISO, let phase = cue.phaseMilliseconds, phase.isFinite,
                      phase >= 0, phase < Double(cue.durationSeconds) * 1000 else { throw BackpackError.invalid("Invalid server cue phase.") }
                let anchor = try CatalogEventTime.parse(start)
                guard serverTime >= anchor, serverTime < anchor.addingTimeInterval(Double(cue.durationSeconds)) else {
                    throw BackpackError.invalid("Clock cue is outside its returned server-time window.")
                }
            }
        }
        for list in scenePlaylists {
            guard let references = plan.scenes.first(where: { $0.id == list.sceneId })?.playlist,
                  list.order == references.order, list.entries.count == references.entries.count else {
                throw BackpackError.invalid("Scene playlist hydration does not match the saved scene.")
            }
            for (reference, entry) in zip(references.entries, list.entries) {
                try entry.validate()
                guard reference.durationMilliseconds == entry.durationMilliseconds,
                      entry.item == nil || entry.item?.id == reference.itemId else { throw BackpackError.invalid("Scene item membership changed.") }
            }
        }
    }
}
/// An ephemeral foreground preview authorization, not a media/transport grant.
struct NativeEventPlanPreview {
    let id = UUID()
    let accountID, accountEpoch: UUID
    let context: NativeEventSocialContext
    let planRevision, optinRevision: Int
    let manualCheckpointID: UUID?
    let snapshot: NativeEventDisplay
    let clock: CatalogEventClock
    let endsAt: Date
    var validUntil: Date { min(endsAt, clock.serverTime.addingTimeInterval(30)) }
    func currentCues() -> [NativeDisplayCue] {
        let now = clock.now()
        guard now < validUntil else { return [] }
        return snapshot.cues.filter { cue in
            if cue.manuallySelected {
                return cue.checkpointId == manualCheckpointID &&
                    now < clock.serverTime.addingTimeInterval(Double(cue.durationSeconds))
            }
            guard let raw = cue.startsAtISO, let start = try? CatalogEventTime.parse(raw) else { return false }
            return now >= start && now < start.addingTimeInterval(Double(cue.durationSeconds))
        }
    }
}
enum NativeGuestbookReaction: String, Codable, CaseIterable { case cheer, love, thanks, wow }
enum NativeGuestbookRetention {
    static let seconds: TimeInterval = 90 * 24 * 60 * 60
    static func expiresAt(createdAtISO: String) throws -> Date {
        try CatalogEventTime.parse(createdAtISO).addingTimeInterval(seconds)
    }
}
struct NativeGuestbookPreferences: Decodable {
    let revision: Int
    let enabled, canManage: Bool
}
struct NativeGuestbookPost: Decodable, Identifiable {
    struct Image: Decodable { let url: URL?; let alt: String?; let unavailable: Bool? }
    let id: UUID
    let revision: Int
    let state: String
    let `public`, shareAuthor, own, canModerate: Bool
    let text: String
    let reaction: NativeGuestbookReaction
    let createdAtISO: String
    let authorName: String?
    let image: Image?
    func validate() throws {
        guard revision > 0, ["pending", "approved", "rejected", "withdrawn"].contains(state),
              text.utf16.count <= 1000, shareAuthor || authorName == nil,
              image?.unavailable != true || image?.url == nil else {
            throw BackpackError.invalid("Invalid guestbook post/audience/reference.")
        }
        _ = try CatalogEventTime.parse(createdAtISO)
    }
}
struct NativeGuestbookPage: Decodable {
    let posts: [NativeGuestbookPost]
    let page: Int
    let hasMore, canPost, canModerate: Bool
}
struct NativeOwnedGuestbookPost: Decodable, Identifiable {
    let id, eventId: UUID
    let revision: Int
    let state, text, createdAtISO: String
    let reaction: NativeGuestbookReaction
    let imageId: UUID?
}
struct NativeOwnedGuestbookPage: Decodable {
    let posts: [NativeOwnedGuestbookPost]
    let page: Int
    let hasMore: Bool
}
struct NativeGuestbookDraft: Equatable {
    var text = ""
    var reaction = NativeGuestbookReaction.cheer
    var imageID: UUID?
    var publicSharing = false
    var shareAuthor = false
    var consent = false
    func validate(event: CatalogEvent, gallery: [NativeEventImage]) throws {
        guard consent, text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 1000,
              !publicSharing || event.visibility == "public",
              imageID == nil || gallery.contains(where: { $0.id == imageID && $0.approved }) else {
            throw BackpackError.invalid("Explicitly consent and choose a current reviewed photo; public sharing is only for public events.")
        }
    }
}
struct NativeGuestbookSubmission {
    let context: NativeEventSocialContext
    let preferencesRevision: Int
    let clientMessageID: UUID
    let draft: NativeGuestbookDraft
    let data: Data
    init(event: CatalogEvent, preferences: NativeGuestbookPreferences, draft: NativeGuestbookDraft,
         gallery: [NativeEventImage]) throws {
        try draft.validate(event: event, gallery: gallery)
        guard preferences.enabled, preferences.revision > 0 else { throw BackpackError.invalid("Load an enabled current guestbook first.") }
        context = try NativeEventSocialContext(event); preferencesRevision = preferences.revision
        self.draft = draft; clientMessageID = UUID()
        struct Body: Encodable {
            let text: String; let reaction: NativeGuestbookReaction; let imageId: UUID?
            let `public`, shareAuthor: Bool
            let consent = true
            let clientMessageId: UUID
            let expectedRevision, expectedParticipationRevision, expectedPreferencesRevision: Int
        }
        data = try JSONEncoder().encode(Body(text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
            reaction: draft.reaction, imageId: draft.imageID, public: draft.publicSharing, shareAuthor: draft.shareAuthor,
            clientMessageId: clientMessageID, expectedRevision: context.revision,
            expectedParticipationRevision: context.participationRevision, expectedPreferencesRevision: preferences.revision))
    }
}
struct NativeEventRecap: Decodable {
    struct Artwork: Decodable {
        let kind, label: String
        let available: Bool
        let id: UUID?
    }
    struct Progress: Decodable {
        struct Checkpoint: Decodable { let id: UUID; let title: String; let kind: EventCheckpointKind }
        let source: String
        let certified, completed: Bool
        let checkpoint: Checkpoint?
    }
    let eventId: UUID
    let revision, participationRevision, page: Int
    let serverTime: String
    let status: CatalogEventStatus
    let hasMore, localOnlyProgressIncluded, filesDownloadedVerified: Bool
    let awards: [NativeOwnedEventBadge]
    let artworkReferences: [Artwork]
    let progress: Progress
    func validate(_ context: NativeEventSocialContext, page: Int) throws {
        try context.check(eventID: eventId, eventRevision: revision, participationRevision: participationRevision)
        guard self.page == page, awards.count <= 24, !localOnlyProgressIncluded, !filesDownloadedVerified,
              progress.source == "self-reported", !progress.certified,
              artworkReferences.allSatisfy({ $0.available || $0.id == nil }) else {
            throw BackpackError.invalid("Invalid owner recap/privacy context.")
        }
        _ = try CatalogEventTime.parse(serverTime)
        for award in awards { try award.validate() }
    }
}
