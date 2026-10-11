import AppKit
import XCTest

@MainActor
final class EarlyUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchFreshApp(appearance: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EARLY_TEST_DEFAULTS_SUITE"] = "local.early.tests.\(UUID().uuidString)"
        app.launchEnvironment["EARLY_TEST_APPEARANCE"] = appearance
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // Session loading is asynchronous. Native controls in the loading shell
        // are not evidence that the browser model and keyboard commands are ready.
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 10))
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

    func testTodayNewTabPlacementAndIntentInDarkAppearance() {
        verifyTodayNewTab(appearance: "dark")
    }

    func testTodayNewTabPlacementAndIntentInLightAppearance() {
        verifyTodayNewTab(appearance: "light")
    }

    private func verifyTodayNewTab(appearance: String) {
        let app = launchFreshApp(appearance: appearance)
        app.typeKey(.escape, modifierFlags: [])
        let heading = app.staticTexts["sidebar.today.heading"]
        let newTab = app.buttons["sidebar.newTab"]
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(heading.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "sidebar.newTab").count, 1)
        XCTAssertGreaterThanOrEqual(newTab.frame.minY, heading.frame.maxY)
        XCTAssertLessThanOrEqual(newTab.frame.minY - heading.frame.maxY, 16)
        XCTAssertTrue(newTab.isHittable)

        // Opening and cancelling the action in an empty window creates nothing.
        newTab.click()
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(query.value as? String, "")
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        app.typeText("cancel this")
        app.typeKey(.escape, modifierFlags: [])
        expectRuntime(app, tabs: 0, views: 0, created: 0)

        // The same action submits a new tab, rather than acting as a tab itself.
        newTab.click()
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        app.typeText("early-test://fixture/one\n")
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        let firstTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch
        XCTAssertTrue(firstTab.exists)
        XCTAssertGreaterThanOrEqual(firstTab.frame.minY, newTab.frame.maxY)
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep this text")

        newTab.click()
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(query.value as? String, "")
        app.typeText("cancel again")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(saved.value as? String, "keep this text")
        expectRuntime(app, tabs: 1, views: 1, created: 1)

        newTab.click()
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        app.typeText("early-test://fixture/two\n")
        expectPage(app, "Two")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "One")
        XCTAssertEqual(saved.value as? String, "keep this text")
        XCTAssertGreaterThanOrEqual(firstTab.frame.minY, newTab.frame.maxY)

        let image = XCTAttachment(screenshot: app.windows["browser"].screenshot())
        image.name = "\(appearance) Today New Tab placement"
        image.lifetime = .keepAlways
        add(image)

        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 2)
        XCTAssertFalse(query.exists)
        XCTAssertTrue(newTab.isHittable)
        XCTAssertLessThanOrEqual(newTab.frame.minY - heading.frame.maxY, 16)
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

    private func navigate(_ app: XCUIApplication, to address: String, newTab: Bool = false) {
        app.typeKey(newTab ? "t" : "l", modifierFlags: .command)
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText(address + "\n")
    }

    private func expectRuntime(_ app: XCUIApplication, tabs: Int, views: Int, created: Int,
                               file: StaticString = #filePath, line: UInt = #line) {
        app.activate()
        let probe = app.staticTexts["test.runtime"]
        let expected = "Tabs \(tabs) · Views \(views) · Created \(created) · Saved"
        let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: probe)], timeout: 8)
        XCTAssertEqual(result, .completed, "Runtime: \(probe.exists ? probe.debugDescription : "missing")", file: file, line: line)
    }

    private func expectPage(_ app: XCUIApplication, _ name: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.webViews.staticTexts["Page \(name)"].firstMatch.waitForExistence(timeout: 10), file: file, line: line)
    }

    func testInvalidSubmissionDoesNotCreateTabOrView() {
        let app = launchFreshApp()
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 5))
        app.typeText("javascript:alert(1)\n")
        XCTAssertTrue(app.staticTexts["commandBar.message"].waitForExistence(timeout: 3))
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
    }

    func testNavigationHistoryAndSidebarLocationReuseOneView() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.buttons["sidebar.addressBar"].click()
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(query.value as? String, "early-test://fixture/one")
        // A current URL should be selected on focus, ready to replace by typing.
        app.typeText("early-test://fixture/two\n")
        expectPage(app, "Two")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.typeKey("[", modifierFlags: .command)
        expectPage(app, "One")
        app.typeKey("]", modifierFlags: .command)
        expectPage(app, "Two")
        app.typeKey("r", modifierFlags: .command)
        expectPage(app, "Two")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testCancelAndTabSwitchKeepLivePageThenCloseAndReopen() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep this text")
        app.typeKey("t", modifierFlags: .command)
        app.typeText("cancel this")
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("!")
        XCTAssertEqual(saved.value as? String, "keep this text!")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "One")
        XCTAssertEqual(saved.value as? String, "keep this text!")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("w", modifierFlags: .command)
        expectPage(app, "Two")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 2)
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
        XCTAssertEqual(app.windows.count, 1)
        app.typeKey("t", modifierFlags: [.command, .shift])
        expectPage(app, "Two")
        expectRuntime(app, tabs: 1, views: 1, created: 3)
    }

    func testRestorationLoadsOnlySelectionAndPersistsEmptySession() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        expectPage(app, "Two")
        expectRuntime(app, tabs: 2, views: 1, created: 1)
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
        app.typeKey("w", modifierFlags: .command)
        expectPage(app, "One")
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 2)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 5))
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
    }

    func testNativeJavaScriptDialogsAndTargetBlank() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        app.webViews.buttons["Alert"].click()
        XCTAssertTrue(app.sheets.buttons["OK"].waitForExistence(timeout: 5))
        app.sheets.buttons["OK"].click()
        XCTAssertTrue(app.webViews.staticTexts["Alert done"].waitForExistence(timeout: 5))
        app.webViews.buttons["Confirm"].click()
        XCTAssertTrue(app.sheets.buttons["Cancel"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.webViews.staticTexts["Cancelled"].waitForExistence(timeout: 5))
        app.webViews.buttons["Prompt"].click()
        let response = app.sheets.textFields["Website prompt response"]
        XCTAssertTrue(response.waitForExistence(timeout: 5))
        response.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("response")
        app.sheets.buttons["OK"].click()
        XCTAssertTrue(app.webViews.staticTexts["response"].waitForExistence(timeout: 5))
        app.webViews.links["Open new tab"].click()
        expectPage(app, "Two")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
    }

    func testFailedNavigationCanRetryAndSlowNavigationCanStop() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/failure")
        let retry = app.buttons["browser.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        navigate(app, to: "early-test://fixture/slow")
        XCTAssertTrue(app.buttons["navigation.stop"].waitForExistence(timeout: 5))
        app.buttons["navigation.stop"].click()
        XCTAssertTrue(app.buttons["navigation.reload"].waitForExistence(timeout: 5))
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testRealHTTPSWebsiteLoads() {
        let app = launchFreshApp()
        navigate(app, to: "https://example.com")
        XCTAssertTrue(app.webViews.matching(NSPredicate(format: "label == %@ ", "Example Domain")).firstMatch.waitForExistence(timeout: 30))
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        XCTAssertEqual(app.buttons["sidebar.addressBar"].value as? String, "https://example.com/")
    }

    func testCompactChromeAlignsNativeControlsAndKeepsBrowsingState() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let close = app.buttons["_XCUI:CloseWindow"]
        let back = app.buttons["navigation.back"]
        let address = app.buttons["sidebar.addressBar"]
        XCTAssertTrue(close.exists)
        XCTAssertEqual(close.frame.midY, back.frame.midY, accuracy: 3)
        XCTAssertGreaterThan(address.frame.minY, back.frame.maxY)
        app.buttons["sidebar.toggle"].click()
        // Move away: auto-hide affects the entire sidebar, not just its tab rows.
        app.webViews.firstMatch.hover()
        XCTAssertFalse(app.buttons["sidebar.newTab"].exists)
        let window = app.windows["browser"]
        let origin = window.coordinate(withNormalizedOffset: .zero)
        // Neither the former sidebar area nor the inset content border reveals it.
        for x in [120.0, 12.0, 5.0] {
            origin.withOffset(CGVector(dx: x, dy: window.frame.height / 2)).hover()
            XCTAssertFalse(app.buttons["sidebar.newTab"].exists)
        }
        let reveal = app.descendants(matching: .any)["sidebar.reveal"]
        XCTAssertEqual(reveal.frame.width, 2, accuracy: 0.5)
        XCTAssertEqual(reveal.frame.minX, window.frame.minX, accuracy: 0.5)
        app.descendants(matching: .any)["sidebar.reveal"].hover()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["sidebar.toggle"].value as? String, "Auto-hide enabled")
        app.webViews.firstMatch.hover()
        app.typeKey("s", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 3))
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        expectPage(app, "One")
        let screenshot = XCTAttachment(screenshot: app.windows["browser"].screenshot())
        screenshot.name = "Compact sidebar chrome"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLoadingIndicatorIsTwoPointsHigh() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/slow")
        let indicator = app.descendants(matching: .any)["browser.loading"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.frame.height, 2, accuracy: 0.5)
        app.buttons["navigation.stop"].click()
    }

    func testTrafficLightsAreMonochromeUntilHovered() throws {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        let close = app.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let lights = [close, app.buttons["_XCUI:MinimizeWindow"], app.buttons["_XCUI:FullScreenWindow"]]
        let window = app.windows["browser"]
        let away = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))

        func colorSpread(_ button: XCUIElement) throws -> CGFloat {
            let shot = button.screenshot()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
            var largest: CGFloat = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    largest = max(largest, channels.max()! - channels.min()!)
                }
            }
            return largest
        }

        away.hover()
        for light in lights { XCTAssertLessThan(try colorSpread(light), 0.12) }
        let idle = XCTAttachment(screenshot: window.screenshot())
        idle.name = "Muted native traffic lights"
        idle.lifetime = .keepAlways
        add(idle)
        close.hover()
        for light in lights {
            XCTAssertGreaterThan(try colorSpread(light), 0.25)
            try assertHoverSymbol(light)
        }
        let hovered = XCTAttachment(screenshot: window.screenshot())
        hovered.name = "Hovered native traffic lights"
        hovered.lifetime = .keepAlways
        add(hovered)
        away.hover()
        for light in lights { XCTAssertLessThan(try colorSpread(light), 0.12) }
        XCTAssertTrue(close.isEnabled)
        XCTAssertTrue(close.isHittable)

        // Relaunch while the cursor is parked over content. Assert the first
        // appearance without any hover event to initialize the control state.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 10))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        for light in lights { XCTAssertLessThan(try colorSpread(light), 0.12) }
        app.typeKey(.escape, modifierFlags: [])
        close.click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
    }

    // Native glass glyphs are tinted, not black. Detect a local dark stroke
    // against its two neighbours, rejecting a solid circle or smooth gradient.
    private func strokePixels(width: Int, height: Int, brightness: (Int, Int) -> CGFloat) -> Int {
        let step = max(1, width / 10)
        var count = 0
        for y in (height / 3)..<(height * 2 / 3) {
            for x in (width / 3)..<(width * 2 / 3) {
                let center = brightness(x, y)
                let horizontal = min(brightness(x - step, y), brightness(x + step, y)) - center
                let vertical = min(brightness(x, y - step), brightness(x, y + step)) - center
                if max(horizontal, vertical) > 0.08 { count += 1 }
            }
        }
        return count
    }

    private func assertHoverSymbol(_ button: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        var shot = button.screenshot()
        var count = 0
        let deadline = Date().addingTimeInterval(1)
        while true {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
            count = strokePixels(width: bitmap.pixelsWide, height: bitmap.pixelsHigh) { x, y in
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 1 }
                return max(c.redComponent, c.greenComponent, c.blueComponent)
            }
            if count >= 3 || Date() >= deadline { break }
            // Glass rollover animates after XCTest considers the app idle.
            // Allow that transition to settle, but do not retry the hover event.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            shot = button.screenshot()
        }
        if count < 3 {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "Missing glyph: \(button.identifier), stroke pixels \(count)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertGreaterThanOrEqual(count, 3, "Missing hover symbol on \(button.identifier)", file: file, line: line)
    }

    func testHoverSymbolDetectorRejectsBlankAndGradientCircles() {
        XCTAssertEqual(strokePixels(width: 32, height: 32) { _, _ in 0.8 }, 0)
        XCTAssertEqual(strokePixels(width: 32, height: 32) { x, y in 0.5 + CGFloat(x + y) / 128 }, 0)
        XCTAssertGreaterThan(strokePixels(width: 32, height: 32) { _, y in
            (15...16).contains(y) ? 0.65 : 0.9
        }, 3)
    }

    func testWindowLifecycleAndTrafficLightsInLightAppearance() throws {
        try verifyWindowLifecycle(appearance: "light")
    }

    func testWindowLifecycleAndTrafficLightsInDarkAppearance() throws {
        try verifyWindowLifecycle(appearance: "dark")
    }

    private func verifyWindowLifecycle(appearance: String) throws {
        let app = launchFreshApp(appearance: appearance)
        app.typeKey(.escape, modifierFlags: [])
        let window = app.windows["browser"]
        let close = app.buttons["_XCUI:CloseWindow"]
        let zoom = app.buttons["_XCUI:FullScreenWindow"]
        let state = app.staticTexts["test.windowState"]
        func expectState(_ name: String) {
            let expected = "\(name) · nativeSize true"
            let predicate = NSPredicate(format: "value BEGINSWITH %@", expected)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: state)], timeout: 10), .completed)
            XCTAssertTrue(close.waitForExistence(timeout: 5), "Native window state: \(state.value ?? "missing")")
        }
        func verifyControls(_ stage: String) throws {
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "_XCUI:CloseWindow").count, 1)
            XCTAssertEqual(close.frame.midY, app.buttons["navigation.back"].frame.midY, accuracy: 3)
            let away = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6))
            for _ in 0..<3 {
                away.hover()
                close.hover()
                try assertHoverSymbol(close)
                try assertHoverSymbol(zoom)
                if app.buttons["_XCUI:MinimizeWindow"].isEnabled {
                    try assertHoverSymbol(app.buttons["_XCUI:MinimizeWindow"])
                }
            }
            away.hover()
            let image = XCTAttachment(screenshot: window.screenshot())
            image.name = "\(appearance) \(stage)"
            image.lifetime = .keepAlways
            add(image)
        }
        expectState("windowed")
        for (title, width) in [("Compact Test Window", 800.0), ("Wide Test Window", 1120.0)] {
            app.menuBars.menuBarItems["Test Window"].click()
            app.menuItems[title].click()
            XCTAssertEqual(window.frame.width, width, accuracy: 1)
            let content = app.descendants(matching: .any)["browser.content"]
            XCTAssertEqual(content.frame.minY - window.frame.minY, 6, accuracy: 1)
            XCTAssertEqual(window.frame.maxX - content.frame.maxX, 6, accuracy: 1)
            XCTAssertEqual(window.frame.maxY - content.frame.maxY, 6, accuracy: 1)
            try verifyControls(title)
        }
        // Use the native menu action: XCTest's pointer dwell over the green
        // button can open macOS's Move & Resize popover before it clicks.
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Enter Full Screen"].click()
        expectState("fullscreen")
        try verifyControls("fullscreen")
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Exit Full Screen"].click()
        expectState("windowed")
        try verifyControls("after fullscreen")

        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        app.webViews.buttons["Alert"].click()
        XCTAssertTrue(app.sheets.buttons["OK"].waitForExistence(timeout: 5))
        XCTAssertTrue(!close.exists || !close.isHittable)
        app.sheets.buttons["OK"].click()
        XCTAssertTrue(app.webViews.staticTexts["Alert done"].waitForExistence(timeout: 5))
        try verifyControls("after native sheet")

        app.buttons["sidebar.toggle"].click()
        app.webViews.firstMatch.hover()
        XCTAssertFalse(app.buttons["sidebar.newTab"].exists)
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 5, dy: 200)).hover()
        XCTAssertFalse(app.buttons["sidebar.newTab"].exists)
        app.descendants(matching: .any)["sidebar.reveal"].hover()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 5))
        // Keep the cursor in the floating sidebar while checking its controls.
        close.hover()
        try assertHoverSymbol(close)
        try assertHoverSymbol(zoom)
        let image = XCTAttachment(screenshot: window.screenshot())
        image.name = "\(appearance) floating sidebar"
        image.lifetime = .keepAlways
        add(image)
        app.typeKey("s", modifierFlags: [.command, .shift])
        try verifyControls("after auto-hide")
        app.terminate()
    }

    func testClickOutsideDismissesCommandBar() {
        let app = launchFreshApp()
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))

        // 1. Clicking in the sidebar dismisses the command bar
        let sidebar = app.descendants(matching: .any)["browser.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3))
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()
        XCTAssertFalse(query.exists)

        // 2. Open command bar again via Command-T
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 3))

        // 3. Clicking in the content area (below command bar) dismisses the command bar
        let content = app.descendants(matching: .any)["browser.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 3))
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).click()
        XCTAssertFalse(query.exists)

        // 4. Open command bar again via Command-T
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 3))

        // 5. Clicking inside the command bar text field does NOT dismiss it
        query.click()
        XCTAssertTrue(query.exists)
        app.typeText("testing")
        XCTAssertEqual(query.value as? String, "testing")
    }
}
