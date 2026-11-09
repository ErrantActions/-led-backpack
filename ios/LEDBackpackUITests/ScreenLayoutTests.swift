import XCTest

final class ScreenLayoutTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLibrarySettingsAndEditorLayouts() throws {
        let app = launch()
        capture(app, page: "library", state: "guest")
        tap(app.buttons["Filter library"], in: app)
        tap(app.buttons["Settings"], in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        capture(app, page: "settings", state: "default")
        expand(["What's in a backup", "Diagnostics", "About"], in: app)
        capture(app, page: "settings", state: "expanded")
        tap(app.buttons["Catalog server and account"], in: app)
        capture(app, page: "catalog-settings", state: "default")
        expand(["Advanced server settings"], in: app)
        capture(app, page: "catalog-settings", state: "expanded")
        back(app)
        tap(app.buttons["Library sync"], in: app)
        capture(app, page: "library-sync", state: "guest")
        back(app)
        tap(app.buttons["settings-done"], in: app)
        let artwork = app.buttons["Preview Night ride"]
        reveal(artwork, in: app)
        artwork.press(forDuration: 1)
        tap(app.buttons["Edit a copy"], in: app)
        XCTAssertTrue(app.navigationBars["GIF Studio"].waitForExistence(timeout: 10))
        capture(app, page: "gif-studio", state: "default")
        expand(["Canvas & framing", "Background cleanup", "Ghost trails", "Timing & loops", "Brush & eraser"], in: app)
        capture(app, page: "gif-studio", state: "expanded")
    }

    func testSocialPeopleAndInboxLayouts() throws {
        let app = launch()
        signIn(app)
        tap(app.buttons["Social"], in: app)
        XCTAssertTrue(app.navigationBars["Social"].waitForExistence(timeout: 10))
        capture(app, page: "social", state: "signed-in")
        expand(["Profile & devices", "Alerts & reminders", "Safety & reports", "Availability & privacy"], in: app)
        capture(app, page: "social", state: "expanded")
        for (route, page) in [
            ("social-primary-friends", "friends-profile"),
            ("social-primary-messages", "messages"),
            ("social-primary-events", "events"),
            ("social-primary-games", "games"),
            ("social-link-Add friends / QR / nearby", "add-friends"),
            ("social-link-Accepted-friend greetings / duet / pass sessions", "friend-sessions"),
            ("social-link-Profile avatar", "avatar"),
            ("social-link-Private event badges / profile choices", "badges"),
            ("social-link-Device cards / accepted-friend transfers (unverified)", "device-cards"),
            ("social-link-Nonfriend message requests", "message-requests"),
            ("social-link-Activity inbox", "activity"),
            ("social-link-Notifications / event reminders", "notifications"),
            ("social-link-Apple device alerts", "apple-alerts"),
            ("social-link-Private playlists / public snapshots", "shared-playlists"),
            ("social-link-Automatic PHONE GIF swap / Found Users", "phone-swap"),
            ("Blocked accounts", "blocked-accounts"),
            ("social-link-My event reports / withdrawal", "event-reports"),
            ("social-link-My message incidents", "message-incidents"),
            ("social-link-My peer incidents / keyless withdrawal receipts", "peer-incidents")
        ] {
            let button = app.buttons[route]
            reveal(button, in: app)
            if !button.isEnabled {
                note("Unavailable under the current generated account/capabilities: \(route)", name: "coverage-gap--\(page)")
                continue
            }
            button.tap()
            capture(app, page: page, state: "default")
            back(app)
            XCTAssertTrue(app.navigationBars["Social"].waitForExistence(timeout: 10))
        }
    }

    func testAddFriendsAndQRLayouts() throws {
        let app = launch()
        signIn(app)
        tap(app.buttons["Social"], in: app)
        tap(app.buttons["social-link-Add friends / QR / nearby"], in: app)
        XCTAssertTrue(app.navigationBars["Add friends"].waitForExistence(timeout: 10))
        capture(app, page: "add-friends", state: "default")
        expand(["Privacy & discovery status"], in: app)
        capture(app, page: "add-friends", state: "privacy-expanded")
        for (button, page) in [
            ("add-friends-my-qr", "my-qr"),
            ("add-friends-scan-qr", "scan-qr"),
            ("add-friends-look", "discovery-permission")
        ] {
            tap(app.buttons[button], in: app)
            capture(app, page: page, state: "default-off")
            let done = app.buttons["Done"]
            if done.exists && done.isHittable { done.tap() }
            else { tap(app.buttons["Cancel"], in: app) }
            XCTAssertTrue(app.navigationBars["Add friends"].waitForExistence(timeout: 10))
        }
    }

