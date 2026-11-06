import XCTest
import BackpackProtocol
@testable import LEDBackpack

private actor NotificationTestTransport: CommunityTransport {
    private var responses: [CommunityResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [CommunityResponse]) { self.responses = responses }
    func send(_ request: URLRequest, maxBytes: Int) async throws -> CommunityResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BackpackError.invalid("Unexpected notification fixture request.") }
        return responses.removeFirst()
    }
    func history() -> [URLRequest] { requests }
}
@MainActor
private final class NotificationTestVault: CommunityVault {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func save(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values[key] = nil }
}
@MainActor
final class NotificationSettingsTests: XCTestCase {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private var settings: String {
        #"{"revision":7,"applePushAvailable":false,"preferences":{"globalEnabled":true,"inAppEnabled":true,"applePushEnabled":false,"categories":{"directMessages":true,"groupMessages":true,"eventMessages":true,"invitations":true,"friendRequests":true,"eventChanges":true,"eventReminders":false,"accountUpdates":true}}}"#
    }
    private func response(_ body: String, status: Int = 200) -> CommunityResponse { CommunityResponse(status: status, data: Data(body.utf8)) }
    private func setup(_ responses: [CommunityResponse], enabled: Bool = true) async throws -> (CommunityController, CommunityFeatureClient, NotificationTestTransport) {
        let login = response(#"{"user":{"id":"\#(account)","email":"test@example.invalid","displayName":"Owner","role":"admin","verified":true},"token":"test-only-notification-token-not-real","expiresAt":"2099-01-01T00:00:00Z"}"#)
        let config = response(enabled ? #"{"requireEmailVerification":false,"notificationsEnabled":true,"notificationPreferencesEnabled":true,"eventRemindersEnabled":true}"# :
            #"{"requireEmailVerification":false,"notificationsEnabled":true}"#)
        let stub = NotificationTestTransport([login, config] + responses)
        let controller = CommunityController(vault: NotificationTestVault(), factory: { _ in stub })
        controller.configure("https://catalog.example")
        try await controller.signIn(email: "test@example.invalid", password: "test-only-password")
        try await controller.loadConfig()
        return (controller, try CommunityFeatureClient(controller), stub)
    }
    func testStrictServerDefaultsPreserveInAppAndDefaultOffRemindersPush() throws {
        let value = try JSONDecoder().decode(NativeNotificationSettings.self, from: Data(settings.utf8))
        XCTAssertTrue(value.preferences.globalEnabled); XCTAssertTrue(value.preferences.inAppEnabled)
        XCTAssertFalse(value.preferences.applePushEnabled); XCTAssertFalse(value.preferences.categories.eventReminders)
        XCTAssertEqual(NativeNotificationPreferences.Category.allCases.count, 8)
    }
    func testMissingPreferenceCapabilityDoesNotUseInboxFlagAsPermission() async throws {
        let (_, client, stub) = try await setup([], enabled: false)
        do { _ = try await client.notificationSettings(); XCTFail("Missing capability") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testCapturedPreferencesSaveHasRevisionAndPinnedAccount() async throws {
        let (_, client, stub) = try await setup([response(settings), response(settings)])
        let original = try await client.notificationSettings()
        _ = try await client.saveNotificationSettings(original, choices: original.preferences)
        let requests = await stub.history()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["expectedRevision"] as? Int, 7)
        XCTAssertNil(body["userId"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-Catalog-Expected-Account"), account.uuidString.lowercased())
    }
    func testUnavailableApplePushCannotEnableOrSendFallback() async throws {
        let (_, client, stub) = try await setup([])
        let original = try JSONDecoder().decode(NativeNotificationSettings.self, from: Data(settings.utf8))
        var choices = original.preferences; choices.applePushEnabled = true
        do { _ = try await client.saveNotificationSettings(original, choices: choices); XCTFail("Unavailable push") } catch {}
        let requests = await stub.history(); XCTAssertEqual(requests.count, 2)
    }
    func testConflictPreservesImmutableCapturedChoicesWithoutRetry() async throws {
        let (_, client, stub) = try await setup([response(#"{"code":"notification_preferences_changed","message":"Refresh required"}"#, status: 409)])
        let original = try JSONDecoder().decode(NativeNotificationSettings.self, from: Data(settings.utf8))
        var choices = original.preferences; choices.categories.eventReminders = true
        do { _ = try await client.saveNotificationSettings(original, choices: choices); XCTFail("Conflict") } catch {}
        XCTAssertTrue(choices.categories.eventReminders); XCTAssertEqual(original.revision, 7)
        let requests = await stub.history(); XCTAssertEqual(requests.count, 3)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        let categories = try XCTUnwrap(body["categories"] as? [String: Bool]); XCTAssertEqual(categories["eventReminders"], true)
        XCTAssertNil(body["rsvp"]); XCTAssertNil(body["latitude"]); XCTAssertNil(body["location"])
    }
    func testGenericReferenceRejectsRoutesCoordinatesAndUnsafeNumericConversion() throws {
        func value(_ reference: String) -> NativeActivityNotice {
            NativeActivityNotice(id: account, type: .eventReminder, referenceId: reference,
                createdAtISO: "2026-11-06T00:00:00Z", readAtISO: nil)
        }
        XCTAssertEqual(try value("\(account):" + String(repeating: "9", count: 63)).reference(), account)
        XCTAssertThrowsError(try value("https://example.invalid/event").reference())
        XCTAssertThrowsError(try value("\(account):").reference())
        XCTAssertThrowsError(try value("\(account):latitude=45").reference())
    }
}
