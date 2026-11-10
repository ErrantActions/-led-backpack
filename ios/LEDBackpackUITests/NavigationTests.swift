import XCTest
import UIKit

final class NavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        let app = XCUIApplication()
        if app.state == .runningForeground {
            attach(app, name: "Final native layout")
            if (testRun?.failureCount ?? 0) > 0 {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Native accessibility hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
        }
    }

    func testGuestLibraryAndCreateLandingHaveNoPermanentEntryForms() throws {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons["OK"].exists { alert.buttons["OK"].tap(); return true }
            return false
        }
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.waitForExistence(timeout: 2) {
            if permission.buttons["Allow"].exists { permission.buttons["Allow"].tap() }
            else if permission.buttons["OK"].exists { permission.buttons["OK"].tap() }
        }
        XCTAssertTrue(app.buttons["Discover GIFs"].exists)
        XCTAssertTrue(app.buttons["Discover GIFs"].isHittable)
        XCTAssertFalse(app.buttons["On iPhone"].exists)
        XCTAssertFalse(app.buttons["Cloud"].exists)
        XCTAssertTrue(app.buttons["Library sync settings"].exists)
        // Accessibility rectangles can subtract to 43.99999999999997 for a 44-point control.
        XCTAssertGreaterThanOrEqual(app.buttons["Library sync settings"].frame.height, 44 - 0.000001)
        assertNoVisibleEntryForms(app)
        attach(app, name: "Unified guest library - no storage scopes")
        reveal(app.buttons["Preview Night ride"], in: app)
        XCTAssertTrue(app.buttons["Preview Night ride"].exists)
        XCTAssertFalse(app.staticTexts["Night ride"].exists)
        XCTAssertFalse(app.staticTexts["Animated preview"].exists)
        XCTAssertFalse(app.staticTexts["Tap to animate"].exists)
        attach(app, name: "Guest Library - artwork-only animated tiles")
        verifyImportPicker("Photo or GIF", in: app)
        verifyImportPicker("Image or GIF file", in: app)

        app.buttons["Catalog account"].tap()
        XCTAssertTrue(app.navigationBars["Catalog account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue with Apple"].waitForExistence(timeout: 10))
        assertNoVisibleEntryForms(app)
        attach(app, name: "Account - Apple primary and email collapsed")
        app.buttons["Continue with email"].tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap(); email.typeText("ui@example.invalid")
        let password = app.secureTextFields["Password"]
        password.tap(); password.typeText("fixture-password")
        app.keyboards.buttons["Go"].tap()
        let accountName = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI Rider")).firstMatch
        XCTAssertTrue(accountName.waitForExistence(timeout: 10))
        let back = app.buttons["BackButton"]
        attach(app, name: "Signed-in account - native vertical back rail")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in back.exists && back.isEnabled && back.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        attach(app, name: "Signed-in account - persistent system back navigation")
        back.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        let artwork = app.buttons["Preview Meetup glow"]
        reveal(artwork, in: app)
        XCTAssertFalse(app.staticTexts["Meetup glow"].exists)
        artwork.press(forDuration: 1)
        app.buttons["Submit to community review"].tap()
        XCTAssertTrue(app.navigationBars["Upload GIF"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Title"].exists)
        XCTAssertFalse(app.textFields["Creator / attribution"].exists)
        XCTAssertFalse(app.buttons["License / permission"].exists)
        XCTAssertFalse(app.buttons["Submit to community review"].isEnabled)
        attach(app, name: "Community review - explicit consent without creator or license choices")
        app.buttons["community-upload-close"].tap()
        reveal(app.buttons["Preview Night ride"], in: app)
        reveal(app.buttons["Preview Cloud demo"], in: app)
        XCTAssertFalse(app.staticTexts["Cloud demo"].exists)
        attach(app, name: "Unified Library - local and private cloud")
        XCTAssertEqual(app.buttons.matching(identifier: "Preview Cloud demo").count, 1)
        reveal(app.buttons["Preview Cloud demo"], in: app)
        app.buttons["Preview Cloud demo"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Display on phone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit a copy"].exists)
        XCTAssertFalse(app.buttons["Keep on this iPhone"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.03)).tap()
        let menuClosed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["Edit a copy"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [menuClosed], timeout: 5), .completed)
        returnToHeader(app)
        XCTAssertFalse(app.buttons["On iPhone"].exists)
        XCTAssertFalse(app.buttons["Cloud"].exists)

        let createTab = app.buttons["Create"]
        XCTAssertTrue(createTab.waitForExistence(timeout: 10)); createTab.tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Text to GIF")).firstMatch.exists)
        assertNoVisibleEntryForms(app)
        attach(app, name: "Create - focused tool chooser")

        app.buttons.matching(NSPredicate(format: "label == %@", "Backpack")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["LED Backpack"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan for backpacks"].isHittable)
        assertNoVisibleEntryForms(app)
        attach(app, name: "Backpack - advanced fields collapsed")
        reveal(app.staticTexts["INDEPENDENT LED CONTROL"], in: app)
        attach(app, name: "Aurora backpack - original floating pixel canvas")

        app.buttons.matching(NSPredicate(format: "label == %@", "Live")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Live"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Customize"].waitForExistence(timeout: 10))
        attach(app, name: "Aurora live studio - preview and atmosphere")
        reveal(app.buttons["Customize"], in: app)
        app.buttons["Customize"].tap()
        XCTAssertTrue(app.navigationBars["Make it yours"].waitForExistence(timeout: 5))
        reveal(app.buttons["Cyan ink"], in: app)
        attach(app, name: "Aurora theme studio - accessible ink palette")
        app.buttons["Cancel"].tap()

        app.buttons.matching(NSPredicate(format: "label == %@", "Library")).firstMatch.tap()
        returnToHeader(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Discover GIFs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Discover GIFs"].isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.intersects(app.buttons["Discover GIFs"].frame))
        attach(app, name: "Duo Library - landscape orientation request")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Discover GIFs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Discover GIFs"].isHittable)
        attach(app, name: "Duo Library - portrait orientation request")
    }

    func testCommunityGridSelectsMultipleFavoritesAndDirectSendWithoutDetailOrRadio() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Discover GIFs"].waitForExistence(timeout: 20))
        app.buttons["Discover GIFs"].tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 10))
        let first = app.buttons["community-gif-cccccccc-1234-4567-89ab-abcdefabcdef"]
        let second = app.buttons["community-gif-dddddddd-1234-4567-89ab-abcdefabcdef"]
        reveal(first, in: app); XCTAssertTrue(first.waitForExistence(timeout: 10)); first.tap()
        XCTAssertFalse(app.navigationBars["Community GIF"].exists)
        reveal(second, in: app); second.tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        XCTAssertFalse(app.staticTexts["Public fixture 1"].exists)
        XCTAssertFalse(app.staticTexts["Fixture author"].exists)
        app.buttons["community-favorite-selection"].tap()
        let saved = app.staticTexts["2 GIFs added to your local Favorites. Credits retained; no public likes/cloud upload."]
        XCTAssertTrue(saved.waitForExistence(timeout: 20))
        reveal(app.buttons["My Favorites"], in: app); app.buttons["My Favorites"].tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Select favorite GIF").count, 2)
        XCTAssertFalse(app.staticTexts["Public fixture 1"].exists)
        attach(app, name: "Community selection and image-only Favorites")
        let favoritesBack = app.buttons["BackButton"]
        XCTAssertTrue(favoritesBack.waitForExistence(timeout: 5))
        let backReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in favoritesBack.exists && favoritesBack.isEnabled && favoritesBack.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backReady], timeout: 10), .completed)
        favoritesBack.tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 5))
        reveal(first, in: app); first.tap(); reveal(second, in: app); second.tap()
        app.buttons["community-send-selection"].tap()
        XCTAssertTrue(app.navigationBars["Send & Play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connect your backpack, then retry."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send & Play on backpack"].exists)
        let prepare = app.buttons["Prepare / update send copies"]
        reveal(prepare, in: app, requireHittable: false)
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertFalse(prepare.isEnabled)
        attach(app, name: "Community direct Send & Play - no forced local save or radio scan")
    }

    func testGPSGamesHubAndSoloAreReachableWithSensingOffUntilConsent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        let games = app.buttons["GPS & nearby games"]
        XCTAssertTrue(games.waitForExistence(timeout: 20))
        reveal(games, in: app); XCTAssertTrue(games.isHittable); games.tap()
        XCTAssertTrue(app.navigationBars["GPS & nearby games"].waitForExistence(timeout: 10))
        let solo = app.buttons["My local places / adventure / distance milestones"]
        XCTAssertTrue(solo.waitForExistence(timeout: 5)); solo.tap()
        XCTAssertTrue(app.navigationBars["SOLO local scenes"].waitForExistence(timeout: 10))
        let permission = app.buttons["Request When-In-Use location permission deliberately"]
        reveal(permission, in: app); XCTAssertTrue(permission.exists)
        XCTAssertFalse(permission.isEnabled)
        let phoneOptions = app.buttons["Phone animation"]
        reveal(phoneOptions, in: app); phoneOptions.tap()
        let automation = app.buttons["Capture durable original and arm PHONE"]
        reveal(automation, in: app, requireHittable: false)
        XCTAssertTrue(automation.exists); XCTAssertFalse(automation.isEnabled)
        assertNoVisibleEntryForms(app)
        XCTAssertFalse(app.buttons["Create scene"].isHittable)
        let scenes = app.buttons["Scenes & playlists"]
        reveal(scenes, in: app); scenes.tap()
        let createScene = app.buttons["Create scene"]
        reveal(createScene, in: app)
        XCTAssertTrue(createScene.isHittable)
        attach(app, name: "GPS games entry and explicit default-off SOLO consents")
    }

    func testSocialTabGroupsFeaturesWithoutGrantingGuestPrivateAccess() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        let social = app.buttons.matching(NSPredicate(format: "label == %@", "Social")).firstMatch
        XCTAssertTrue(social.waitForExistence(timeout: 20)); social.tap()
        XCTAssertTrue(app.navigationBars["Social"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Community GIF gallery"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sign in for friends, events and messaging"].exists)
        assertNoVisibleEntryForms(app)
        let friends = app.buttons["social-primary-friends"]
        reveal(friends, in: app, requireHittable: false)
        XCTAssertTrue(friends.exists); XCTAssertFalse(friends.isEnabled)
        attach(app, name: "Social tab - grouped features, private capabilities sign-in gated")
    }

    func testEachSocialTileOpensItsOwnFeatureAndReturnsToSocial() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--social-ui-fixture"]
        app.launch()
        signInFixture(app)
        let social = app.buttons.matching(NSPredicate(format: "label == %@", "Social")).firstMatch
        social.tap()
        let routes = [
            ("friends", "Friends & profile", "No friends yet"), ("messages", "Messages", "No conversations yet"),
            ("events", "Events", "No events yet"), ("games", "GPS & nearby games", "Choose your next game")
        ]
        for (route, title, content) in routes {
            XCTAssertTrue(app.navigationBars["Social"].waitForExistence(timeout: 10))
            let tile = app.buttons["social-primary-\(route)"]
            reveal(tile, in: app); XCTAssertTrue(tile.isEnabled); tile.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "The \(route) tile must open \(title).")
            XCTAssertTrue(app.staticTexts[content].waitForExistence(timeout: 10), "Verify actual \(route) content, not just a title.")
            for (_, other, _) in routes where other != title {
                XCTAssertFalse(app.navigationBars[other].isHittable, "Do not route \(route) to \(other).")
            }
            attach(app, name: "Social \(route) - distinct intended destination")
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        XCTAssertTrue(app.navigationBars["Social"].waitForExistence(timeout: 10))
    }

    func testEventInvitationsAreEasyToFindAndCreationStartsWithOnlyEssentials() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--social-ui-fixture", "--events-ui-fixture"]
        app.launch()
        signInFixture(app)
        app.buttons.matching(NSPredicate(format: "label == %@", "Social")).firstMatch.tap()
        let events = app.buttons["social-primary-events"]
        XCTAssertTrue(events.waitForExistence(timeout: 10)); XCTAssertTrue(events.isHittable)
        attach(app, name: "Social - prominent Events entry")
        events.tap()
        XCTAssertTrue(app.navigationBars["Events"].waitForExistence(timeout: 10))
        let card = app.buttons["event-card-eeeeeeee-1234-4567-89ab-abcdefabcdef"]
        reveal(card, in: app)
        attach(app, name: "Events - visual browse, yours and invitations")
        card.tap()
        XCTAssertTrue(app.navigationBars["Event"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Glow in the park"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Fountain plaza"].exists)
        XCTAssertTrue(app.buttons["event-rsvp"].exists)
        XCTAssertFalse(app.staticTexts["Bring your favorite lights. Meet by the fountain, then take a relaxed ride together."].isHittable)
        attach(app, name: "Aurora event invitation - essentials visible, extras collapsed")
        app.buttons["BackButton"].tap()
        let create = app.buttons["events-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        XCTAssertTrue(app.navigationBars["Create event"].waitForExistence(timeout: 10))
        let title = app.textFields["event-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("My next plan\n")
        XCTAssertFalse(app.buttons["event-preview-invitation"].isEnabled)
        let times = app.switches["event-confirm-times"]
        reveal(times, in: app)
        XCTAssertEqual(times.value as? String, "0")
        XCTAssertFalse(app.staticTexts["Step 1 of4: Basics"].exists)
        attach(app, name: "Quick event creation - no wizard, no automatic time consent")
        let cancel = app.buttons["event-create-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(app.navigationBars["Events"].waitForExistence(timeout: 10))
    }

    func testNativeMessagingRetainsContextDraftsAndUsesServerAcceptanceNotReadReceipts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--social-ui-fixture", "--messaging-ui-fixture"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        signInFixture(app)
        app.buttons.matching(NSPredicate(format: "label == %@", "Social")).firstMatch.tap()
        let messages = app.buttons["social-primary-messages"]
        reveal(messages, in: app); messages.tap()
        XCTAssertTrue(app.navigationBars["Messages"].waitForExistence(timeout: 10))
        let maya = "chat-contact-33333333-1234-4567-89ab-abcdefabcdef-direct"
        let casey = "chat-contact-44444444-1234-4567-89ab-abcdefabcdef-direct"
        func open(_ id: String) {
            let composer = app.descendants(matching: .any).matching(identifier: "chat-message-input").firstMatch
            if composer.exists && !app.buttons[id].isHittable {
                let back = app.buttons["BackButton"]
                XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
            }
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10))
            reveal(app.buttons[id], in: app)
            XCTAssertTrue(app.buttons[id].isHittable); app.buttons[id].tap()
        }
        open(maya)
        let input = app.descendants(matching: .any).matching(identifier: "chat-message-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("Maya private draft")
        attach(app, name: "Aurora Messages - native conversation and anchored composer")
        open(casey)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(["", "Message"].contains(input.value as? String ?? ""))
        input.tap(); input.typeText("Casey separate draft")
        open(maya)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "Maya private draft")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertEqual(input.value as? String, "Maya private draft")
            attach(app, name: "Aurora Messages - native orientation \(orientation.rawValue)")
        }
        let send = app.buttons["chat-send-message"]
        XCTAssertTrue(send.waitForExistence(timeout: 10)); XCTAssertTrue(send.isEnabled); send.tap()
        XCTAssertTrue(app.staticTexts["Maya private draft"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Delivered"].exists)
        XCTAssertFalse(app.staticTexts["Seen"].exists)
        attach(app, name: "Aurora Messages - persisted fixture result without peer receipts")
    }

    func testCommunityLoadsNextPageByScrollingWithoutLoadMore() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--pagination-ui-fixture"]
        app.launch()
        let discover = app.buttons["Discover GIFs"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20)); discover.tap()
        XCTAssertTrue(app.navigationBars["Community"].waitForExistence(timeout: 10))
        let first = app.buttons["community-gif-cccccccc-1234-4567-89ab-000000000001"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Load more"].exists)
        let last = app.buttons["community-gif-cccccccc-1234-4567-89ab-000000000030"]
        reveal(last, in: app, maximumSwipes: 20); XCTAssertTrue(last.exists)
        let results = app.staticTexts["community-page-count"]
        reveal(results, in: app)
        XCTAssertEqual(results.label, "30 GIFs · End of results")
        XCTAssertFalse(app.buttons["Load more"].exists)
        attach(app, name: "Community - next page acknowledged from near-end visibility")
    }

    func testAddFriendsMatchesSketchAndNeverStartsDiscoveryOnEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--social-ui-fixture"]
        app.launch(); signInFixture(app)
        app.buttons.matching(NSPredicate(format: "label == %@", "Social")).firstMatch.tap()
        let friends = app.buttons["social-primary-friends"]
        reveal(friends, in: app); friends.tap()
        let add = app.buttons["Add friends"]
        reveal(add, in: app); add.tap()
        XCTAssertTrue(app.navigationBars["Add friends"].waitForExistence(timeout: 10))
        for id in ["add-friends-look", "add-friends-my-qr", "add-friends-scan-qr"] {
            XCTAssertTrue(app.buttons[id].exists); XCTAssertTrue(app.buttons[id].isHittable)
        }
        XCTAssertTrue(app.switches["find-me-toggle"].exists)
        XCTAssertTrue(app.staticTexts["Discovery off"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "add-friends-empty").firstMatch.exists)
        attach(app, name: "Add friends - three actions, Find Me off, real empty state")
        app.buttons["add-friends-my-qr"].tap()
        XCTAssertTrue(app.navigationBars["My QR Code"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Create a new 15-minute invitation"].exists)
        XCTAssertFalse(app.buttons["Scan friend QR with camera (explicit)"].exists)
        attach(app, name: "My QR Code - distinct subsection, no automatic code renewal")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Add friends"].waitForExistence(timeout: 10))
        app.buttons["add-friends-look"].tap()
        XCTAssertTrue(app.navigationBars["Discovery permission"].waitForExistence(timeout: 10))
        let enable = app.buttons["Enable Bluetooth"]
        XCTAssertTrue(enable.exists); XCTAssertFalse(enable.isEnabled)
        XCTAssertFalse(app.buttons["Start discovery"].exists)
        attach(app, name: "Find friends - separate default-off consent before Bluetooth")
        app.buttons["Cancel"].tap()
    }

    func testAppWideProcessesStartWithEssentialsAndKeepSafeExits() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Discover GIFs"].isHittable)
        XCTAssertFalse(app.staticTexts["Night ride"].exists)
        let collections = app.buttons["Playlists, scenes & send queue"]
        reveal(collections, in: app); collections.tap()
        let queue = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send queue (")).firstMatch
        reveal(queue, in: app); queue.tap()
        XCTAssertTrue(app.navigationBars["Send queue"].waitForExistence(timeout: 10))
        app.buttons["Add local GIFs"].tap()
        let add = app.buttons["Add to queue"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(add.isEnabled)
        let artwork = app.buttons["Select Night ride"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 10)); artwork.tap()
        XCTAssertTrue(add.isEnabled)
        attach(app, name: "App-wide - artwork selection and persistent queue actions")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(app.navigationBars["Send queue"].waitForExistence(timeout: 10))
        let review = app.buttons["Review and send 0 GIFs"]
        reveal(review, in: app, requireHittable: false)
        XCTAssertTrue(review.exists)
        XCTAssertFalse(review.isEnabled, "Cancelling selection must not enqueue or authorize hardware writes.")
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))

        app.buttons["Filter library"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings-save"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings-save"].isHittable)
        XCTAssertFalse(app.buttons["Request Always location permission"].exists)
        XCTAssertFalse(app.buttons["Export connection log"].exists)
        attach(app, name: "App-wide - settings essentials and persistent save or cancel")
        app.buttons["settings-done"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))

        app.buttons.matching(NSPredicate(format: "label == %@", "Create")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 10))
        assertNoVisibleEntryForms(app)
        attach(app, name: "App-wide - creation tool chooser")
        app.buttons.matching(NSPredicate(format: "label == %@", "Backpack")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Scan for backpacks"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Stop scan"].exists)
        assertNoVisibleEntryForms(app)
        attach(app, name: "App-wide - explicit hardware discovery, advanced controls collapsed")
        app.buttons.matching(NSPredicate(format: "label == %@", "Live")).firstMatch.tap()
        let start = app.buttons["live-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(start.isEnabled, "Previewing a live mode must not bypass the hardware connection gate.")
        XCTAssertGreaterThanOrEqual(start.frame.height, 44 - 0.000001)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(start.frame))
        attach(app, name: "App-wide - live preview and persistent gated primary action")
    }

    func testWorkflowEndScreensKeepAdvancedControlsCollapsedAndSettingsReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Filter library"].waitForExistence(timeout: 20))
        app.buttons["Filter library"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Export connection log"].exists)
        let catalog = app.buttons["Catalog server and account"]
        reveal(catalog, in: app); XCTAssertTrue(catalog.isHittable)
        attach(app, name: "Settings - account route reachable, diagnostics collapsed")
        let done = app.buttons["settings-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        let settingsClosed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["settings-done"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settingsClosed], timeout: 10), .completed)
        let artwork = app.buttons["Preview Night ride"]
        reveal(artwork, in: app); artwork.press(forDuration: 1)
        app.buttons["Edit a copy"].tap()
        XCTAssertTrue(app.navigationBars["GIF Studio"].waitForExistence(timeout: 10))
        let timing = app.buttons["Timing & loops"]
        reveal(timing, in: app)
        XCTAssertFalse(app.buttons["Use source timing"].exists)
        XCTAssertFalse(app.buttons["Reset manual edits"].exists)
        XCTAssertTrue(timing.isHittable)
        let save = app.buttons["Save GIF copy"]
        reveal(save, in: app); XCTAssertTrue(save.isHittable)
        attach(app, name: "GIF Studio - clear save action, advanced tools collapsed")
        let cancel = app.buttons["editor-cancel"]
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
    }

    private func signInFixture(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Catalog account"].waitForExistence(timeout: 20))
        app.buttons["Catalog account"].tap()
        let emailOption = app.buttons["Continue with email"]
        XCTAssertTrue(emailOption.waitForExistence(timeout: 10)); emailOption.tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5)); email.tap(); email.typeText("ui@example.invalid")
        app.secureTextFields["Password"].tap(); app.secureTextFields["Password"].typeText("fixture-password")
        app.keyboards.buttons["Go"].tap()
        let account = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI Rider")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
    }

    func testConnectedBackpackRegistrationRequiresSignInBeforeReadingHardware() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--social-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20))
        app.buttons["backpack"].tap()
        let add = app.buttons["connected-backpack-my-devices"]
        reveal(add, in: app); add.tap()
        XCTAssertTrue(app.navigationBars["My devices"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sign in to manage your backpacks"].exists)
        XCTAssertFalse(app.buttons["connected-backpack-read"].exists)
        XCTAssertFalse(app.textFields["connected-backpack-nickname"].exists)
        XCTAssertFalse(app.buttons["connected-backpack-add"].exists)
        attach(app, name: "Connected backpack - account consent before any identity read")
    }

    func testLiveMessageSurvivesReflowAndPrimaryControlsRemainReachable() throws {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Live workflow system permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons["OK"].exists { alert.buttons["OK"].tap(); return true }
            return false
        }
        app.launchArguments = ["--library-ui-fixture"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20))
        app.buttons.matching(NSPredicate(format: "label == %@", "Live")).firstMatch.tap()
        let picker = app.buttons["live-mode-picker"]
        reveal(picker, in: app); picker.tap()
        let mode = app.buttons["Scrolling message"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.tap()
        let field = app.textFields["live-message"]
        reveal(field, in: app); field.tap(); field.typeText("Reflow keeps this message")
        let draft = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(draft.contains("Reflow keeps this message"))
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            XCTAssertEqual(field.value as? String, draft)
            let customize = app.buttons["Customize"]
            reveal(customize, in: app); customize.tap()
            XCTAssertTrue(app.navigationBars["Make it yours"].waitForExistence(timeout: 10))
            app.buttons["Cancel"].tap()
            XCTAssertEqual(field.value as? String, draft)
            let start = app.buttons["live-start"]
            reveal(start, in: app, requireHittable: false)
            XCTAssertTrue(start.exists)
            XCTAssertFalse(start.isEnabled, "Reflow must not bypass the connected-hardware gate.")
            attach(app, name: "Live message reflow - \(orientation.rawValue), primary controls and draft")
        }
    }

    func testConnectedBackpackRegistrationDoesNotScanOrInventIdentityWhileDisconnected() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--social-ui-fixture"]
        app.launch()
        signInFixture(app)
        app.buttons["backpack"].tap()
        let add = app.buttons["connected-backpack-my-devices"]
        reveal(add, in: app); add.tap()
        XCTAssertTrue(app.navigationBars["My devices"].waitForExistence(timeout: 10))
        let read = app.buttons["connected-backpack-read"]
        reveal(read, in: app, requireHittable: false)
        XCTAssertTrue(read.exists)
        XCTAssertFalse(read.isEnabled)
        XCTAssertFalse(app.textFields["connected-backpack-nickname"].exists)
        XCTAssertFalse(app.switches["connected-backpack-consent"].exists)
        XCTAssertFalse(app.buttons["connected-backpack-add"].exists)
        attach(app, name: "Connected backpack - disconnected, no scan or fabricated vendor ID")
    }

    func testFoundUsersIsReachableWithoutStartingBluetoothOrInventingSwapSuccess() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        let games = app.buttons["GPS & nearby games"]
        XCTAssertTrue(games.waitForExistence(timeout: 20))
        reveal(games, in: app); games.tap()
        let swap = app.buttons["Automatic PHONE GIF exchange game"]
        XCTAssertTrue(swap.waitForExistence(timeout: 10))
        reveal(swap, in: app); swap.tap()
        XCTAssertTrue(app.navigationBars["Phone GIF swap game"].waitForExistence(timeout: 10))
        let found = app.staticTexts["Found Users"]
        reveal(found, in: app); XCTAssertTrue(found.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "found-users-empty").firstMatch.exists)
        XCTAssertTrue(app.staticTexts["No swaps yet"].exists)
        XCTAssertFalse(app.buttons["Prepare GAME Bluetooth (explicit)"].exists)
        XCTAssertFalse(app.buttons["Enable 5-minute phone-only game"].exists)
        XCTAssertFalse(app.buttons["Send friend request"].exists)
        XCTAssertTrue(app.buttons["Reload Found Users"].exists)
        attach(app, name: "Found Users - empty verified-pair collection, no sensor or friendship consent")
    }

    func testCompactTimingFlowRequiresFreshReviewAndSavesOnlyANewCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20))
        let artwork = app.buttons["Preview Night ride"]
        reveal(artwork, in: app); artwork.press(forDuration: 1)
        app.buttons["Adjust GIF timing / loops"].tap()
        XCTAssertTrue(app.navigationBars["GIF timing"].waitForExistence(timeout: 10))
        let save = app.buttons["Save copy"]
        reveal(save, in: app); XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(app.buttons["Review changes"].exists)
        XCTAssertFalse(app.switches["Use one frame delay"].isHittable)
        let faster = app.buttons["2×"]
        reveal(faster, in: app); faster.tap()
        XCTAssertTrue(app.staticTexts["Speed · 2.00×"].exists)
        XCTAssertFalse(app.switches["Use one frame delay"].isHittable)
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        let review = app.buttons["Review changes"]
        reveal(review, in: app); XCTAssertTrue(review.isEnabled); review.tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 20))
        reveal(save, in: app); XCTAssertTrue(save.isEnabled)
        let advanced = app.buttons["Advanced frame timing"]
        reveal(advanced, in: app); advanced.tap()
        let uniform = app.switches["Use one frame delay"].switches.firstMatch
        reveal(uniform, in: app); uniform.tap()
        XCTAssertEqual(uniform.value as? String, "1")
        XCTAssertTrue(app.staticTexts["Base frame delay 0.10s"].waitForExistence(timeout: 5))
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        reveal(review, in: app); review.tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 20))
        reveal(save, in: app); XCTAssertTrue(save.isEnabled)
        attach(app, name: "Compact timing - reviewed copy with advanced frame controls")
        save.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        let copy = app.buttons["Preview Night ride timed copy"]
        reveal(copy, in: app); XCTAssertTrue(copy.exists)
        reveal(artwork, in: app); XCTAssertTrue(artwork.exists)
        attach(app, name: "Timing save - new copy and original both retained")
    }

    func testExpandableDetailsButtonsFireOnlyTheChosenAction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        let create = app.buttons["paintbrush.pointed"]
        XCTAssertTrue(create.waitForExistence(timeout: 20)); create.tap()
        let tools = app.buttons["More tools"]
        reveal(tools, in: app); tools.tap()
        let fixture = app.buttons["Action isolation fixture"]
        reveal(fixture, in: app); fixture.tap()
        XCTAssertTrue(app.navigationBars["Action isolation"].waitForExistence(timeout: 10))
        app.buttons["Fixture actions"].tap()
        app.buttons["Primary fixture action"].tap()
        XCTAssertTrue(app.staticTexts["Primary: 1"].exists)
        XCTAssertTrue(app.staticTexts["Secondary: 0"].exists)
        app.buttons["Secondary fixture action"].tap()
        XCTAssertTrue(app.staticTexts["Primary: 1"].exists)
        XCTAssertTrue(app.staticTexts["Secondary: 1"].exists)
        attach(app, name: "Expandable details - chosen action fires independently")
    }

    func testEraseReviewUsesDefaultOffToggleInsteadOfTypingAndStillRequiresConnectedHardware() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture"]
        app.launch()
        let create = app.buttons["paintbrush.pointed"]
        XCTAssertTrue(create.waitForExistence(timeout: 20)); create.tap()
        let tools = app.buttons["More tools"]
        reveal(tools, in: app); tools.tap()
        let fixture = app.buttons["Erase review fixture"]
        reveal(fixture, in: app); fixture.tap()
        XCTAssertTrue(app.navigationBars["Erase backpack"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["Type ERASE ALL"].exists)
        let allow = app.switches["allow-backpack-erase"].switches.firstMatch
        reveal(allow, in: app)
        XCTAssertEqual(allow.value as? String, "0")
        let erase = app.buttons["erase-backpack-action"]
        reveal(erase, in: app, requireHittable: false)
        XCTAssertFalse(erase.isEnabled)
        reveal(allow, in: app); allow.tap()
        XCTAssertEqual(allow.value as? String, "1")
        XCTAssertFalse(erase.isEnabled, "An opt-in toggle cannot substitute for a real connected backpack.")
        attach(app, name: "Erase backpack - explicit default-off toggle, disconnected safety gate")
    }

    private func assertNoVisibleEntryForms(_ app: XCUIApplication) {
        XCTAssertFalse(app.textFields.allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertFalse(app.secureTextFields.allElementsBoundByIndex.contains { $0.isHittable })
    }

    private func verifyImportPicker(_ choice: String, in app: XCUIApplication) {
        app.buttons["Add artwork"].tap()
        let option = app.buttons[choice]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        if choice == "Photo or GIF" {
            XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 30))
        }
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "\(choice) must open a picker, not silently dismiss the menu.")
        let pickerReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in cancel.exists && cancel.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pickerReady], timeout: 30), .completed)
        attach(app, name: "Import regression - \(choice) opens system picker")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 20))
        let add = app.buttons["Add artwork"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in add.exists && add.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, requireHittable: Bool = true, maximumSwipes: Int = 8) {
        let window = app.windows.firstMatch.frame
        let collection = app.collectionViews.allElementsBoundByIndex.last {
            $0.isHittable && $0.frame.intersects(window) && $0.frame.height > window.height * 0.4
        }
        let scroll = collection ?? app.scrollViews.allElementsBoundByIndex.last {
            $0.isHittable && $0.frame.intersects(window) && $0.frame.height > window.height * 0.4
        }
        let container = scroll ?? app
        var visible = scroll?.frame.intersection(window) ?? window
        if let navigation = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable && $0.frame.intersects(visible) }) {
            let top = max(visible.minY, navigation.frame.maxY)
            visible = CGRect(x: visible.minX, y: top, width: visible.width,
                height: max(0, visible.maxY - top))
        }
        let tabs = app.tabBars.firstMatch
        if tabs.exists && tabs.frame.intersects(visible) {
            visible.size.height = max(0, tabs.frame.minY - visible.minY)
        }
        for _ in 0..<maximumSwipes {
            if element.exists {
                if (!requireHittable || element.isHittable) && visible.contains(element.frame) { return }
                let distance = min(visible.height * 0.45,
                    max(-visible.height * 0.45, visible.midY - element.frame.midY))
                if abs(distance) < 1 {
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        (!requireHittable || element.isHittable) && visible.contains(element.frame)
                    }, object: nil)
                    if XCTWaiter.wait(for: [ready], timeout: 1) == .completed { return }
                    continue
                }
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: visible.midX, dy: visible.midY))
                let end = start.withOffset(CGVector(dx: 0, dy: distance))
                start.press(forDuration: 0, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0)
            } else {
                container.swipeUp()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue((!requireHittable || element.isHittable) && visible.contains(element.frame),
            "Reveal the entire control before interacting. Hittable=\(element.isHittable), control=\(element.frame), viewport=\(visible)")
    }

    private func returnToHeader(_ app: XCUIApplication) {
        reveal(app.buttons["Discover GIFs"], in: app)
        XCTAssertTrue(app.buttons["Discover GIFs"].isHittable)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " - element frames"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
