import XCTest
import UIKit
import BackpackProtocol
@testable import LEDBackpack

@MainActor private final class FriendSelectionIdle: PhoneIdleTimer { var disabled = false }
@MainActor private final class FriendSelectionBrightness: PhoneScreenBrightness { var value = 0.3 }
@MainActor
final class FriendArtworkSelectionTests: XCTestCase {
    private let owner = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let peer = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let sessionID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private func gif(_ color: UInt8 = 0, delays: [UInt16] = [3]) -> Data {
        var bytes = Array("GIF89a".utf8) + [1,0,1,0,128,0,0,color,0,0,255,255,255]
        for (index, delay) in delays.enumerated() {
            let pixel: UInt8 = index.isMultiple(of: 2) ? 68 : 76
            bytes += [33,249,4,0,UInt8(truncatingIfNeeded: delay),UInt8(delay >> 8),0,0,
                44,0,0,0,0,1,0,1,0,0,2,2,pixel,1,0]
        }
        return Data(bytes + [59])
    }
    private func phone() -> PhoneDisplayController {
        let value = PhoneDisplayController(idleTimer: FriendSelectionIdle(), brightness: FriendSelectionBrightness())
        value.setForeground(true); value.setVisible(true); return value
    }
    private func session(_ kind: FriendInteractionKind = .greeting, direction: String = "outgoing") -> NativeFriendSession {
        NativeFriendSession(id: sessionID, revision: 2, durationSeconds: 300, kind: kind, direction: direction,
            status: "active", expiresAtISO: "2026-11-06T12:05:00Z", serverTimeISO: "2026-11-06T12:00:00Z",
            peer: SocialPerson(id: peer, displayName: "Synthetic friend"), ownedByCurrentSession: true,
            coordinatesIncluded: false, physicalProximityVerified: false, playbackStarted: false,
            automaticGifExchangeEnabled: false, clockSynchronizationVerified: false, historyStored: false)
    }
    @discardableResult
    private func select(_ store: FriendArtworkSelection, _ data: Data, gifOnly: Bool = false,
        attribution: Attribution? = nil) async -> Bool {
        await store.select(name: "Explicit fixture choice", attribution: attribution, requiresOutgoingGIF: gifOnly,
            read: { data }, context: {})
    }
    func testChoosingInteractionArtworkNeverMutatesPhoneOrItsSelectionRevision() async throws {
        let display = phone(), selection = FriendArtworkSelection()
        try await display.show(gif(1))
        let before = display.snapshot(), revision = display.artworkRevision
        let changed = await select(selection, gif(2))
        XCTAssertTrue(changed); XCTAssertEqual(selection.choice?.data, gif(2))
        XCTAssertEqual(display.data, before.data); XCTAssertEqual(display.artworkRevision, revision)
        XCTAssertEqual(display.snapshot().wantsPlayback, before.wantsPlayback)
    }
    func testCorruptOrOversizedImportExplicitlyFailsWithPreviousChoicePreserved() async {
        let selection = FriendArtworkSelection()
        _ = await select(selection, gif())
        let original = selection.choice?.id
        for data in [Data([1,2,3]), Data(repeating: 0, count: 5_000_001)] {
            let changed = await select(selection, data)
            XCTAssertFalse(changed); XCTAssertNotNil(selection.failure)
            XCTAssertEqual(selection.choice?.id, original); XCTAssertEqual(selection.choice?.data, gif())
        }
    }
    func testPassChoiceKeepsOriginalPrivateMetadataAndOnlyOutgoingCandidateStripsIt() async throws {
        let selection = FriendArtworkSelection()
        var source = gif(); source.insert(contentsOf: [33,254,3,97,98,99,0], at: 19)
        let changed = await select(selection, source, gifOnly: true)
        XCTAssertTrue(changed); XCTAssertEqual(selection.choice?.data, source)
        XCTAssertEqual(try PrivateOutgoingGIF.make(source), gif())
    }
    func testPassRejectsSupportedPhoneStillWithoutSecretConversionOrSelectionLoss() async throws {
        let selection = FriendArtworkSelection()
        let png = try XCTUnwrap(try PixelFrame.black(PanelSize(width: 1, height: 1)).image().pngData())
        let acceptedStill = await select(selection, png)
        XCTAssertTrue(acceptedStill)
        let retained = selection.choice?.id
        let sharedStill = await select(selection, png, gifOnly: true)
        XCTAssertFalse(sharedStill); XCTAssertEqual(selection.choice?.id, retained)
        XCTAssertEqual(selection.choice?.data, png)
    }
    func testCancelledReadCannotAdoptLateBytesOrClearPreviousSelection() async {
        let selection = FriendArtworkSelection()
        _ = await select(selection, gif(1))
        let original = selection.choice?.id, next = gif(2)
        let changed = await selection.select(name: "Late", attribution: nil, requiresOutgoingGIF: false,
            read: { selection.cancelPending(); return next }, context: {})
        XCTAssertFalse(changed); XCTAssertFalse(selection.reading)
        XCTAssertEqual(selection.choice?.id, original)
    }
    func testAccountOrSessionContextLossAfterDecodeRejectsLateResult() async {
        let selection = FriendArtworkSelection()
        _ = await select(selection, gif(1))
        let original = selection.choice?.id, data = gif(2)
        var checks = 0
        let changed = await selection.select(name: "Late account", attribution: nil, requiresOutgoingGIF: false,
            read: { data }, context: {
                checks += 1
                if checks == 3 { throw CancellationError() }
            })
        XCTAssertFalse(changed); XCTAssertEqual(checks, 3)
        XCTAssertEqual(selection.choice?.id, original)
    }
    func testIsolatedPresetPreviewDoesNotOverwriteChoiceOrGlobalPhone() async throws {
        let selection = FriendArtworkSelection(), display = phone()
        try await display.show(gif(1)); _ = await select(selection, gif(2))
        let chosenID = selection.choice?.id, revision = display.artworkRevision
        await selection.previewPreset(kind: .duet, preset: .aurora, sender: true, context: {})
        XCTAssertEqual(selection.preview?.frames.count, 24)
        XCTAssertEqual(selection.choice?.id, chosenID); XCTAssertEqual(selection.choice?.data, gif(2))
        XCTAssertEqual(display.artworkRevision, revision); XCTAssertEqual(display.data, gif(1))
        XCTAssertFalse(selection.playing)
    }
    func testPreviewStartsPausedHonorsSourceTimingAndStopsWithoutAutoResume() async throws {
        let selection = FriendArtworkSelection()
        let data = gif(delays: [3,12])
        _ = await select(selection, data)
        let preview = try XCTUnwrap(selection.preview)
        XCTAssertEqual(preview.frames.count, 2)
        XCTAssertEqual(preview.duration, 0.15, accuracy: 0.000001)
        XCTAssertFalse(selection.playing)
        XCTAssertEqual(selection.position(at: 0.02).index, 0)
        XCTAssertEqual(selection.position(at: 0.04).index, 1)
        XCTAssertTrue(selection.position(at: 0.2).finished)
        selection.play(allowed: true); XCTAssertTrue(selection.playing)
        selection.play(allowed: false); XCTAssertFalse(selection.playing)
        selection.pause(); XCTAssertFalse(selection.playing); XCTAssertEqual(selection.choice?.data, data)
    }
    func testGreetingAuthorityUsesSeparateChosenBytesAndKeepsOriginalSnapshotUntouched() async throws {
        let display = phone(), selection = FriendArtworkSelection()
        try await display.show(gif(1)); _ = await select(selection, gif(2))
        let revision = display.artworkRevision
        let intent = try AcceptedFriendAuthority(session: session(), preset: .aurora, consent: true,
            phone: display, account: owner, attribution: nil, artwork: selection.choice)
        XCTAssertEqual(intent.chosenArtwork, gif(2)); XCTAssertEqual(intent.initialRevision, revision)
        XCTAssertEqual(display.snapshot().data, gif(1))
        let actualScene = try FriendInteractionPixels.render(kind: .greeting, preset: .aurora, sender: true,
            chosen: intent.chosenArtwork, received: nil)
        XCTAssertEqual(actualScene, gif(2)); XCTAssertEqual(display.data, gif(1))
    }
    func testPassRecipientIgnoresSuppliedPrivateChoiceAndNeverUsesItAsOutgoingContent() async throws {
        let display = phone(), selection = FriendArtworkSelection()
        try await display.show(gif(1)); _ = await select(selection, gif(2))
        let intent = try AcceptedFriendAuthority(session: session(.pass, direction: "incoming"), preset: .aurora,
            consent: true, phone: display, account: owner, attribution: nil, artwork: selection.choice)
        XCTAssertFalse(intent.mainSender); XCTAssertEqual(intent.chosenArtwork, gif(1))
        XCTAssertNil(intent.chosenAttribution)
    }
    func testClearingAccountDraftDropsPrivateChoicePreviewAndPendingPlayback() async {
        let selection = FriendArtworkSelection()
        _ = await select(selection, gif())
        await selection.previewPreset(kind: .palette, preset: .sunset, sender: true, context: {})
        selection.play(allowed: true); XCTAssertTrue(selection.playing)
        selection.clear()
        XCTAssertNil(selection.choice); XCTAssertNil(selection.preview)
        XCTAssertFalse(selection.playing); XCTAssertFalse(selection.reading)
    }
    func testRejectedArmDoesNotConsumeSessionOrInitializeRadio() {
        let engine = PhoneSwapGame()
        XCTAssertFalse(engine.radio.ready)
        XCTAssertFalse(engine.enable(consent: false, attribution: nil))
        XCTAssertFalse(engine.enabled); XCTAssertFalse(engine.busy)
        let store = FriendPhoneInteractionStore()
        store.arm(session(), consent: true, attribution: nil)
        XCTAssertTrue(store.consumed.isEmpty); XCTAssertNotNil(store.failure)
    }
    func testDurableRecoveryCapturesDisplayedOriginalNotChosenGreeting() async throws {
        let display = phone(), selection = FriendArtworkSelection()
        try await display.show(gif(1)); _ = await select(selection, gif(2))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("friend-selection-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = SwapRecoveryRepository(root: root)
        let original = try await repository.prepareGame(snapshot: display.snapshot(), artworkRevision: display.artworkRevision,
            ownerScope: "fixture-owner", attribution: nil, purpose: "friend-v1:" + sessionID.uuidString.lowercased())
        XCTAssertEqual(original.phone.data, gif(1)); XCTAssertNotEqual(original.phone.data, selection.choice?.data)
        let reopened = try await SwapRecoveryRepository(root: root).load()
        XCTAssertEqual(reopened?.phone.data, gif(1))
    }
    func testSeparateChoiceNeverInheritsUnrelatedOriginalAttribution() async throws {
        let display = phone(), selection = FriendArtworkSelection()
        try await display.show(gif(1)); _ = await select(selection, gif(2))
        let originalCredit = Attribution(source: "Original local source", author: "Original author", license: "Original license", licenseURL: "")
        let intent = try AcceptedFriendAuthority(session: session(), preset: .aurora, consent: true,
            phone: display, account: owner, attribution: originalCredit, artwork: selection.choice)
        XCTAssertNil(intent.chosenAttribution); XCTAssertEqual(intent.chosenArtwork, gif(2))
    }
}
