import XCTest

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
        XCTAssertTrue(app.buttons["On iPhone"].exists)
        assertNoVisibleEntryForms(app)
        attach(app, name: "Aurora guest library - editorial header and glass scopes")
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
        XCTAssertTrue(app.textFields["Title"].exists)
        XCTAssertFalse(app.textFields["Creator / attribution"].exists)
        XCTAssertFalse(app.buttons["License / permission"].exists)
        XCTAssertFalse(app.buttons["Submit to community review"].isEnabled)
        attach(app, name: "Community review - explicit consent without creator or license choices")
        app.buttons["Done"].tap()
        reveal(app.buttons["Preview Night ride"], in: app)
        reveal(app.buttons["Preview Cloud demo"], in: app)
        XCTAssertFalse(app.staticTexts["Cloud demo"].exists)
        attach(app, name: "Unified Library - local and private cloud")
        returnToHeader(app)
        app.buttons["Cloud"].tap()
        reveal(app.buttons["Preview Cloud demo"], in: app)
        XCTAssertTrue(app.buttons["Preview Cloud demo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Preview Meetup glow"].exists)
        attach(app, name: "Cloud scope - local linked and cloud-only")
        returnToHeader(app)
        app.buttons["On iPhone"].tap()
        reveal(app.buttons["Preview Meetup glow"], in: app)
        XCTAssertTrue(app.buttons["Preview Meetup glow"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Preview Cloud demo"].exists)
        returnToHeader(app)
        app.buttons["All"].tap()

        app.buttons.matching(NSPredicate(format: "label == %@", "Create")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Create"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Text to GIF"].exists)
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
        app.buttons["Done"].tap()

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
        XCTAssertTrue(app.staticTexts["Connect from the Backpack tab, then retry. This screen does not scan or connect automatically."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send & Play on backpack"].exists)
        XCTAssertTrue(app.buttons["Prepare / update send copies"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Prepare / update send copies"].isEnabled)
        attach(app, name: "Community direct Send & Play - no forced local save or radio scan")
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

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let scroll = app.scrollViews.allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.intersects(window)
        }
        let container = scroll ?? app
        var visible = scroll?.frame.intersection(window) ?? window
        let navigation = app.navigationBars.firstMatch
        if navigation.exists && navigation.frame.intersects(visible) {
            let top = max(visible.minY, navigation.frame.maxY)
            visible = CGRect(x: visible.minX, y: top, width: visible.width,
                height: max(0, visible.maxY - top))
        }
        let tabs = app.tabBars.firstMatch
        if tabs.exists && tabs.frame.intersects(visible) {
            visible.size.height = max(0, tabs.frame.minY - visible.minY)
        }
        for _ in 0..<8 {
            if element.exists {
                if element.isHittable && visible.contains(element.frame) { return }
                let distance = min(visible.height * 0.45,
                    max(-visible.height * 0.45, visible.midY - element.frame.midY))
                if abs(distance) < 1 {
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        element.isHittable && visible.contains(element.frame)
                    }, object: nil)
                    if XCTWaiter.wait(for: [ready], timeout: 1) == .completed { return }
                    continue
                }
                let startY = distance > 0 ? visible.minY + visible.height * 0.25 :
                    visible.minY + visible.height * 0.75
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: visible.midX - app.frame.minX,
                    dy: startY - app.frame.minY))
                let end = origin.withOffset(CGVector(dx: visible.midX - app.frame.minX,
                    dy: startY + distance - app.frame.minY))
                start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                container.swipeUp()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable && visible.contains(element.frame),
            "Reveal the entire control before interacting. Hittable=\(element.isHittable), control=\(element.frame), viewport=\(visible)")
    }

    private func returnToHeader(_ app: XCUIApplication) {
        for _ in 0..<3 {
            if app.buttons["Discover GIFs"].isHittable { return }
            app.swipeDown()
        }
        XCTAssertTrue(app.buttons["Discover GIFs"].isHittable)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
