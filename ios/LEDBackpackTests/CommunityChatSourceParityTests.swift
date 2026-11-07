import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor ChatParityTransport: CommunityTransport {
    private var replies: [CommunityResponse]
    private var sent: [URLRequest] = []
    init(_ replies: [CommunityResponse]) { self.replies = replies }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        sent.append(request)
        guard !replies.isEmpty else { throw BackpackError.invalid("Unexpected prepared fixture request.") }
        return replies.removeFirst()
    }
    func requests() -> [URLRequest] { sent }
}
@MainActor
private final class ChatParityVault: CommunityVault {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}

// Prepared deterministic source fixtures only. No test, build or native runtime execution.
@MainActor
final class CommunityChatSourceParityTests: XCTestCase {
    private let account = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let peer = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let clientID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    private let referenceID = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
    private let snapshotID = UUID(uuidString: "50000000-0000-4000-8000-000000000005")!
    private let itemID = UUID(uuidString: "60000000-0000-4000-8000-000000000006")!
    private let eventID = UUID(uuidString: "70000000-0000-4000-8000-000000000007")!
    private let origin = "https://catalog.example"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: data(object))
    }
    private func person() -> SocialPerson { .init(id: peer, displayName: "Named eligible contact") }
    private func request(state: String = "pending", available: Bool = true, incoming: Bool = true,
                         revision: Int = 2, intro: Bool = true) throws -> NativeMessageRequest {
        var object: [String: Any] = ["id": referenceID.uuidString, "revision": revision, "state": state,
            "available": available, "incoming": incoming, "createdAtISO": "2027-01-15T08:00:00Z"]
        if available {
            object["contact"] = ["id": peer.uuidString, "displayName": "Named eligible contact"]
            if intro { object["message"] = ["id": referenceID.uuidString, "text": "One introduction", "createdAt": 1_800_000_000_000] }
        }
        return try decode(NativeMessageRequest.self, object)
    }
    private func record(purpose: NativeChatOutboxRecord.Purpose = .message) throws -> NativeChatOutboxRecord {
        let context = ChatConversation.direct(peer: peer, event: nil)
        let bytes: Data
        if purpose == .introduction {
            bytes = try NativeMessageRequestIntent(account: account, contact: person(), text: "Hello", consent: true,
                clientID: clientID, now: now).data
        } else {
            bytes = try ChatSendIntent(context: context, text: "Hello", attachmentID: nil, pin: nil, clientID: clientID).data
        }
        return try .init(account: account, origin: origin, context: context, clientID: clientID, bytes: bytes,
            purpose: purpose, consent: true, now: now)
    }
    private func playlist(url: String? = nil, expiry: String = "2099-01-01T00:00:00Z") -> [String: Any] {
        var object: [String: Any] = ["kind": "playlist", "available": true, "id": snapshotID.uuidString,
            "title": "Public snapshot title", "description": "Public description only", "order": "in-order",
            "expiresAtISO": expiry, "entryCount": 1, "privateScheduleIncluded": false, "privateCloudIncluded": false]
        if let url { object["url"] = url }
        return object
    }
    private func manifest() -> [String: Any] {
        var object = playlist()
        let base = "/api/v1/social/chat-references/\(referenceID.uuidString.lowercased())/playlist/items/\(itemID.uuidString.lowercased())/"
        object["entries"] = [["durationMilliseconds": 1000, "available": true, "item": [
            "id": itemID.uuidString, "title": "Public art", "gifUrl": base + "original.gif",
            "previewUrl": base + "preview.png", "nativeSize": "64x64"]]]
        return object
    }
    private func response(_ object: [String: Any], status: Int = 200) throws -> CommunityResponse {
        .init(status: status, data: try data(object))
    }
    private func setup(_ replies: [CommunityResponse], flags: [String: Any] = [:]) async throws -> (CommunityController, CommunityFeatureClient, ChatParityTransport) {
        var config: [String: Any] = ["requireEmailVerification": false, "messagingEnabled": true]
        config.merge(flags) { _, rhs in rhs }
        let login = try response(["user": ["id": account.uuidString, "email": "fixture@example.invalid",
            "displayName": "Fixture", "role": "user", "verified": true], "token": "prepared-fixture-not-a-real-token",
            "expiresAt": "2099-01-01T00:00:00Z"])
        let transport = ChatParityTransport([login, try response(config)] + replies)
        let controller = CommunityController(vault: ChatParityVault(), factory: { _ in transport })
        controller.configure(origin)
        try await controller.signIn(email: "fixture@example.invalid", password: "prepared-not-real")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), transport)
    }

    func testRequestPreferenceRevisionZeroIsExplicitDefaultOff() throws {
        let value = try decode(NativeMessageRequestPreference.self, ["revision": 0, "enabled": false])
        try value.validate(); XCTAssertFalse(value.enabled); XCTAssertEqual(value.revision, 0)
    }
    func testRequestPreferenceMissingEnabledDoesNotManufactureConsent() {
        XCTAssertThrowsError(try decode(NativeMessageRequestPreference.self, ["revision": 0]))
    }
    func testRequestPreferenceRejectsNegativeRevision() throws {
        XCTAssertThrowsError(try decode(NativeMessageRequestPreference.self, ["revision": -1, "enabled": false]).validate())
    }
    func testIntroductionIntentHasOnlyExactThreeFields() throws {
        let intent = try NativeMessageRequestIntent(account: account, contact: person(), text: "  Hello  ", consent: true, clientID: clientID, now: now)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: String])
        XCTAssertEqual(Set(fields.keys), Set(["recipientId", "clientMessageId", "text"]))
        XCTAssertEqual(fields["text"], "Hello"); XCTAssertEqual(fields["recipientId"], peer.uuidString.lowercased())
    }
    func testIntroductionRequiresDeliberateConsent() {
        XCTAssertThrowsError(try NativeMessageRequestIntent(account: account, contact: person(), text: "Hello", consent: false))
    }
    func testIntroductionRejectsEmptyOrOverLimitText() {
        for text in ["  ", String(repeating: "a", count: 1001)] {
            XCTAssertThrowsError(try NativeMessageRequestIntent(account: account, contact: person(), text: text, consent: true))
        }
    }
    func testIntroductionCannotTargetCurrentAccount() {
        let own = SocialPerson(id: account, displayName: "Me")
        XCTAssertThrowsError(try NativeMessageRequestIntent(account: account, contact: own, text: "Hello", consent: true))
    }
    func testPendingRequestDoesNotOpenAcceptedThread() throws {
        XCTAssertThrowsError(try request().acceptedConversation(account: account))
    }
    func testAcceptedRequestOpensOnlyActualDirectPeer() throws {
        let row = try request(state: "accepted", intro: false)
        XCTAssertEqual(try row.acceptedConversation(account: account), .direct(peer: peer, event: nil))
    }
    func testUnavailableRequestCannotExposeContactOrIntro() throws {
        let valid = try request(state: "revoked", available: false)
        try valid.validate(account: account)
        XCTAssertNil(valid.contact); XCTAssertNil(valid.message)
        var object: [String: Any] = ["id": referenceID.uuidString, "revision": 3, "state": "revoked", "available": false,
            "incoming": false, "createdAtISO": "2027-01-15T08:00:00Z"]
        object["contact"] = ["id": peer.uuidString, "displayName": "Must not leak"]
        XCTAssertThrowsError(try decode(NativeMessageRequest.self, object).validate(account: account))
    }
    func testAcceptedConsentDoesNotRequireRetainedIntroduction() throws {
        try request(state: "accepted", intro: false).validate(account: account)
    }
    func testSenderCannotAcceptOwnOutgoingRequest() throws {
        let row = try request(incoming: false)
        XCTAssertThrowsError(try NativeMessageRequestControl(row, account: account, accept: true))
    }
    func testRequestCancelCarriesOnlyCapturedRevision() throws {
        let value = try NativeMessageRequestControl(request(incoming: false), account: account, accept: nil)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: value.data) as? [String: Int])
        XCTAssertEqual(fields, ["expectedRevision": 2])
    }
    func testAcceptedRequestCannotBeAcceptedAgainAsPending() throws {
        XCTAssertThrowsError(try NativeMessageRequestControl(request(state: "accepted"), account: account, accept: true))
    }
    func testRequestFlagsMissingDoNotInvokeNetwork() async throws {
        let (_, client, transport) = try await setup([])
        XCTAssertFalse(client.messageRequestsEnabled); XCTAssertFalse(client.chatPlaylistReferencesEnabled); XCTAssertFalse(client.retainedChatRecoveryEnabled)
        do { _ = try await client.messageRequestPreference(); XCTFail("Missing flag must deny") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 2)
    }
    func testPreferenceConflictDoesNotSilentlyRebase() async throws {
        let conflict = try response(["error": ["code": "chat_request_preferences_changed", "message": "Reload revision"]], status: 409)
        let (_, client, transport) = try await setup([conflict], flags: ["chatMessageRequestsEnabled": true])
        let original = try decode(NativeMessageRequestPreference.self, ["revision": 2, "enabled": false])
        do { _ = try await client.saveMessageRequestPreference(original, enabled: true); XCTFail("Expected conflict") }
        catch let failure as CommunityFailure { XCTAssertEqual(failure.status, 409) }
        let requests = await transport.requests(); XCTAssertEqual(requests.count, 3)
        let sent = try XCTUnwrap(requests.last?.httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(fields["expectedRevision"] as? Int, 2); XCTAssertEqual(fields["enabled"] as? Bool, true)
    }
    func testOutboxRoundTripPreservesExactBytesClientIDAndConsent() throws {
        let original = try record()
        let restored = try JSONDecoder().decode(NativeChatOutboxRecord.self, from: JSONEncoder().encode(original))
        try restored.validate()
        XCTAssertEqual(restored.bytes, original.bytes); XCTAssertEqual(restored.clientID, clientID)
        XCTAssertEqual(restored.accountID, account); XCTAssertTrue(restored.deliberateConsent)
        XCTAssertEqual(restored.context, .direct(peer: peer, event: nil))
    }
    func testOutboxRetryImmediatelyBeforeThirtyDaysAllowed() throws {
        let value = try record()
        XCTAssertNoThrow(try value.requireRetry(account: account, origin: origin, context: value.context,
            now: now.addingTimeInterval(NativeChatRetention.historySeconds - 0.001)))
    }
    func testOutboxRetryAtExactThirtyDaysDenied() throws {
        let value = try record()
        XCTAssertThrowsError(try value.requireRetry(account: account, origin: origin, context: value.context, now: value.retryBefore))
    }
    func testIntroductionOutboxExpiresAtFourteenDays() throws {
        let value = try record(purpose: .introduction)
        XCTAssertEqual(value.retryBefore, now.addingTimeInterval(14 * 86400))
        XCTAssertThrowsError(try value.requireRetry(account: account, origin: origin, context: value.context, now: value.retryBefore))
    }
    func testOutboxNeverRetriesAnotherAccountOrOrigin() throws {
        let value = try record()
        XCTAssertThrowsError(try value.requireRetry(account: peer, origin: origin, context: value.context, now: now))
        XCTAssertThrowsError(try value.requireRetry(account: account, origin: "https://other.invalid", context: value.context, now: now))
    }
    func testOutboxNeverRetargetsAnotherPeerOrEvent() throws {
        let value = try record()
        XCTAssertThrowsError(try value.requireRetry(account: account, origin: origin, context: .direct(peer: itemID, event: nil), now: now))
        XCTAssertThrowsError(try value.requireRetry(account: account, origin: origin, context: .direct(peer: peer, event: eventID), now: now))
    }
    func testRetiredReceiptClearsUnverifiedAcknowledgmentAndDisablesRetry() throws {
        var value = try record(); value.acknowledgedMessageID = referenceID
        value.recordFailure(.init(status: 409, code: "message_retired", message: "Retired"))
        XCTAssertEqual(value.state, .retired); XCTAssertNil(value.acknowledgedMessageID)
        XCTAssertThrowsError(try value.requireRetry(account: account, origin: origin, context: value.context, now: now))
    }
    func testExpiredReceiptIsNotNewDelivery() throws {
        var value = try record()
        value.recordFailure(.init(status: 409, code: "message_expired", message: "Expired"))
        XCTAssertEqual(value.clientID, clientID); XCTAssertEqual(value.state, .retired)
    }
    func testIdentityConflictNeverReplacesFinalizedBytes() throws {
        var value = try record(); let original = value.bytes
        value.recordFailure(.init(status: 409, code: "message_id_conflict", message: "Conflict"))
        XCTAssertEqual(value.state, .retired); XCTAssertEqual(value.bytes, original); XCTAssertEqual(value.clientID, clientID)
    }
    func testAccessLossAndBlockPreventStoredSendSuccess() throws {
        for status in [401, 403, 404] {
            var value = try record(); value.acknowledgedMessageID = referenceID
            value.recordFailure(.init(status: status, code: "chat_unavailable", message: "Unavailable"))
            XCTAssertEqual(value.state, .accessLost); XCTAssertNil(value.acknowledgedMessageID)
            XCTAssertThrowsError(try value.requireRetry(account: account, origin: origin, context: value.context, now: now))
        }
    }
    func testTransientFailureRemainsUncertainWithoutNewID() throws {
        var value = try record()
        value.recordFailure(.init(status: 503, code: "messaging_unavailable", message: "Unavailable"))
        XCTAssertEqual(value.state, .uncertain); XCTAssertEqual(value.clientID, clientID)
    }
    func testAcknowledgmentCannotManufactureMissingServerMessageID() throws {
        var value = try record(); value.state = .acknowledged
        XCTAssertThrowsError(try value.validate())
    }
    func testOutboxMissingCreationAndDeadlinesCannotDecode() throws {
        let value = try record()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for field in ["createdAt", "retryBefore", "forgetAfter"] {
            var incomplete = object; incomplete.removeValue(forKey: field)
            XCTAssertThrowsError(try decode(NativeChatOutboxRecord.self, incomplete))
        }
        object.removeValue(forKey: "deliberateConsent")
        XCTAssertThrowsError(try decode(NativeChatOutboxRecord.self, object))
    }
    func testMinimalClientReceiptExpiresAtSixtyDaysAndHasNoContent() throws {
        let receipt = NativeChatClientReceipt(accountID: account, clientID: clientID, state: .retired,
            forgetAfter: now.addingTimeInterval(NativeChatRetention.receiptSeconds))
        XCTAssertTrue(receipt.retained(at: receipt.forgetAfter.addingTimeInterval(-0.001)))
        XCTAssertFalse(receipt.retained(at: receipt.forgetAfter))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        XCTAssertNil(fields["recipientId"]); XCTAssertNil(fields["bytes"]); XCTAssertNil(fields["text"]); XCTAssertNil(fields["context"])
    }
    func testMissingReceiptExpiryNeverBecomesInfiniteDeduplication() {
        XCTAssertThrowsError(try decode(NativeChatClientReceipt.self, ["accountID": account.uuidString, "clientID": clientID.uuidString, "state": "retired"]))
    }
    func testHistoryCutoffIsExclusiveAtExactThirtyDays() {
        let created = now.timeIntervalSince1970 * 1000
        XCTAssertTrue(NativeChatRetention.retained(createdAtMilliseconds: created, now: now.addingTimeInterval(NativeChatRetention.historySeconds - 0.001)))
        XCTAssertFalse(NativeChatRetention.retained(createdAtMilliseconds: created, now: now.addingTimeInterval(NativeChatRetention.historySeconds)))
        XCTAssertFalse(NativeChatRetention.retained(createdAtMilliseconds: .nan, now: now))
    }
    func testHistoryMissingCreationIsNotRecovered() {
        XCTAssertThrowsError(try decode(NativeChatMessage.self, ["id": referenceID.uuidString, "senderId": account.uuidString, "text": "Missing creation"]))
    }
    func testAdvertisedRecoveryRequiresExplicitHistoryContract() async throws {
        let body: [String: Any] = ["messages": [], "page": 1, "limit": 50, "hasMore": false]
        let (_, client, _) = try await setup([response(body)], flags: ["directMessageRetentionDays": 30, "directMessageRecovery": "retained-history-only"])
        do { _ = try await client.directHistory(peer: peer, event: nil, before: nil); XCTFail("Missing history contract") }
        catch { XCTAssertTrue(error.localizedDescription.contains("confirm retained-history")) }
    }
    func testPublishedReferenceEncodesPublishedShareIDNotOwnerDraftID() throws {
        let selection = ChatReferenceSelection(publishedShare: .init(value: snapshotID))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: String])
        XCTAssertEqual(fields, ["kind": "playlist", "id": snapshotID.uuidString.lowercased()])
        XCTAssertNotEqual(fields["id"], eventID.uuidString.lowercased())
    }
    func testUnknownReferenceKindIsGenericUnavailableNotHistoryFailure() throws {
        let card = try decode(HydratedChatReference.self, ["kind": "future-kind", "available": true, "title": "Do not expose"])
        XCTAssertFalse(card.available); XCTAssertNil(card.event); XCTAssertNil(card.gif); XCTAssertNil(card.playlist)
    }
    func testExpiredPlaylistHydratesAsUnavailableWithoutPrivateText() throws {
        let card = try decode(HydratedChatReference.self, playlist(expiry: "2000-01-01T00:00:00Z"))
        XCTAssertFalse(card.available); XCTAssertNil(card.playlist)
    }
    func testUnavailablePlaylistDoesNotDecodeEmbeddedPrivateMetadata() throws {
        let card = try decode(HydratedChatReference.self, ["kind": "playlist", "available": false, "title": "Private text", "schedule": ["enabled": true]])
        XCTAssertFalse(card.available); XCTAssertNil(card.playlist)
    }
    func testPlaylistManifestRejectsPrivateCloudOrScheduleClaim() throws {
        for key in ["privateCloudIncluded", "privateScheduleIncluded"] {
            var object = manifest(); object[key] = true
            XCTAssertThrowsError(try decode(NativeChatPlaylistManifest.self, object).validate(reference: referenceID, now: now))
        }
    }
    func testPlaylistExpiryHasNoImplicitExtension() throws {
        let value = try decode(NativeChatPlaylistManifest.self, manifest())
        let deadline = try CatalogEventTime.parse(value.expiresAtISO)
        XCTAssertThrowsError(try value.validate(reference: referenceID, now: deadline))
    }
    func testPlaylistManifestValidatesExactReferenceMediaMembership() throws {
        let value = try decode(NativeChatPlaylistManifest.self, manifest())
        try value.validate(reference: referenceID, now: now)
        XCTAssertThrowsError(try value.validate(reference: snapshotID, now: now))
    }
    func testPlaylistMediaRejectsArbitraryURLsTokensAndTraversal() {
        for raw in ["https://other.invalid/a.gif", "/playlist-share/token/items/id/original.gif",
                    "/api/v1/social/chat-references/\(referenceID)/playlist/items/\(itemID)/%2e%2e",
                    "/api/v1/social/chat-references/\(referenceID)/playlist/items/\(itemID)/original.gif?token=x"] {
            XCTAssertThrowsError(try NativeChatPlaylistManifest.mediaPath(URL(string: raw)!, reference: referenceID, item: itemID))
        }
    }
    func testPlaylistUnavailableEntryCannotExposeItemMetadata() throws {
        var object = manifest()
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0]["available"] = false; object["entries"] = entries
        XCTAssertThrowsError(try decode(NativeChatPlaylistManifest.self, object).validate(reference: referenceID, now: now))
    }
    func testPlaylistViewerUsesReferenceIDNotPublishedSnapshotID() throws {
        let path = "/chat-playlist/\(referenceID.uuidString.lowercased())"
        XCTAssertEqual(try NativeChatPublishedPlaylist.referenceID(path), referenceID)
        XCTAssertThrowsError(try NativeChatPublishedPlaylist.referenceID(path + "?token=private"))
        XCTAssertThrowsError(try NativeChatPublishedPlaylist.referenceID(origin + path))
    }
    func testVisitorQuestionGateUsesActualOrganizerPeer() throws {
        let value = try decode(NativeOrganizerChatContext.self, ["organizers": [["id": peer.uuidString, "acceptsQuestions": false]]])
        XCTAssertFalse(try value.newMessageAllowed(account: account, peer: peer))
        XCTAssertThrowsError(try value.newMessageAllowed(account: account, peer: itemID))
    }
    func testOrganizerRepliesRemainAllowedWhenQuestionsAreStopped() throws {
        let value = try decode(NativeOrganizerChatContext.self, ["organizers": [["id": account.uuidString, "acceptsQuestions": false]]])
        XCTAssertTrue(try value.newMessageAllowed(account: account, peer: peer))
    }
    func testMissingOrganizerQuestionFlagDoesNotEnableNewVisitorQuestion() throws {
        let value = try decode(NativeOrganizerChatContext.self, ["organizers": [["id": peer.uuidString]]])
        XCTAssertFalse(try value.newMessageAllowed(account: account, peer: peer))
    }
    func testRoomReferenceNeverForwardsEventInvitation() throws {
        let event: [String: Any] = ["id": eventID.uuidString, "title": "Event", "visibility": "public", "status": "scheduled",
            "startsAtISO": "2099-01-01T00:00:00Z", "endsAtISO": "2099-01-02T00:00:00Z", "timezone": "UTC",
            "revision": 4, "participationRevision": 2, "location": ["label": "Fixed venue", "latitude": 1, "longitude": 2, "radiusMeters": 10]]
        var selection = try ChatReferenceSelection(event: decode(SharedChatEvent.self, event))
        selection.inviteRecipient = true
        XCTAssertThrowsError(try ChatSendIntent(context: .room(referenceID), text: "", attachmentID: nil, pin: nil, reference: selection))
        let direct = try ChatSendIntent(context: .direct(peer: peer, event: nil), text: "", attachmentID: nil, pin: nil, reference: selection, clientID: clientID)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: direct.data) as? [String: Any])
        XCTAssertEqual(fields["recipientId"] as? String, peer.uuidString.lowercased())
    }
    func testOpaqueActivityMessageIDNeverBecomesPeerOrEventContext() throws {
        let notice = NativeActivityNotice(id: itemID, type: .message, referenceId: referenceID.uuidString,
            createdAtISO: "2027-01-15T08:00:00Z", readAtISO: nil)
        XCTAssertEqual(try notice.reference(), referenceID)
        XCTAssertNotEqual(try notice.reference(), peer)
        let invalid = NativeActivityNotice(id: itemID, type: .eventInvite, referenceId: eventID.uuidString + ":arbitrary-peer",
            createdAtISO: "2027-01-15T08:00:00Z", readAtISO: nil)
        XCTAssertThrowsError(try invalid.reference())
    }
    func testClearedSessionRejectsLateResult() async throws {
        let (controller, _, _) = try await setup([])
        let session = CommunityFeatureSession(); session.bind(controller)
        let old = try XCTUnwrap(session.client); session.clear()
        XCTAssertThrowsError(try session.checked(old))
    }
    func testAccountChangeRejectsCapturedChatClient() async throws {
        let (controller, client, _) = try await setup([])
        controller.configure("https://different.example")
        XCTAssertThrowsError(try client.check(.messaging))
    }
    func testLocalBlockInvalidationRejectsCapturedChatClient() async throws {
        let (controller, client, _) = try await setup([])
        controller.invalidateChatAccess()
        XCTAssertThrowsError(try client.check(.messaging))
    }
}
