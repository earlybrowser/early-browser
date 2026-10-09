import XCTest

@MainActor
final class EarlyUITests: XCTestCase {
    private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EARLY_TEST_DEFAULTS_SUITE"] = "local.early.tests.\(UUID().uuidString)"
        app.launch()
        return app
    }

    func testFirstLaunchFocusAndEscape() {
        let app = launchFreshApp()
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        app.typeText("example.com")
        XCTAssertEqual(query.value as? String, "example.com")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(query.exists)
        XCTAssertTrue(app.buttons["sidebar.newTab"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertEqual(app.windows.count, 1)
    }

    func testKeyboardCommandsLeaveEmptyWindowUsable() {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
        app.typeText("cancel me")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["commandBar.query"].value as? String, "")
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testEmptyRelaunchDoesNotRepeatFirstLaunchPrompt() {
        let app = launchFreshApp()
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        let addressBar = app.buttons["sidebar.addressBar"]
        XCTAssertTrue(addressBar.exists)
        XCTAssertEqual(addressBar.value as? String, "No active tab")
        addressBar.click()
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields.matching(identifier: "commandBar.query").count, 1)
        app.typeText("example.com")
        XCTAssertEqual(query.value as? String, "example.com")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(query.exists)
        XCTAssertEqual(app.webViews.count, 0)
        app.buttons["sidebar.newTab"].click()
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
    }

    func testPhaseZeroSubmissionDoesNotPretendToNavigate() {
        let app = launchFreshApp()
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 5))
        app.typeText("example.com\n")
        XCTAssertTrue(app.staticTexts["commandBar.message"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.webViews.count, 0)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
    }
}
