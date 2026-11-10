import XCTest
@testable import LEDBackpack

@MainActor
final class NativeMessagingPresentationTests: XCTestCase {
    private let peer = UUID()
    private let event = UUID()
    private func scope(origin: String = "https://catalog.example", account: UUID = UUID(),
                       revision: UUID = UUID(), access: UUID = UUID()) -> NativeChatDraftScope {
        .init(origin: origin, account: account, accountRevision: revision, accessRevision: access)
    }

    func testDirectOrganizerAndRoomDraftsNeverMerge() {
        let store = NativeChatDraftStore(), identity = scope()
        let direct = ChatConversation.direct(peer: peer, event: nil)
        let organizer = ChatConversation.direct(peer: peer, event: event)
        let room = ChatConversation.room(event)
        _ = store.restore(scope: identity, context: direct)
        XCTAssertTrue(store.save(.init(text: "Direct"), scope: identity, context: direct))
        XCTAssertTrue(store.save(.init(text: "Organizer"), scope: identity, context: organizer))
        XCTAssertTrue(store.save(.init(text: "Room"), scope: identity, context: room))
        XCTAssertEqual(store.restore(scope: identity, context: direct)?.text, "Direct")
        XCTAssertEqual(store.restore(scope: identity, context: organizer)?.text, "Organizer")
        XCTAssertEqual(store.restore(scope: identity, context: room)?.text, "Room")
    }
    func testAccountOriginAndAuthorizationChangesDiscardPreviousDrafts() {
        let original = scope(), context = ChatConversation.direct(peer: peer, event: nil)
        let changes = [
            scope(origin: "https://other.example", account: original.account, revision: original.accountRevision, access: original.accessRevision),
            scope(account: UUID(), revision: original.accountRevision, access: original.accessRevision),
            scope(account: original.account, revision: UUID(), access: original.accessRevision),
            scope(account: original.account, revision: original.accountRevision, access: UUID())
        ]
        for changed in changes {
            let store = NativeChatDraftStore()
            _ = store.restore(scope: original, context: context)
            store.save(.init(text: "Private draft"), scope: original, context: context)
            XCTAssertNil(store.restore(scope: changed, context: context))
            XCTAssertNil(store.restore(scope: original, context: context))
        }
    }
    func testOldViewCannotWriteOrEraseAnotherActiveScope() {
        let store = NativeChatDraftStore(), first = scope(), next = scope()
        let context = ChatConversation.direct(peer: peer, event: nil)
        _ = store.restore(scope: first, context: context)
        _ = store.restore(scope: next, context: context)
        store.save(.init(text: "Current account"), scope: next, context: context)
        XCTAssertFalse(store.save(.init(text: "Stale account"), scope: first, context: context))
        store.remove(scope: first, context: context)
        XCTAssertEqual(store.restore(scope: next, context: context)?.text, "Current account")
    }
    func testClearingOneDraftDoesNotClearAnotherConversation() {
        let store = NativeChatDraftStore(), identity = scope()
        let direct = ChatConversation.direct(peer: peer, event: nil), room = ChatConversation.room(event)
        _ = store.restore(scope: identity, context: direct)
        store.save(.init(text: "One"), scope: identity, context: direct)
        store.save(.init(text: "Two"), scope: identity, context: room)
        store.save(.init(), scope: identity, context: direct)
        XCTAssertNil(store.restore(scope: identity, context: direct))
        XCTAssertEqual(store.restore(scope: identity, context: room)?.text, "Two")
    }
    func testUnsentPlaceRetainsItsExactCoordinates() {
        let store = NativeChatDraftStore(), identity = scope(), context = ChatConversation.room(event)
        _ = store.restore(scope: identity, context: context)
        let pin = ChatPin(label: "Meeting point", latitude: 40.12, longitude: -83.45)
        store.save(.init(text: "Here", pin: pin), scope: identity, context: context)
        XCTAssertEqual(store.restore(scope: identity, context: context)?.pin, pin)
    }
    func testExplicitInvalidationDoesNotReviveDrafts() {
        let store = NativeChatDraftStore(), identity = scope(), context = ChatConversation.room(event)
        _ = store.restore(scope: identity, context: context)
        store.save(.init(text: "Private"), scope: identity, context: context)
        store.invalidate()
        XCTAssertFalse(store.save(.init(text: "Stale"), scope: identity, context: context))
        XCTAssertNil(store.restore(scope: identity, context: context))
    }
    func testSearchUsesOnlyNamesAndAuthorizedContextDescriptions() {
        let filter = NativeChatInboxFilter.chats
        XCTAssertTrue(filter.matches("Casey", context: "Private organizer question", query: " casey "))
        XCTAssertTrue(filter.matches("Casey", context: "Private organizer question", query: "organizer"))
        XCTAssertFalse(filter.matches("Casey", context: "Private organizer question", query: "unloaded message content"))
        XCTAssertTrue(filter.matches("Casey", context: "Direct message", query: "  "))
    }
    func testInboxSortsSupportedActivityWithoutMergingContexts() {
        let profile = SocialPerson(id: peer, displayName: "Casey")
        let direct = RecentChatContact(profile: profile, eventId: nil, lastMessageCreatedAt: 100)
        let organizer = RecentChatContact(profile: profile, eventId: event, lastMessageCreatedAt: 300)
        let room = NativeChatRoom(id: event, kind: "group", title: "Ride", eventId: nil, ownerId: nil,
            revision: 1, archived: false, canManage: false, canSend: true, updatedAt: 200,
            readSequence: 0, latestSequence: 1, unread: 1)
        let entries = [NativeChatInboxEntry.direct(direct), .room(room), .direct(organizer)]
            .sorted(by: NativeChatInboxEntry.newestFirst)
        XCTAssertEqual(entries.map(\.updatedAt), [300, 200, 100])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
    }
}
