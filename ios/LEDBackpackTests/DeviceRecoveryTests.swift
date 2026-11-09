import XCTest
import BackpackProtocol
@testable import LEDBackpack

@MainActor
private final class RecoveryTestVault: CommunityVault {
    var values: [String: Data] = [:]
    var failWrites = false
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws {
        guard !failWrites else { throw BackpackError.invalid("Keychain locked") }
        values[key] = data
    }
    func remove(_ key: String) throws { values[key] = nil }
}

@MainActor
final class DeviceRecoveryTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let owner = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let conversation = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let vendor = "Ab12345678"
    private let origin = "https://catalog.example.invalid"
    private let token = String(repeating: "A", count: 43)
    private let recoveryCreated = Date().addingTimeInterval(-60)

    private func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    private func foreignLookup(status: String = "registered-elsewhere", enabled: Bool = false,
        seconds: TimeInterval = 120) -> [String: Any] {
        let now = Date()
        var result: [String: Any] = ["status": status, "recoveryEnabled": enabled, "serverTimeISO": CatalogEventTime.wire(now)]
        if enabled {
            result["recovery"] = [
                "owner": ["id": owner.uuidString, "displayName": "Registered person"],
                "contactAuthorization": ["token": token, "expiresAtISO": CatalogEventTime.wire(now.addingTimeInterval(seconds))]
            ]
        }
        return result
    }
    private func messageIntent(text: String = "Found it", client: UUID = UUID(), now: Date = Date()) throws -> DeviceRecoveryIntent {
        try DeviceRecoveryIntent(account: account, origin: origin, peer: owner, kind: .message,
            conversationID: conversation, text: text, clientID: client, now: now)
    }

    func testOffAndAmbiguousLookupNeverCarryForeignIdentity() throws {
        for status in ["available", "registered-elsewhere", "ambiguous"] {
            try decode(DeviceRegistryLookup.self, foreignLookup(status: status)).validate(vendorID: vendor, account: account)
        }
        for status in ["available", "ambiguous"] {
            XCTAssertThrowsError(try decode(DeviceRegistryLookup.self, foreignLookup(status: status, enabled: true))
                .validate(vendorID: vendor, account: account))
        }
        var invalid = foreignLookup(enabled: true)
        invalid["recoveryEnabled"] = false
        XCTAssertThrowsError(try decode(DeviceRegistryLookup.self, invalid).validate(vendorID: vendor, account: account))
    }
    func testForeignLookupCannotReturnPrivateDeviceRecord() throws {
        var invalid = foreignLookup()
        invalid["device"] = [
            "id": conversation.uuidString, "revision": 1, "nickname": "Private record", "model": "BP10",
            "matrix": NSNull(), "ownerCardEnabled": false, "transferPending": false,
            "claimStatus": "unverified-tag", "physicalOwnershipVerified": false,
            "hardwareIdentityVerified": false, "flashingCompatibilityVerified": false
        ]
        XCTAssertThrowsError(try decode(DeviceRegistryLookup.self, invalid).validate(vendorID: vendor, account: account))
    }
    func testRecoveryProfileHasBoundedTokenLeaseAndCannotBeOwnProfile() throws {
        let value = try decode(DeviceRegistryLookup.self, foreignLookup(enabled: true))
        try value.validate(vendorID: vendor, account: account)
        let review = try DeviceRegistryReview(lookup: value, clock: CatalogEventClock(serverTime: value.serverTimeISO))
        XCTAssertEqual(try review.recovery().owner.id, owner)
        XCTAssertLessThanOrEqual(try XCTUnwrap(review.recoverySecondsRemaining), 120)
        for seconds in [-1, 0, 126] {
            XCTAssertThrowsError(try decode(DeviceRegistryLookup.self, foreignLookup(enabled: true, seconds: TimeInterval(seconds)))
                .validate(vendorID: vendor, account: account))
        }
        XCTAssertThrowsError(try value.validate(vendorID: vendor, account: owner))
    }
    func testAvatarNeedsMatchingRecoveryScopeAndCompleteURLPair() throws {
        let url = "https://catalog.example.invalid/api/v1/social/avatars/\(owner)/version/preview.png"
        let incomplete = try decode(DeviceRecoveryOwner.self, ["id": owner.uuidString,
            "displayName": "Person", "avatarPreviewUrl": url])
        XCTAssertThrowsError(try incomplete.validate(account: account, token: token))
        let unscoped = try decode(DeviceRecoveryOwner.self, ["id": owner.uuidString, "displayName": "Person",
            "avatarUrl": url, "avatarPreviewUrl": url])
        XCTAssertThrowsError(try unscoped.validate(account: account, token: token))
        let wrong = try decode(DeviceRecoveryOwner.self, ["id": owner.uuidString, "displayName": "Person",
            "avatarUrl": url, "avatarPreviewUrl": url, "avatarScope": ["kind": "device-tag", "token": token]])
        XCTAssertThrowsError(try wrong.validate(account: account, token: token))
    }
    func testPendingMessageIsPrivateScopedAndCannotBeReplacedWithNewIDOrRecipient() throws {
        let vault = RecoveryTestVault(), outbox = DeviceRecoveryOutbox(vault: vault)
        let first = try messageIntent()
        try outbox.save(first)
        XCTAssertEqual(try outbox.load(account: account, origin: origin, kind: .message), first)
        XCTAssertNil(try outbox.load(account: owner, origin: origin, kind: .message))
        XCTAssertThrowsError(try outbox.save(messageIntent(text: "Different")))
        XCTAssertThrowsError(try first.requireRetry(account: owner, origin: origin, peer: account, conversation: conversation))
        XCTAssertFalse(vault.values.keys.contains { $0.contains(account.uuidString) || $0.contains(owner.uuidString) })
    }
    func testUTF8ChangedTextCannotReuseStoredMessageID() throws {
        let vault = RecoveryTestVault(), outbox = DeviceRecoveryOutbox(vault: vault)
        let first = try messageIntent(text: "\u{00e9}")
        let second = try messageIntent(text: "e\u{0301}", client: first.clientID, now: first.createdAt)
        XCTAssertEqual(first.text, second.text)
        XCTAssertFalse(first.sameIntent(as: second))
        try outbox.save(first)
        XCTAssertThrowsError(try outbox.save(second))
    }
    func testAcknowledgementStopsRetryAndOldReceiptCannotClearNewDraft() throws {
        let vault = RecoveryTestVault(), outbox = DeviceRecoveryOutbox(vault: vault)
        let first = try messageIntent()
        try outbox.save(first)
        try outbox.acknowledge(first, receipt: UUID())
        XCTAssertThrowsError(try outbox.requireCurrent(first))
        let acknowledged = try XCTUnwrap(outbox.load(account: account, origin: origin, kind: .message))
        XCTAssertEqual(acknowledged.state, .acknowledged)
        try outbox.clearResolved(acknowledged)
        let next = try messageIntent(text: "Another reply")
        try outbox.save(next)
        XCTAssertThrowsError(try outbox.clearResolved(acknowledged))
        XCTAssertEqual(try outbox.load(account: account, origin: origin, kind: .message)?.clientID, next.clientID)
    }
    func testExpiredIntentCannotResetItsDeadlineOrBeSilentlyCleared() throws {
        let vault = RecoveryTestVault(), outbox = DeviceRecoveryOutbox(vault: vault)
        let intent = try DeviceRecoveryIntent(account: account, origin: origin, peer: owner,
            kind: .contact, vendorID: vendor, text: "I found your device")
        try outbox.save(intent)
        XCTAssertThrowsError(try outbox.clearResolved(intent))
        let expired = try XCTUnwrap(outbox.load(account: account, origin: origin, kind: .contact,
            now: intent.createdAt.addingTimeInterval(601)))
        XCTAssertEqual(expired.state, .expired)
        XCTAssertThrowsError(try outbox.save(intent))
    }
    func testLocalReceiptFailureKeepsTheOriginalRequestID() throws {
        let vault = RecoveryTestVault(), outbox = DeviceRecoveryOutbox(vault: vault)
        let intent = try messageIntent()
        try outbox.save(intent)
        vault.failWrites = true
        XCTAssertThrowsError(try outbox.acknowledge(intent, receipt: UUID()))
        XCTAssertEqual(try outbox.load(account: account, origin: origin, kind: .message)?.clientID, intent.clientID)
        XCTAssertEqual(try outbox.load(account: account, origin: origin, kind: .message)?.state, .uncertain)
    }
    func testConversationRejectsForeignDeviceRecordScopeAndInvalidRetention() throws {
        let now = Date()
        let base: [String: Any] = [
            "id": conversation.uuidString, "revision": 1, "state": "pending", "role": "finder",
            "peer": ["id": owner.uuidString, "displayName": "Person"],
            "createdAtISO": CatalogEventTime.wire(now), "expiresAtISO": CatalogEventTime.wire(now.addingTimeInterval(30 * 86400))
        ]
        try decode(DeviceRecoveryConversation.self, base).validate(account: account)
        var leaked = base; leaked["deviceId"] = UUID().uuidString
        XCTAssertThrowsError(try decode(DeviceRecoveryConversation.self, leaked).validate(account: account))
        var invalid = base; invalid["expiresAtISO"] = CatalogEventTime.wire(now.addingTimeInterval(31 * 86400))
        XCTAssertThrowsError(try decode(DeviceRecoveryConversation.self, invalid).validate(account: account))
    }

    private func context(peer: UUID? = nil, revision: Int = 1) -> DeviceRecoveryConversation {
        DeviceRecoveryConversation(id: conversation, revision: revision, state: .accepted, role: .finder,
            peer: DeviceRecoveryPerson(id: peer ?? owner, displayName: "Person"),
            createdAtISO: CatalogEventTime.wire(recoveryCreated),
            expiresAtISO: CatalogEventTime.wire(recoveryCreated.addingTimeInterval(30 * 86400)), deviceId: nil)
    }
    private func messages(_ range: ClosedRange<Int>) -> [DeviceRecoveryMessage] {
        range.map { DeviceRecoveryMessage(id: UUID(), senderId: owner, text: "Reply \($0)",
            sequence: $0, createdAtISO: CatalogEventTime.wire(recoveryCreated.addingTimeInterval(1))) }
    }
    func testDraftRestoresOnlyExactAccountOriginConversationAndPeer() throws {
        let outbox = DeviceRecoveryOutbox(vault: RecoveryTestVault()), context = context()
        try outbox.saveDraft("Unsent reply", account: account, origin: origin, conversation: context)
        XCTAssertEqual(try outbox.draft(account: account, origin: origin, conversation: context), "Unsent reply")
        XCTAssertNil(try outbox.draft(account: account, origin: "https://other.example.invalid", conversation: context))
        XCTAssertThrowsError(try outbox.draft(account: account, origin: origin, conversation: self.context(peer: UUID())))
        XCTAssertThrowsError(try outbox.draft(account: account, origin: origin + "/", conversation: context))
        XCTAssertThrowsError(try outbox.saveDraft(String(repeating: "A", count: 1001),
            account: account, origin: origin, conversation: context))
        try outbox.saveDraft("", account: account, origin: origin, conversation: context)
        XCTAssertNil(try outbox.draft(account: account, origin: origin, conversation: context))
    }
    func testExpiredDraftIsRemovedInsteadOfRestored() throws {
        let vault = RecoveryTestVault(), outbox = DeviceRecoveryOutbox(vault: vault), context = context()
        try outbox.saveDraft("Unsent", account: account, origin: origin, conversation: context)
        XCTAssertNil(try outbox.draft(account: account, origin: origin, conversation: context,
            now: CatalogEventTime.parse(context.expiresAtISO)))
        XCTAssertTrue(vault.values.isEmpty)
    }
    func testHistoryCollectsExactly100MessagesInAscendingOrderAcrossTwoPages() throws {
        var timeline = DeviceRecoveryTimeline(account: account, id: conversation)
        try timeline.append(DeviceRecoveryHistory(conversation: context(), messages: messages(51...100), hasMore: true, nextBefore: 51))
        try timeline.append(DeviceRecoveryHistory(conversation: context(), messages: messages(1...50), hasMore: false, nextBefore: 1))
        XCTAssertEqual(timeline.messages.map(\.sequence), Array(1...100))
        XCTAssertFalse(timeline.hasMore)
        XCTAssertThrowsError(try timeline.append(DeviceRecoveryHistory(conversation: context(), messages: [], hasMore: false, nextBefore: nil)))
    }
    func testHistoryRejectsChangingRevisionAndCrossPageRepeatedID() throws {
        let newer = messages(51...100)
        var timeline = DeviceRecoveryTimeline(account: account, id: conversation)
        try timeline.append(DeviceRecoveryHistory(conversation: context(), messages: newer, hasMore: true, nextBefore: 51))
        XCTAssertThrowsError(try timeline.append(DeviceRecoveryHistory(conversation: context(revision: 2),
            messages: messages(1...50), hasMore: false, nextBefore: 1)))
        let duplicate = DeviceRecoveryMessage(id: newer[0].id, senderId: owner, text: "Repeated ID",
            sequence: 1, createdAtISO: CatalogEventTime.wire(recoveryCreated.addingTimeInterval(1)))
        XCTAssertThrowsError(try timeline.append(DeviceRecoveryHistory(conversation: context(),
            messages: [duplicate], hasMore: false, nextBefore: 1)))
    }
    func testRecoveryIncidentUsesItsOwnPurposeAndNeverCopiesOriginalText() throws {
        let message = try XCTUnwrap(messages(1...1).first)
        let intent = try MessageIncidentIntent(recoveryMessage: message, context: context(), account: account,
            category: .harassment, details: "My explanation", consent: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: intent.data) as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "device-recovery")
        XCTAssertEqual(body["messageId"] as? String, message.id.uuidString.lowercased())
        XCTAssertEqual(body["details"] as? String, "My explanation")
        XCTAssertNil(body["text"])
        XCTAssertFalse(String(decoding: intent.data, as: UTF8.self).contains(message.text))
        XCTAssertThrowsError(try MessageIncidentIntent(recoveryMessage: message, context: context(), account: account,
            category: .other, details: "Explanation", consent: false))
    }
}
