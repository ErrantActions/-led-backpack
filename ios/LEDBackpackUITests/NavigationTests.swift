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
        reveal(app.staticTexts["Night ride"], in: app)
        XCTAssertTrue(app.staticTexts["Night ride"].exists)
        attach(app, name: "Guest Library - local and cloud")
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
        reveal(app.staticTexts["Meetup glow"], in: app)
        let actions = app.buttons.matching(NSPredicate(format: "label == 'Actions'")).firstMatch
        reveal(actions, in: app)
        actions.tap()
        app.buttons["Save a private cloud copy"].tap()
        XCTAssertTrue(app.navigationBars["Upload GIF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Title"].exists)
        XCTAssertFalse(app.textFields["Creator / attribution"].exists)
        XCTAssertFalse(app.buttons["License / permission"].exists)
        XCTAssertTrue(app.buttons["Upload to private library"].isEnabled)
        attach(app, name: "Private upload - classification only without creator or license choices")
        app.buttons["Done"].tap()
        reveal(app.staticTexts["Night ride"], in: app)
        reveal(app.staticTexts["Cloud demo"], in: app)
        attach(app, name: "Unified Library - local and private cloud")
        returnToHeader(app)
        app.buttons["Cloud"].tap()
        reveal(app.staticTexts["Cloud demo"], in: app)
        XCTAssertTrue(app.staticTexts["Cloud demo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Meetup glow"].exists)
        attach(app, name: "Cloud scope - local linked and cloud-only")
        returnToHeader(app)
        app.buttons["On iPhone"].tap()
        reveal(app.staticTexts["Meetup glow"], in: app)
        XCTAssertTrue(app.staticTexts["Meetup glow"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Cloud demo"].exists)
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

    private func assertNoVisibleEntryForms(_ app: XCUIApplication) {
        XCTAssertFalse(app.textFields.allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertFalse(app.secureTextFields.allElementsBoundByIndex.contains { $0.isHittable })
    }

    private func verifyImportPicker(_ choice: String, in app: XCUIApplication) {
        app.buttons["Add artwork"].tap()
        let option = app.buttons[choice]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == 'Close'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "\(choice) must open a picker, not silently dismiss the menu.")
        attach(app, name: "Import regression - \(choice) opens system picker")
        cancel.tap()
        XCTAssertTrue(app.buttons["Add artwork"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
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