    func testSoloAndOfflineGameLayouts() throws {
        let app = launch()
        tap(app.buttons["GPS & nearby games"], in: app)
        capture(app, page: "gps-games", state: "default")
        tap(app.buttons["My local places / adventure / distance milestones"], in: app)
        capture(app, page: "solo", state: "default-off")
        expand(["Status & privacy", "Phone animation", "Scenes & playlists",
                "Daylight plans", "My badges", "Private recaps", "Milestones & reset"], in: app)
        capture(app, page: "solo", state: "expanded-default-off")
        tap(app.buttons["Create scene"], in: app)
        capture(app, page: "new-scene", state: "draft")
        tap(app.buttons["Cancel"], in: app)
        back(app)
        back(app)
        tap(app.buttons["Social"], in: app)
        tap(app.buttons["Pair offline"], in: app)
        capture(app, page: "offline-pairing", state: "default-off")
        back(app)
        tap(app.buttons["Received & recovery"], in: app)
        capture(app, page: "received-recovery", state: "empty")
    }

    func testCreateBackpackAndLiveLayouts() throws {
        let app = launch()
        for tab in ["Backpack", "Create", "Live"] {
            tap(app.buttons[tab], in: app)
            capture(app, page: tab.lowercased(), state: "default")
        }
        tap(app.buttons["Customize"], in: app)
        capture(app, page: "live-theme", state: "default")
    }

    func testTextAndDrawingStudioLayouts() throws {
        let app = launch()
        tap(app.buttons["Create"], in: app)
        let textTool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Text to GIF")).firstMatch
        tap(textTool, in: app)
        XCTAssertTrue(app.navigationBars["Text artwork"].waitForExistence(timeout: 10))
        capture(app, page: "text-artwork", state: "default")
        back(app)
        let drawingTool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pixel drawing")).firstMatch
        tap(drawingTool, in: app)
        XCTAssertTrue(app.navigationBars["Drawing & animation"].waitForExistence(timeout: 10))
        capture(app, page: "drawing-animation", state: "default")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--library-ui-fixture", "--social-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20))
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        tap(app.buttons["Catalog account"], in: app)
        tap(app.buttons["Continue with email"], in: app)
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("ui@example.invalid")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("fixture-password")
        app.keyboards.buttons["Go"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UI Rider"))
            .firstMatch.waitForExistence(timeout: 10))
        capture(app, page: "catalog-account", state: "signed-in")
        back(app)
    }

    private func back(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
    }

    private func expand(_ labels: [String], in app: XCUIApplication) {
        for label in labels {
            let button = app.buttons[label]
            reveal(button, in: app)
            button.tap()
        }
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isEnabled)
        element.tap()
    }

    private func viewport(_ app: XCUIApplication) -> CGRect {
        var result = app.windows.firstMatch.frame
        if let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable }) {
            result.origin.y = bar.frame.maxY
            result.size.height = app.windows.firstMatch.frame.maxY - result.minY
        }
        let done = app.buttons["settings-done"]
        if done.exists && done.isHittable { result.size.height = done.frame.minY - result.minY - 8 }
        result.size.width = min(result.width, 382)
        result.size.height = max(1, result.height - 8)
        return result
    }

    private func pan(_ distance: CGFloat, in app: XCUIApplication) {
        let area = viewport(app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: area.minX + 14, dy: area.midY))
        let end = start.withOffset(CGVector(dx: 0, dy: distance))
        start.press(forDuration: 0, thenDragTo: end,
            withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.1)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if !element.exists { seekTop(app) }
        for _ in 0..<25 {
            let area = viewport(app)
            if element.exists {
                if (!element.isEnabled || element.isHittable)
                    && element.frame.minY >= area.minY && element.frame.maxY <= area.maxY { return }
                pan(max(-180, min(180, area.midY - element.frame.midY)), in: app)
            } else { pan(-180, in: app) }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Cannot reveal \(element)")
    }

    private func signature(_ app: XCUIApplication) -> String {
        app.debugDescription.replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x", options: .regularExpression)
    }

    private func capture(_ app: XCUIApplication, page: String, state: String) {
        seekTop(app)
        var exhausted = false
        for segment in 0..<30 {
            let name = String(format: "layout--%@--%@--%03d", page, state, segment)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            add(screenshot)
            note(app.debugDescription, name: name + "--frames")
            let area = viewport(app)
            note("{\"page\":\"\(page)\",\"state\":\"\(state)\",\"segment\":\(segment),\"viewport\":"
                + "[\(area.minX),\(area.minY),\(area.width),\(area.height)]}", name: name + "--capture")
            let before = signature(app)
            pan(-180, in: app)
            if signature(app) == before { exhausted = true; break }
        }
        note("{\"complete\":\(exhausted)}", name: "layout--\(page)--\(state)--result")
        XCTAssertTrue(exhausted, "Capture truncated: \(page) / \(state)")
    }

    private func seekTop(_ app: XCUIApplication) {
        for _ in 0..<20 {
            let before = signature(app)
            pan(180, in: app)
            if signature(app) == before { break }
        }
    }

    private func note(_ value: String, name: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
