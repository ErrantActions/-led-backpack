import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
final class EventSocialSourceTests: XCTestCase {
    private let eventID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let targetID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let finishID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    private let teamID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    private func event(revision: Int = 7, participation: Int = 3, owner: Bool = false,
                       review: Bool = false, visibility: String = "public", held: Bool = false,
                       cancelled: Bool = false) throws -> CatalogEvent {
        try decode(CatalogEvent.self, eventObject(revision: revision, participation: participation, owner: owner,
            review: review, visibility: visibility, held: held, cancelled: cancelled))
    }
    private func eventObject(revision: Int = 7, participation: Int = 3, owner: Bool = false,
                             review: Bool = false, visibility: String = "public", held: Bool = false,
                             cancelled: Bool = false) -> [String: Any] {
        let role: Any = owner ? "owner" as Any : NSNull()
        return [
            "id": eventID.uuidString, "title": "Named event", "description": "Planned, not verified attendance",
            "startsAtISO": "2026-11-06T12:00:00Z", "endsAtISO": "2026-11-07T12:00:00Z",
            "timezone": "UTC", "visibility": visibility, "serverTime": "2026-11-06T13:00:00Z",
            "capacity": 20, "revision": revision, "cancelled": cancelled, "status": cancelled ? "cancelled" : "in-progress",
            "moderation": ["revision": held ? 1 : 0, "held": held],
            "location": ["label": "Fixed venue", "latitude": 1, "longitude": 2, "radiusMeters": 10],
            "rsvpStatus": "going", "organizers": [], "participationRevision": participation,
            "requiresReconfirmation": review,
            "access": ["role": role, "invited": false, "member": true,
                       "canManage": owner, "canManageRoute": owner, "canRsvp": !held, "canViewProgress": !held,
                       "canChooseTeam": true, "canViewRecap": true],
            "route": ["published": true, "geometry": [], "checkpoints": [
                ["id": "10000000-0000-4000-8000-000000000005", "title": "Start", "kind": "start",
                 "latitude": 1, "longitude": 2, "radiusMeters": 10, "order": 0],
                ["id": targetID.uuidString, "title": "Named target", "kind": "checkpoint",
                 "latitude": 1, "longitude": 2, "radiusMeters": 10, "order": 1],
                ["id": finishID.uuidString, "title": "Finish", "kind": "finish",
                 "latitude": 1, "longitude": 2, "radiusMeters": 10, "order": 2]]],
            "badges": [],
            "settings": ["exclusiveArtworkReferences": false, "eventTeamsEnabled": true,
                         "eventCollectionsEnabled": true, "eventDisplayPlanningEnabled": true,
                         "eventGuestbookAvailable": true, "eventGuestbookEnabled": false, "eventRecapsEnabled": true]
        ]
    }
    private func teams(roster: Bool = false, own: UUID? = nil, revision: Int = 7) throws -> NativeEventTeams {
        try decode(NativeEventTeams.self, [
            "eventId": eventID.uuidString, "eventRevision": revision, "participationRevision": 3,
            "revision": 2, "optinRevision": 4,
            "teams": [["id": teamID.uuidString, "name": "Mint group", "colors": ["#55CCAA"],
                       "pattern": "gentle-pulse", "periodMilliseconds": 4000]],
            "ownTeamId": own?.uuidString as Any? ?? NSNull(), "canManage": false,
            "participantRosterIncluded": roster, "synchronizedPlaybackVerified": false
        ])
    }
    private func collection(completed: Bool = false, enabled: Bool = true, exact: Bool = false,
        optin: Int = 4) throws -> NativeEventCollection {
        try decode(NativeEventCollection.self, [
            "eventId": eventID.uuidString, "eventRevision": 7, "participationRevision": 3,
            "revision": 2, "optinRevision": optin, "canManage": false,
            "plan": ["enabled": true, "checkpointIds": [targetID.uuidString], "cooperativeGoal": 5,
                     "celebrationColors": ["#55CCAA"], "celebrationPattern": "solid"],
            "ownEnabled": enabled, "ownCooperativeConsent": false, "ownCompleted": completed,
            "cooperativeReached": false, "contributorIdentitiesIncluded": false,
            "exactContributorCountIncluded": exact, "certified": false, "gpsUsed": false,
            "checkpoints": [["id": targetID.uuidString, "title": "Named target", "collected": completed]]
        ])
    }
    func testClaimReadbackRequiresSelectedTargetActuallyCollected() throws {
        let current = try event(), before = try collection()
        XCTAssertThrowsError(try before.requireClaimReadback(targetID, event: current, previous: before))
        XCTAssertNoThrow(try collection(completed: true).requireClaimReadback(targetID, event: current, previous: before))
        XCTAssertThrowsError(try collection(completed: true).requireClaimReadback(UUID(), event: current, previous: before))
    }
    func testClaimReadbackRejectsChangedOptinOrWithdrawnHunt() throws {
        let current = try event(), before = try collection()
        XCTAssertThrowsError(try collection(completed: true, optin: 5).requireClaimReadback(targetID, event: current, previous: before))
        XCTAssertThrowsError(try collection(enabled: false).requireClaimReadback(targetID, event: current, previous: before))
    }
    func testFinishReadbackUsesCompletedPrivatePrerequisitesNotGPSProof() throws {
        let current = try event(), completed = try collection(completed: true)
        XCTAssertNoThrow(try completed.requireClaimReadback(finishID, event: current, previous: completed))
        XCTAssertThrowsError(try collection().requireClaimReadback(finishID, event: current, previous: completed))
    }
    private func display(own: Bool = true, cues: [[String: Any]] = []) throws -> NativeEventDisplay {
        try decode(NativeEventDisplay.self, [
            "eventId": eventID.uuidString, "eventRevision": 7, "participationRevision": 3,
            "revision": 2, "optinRevision": 4, "plan": ["enabled": true, "scenes": []],
            "ownEnabled": own, "canManage": false, "gpsUsed": false, "synchronizedPlaybackVerified": false,
            "safetyMonitoring": false, "serverTimeISO": "2026-11-06T13:00:00Z",
            "cues": cues, "scenePlaylists": []
        ])
    }
    private func post(name: Any = NSNull(), shareAuthor: Bool = false, image: [String: Any]? = nil) throws -> NativeGuestbookPost {
        var object: [String: Any] = [
            "id": teamID.uuidString, "revision": 1, "state": "pending", "public": false,
            "shareAuthor": shareAuthor, "own": true, "canModerate": false, "text": "Typed thanks",
            "reaction": "thanks", "createdAtISO": "2026-11-06T13:00:00Z", "authorName": name
        ]
        if let image { object["image"] = image }
        return try decode(NativeGuestbookPost.self, object)
    }
    private func recap(reference: [String: Any], local: Bool = false) throws -> NativeEventRecap {
        try decode(NativeEventRecap.self, [
            "eventId": eventID.uuidString, "revision": 7, "participationRevision": 3, "page": 1,
            "serverTime": "2026-11-06T13:00:00Z", "status": "in-progress", "hasMore": false,
            "localOnlyProgressIncluded": local, "filesDownloadedVerified": false, "awards": [],
            "artworkReferences": [reference],
            "progress": ["source": "self-reported", "certified": false, "completed": false]
        ])
    }

    func testMissingFlagsDoNotEnableSourceFeatures() throws {
        let config = try decode(CommunityConfig.self, ["requireEmailVerification": false])
        XCTAssertNil(config.eventTeamsEnabled); XCTAssertNil(config.eventCollectionsEnabled)
        XCTAssertNil(config.eventDisplayPlanningEnabled); XCTAssertNil(config.eventGuestbookAvailable)
        XCTAssertNil(config.eventRecapsEnabled); XCTAssertNil(config.playlistsEnabled)
    }
    func testPaletteResponseBindsAllCurrentRevisions() throws {
        let snapshot = try teams(own: teamID)
        try snapshot.validate(NativeEventSocialContext(event()))
        XCTAssertEqual(snapshot.ownTeamId, teamID); XCTAssertEqual(snapshot.optinRevision, 4)
    }
    func testPaletteRosterClaimIsRejected() throws {
        XCTAssertThrowsError(try teams(roster: true).validate(NativeEventSocialContext(event())))
    }
    func testPaletteUnknownOwnChoiceIsRejected() throws {
        XCTAssertThrowsError(try teams(own: finishID).validate(NativeEventSocialContext(event())))
    }
    func testPaletteNameColorsAndGentlePeriodBounds() throws {
        var team = NativeEventTeam(name: "Mint")
        try team.validate()
        team.periodMilliseconds = 1999; XCTAssertThrowsError(try team.validate())
        team.periodMilliseconds = 4000; team.colors = ["red"]; XCTAssertThrowsError(try team.validate())
        team.colors = ["#55CCAA"]; team.name = " "; XCTAssertThrowsError(try team.validate())
    }
    func testOrganizerContextDoesNotInferAuthorityFromMembership() throws {
        let current = try event()
        XCTAssertThrowsError(try NativeEventSocialContext(current).check(current, organizer: true))
    }
    func testMaterialReviewInvalidatesParticipantIntent() throws {
        let current = try event(review: true)
        XCTAssertThrowsError(try NativeEventSocialContext(current).check(current, participant: true))
    }
    func testStaleEventRevisionInvalidatesCapturedIntent() throws {
        let context = try NativeEventSocialContext(event())
        XCTAssertThrowsError(try context.check(event(revision: 8), participant: true))
    }
    func testStaleParticipationRevisionInvalidatesCapturedIntent() throws {
        let context = try NativeEventSocialContext(event())
        XCTAssertThrowsError(try context.check(event(participation: 4), participant: true))
    }
    func testPaletteResponseFromChangedEventIsRejected() throws {
        XCTAssertThrowsError(try teams(revision: 8).validate(NativeEventSocialContext(event())))
    }
    func testCollectionDisabledCooperativeGoalEncodesExplicitNull() throws {
        let encoded = try JSONEncoder().encode(NativeCollectionPlan())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(object["cooperativeGoal"] is NSNull)
    }
    func testEnabledHuntCannotUsePrivateEvent() throws {
        var plan = NativeCollectionPlan(); plan.enabled = true; plan.checkpointIds = [targetID]
        XCTAssertThrowsError(try plan.validate(event: event(visibility: "private")))
    }
    func testHuntPlanUsesNamedCheckpointTargetsNotFinish() throws {
        var plan = NativeCollectionPlan(); plan.enabled = true; plan.checkpointIds = [finishID]
        XCTAssertThrowsError(try plan.validate(event: event()))
    }
    func testHuntPlanRejectsDuplicateTargets() throws {
        var plan = NativeCollectionPlan(); plan.enabled = true; plan.checkpointIds = [targetID, targetID]
        XCTAssertThrowsError(try plan.validate(event: event()))
    }
    func testAnyOrderUncollectedTargetIsManualChoice() throws {
        let value = try collection()
        XCTAssertTrue(try value.permitsManualCollection(targetID, event: event()))
        XCTAssertFalse(try value.permitsManualCollection(teamID, event: event()))
    }
    func testHuntFinishRequiresAllSelectedTargets() throws {
        XCTAssertFalse(try collection().permitsManualCollection(finishID, event: event()))
        XCTAssertTrue(try collection(completed: true).permitsManualCollection(finishID, event: event()))
    }
    func testNonOptedInLocalCollectionDoesNotContribute() throws {
        let value = try collection(enabled: false)
        XCTAssertFalse(value.ownCooperativeConsent); XCTAssertFalse(value.cooperativeReached)
        XCTAssertFalse(try value.permitsManualCollection(targetID, event: event()))
    }
    func testCooperativeResponseRejectsExactContributorDisclosure() throws {
        XCTAssertThrowsError(try collection(exact: true).validate(NativeEventSocialContext(event())))
    }
    func testGuestbookConsentAudienceAndNameDefaultOff() throws {
        let draft = NativeGuestbookDraft()
        XCTAssertFalse(draft.consent); XCTAssertFalse(draft.publicSharing); XCTAssertFalse(draft.shareAuthor)
        XCTAssertThrowsError(try draft.validate(event: event(), gallery: []))
    }
    func testPrivateGuestbookCannotPublishPublicNote() throws {
        var draft = NativeGuestbookDraft(); draft.consent = true; draft.publicSharing = true
        XCTAssertThrowsError(try draft.validate(event: event(visibility: "private"), gallery: []))
    }
    func testGalleryChoiceRequiresActuallyReviewedReference() throws {
        let image = try decode(NativeEventImage.self, ["id": teamID.uuidString, "caption": "Named photo",
            "alt": "Still image", "createdAt": "2026-11-06T13:00:00Z", "byteSize": 100, "revision": 1,
            "approved": false, "url": "/api/v1/events/image.png"])
        var draft = NativeGuestbookDraft(); draft.consent = true; draft.imageID = teamID
        XCTAssertThrowsError(try draft.validate(event: event(), gallery: [image]))
    }
    func testGuestbookWithheldNameDoesNotAcquireCachedIdentity() throws {
        let value = try post()
        try value.validate(); XCTAssertNil(value.authorName)
        XCTAssertThrowsError(try post(name: "Unexpected private name").validate())
    }
    func testUnavailableGuestbookImageCannotCarryURL() throws {
        XCTAssertThrowsError(try post(image: ["unavailable": true, "url": "/private.png"]).validate())
        try post(image: ["unavailable": true]).validate()
    }
    func testGuestbookImmutableRetryCapturesRevisionConsentAndMessageID() throws {
        let current = try event()
        let settings = NativeGuestbookPreferences(revision: 2, enabled: true, canManage: false)
        var draft = NativeGuestbookDraft(); draft.text = "Typed by owner"; draft.consent = true
        let intent = try NativeGuestbookSubmission(event: current, preferences: settings, draft: draft, gallery: [])
        let retryBytes = intent.data
        draft.text = "A later unsent edit"
        XCTAssertEqual(intent.data, retryBytes); XCTAssertEqual(intent.draft.text, "Typed by owner")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
        XCTAssertEqual(body["expectedRevision"] as? Int, 7)
        XCTAssertEqual(body["expectedParticipationRevision"] as? Int, 3)
        XCTAssertEqual(body["expectedPreferencesRevision"] as? Int, 2)
        XCTAssertEqual(body["consent"] as? Bool, true)
        XCTAssertNotNil(body["clientMessageId"]); XCTAssertNil(body["venue"]); XCTAssertNil(body["gps"])
    }
    func testGuestbookLogicalRetentionDoesNotExtendWithEventSchedule() throws {
        let created = try CatalogEventTime.parse("2026-11-06T13:00:00Z")
        let expires = try NativeGuestbookRetention.expiresAt(createdAtISO: "2026-11-06T13:00:00Z")
        XCTAssertEqual(expires.timeIntervalSince(created), 90 * 86400)
    }
    func testRestStopRequiresCurrentNamedCheckpoint() throws {
        var scene = NativeDisplayScene(name: "Regroup", kind: .restStop)
        XCTAssertThrowsError(try scene.validate(event: event()))
        scene.checkpointId = targetID; scene.regroupPrompt = "Manually selected regroup"
        try scene.validate(event: event())
    }
    func testOpeningSceneCannotImplyCheckpointOrRegroupArrival() throws {
        var scene = NativeDisplayScene(name: "Opening")
        scene.regroupPrompt = "Unexpected arrival inference"
        XCTAssertThrowsError(try scene.validate(event: event()))
    }
    func testDisplayCueWithoutCurrentOwnConsentIsRejected() throws {
        let cue: [String: Any] = ["id": teamID.uuidString, "name": "Opening", "kind": "opening",
            "offsetSeconds": 0, "durationSeconds": 30, "periodMilliseconds": 4000, "colors": ["#55CCAA"],
            "pattern": "solid", "manuallySelected": false, "startsAtISO": "2026-11-06T13:00:00Z", "phaseMilliseconds": 0]
        XCTAssertThrowsError(try display(own: false, cues: [cue]).validate(NativeEventSocialContext(event())))
    }
    func testSourcePreviewExpiresAgainstMonotonicServerAnchor() throws {
        let value = try display(), context = try NativeEventSocialContext(event())
        let clock = try CatalogEventClock(serverTime: value.serverTimeISO,
            instant: ContinuousClock().now.advanced(by: .seconds(-31)))
        let preview = NativeEventPlanPreview(accountID: teamID, accountEpoch: UUID(), context: context,
            planRevision: 2, optinRevision: 4, manualCheckpointID: nil, snapshot: value,
            clock: clock, endsAt: try CatalogEventTime.parse("2026-11-07T12:00:00Z"))
        XCTAssertGreaterThan(clock.now(), preview.validUntil); XCTAssertTrue(preview.currentCues().isEmpty)
    }
    func testRecapUnavailableArtworkOmitsProtectedID() throws {
        let context = try NativeEventSocialContext(event())
        let safe = try recap(reference: ["kind": "eventExclusive", "label": "Withdrawn", "available": false])
        try safe.validate(context, page: 1); XCTAssertNil(safe.artworkReferences.first?.id)
        let unsafe = try recap(reference: ["kind": "eventExclusive", "label": "Withdrawn", "available": false, "id": teamID.uuidString])
        XCTAssertThrowsError(try unsafe.validate(context, page: 1))
    }
    func testRecapNeverRestoresLocalOnlyProgress() throws {
        let value = try recap(reference: ["kind": "community", "label": "Unavailable", "available": false], local: true)
        XCTAssertThrowsError(try value.validate(NativeEventSocialContext(event()), page: 1))
    }
    func testClearRejectsLateEventScopeAndErasesConsentDrafts() throws {
        let model = NativeEventSocialStore(eventID: eventID, surface: .guestbook)
        model.guestDraft.text = "Private typed note"; model.guestDraft.consent = true
        model.consent = true; model.cooperativeConsent = true; model.manualCheckpointID = targetID
        model.clear()
        XCTAssertNil(model.event); XCTAssertNil(model.preview); XCTAssertNil(model.manualCheckpointID)
        XCTAssertTrue(model.guestDraft.text.isEmpty); XCTAssertFalse(model.guestDraft.consent)
        XCTAssertFalse(model.consent); XCTAssertFalse(model.cooperativeConsent)
    }
    func testHeldEventRejectsEvenOrganizerIntent() throws {
        let current = try event(owner: true, held: true)
        XCTAssertThrowsError(try NativeEventSocialContext(current).check(current, participant: true, organizer: true))
    }
    func testCancelledEventCannotStartOwnPlanConsent() throws {
        let current = try event(cancelled: true)
        XCTAssertThrowsError(try NativeEventSocialContext(current).check(current, participant: true))
    }
    func testDisplayResponseCannotClaimPhysicalSynchronization() throws {
        let context = try NativeEventSocialContext(event())
        let value = try decode(NativeEventDisplay.self, [
            "eventId": eventID.uuidString, "eventRevision": 7, "participationRevision": 3,
            "revision": 2, "optinRevision": 4, "plan": ["enabled": false, "scenes": []],
            "ownEnabled": false, "canManage": false, "gpsUsed": false, "synchronizedPlaybackVerified": true,
            "safetyMonitoring": false, "serverTimeISO": "2026-11-06T13:00:00Z", "cues": [], "scenePlaylists": []
        ])
        XCTAssertThrowsError(try value.validate(context))
    }
    func testOwnedReceiptDoesNotHydrateEventOrGalleryDetails() throws {
        let value = try decode(NativeOwnedGuestbookPage.self, [
            "posts": [["id": teamID.uuidString, "eventId": eventID.uuidString, "revision": 4,
                       "state": "withdrawn", "text": "My typed text", "reaction": "thanks",
                       "createdAtISO": "2026-11-06T13:00:00Z"]],
            "page": 1, "hasMore": false
        ])
        XCTAssertEqual(value.posts.first?.text, "My typed text")
        XCTAssertNil(value.posts.first?.imageId)
    }
    private func phoneDisplayObject(optin: Int = 4) -> [String: Any] {
        let playlist: [String: Any] = ["order": "in-order", "entries": [["itemId": targetID.uuidString, "durationMilliseconds": 10000]]]
        let scene: [String: Any] = ["id": teamID.uuidString, "name": "Named manual regroup", "kind": "rest-stop",
            "checkpointId": targetID.uuidString, "regroupPrompt": "Deliberately selected, not arrival",
            "offsetSeconds": 0, "durationSeconds": 300, "colors": ["#55CCAA"], "pattern": "gentle-pulse",
            "periodMilliseconds": 4000, "playlist": playlist]
        var cue = scene; cue["manuallySelected"] = true
        let item: [String: Any] = ["id": targetID.uuidString, "title": "Current public scene original",
            "nativeSize": "32x32",
            "gifUrl": "/api/v1/events/\(eventID.uuidString.lowercased())/display-plan/items/\(teamID.uuidString.lowercased())/\(targetID.uuidString.lowercased())/original.gif",
            "previewUrl": "/unused.png"]
        return ["eventId": eventID.uuidString, "eventRevision": 7, "participationRevision": 3,
            "revision": 2, "optinRevision": optin, "plan": ["enabled": true, "scenes": [scene]],
            "ownEnabled": true, "canManage": false, "gpsUsed": false, "synchronizedPlaybackVerified": false,
            "safetyMonitoring": false, "serverTimeISO": "2026-11-06T13:00:00Z", "cues": [cue],
            "scenePlaylists": [["sceneId": teamID.uuidString, "order": "in-order",
                "entries": [["durationMilliseconds": 10000, "available": true, "item": item]]]]]
    }
    private func phoneResponse(_ object: [String: Any]) throws -> CommunityResponse {
        .init(status: 200, data: try JSONSerialization.data(withJSONObject: object))
    }
    private func phoneInitialResponses() throws -> [CommunityResponse] {
        [try phoneResponse(["user": ["id": finishID.uuidString, "email": "event-owner@example.invalid",
            "displayName": "Reviewed participant", "role": "user", "verified": true],
            "token": "event-fixture-only-session", "expiresAt": "2099-01-01T00:00:00Z"]),
         try phoneResponse(["requireEmailVerification": false, "eventsEnabled": true, "eventDisplayPlanningEnabled": true])]
    }
    private func phoneController(_ transport: PlaylistSourceTransport) async throws -> CommunityController {
        let value = CommunityController(vault: PlaylistSourceVault(), factory: { _ in transport })
        value.configure("https://catalog.example")
        try await value.signIn(email: "event-owner@example.invalid", password: "event-fixture-only-password")
        try await value.loadConfig(); return value
    }
    private func phoneSource(_ client: CommunityFeatureClient) throws -> NativeScopedPhoneSource {
        let display = try decode(NativeEventDisplay.self, phoneDisplayObject())
        let preview = NativeEventPlanPreview(accountID: client.accountID, accountEpoch: client.revision,
            context: try NativeEventSocialContext(event()), planRevision: 2, optinRevision: 4, manualCheckpointID: targetID,
            snapshot: display, clock: try CatalogEventClock(serverTime: display.serverTimeISO),
            endsAt: try CatalogEventTime.parse("2026-11-07T12:00:00Z"))
        return .event(preview, sceneID: teamID)
    }
    private var phoneOriginalGIF: Data {
        Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0,
              0, 0, 0, 255, 255, 255, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0, 0x3b])
    }
    func testScenePhoneOriginalRequiresExactEventSceneMembershipBeforeAndAfterIO() async throws {
        let current = try phoneResponse(["event": eventObject()]), display = try phoneResponse(phoneDisplayObject())
        let transport = PlaylistSourceTransport(try phoneInitialResponses() + [
            current, display, .init(status: 200, data: phoneOriginalGIF), current, display])
        let community = try await phoneController(transport), client = try CommunityFeatureClient(community)
        let bytes = try await client.scopedPhoneOriginal(phoneSource(client), index: 0)
        XCTAssertEqual(bytes, phoneOriginalGIF)
        let history = await transport.history()
        XCTAssertEqual(history.filter { $0.url?.path.hasSuffix("/original.gif") == true }.first?.url?.path,
            "/api/v1/events/\(eventID.uuidString.lowercased())/display-plan/items/\(teamID.uuidString.lowercased())/\(targetID.uuidString.lowercased())/original.gif")
    }
    func testScenePhoneOriginalRejectsChangedOptinAfterIO() async throws {
        let current = try phoneResponse(["event": eventObject()])
        let transport = PlaylistSourceTransport(try phoneInitialResponses() + [
            current, phoneResponse(phoneDisplayObject()), .init(status: 200, data: phoneOriginalGIF),
            current, phoneResponse(phoneDisplayObject(optin: 5))])
        let community = try await phoneController(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.scopedPhoneOriginal(phoneSource(client), index: 0); XCTFail("Changed own consent must discard decoded-media input") }
        catch { }
    }
    func testScenePhoneOriginalRejectsChangedParticipationAfterIO() async throws {
        let transport = PlaylistSourceTransport(try phoneInitialResponses() + [
            phoneResponse(["event": eventObject()]), phoneResponse(phoneDisplayObject()),
            .init(status: 200, data: phoneOriginalGIF), phoneResponse(["event": eventObject(participation: 4)])])
        let community = try await phoneController(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.scopedPhoneOriginal(phoneSource(client), index: 0); XCTFail("Changed participation must discard media") }
        catch { }
    }
    func testScenePhoneHeldEventCannotFetchAnOriginal() async throws {
        let transport = PlaylistSourceTransport(try phoneInitialResponses() + [phoneResponse(["event": eventObject(held: true)])])
        let community = try await phoneController(transport), client = try CommunityFeatureClient(community)
        do { _ = try await client.scopedPhoneOriginal(phoneSource(client), index: 0); XCTFail("Held event must not expose scene media") }
        catch { }
        let history = await transport.history()
        XCTAssertFalse(history.contains { $0.url?.path.hasSuffix("/original.gif") == true })
    }
}
