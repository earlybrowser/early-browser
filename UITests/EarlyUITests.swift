// SPDX-License-Identifier: MPL-2.0

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

    func testKeyboardCommandsLeaveEmptyWindowUsable() {
        let app = launchFreshApp()
        let query = app.textFields["commandBar.query"]
        let windowFrame = app.windows["browser"].frame
        XCTAssertEqual((query.frame.midY - windowFrame.minY) / windowFrame.height, 0.40, accuracy: 0.04)
        app.typeText("example.com")
        XCTAssertEqual(query.value as? String, "example.com")
        app.typeKey(.escape, modifierFlags: [])
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
        XCTAssertFalse(app.staticTexts["Open a new tab with ⌘T"].exists)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
        app.typeText("cancel me")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["commandBar.query"].value as? String, "")
        XCTAssertEqual(app.webViews.count, 0)
        app.typeKey(.escape, modifierFlags: [])
        let address = app.buttons["sidebar.addressBar"]
        XCTAssertEqual(address.value as? String, "No active tab")
        address.click()
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(query.value as? String, "")
    }

    func testThumbnailSwitcherCancelCommitAndCompactLayoutPreserveLivePages() {
        for appearance in ["dark", "light"] {
            let app = launchFreshApp(appearance: appearance)
            navigate(app, to: "early-test://fixture/one")
            expectPage(app, "One")
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
            let firstID = rows.firstMatch.identifier
            let saved = app.webViews.textFields["Saved text"]
            pasteText("switcher keeps this page", into: saved, in: app)
            navigate(app, to: "early-test://fixture/two", newTab: true)
            expectPage(app, "Two")
            let secondID = rows.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
            let firstCard = app.buttons["tabSwitcher.tab.\(firstID.dropFirst(4))"]
            let secondCard = app.buttons["tabSwitcher.tab.\(secondID.dropFirst(4))"]
            let strip = app.descendants(matching: .any).matching(identifier: "tabSwitcher").firstMatch

            func showSwitcher() {
                app.menuBarItems["Navigate"].click()
                visibleMenuAction("Next Tab")
                XCTAssertTrue(strip.waitForExistence(timeout: 5))
                XCTAssertTrue(firstCard.exists && secondCard.exists)
            }
            showSwitcher()
            XCTAssertTrue(firstCard.isSelected)
            expectPage(app, "Two") // Highlighting does not navigate or resume.
            expectRuntime(app, tabs: 2, views: 2, created: 2)
            app.typeKey(.rightArrow, modifierFlags: [])
            XCTAssertTrue(secondCard.isSelected)
            app.typeKey(.leftArrow, modifierFlags: [])
            XCTAssertTrue(firstCard.isSelected)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(strip.waitForNonExistence(timeout: 3))
            expectPage(app, "Two")
            showSwitcher()
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(strip.waitForNonExistence(timeout: 3))
            expectPage(app, "One")
            XCTAssertEqual(saved.value as? String, "switcher keeps this page")
            expectRuntime(app, tabs: 2, views: 2, created: 2)

            for size in ["Compact Test Window", "Wide Test Window"] {
                app.menuBarItems["Test Window"].click()
                visibleMenuAction(size)
                showSwitcher()
                let window = app.windows["browser"].frame
                XCTAssertGreaterThan(strip.frame.width, 100)
                XCTAssertGreaterThanOrEqual(strip.frame.minX, window.minX + 6)
                XCTAssertLessThanOrEqual(strip.frame.maxX, window.maxX - 6)
                XCTAssertGreaterThanOrEqual(strip.frame.minY, window.minY + 6)
                XCTAssertLessThanOrEqual(strip.frame.maxY, window.maxY - 6)
                let capture = XCTAttachment(screenshot: app.windows["browser"].screenshot())
                capture.name = "\(appearance) thumbnail switcher — \(size)"
                capture.lifetime = .keepAlways
                add(capture)
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(strip.waitForNonExistence(timeout: 3))
            }
            showSwitcher()
            secondCard.click()
            expectPage(app, "Two")
            // A quick Control-Tab must commit when Control is released.
            app.typeKey(.tab, modifierFlags: .control)
            expectPage(app, "One")
            XCTAssertTrue(strip.waitForNonExistence(timeout: 3))
            XCTAssertEqual(saved.value as? String, "switcher keeps this page")
            expectRuntime(app, tabs: 2, views: 2, created: 2)
            app.terminate()
        }
    }

    func testSplitPaneFocusResizeAndRemovalKeepTabsAndLiveForms() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let firstID = rows.firstMatch.identifier
        pasteText("keep left", into: app.webViews.textFields["Saved text"], in: app)
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let secondID = rows.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
        pasteText("keep right", into: app.webViews.textFields["Saved text"], in: app)
        app.buttons[firstID].rightClick()
        app.menuItems["Split View"].hover()
        visibleMenuAction("Place on Left")
        let divider = app.descendants(matching: .any).matching(identifier: "split.divider").firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let left = app.descendants(matching: .any).matching(identifier: "browser.pane.\(firstID.dropFirst(4))").firstMatch
        let right = app.descendants(matching: .any).matching(identifier: "browser.pane.\(secondID.dropFirst(4))").firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5) && right.exists)
        XCTAssertLessThan(left.frame.midX, right.frame.midX)
        XCTAssertEqual(left.textFields["Saved text"].value as? String, "keep left")
        XCTAssertEqual(right.textFields["Saved text"].value as? String, "keep right")
        for reversed in [true, false] {
            app.buttons[firstID].rightClick()
            app.menuItems["Split View"].hover()
            XCTAssertTrue(app.menuItems["Swap Sides"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.menuItems["Exit Split View"].exists)
            XCTAssertFalse(app.menuItems["Place on Left"].exists || app.menuItems["Place on Right"].exists)
            visibleMenuAction("Swap Sides")
            let swapped = NSPredicate { _, _ in reversed ? left.frame.midX > right.frame.midX : left.frame.midX < right.frame.midX }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: swapped, object: nil)], timeout: 5), .completed)
            XCTAssertEqual(left.textFields["Saved text"].value as? String, "keep left")
            XCTAssertEqual(right.textFields["Saved text"].value as? String, "keep right")
        }
        right.textFields["Saved text"].click()
        app.typeKey("l", modifierFlags: .command)
        XCTAssertEqual(app.textFields["commandBar.query"].value as? String, "early-test://fixture/two")
        app.typeKey(.escape, modifierFlags: [])
        left.textFields["Saved text"].click()
        app.typeKey("l", modifierFlags: .command)
        XCTAssertEqual(app.textFields["commandBar.query"].value as? String, "early-test://fixture/one")
        app.typeKey(.escape, modifierFlags: [])
        let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.click(forDuration: 0.15, thenDragTo: handle.withOffset(CGVector(dx: 70, dy: 0)))
        XCTAssertEqual(left.textFields["Saved text"].value as? String, "keep left")
        XCTAssertEqual(right.textFields["Saved text"].value as? String, "keep right")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.menuBarItems["Tab"].click()
        visibleMenuAction("Remove Current Pane from Split")
        XCTAssertTrue(divider.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[firstID].exists && app.buttons[secondID].exists)
        XCTAssertEqual(app.webViews.textFields["Saved text"].value as? String, "keep right")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.terminate()
    }

    func testSidebarFloatingTargetDropCreatesSplitAndRelaunchRestoresItsPanes() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let firstID = rows.firstMatch.identifier
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let secondID = rows.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
        let content = app.descendants(matching: .any).matching(identifier: "browser.content").firstMatch
        let divider = app.descendants(matching: .any).matching(identifier: "split.divider").firstMatch
        // Entering content reveals targets, but dropping between them cancels.
        app.buttons[firstID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.25, thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertFalse(divider.exists)
        XCTAssertEqual(app.buttons[firstID].value as? String, "Today")
        XCTAssertEqual(app.buttons[secondID].value as? String, "Today")
        expectPage(app, "Two")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.buttons[firstID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.25, thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        XCTAssertEqual(app.buttons[firstID].value as? String, "Today")
        XCTAssertEqual(app.buttons[secondID].value as? String, "Today")
        app.terminate()
        app.launch()
        XCTAssertTrue(divider.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "browser.pane.\(firstID.dropFirst(4))").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "browser.pane.\(secondID.dropFirst(4))").firstMatch.exists)
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.terminate()
    }

    func testCurrentSavedResultsPreservePagesAndFreshLocationOpensToday() {
        for action in ["Pin Tab", "Add to Favorites"] {
            let app = launchFreshApp()
            navigate(app, to: "early-test://fixture/one")
            expectPage(app, "One")
            let id = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
            let saved = app.webViews.textFields["Saved text"]
            pasteText("keep saved document", into: saved, in: app)
            pinAction(action, on: app.buttons[id])
            let savedControl = action == "Pin Tab" ? app.buttons[id] : app.buttons["favorite.\(id.dropFirst(4))"]
            XCTAssertTrue(savedControl.waitForExistence(timeout: 3))

            app.typeKey("l", modifierFlags: .command)
            let query = app.textFields["commandBar.query"]
            XCTAssertTrue(query.waitForExistence(timeout: 3))
            pasteText("Page One", into: query, in: app)
            let current = app.buttons.matching(NSPredicate(format: "label == %@", "Current tab: Page One")).firstMatch
            XCTAssertTrue(current.waitForExistence(timeout: 5))
            current.click()
            XCTAssertTrue(query.waitForNonExistence(timeout: 3))
            XCTAssertEqual(saved.value as? String, "keep saved document")
            expectRuntime(app, tabs: 1, views: 1, created: 1)
            // Untouched location Return must not reload or make a duplicate.
            app.typeKey("l", modifierFlags: .command)
            XCTAssertTrue(query.waitForExistence(timeout: 3))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(query.waitForNonExistence(timeout: 3))
            XCTAssertEqual(saved.value as? String, "keep saved document")
            expectRuntime(app, tabs: 1, views: 1, created: 1)

            navigate(app, to: "early-test://fixture/two")
            expectPage(app, "Two")
            expectRuntime(app, tabs: 2, views: 2, created: 2)
            XCTAssertFalse(savedControl.isSelected)
            let today = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", id)).firstMatch
            XCTAssertEqual(today.value as? String, "Today")
            savedControl.click()
            expectPage(app, "One")
            XCTAssertEqual(saved.value as? String, "keep saved document")
            app.typeKey("l", modifierFlags: .command)
            XCTAssertTrue(query.waitForExistence(timeout: 3))
            pasteText("Page Two", into: query, in: app)
            let existing = app.buttons.matching(NSPredicate(format: "label == %@", "Switch to Tab: Page Two")).firstMatch
            XCTAssertTrue(existing.waitForExistence(timeout: 5))
            existing.click()
            expectPage(app, "Two")
            expectRuntime(app, tabs: 2, views: 2, created: 2)
            app.terminate()
        }
    }

    func testLongCommandBarInputWrapsInCompactWindowAndKeepsNavigationIntent() {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        app.menuBarItems["Test Window"].click()
        visibleMenuAction("Compact Test Window")
        let window = app.windows["browser"]
        XCTAssertEqual(window.frame.width, 800, accuracy: 1)
        app.typeKey("t", modifierFlags: .command)
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.matching(identifier: "commandBar.query").count, 1)
        XCTAssertEqual(query.value as? String, "")
        let card = app.descendants(matching: .any).matching(identifier: "commandBar.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        let initialInputHeight = query.frame.height
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(query.exists, "An empty Return must not create a tab")
        expectRuntime(app, tabs: 0, views: 0, created: 0)

        // Exercise normal paste instead of synthesizing thousands of key events.
        // Restore every original clipboard type only after all paste waits finish.
        let pasteboard = NSPasteboard.general
        let originalClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        defer {
            let items = originalClipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        func pasteQuery(_ text: String) {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString(text, forType: .string))
            app.typeKey("v", modifierFlags: .command)
            let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: query)
            XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
            XCTAssertEqual(query.value as? String, text)
        }
        let longURL = "early-test://fixture/one?payload=" + String(repeating: "wrapped-input-", count: 180)
        pasteQuery(longURL)
        let wrapped = NSPredicate { _, _ in query.frame.height > initialInputHeight + 5 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: wrapped, object: nil)], timeout: 3), .completed)
        XCTAssertLessThanOrEqual(query.frame.height, 120.5, "Long input must scroll inside a bounded editor")
        XCTAssertGreaterThan(query.frame.width, 100)
        XCTAssertGreaterThanOrEqual(query.frame.minX, card.frame.minX)
        XCTAssertLessThanOrEqual(query.frame.maxX, card.frame.maxX)
        XCTAssertGreaterThanOrEqual(query.frame.minY, card.frame.minY)
        XCTAssertLessThanOrEqual(query.frame.maxY, card.frame.maxY)
        XCTAssertGreaterThanOrEqual(card.frame.minX, window.frame.minX + 6)
        XCTAssertLessThanOrEqual(card.frame.maxX, window.frame.maxX - 6)
        XCTAssertLessThanOrEqual(card.frame.maxY, window.frame.maxY - 6)
        XCTAssertEqual(app.webViews.count, 0)
        app.typeKey(.return, modifierFlags: [])
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, longURL)
        // No explicit Select All: Open Location must select the entire long URL.
        pasteQuery("early-test://fixture/two")
        app.typeKey(.return, modifierFlags: [])
        expectPage(app, "Two")
        expectRuntime(app, tabs: 1, views: 1, created: 1)

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "")
        pasteQuery("early-test://fixture/one")
        app.typeKey(.escape, modifierFlags: [])
        expectPage(app, "Two")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        pasteQuery("early-test://fixture/one")
        app.typeKey(.return, modifierFlags: [])
        expectPage(app, "One")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
    }

    func testTranslucentChromePreservesNavigationInBothAppearances() {
        for appearance in ["dark", "light"] {
            let app = launchFreshApp(appearance: appearance)
            func capture(_ state: String) {
                let attachment = XCTAttachment(screenshot: app.windows["browser"].screenshot())
                attachment.name = "\(appearance) translucent chrome — \(state)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            capture("command bar")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.textFields["commandBar.query"].exists)
            expectRuntime(app, tabs: 0, views: 0, created: 0)
            capture("empty canvas")
            navigate(app, to: "early-test://fixture/one")
            expectPage(app, "One")
            let saved = app.webViews.textFields["Saved text"]
            saved.click()
            saved.typeText("preserve page through chrome changes")
            app.typeKey("l", modifierFlags: .command)
            XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(saved.value as? String, "preserve page through chrome changes")
            expectRuntime(app, tabs: 1, views: 1, created: 1)
            capture("loaded website")
            app.typeKey("l", modifierFlags: .command)
            let query = app.textFields["commandBar.query"]
            XCTAssertTrue(query.waitForExistence(timeout: 3))
            XCTAssertEqual(app.textFields.matching(identifier: "commandBar.query").count, 1)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "commandBar.card").firstMatch.exists)
            capture("command bar with Space theme")
            app.typeKey(.escape, modifierFlags: [])
            openSettings(app, section: "appearance")
            let themes = app.descendants(matching: .any).matching(identifier: "settings.spaceThemes").firstMatch
            XCTAssertTrue(themes.waitForExistence(timeout: 3))
            themes.click()
            let off = NSPredicate { _, _ in
                if let value = themes.value as? NSNumber { return !value.boolValue }
                return ["0", "off", "false"].contains((themes.value as? String)?.lowercased() ?? "")
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: off, object: nil)], timeout: 3), .completed)
            app.typeKey("w", modifierFlags: .command)
            app.typeKey("l", modifierFlags: .command)
            XCTAssertTrue(query.waitForExistence(timeout: 3))
            XCTAssertEqual(query.value as? String, "early-test://fixture/one")
            capture("command bar without Space theme")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(saved.value as? String, "preserve page through chrome changes")
            expectRuntime(app, tabs: 1, views: 1, created: 1)
            app.terminate()
        }
    }

    func testDefaultSearchSuggestionsKeyboardDismissalAndRelaunch() {
        let app = launchFreshApp()
        let toggle = app.checkBoxes["commandBar.onlineSuggestions"]
        let query = app.textFields["commandBar.query"]
        let first = app.buttons["commandBar.suggestion.0"]
        XCTAssertFalse(toggle.exists)
        XCTAssertFalse(app.staticTexts["When enabled, typed searches are sent to Google."].exists)
        query.typeText("swift")
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.label, "Search Google for swift guide")
        query.click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(first.isSelected)
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertFalse(first.isSelected)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("https://example.com/private")
        XCTAssertFalse(first.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(query.exists)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertFalse(toggle.exists)
        XCTAssertFalse(first.exists)
        query.typeText("browser")
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.label, "Search Google for browser guide")
        XCTAssertLessThan(app.buttons["commandBar.suggestion.2"].frame.maxY, app.windows["browser"].frame.maxY)
        app.terminate()
        app.launch()
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        XCTAssertFalse(toggle.exists)
        XCTAssertFalse(first.exists)
        query.typeText("swift")
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.label, "Search Google for swift guide")
    }

    func testRightArrowCompletesTheHighlightedSuggestionWithoutSubmittingOrLosingTheCaret() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep page state")
        let pageState = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "keep page state"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [pageState], timeout: 5), .completed)
        let originalTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.")).firstMatch.identifier
        expectRuntime(app, tabs: 1, views: 1, created: 1)

        app.typeKey("l", modifierFlags: .command)
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        app.typeText("swift")
        let first = app.buttons["commandBar.suggestion.0"]
        let second = app.buttons["commandBar.suggestion.1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == true", "Search Google for swift guide"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        func expectSelected(_ element: XCUIElement, _ selected: Bool) {
            let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == %@", NSNumber(value: selected)), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 3), .completed)
        }
        func expectQuery(_ text: String) {
            let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: query)
            XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed)
            XCTAssertEqual(query.value as? String, text)
        }
        app.typeKey(.downArrow, modifierFlags: [])
        expectSelected(first, true)
        app.typeKey(.downArrow, modifierFlags: [])
        expectSelected(second, true)
        app.typeKey(.upArrow, modifierFlags: [])
        expectSelected(first, true)
        expectSelected(second, false)
        expectQuery("swift")

        app.typeKey(.rightArrow, modifierFlags: [])
        expectQuery("swift guide")
        // Do not click or reposition the cursor: completion must leave focus
        // in the native editor with its caret after the completed phrase.
        app.typeText(" edited")
        expectQuery("swift guide edited")
        XCTAssertTrue(query.exists)
        XCTAssertTrue(app.buttons[originalTab].isSelected)
        expectRuntime(app, tabs: 1, views: 1, created: 1)

        // Keep this regression offline. Model/native tests cover Return's
        // navigation intent; here cancellation proves no submission occurred.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(query.waitForNonExistence(timeout: 3))
        expectPage(app, "One")
        XCTAssertEqual(saved.value as? String, "keep page state")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    private func visibleMenuAction(_ title: String) {
        let items = XCUIApplication().menuItems.matching(identifier: title)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 3))
        let item = items.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(item, "No visible menu action: \(title)")
        item?.click()
    }

    private func openSettings(_ app: XCUIApplication, section: String) {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings.window").firstMatch.waitForExistence(timeout: 5))
        // The Settings group must not overwrite its children's identifiers.
        for key in ["appearance", "profiles", "sidebar", "search", "sessions"] {
            XCTAssertEqual(app.buttons.matching(identifier: "settings.section.\(key)").count, 1,
                           "Settings navigation should expose a unique identifier for \(key)")
        }
        let tab = app.buttons["settings.section.\(section)"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.click()
    }

    @discardableResult private func createProfile(_ app: XCUIApplication, named name: String) -> String {
        openSettings(app, section: "profiles")
        app.buttons["profile.create"].click()
        let field = app.textFields["profile.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.buttons["profile.save"].click()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "profile.", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        return String(row.identifier.dropFirst("profile.".count))
    }

    func testSettingsPersistWithoutReplacingTheLiveWebsite() throws {
        // Native macOS switches expose NSNumber values on some runner versions
        // and strings on others. Both describe the same checked state.
        func switchState(_ control: XCUIElement) -> Bool? {
            if let value = control.value as? NSNumber { return value.boolValue }
            switch (control.value as? String)?.lowercased() {
            case "1", "on", "true": return true
            case "0", "off", "false": return false
            default: return nil
            }
        }
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let saved = app.windows["browser"].webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep my page through settings")
        openSettings(app, section: "appearance")
        app.buttons["settings.appearance.light"].click()
        let translucency = app.descendants(matching: .any).matching(identifier: "settings.translucency").firstMatch
        XCTAssertTrue(translucency.waitForExistence(timeout: 3))
        let themes = app.descendants(matching: .any).matching(identifier: "settings.spaceThemes").firstMatch
        XCTAssertEqual(themes.frame.midX, translucency.frame.midX, accuracy: 1, "Settings switches should share one trailing column")
        let originalSetting = try XCTUnwrap(switchState(translucency), "The switch must expose its checked state")
        translucency.click()
        let changed = NSPredicate { _, _ in switchState(translucency) == !originalSetting }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 3), .completed)
        let setting = try XCTUnwrap(switchState(translucency))
        XCTAssertNotEqual(setting, originalSetting)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(saved.value as? String, "keep my page through settings")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.terminate()
        app.launch()
        expectPage(app, "One")
        openSettings(app, section: "appearance")
        XCTAssertTrue(app.buttons["settings.appearance.light"].isSelected)
        XCTAssertEqual(switchState(translucency), setting)
        app.typeKey("w", modifierFlags: .command)
    }

    func testProfilesKeepSeparateTabsAndRestoreBothWindows() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let personalWindow = app.windows["browser"]
        let personalText = personalWindow.webViews.textFields["Saved text"]
        personalText.click()
        personalText.typeText("personal page state")
        let profileID = createProfile(app, named: "Work")
        app.buttons["profile.open.\(profileID)"].click()
        let workWindow = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.")).firstMatch
        XCTAssertTrue(workWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(workWindow.textFields["commandBar.query"].waitForExistence(timeout: 5))
        XCTAssertEqual(workWindow.webViews.count, 0)
        workWindow.textFields["commandBar.query"].typeText("early-test://fixture/two\n")
        XCTAssertTrue(workWindow.webViews.staticTexts["Page Two"].waitForExistence(timeout: 10))
        XCTAssertEqual(personalText.value as? String, "personal page state")
        // Close Settings, not a browser window, so its restoration cannot mask
        // whether both profile windows were actually restored by Early.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["settings.section.profiles"].waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
        app.launch()
        let browsers = app.windows.matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "browser", "browser."))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: browsers)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        XCTAssertTrue(app.webViews.staticTexts["Page One"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Page Two"].waitForExistence(timeout: 10))
    }

    func testDefaultProfileSelectionPersistsWithoutOpeningOrSwitchingProfiles() {
        let app = launchFreshApp()
        let profileID = createProfile(app, named: "Work")
        let menu = app.descendants(matching: .any).matching(identifier: "profile.manage.\(profileID)").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.click()
        visibleMenuAction("Make Default")
        menu.click()
        XCTAssertTrue(app.menuItems["Make Default"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Make Default"].isEnabled, "The current default should not offer to make itself default again")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.popUpButtons["profile.default"].exists)
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.")).count, 0)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 10))
        openSettings(app, section: "profiles")
        XCTAssertTrue(app.buttons["profile.\(profileID)"].exists)
        menu.click()
        XCTAssertTrue(app.menuItems["Make Default"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Make Default"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMovingSpaceToAnotherProfileRequiresConfirmationAndKeepsClosedPinsClosed() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.")).firstMatch
        tab.rightClick()
        visibleMenuAction("Pin Tab")
        app.typeKey("w", modifierFlags: .command)
        let profileID = createProfile(app, named: "Work")
        XCTAssertTrue(app.buttons["profile.open.\(profileID)"].exists)
        app.typeKey("w", modifierFlags: .command)
        spaceDot(app, named: "Personal").rightClick()
        visibleMenuAction("Edit Space…")
        let field = app.textFields["space.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText("Moved")
        app.popUpButtons["space.profile"].click()
        visibleMenuAction("Work")
        app.buttons["Save"].click()
        // The editor and Touch Bar also contain Cancel. Target the native
        // confirmation sheet, not an unrelated underlying button.
        let confirmation = app.windows["browser"].sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
        XCTAssertTrue(confirmation.buttons["Move and Reload"].waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.value as? String, "Moved")
        XCTAssertEqual(app.popUpButtons["space.profile"].value as? String, "Work")
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.")).count, 0)
        app.buttons["Save"].click()
        XCTAssertTrue(confirmation.buttons["Move and Reload"].waitForExistence(timeout: 5))
        confirmation.buttons["Move and Reload"].click()
        let destination = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.")).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "space.", "Moved")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(destination.webViews.count, 0)
        XCTAssertEqual(app.windows["browser"].webViews.count, 0)
        XCTAssertTrue(destination.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.")).firstMatch.exists)
    }

    private func spaceDot(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "space.", name)).firstMatch
    }

    private func createSpace(_ app: XCUIApplication, named name: String) {
        app.buttons["space.new"].click()
        let field = app.textFields["space.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.buttons["Save"].click()
        XCTAssertTrue(spaceDot(app, named: name).waitForExistence(timeout: 5))
        XCTAssertTrue(spaceDot(app, named: name).isSelected)
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
    }

    func testProfilesSpaceEditFollowsSavedSpaceButCancelKeepsCurrentSpace() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        createSpace(app, named: "Work")
        navigate(app, to: "early-test://fixture/two")
        expectPage(app, "Two")
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep the edited Space alive")
        let work = spaceDot(app, named: "Work")
        let workID = String(work.identifier.dropFirst("space.".count))
        spaceDot(app, named: "Personal").click()
        expectPage(app, "One")

        openSettings(app, section: "profiles")
        app.buttons["settings.space.edit.\(workID)"].click()
        XCTAssertTrue(app.textFields["space.name"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        expectPage(app, "One")

        openSettings(app, section: "profiles")
        app.buttons["settings.space.edit.\(workID)"].click()
        let field = app.textFields["space.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText("Research")
        app.buttons["Save"].click()
        let research = spaceDot(app, named: "Research")
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        XCTAssertTrue(research.isSelected)
        expectPage(app, "Two")
        XCTAssertEqual(saved.value as? String, "keep the edited Space alive")
        expectRuntime(app, tabs: 1, views: 2, created: 2)
    }

    func testSpaceIconsDragToReorderWithoutSwitchingTheLivePage() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep while reordering Spaces")
        createSpace(app, named: "Work")
        createSpace(app, named: "Research")
        let personal = spaceDot(app, named: "Personal")
        let work = spaceDot(app, named: "Work")
        let research = spaceDot(app, named: "Research")
        // An ancestor's viewport must not become the first icon's AX frame.
        // In that case both click() and drag coordinates land on another Space.
        for icon in [personal, work, research] {
            XCTAssertEqual(icon.frame.width, 30, accuracy: 0.5)
            XCTAssertEqual(icon.frame.height, 28, accuracy: 0.5)
        }
        XCTAssertLessThanOrEqual(personal.frame.maxX, work.frame.minX + 0.5)
        XCTAssertLessThanOrEqual(work.frame.maxX, research.frame.minX + 0.5)
        personal.click()
        let selected = NSPredicate(format: "selected == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: personal)], timeout: 5), .completed)
        expectPage(app, "One")
        let source = personal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = research.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        source.click(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.2)
        let order = NSPredicate { _, _ in
            self.spaceDot(app, named: "Work").frame.minX < self.spaceDot(app, named: "Research").frame.minX
                && self.spaceDot(app, named: "Research").frame.minX < personal.frame.minX
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: order, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(personal.isSelected)
        XCTAssertFalse(app.textFields["space.name"].exists)
        XCTAssertEqual(saved.value as? String, "keep while reordering Spaces")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(personal.waitForExistence(timeout: 10))
        XCTAssertTrue(personal.isSelected)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: order, object: nil)], timeout: 5), .completed)
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testSpaceSwitchingPreservesPageStateAndEmptySpaceRelaunch() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep this Space alive")
        createSpace(app, named: "Work")
        expectRuntime(app, tabs: 0, views: 1, created: 1)
        app.typeKey("l", modifierFlags: .command)
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.typeText("cancel when switching")
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        XCTAssertFalse(query.exists)
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        expectPage(app, "One")
        XCTAssertEqual(saved.value as? String, "keep this Space alive")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.typeKey("9", modifierFlags: [.command, .option])
        XCTAssertTrue(spaceDot(app, named: "Work").isSelected)
        XCTAssertFalse(query.exists)
        expectRuntime(app, tabs: 0, views: 1, created: 1)
        navigate(app, to: "early-test://fixture/two")
        expectPage(app, "Two")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(query.exists)
        expectRuntime(app, tabs: 0, views: 1, created: 2)
        app.terminate()
        app.launch()
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(spaceDot(app, named: "Work").isSelected)
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        spaceDot(app, named: "Personal").click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testSpaceRenameDuplicateMoveAndDeleteConfirmation() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.")).firstMatch
        pinAction("Pin Tab", on: original)
        app.menuBarItems["Space"].click()
        visibleMenuAction("Duplicate Space")
        XCTAssertTrue(spaceDot(app, named: "Personal Copy").waitForExistence(timeout: 5))
        expectRuntime(app, tabs: 0, views: 1, created: 1)
        app.menuBarItems["Space"].click()
        visibleMenuAction("Edit Space…")
        let field = app.textFields["space.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText("Research")
        app.buttons["Save"].click()
        XCTAssertTrue(spaceDot(app, named: "Research").waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.")).firstMatch.click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 2, created: 2)
        app.menuBarItems["Tab"].click()
        app.menuItems["Move Tab to Space"].hover()
        visibleMenuAction("Personal")
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        expectPage(app, "One")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        spaceDot(app, named: "Research").click()
        expectRuntime(app, tabs: 0, views: 2, created: 2)
        app.menuBarItems["Space"].click()
        visibleMenuAction("Delete Space…")
        // Native alerts also mirror their actions into the Touch Bar. Scope
        // these queries to the sheet so its duplicate buttons cannot match.
        let cancelDeletion = app.sheets.buttons["Cancel"]
        XCTAssertTrue(cancelDeletion.waitForExistence(timeout: 5))
        cancelDeletion.click()
        XCTAssertTrue(cancelDeletion.waitForNonExistence(timeout: 3))
        XCTAssertTrue(spaceDot(app, named: "Research").exists)
        app.menuBarItems["Space"].click()
        visibleMenuAction("Delete Space…")
        let confirmDeletion = app.sheets.buttons["Delete Space"]
        XCTAssertTrue(confirmDeletion.waitForExistence(timeout: 5))
        confirmDeletion.click()
        XCTAssertTrue(confirmDeletion.waitForNonExistence(timeout: 3))
        XCTAssertFalse(spaceDot(app, named: "Research").exists)
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        expectRuntime(app, tabs: 2, views: 2, created: 2)
    }

    func testContextMenusMoveTodayTabsPinsAndFoldersWithoutReplacingLivePages() {
        let app = launchFreshApp()
        createSpace(app, named: "Work")
        spaceDot(app, named: "Personal").click()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let tabID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.")).firstMatch.identifier
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep through Space moves")
        func move(_ row: XCUIElement, to name: String) {
            row.rightClick()
            XCTAssertTrue(app.menuItems["Move to Space"].waitForExistence(timeout: 3))
            app.menuItems["Move to Space"].hover()
            visibleMenuAction(name)
        }
        move(app.buttons[tabID], to: "Work")
        XCTAssertTrue(spaceDot(app, named: "Work").isSelected)
        XCTAssertTrue(app.buttons[tabID].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons[tabID].value as? String, "Today")
        XCTAssertTrue(app.buttons[tabID].isSelected)
        expectPage(app, "One")
        XCTAssertEqual(saved.value as? String, "keep through Space moves")

        pinAction("Pin Tab", on: app.buttons[tabID])
        move(app.buttons[tabID], to: "Personal")
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        XCTAssertTrue(app.buttons[tabID].waitForExistence(timeout: 3))
        XCTAssertTrue((app.buttons[tabID].value as? String)?.hasPrefix("Pinned, open") == true)
        XCTAssertTrue(app.buttons[tabID].isSelected)
        expectPage(app, "One")
        app.scrollViews["sidebar.tabs"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        visibleMenuAction("New Folder")
        let name = app.textFields["folder.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeText("Collection")
        app.buttons["Save"].click()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Collection'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        let folderID = folder.identifier
        app.buttons[tabID].rightClick()
        app.menuItems["Move to Folder"].hover()
        visibleMenuAction("Collection")
        move(app.buttons[folderID], to: "Work")
        XCTAssertTrue(spaceDot(app, named: "Work").isSelected)
        XCTAssertTrue(app.buttons[folderID].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[tabID].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[folderID].isHittable)
        XCTAssertTrue(app.buttons[tabID].isSelected)
        expectPage(app, "One")
        XCTAssertEqual(saved.value as? String, "keep through Space moves")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testSpaceColorSwatchesPersistTheSelectedColor() {
        let app = launchFreshApp()
        app.buttons["space.new"].click()
        let field = app.textFields["space.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Green Space")
        for color in ["gray", "blue", "purple", "pink", "red", "orange", "yellow", "green"] {
            XCTAssertTrue(app.buttons["space.color.\(color)"].exists)
        }
        app.buttons["space.color.green"].click()
        XCTAssertTrue(app.buttons["space.color.green"].isSelected)
        app.buttons["Save"].click()
        XCTAssertTrue(spaceDot(app, named: "Green Space").waitForExistence(timeout: 5))
        app.menuBarItems["Space"].click()
        visibleMenuAction("Edit Space…")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["space.color.green"].isSelected)
        app.buttons["Cancel"].click()
    }

    func testSpaceFooterSlidesToKeepSelectionVisibleWithoutOverflowMenu() {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        for number in 1...6 { createSpace(app, named: "Space \(number)") }
        let overflow = app.descendants(matching: .any).matching(identifier: "space.overflow").firstMatch
        XCTAssertFalse(overflow.exists)
        let strip = app.descendants(matching: .any).matching(identifier: "space.strip").firstMatch
        XCTAssertTrue(strip.exists)
        let newSpace = app.buttons["space.new"]
        let newSpaceFrame = newSpace.frame
        let last = spaceDot(app, named: "Space 6")
        XCTAssertTrue(last.isHittable)
        XCTAssertGreaterThanOrEqual(last.frame.minX, strip.frame.minX)
        XCTAssertLessThanOrEqual(last.frame.maxX, strip.frame.maxX)
        // The ordinary Space menu remains available for direct navigation to
        // a hidden item; the footer itself never inserts another control.
        app.menuBarItems["Space"].click()
        visibleMenuAction("Personal")
        XCTAssertTrue(spaceDot(app, named: "Personal").waitForExistence(timeout: 5))
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        XCTAssertTrue(spaceDot(app, named: "Personal").isHittable)
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        app.typeKey("9", modifierFlags: [.command, .option])
        XCTAssertTrue(spaceDot(app, named: "Space 6").isSelected)
        XCTAssertTrue(spaceDot(app, named: "Space 6").isHittable)
        XCTAssertEqual(newSpace.frame, newSpaceFrame)
        XCTAssertFalse(overflow.exists)
    }

    func testSpaceIconPickerPersistsAndCancelKeepsOriginalAppearance() {
        let app = launchFreshApp()
        app.buttons["space.new"].click()
        let name = app.textFields["space.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Star Space")
        let picker = app.buttons["space.iconPicker"]
        picker.click()
        let star = app.buttons["space.symbol.star.fill"]
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        star.click()
        XCTAssertEqual(picker.value as? String, "Star")
        app.buttons["space.color.purple"].click()
        app.buttons["Save"].click()
        let space = spaceDot(app, named: "Star Space")
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        XCTAssertEqual(space.value as? String, "Current Space · Star")
        app.menuBarItems["Space"].click()
        visibleMenuAction("Edit Space…")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        picker.click()
        let moon = app.buttons["space.symbol.moon.fill"]
        XCTAssertTrue(moon.waitForExistence(timeout: 3))
        moon.click()
        app.buttons["space.color.red"].click()
        app.buttons["Cancel"].click()
        XCTAssertEqual(space.value as? String, "Current Space · Star")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(space.value as? String, "Current Space · Star")
        app.menuBarItems["Space"].click()
        visibleMenuAction("Edit Space…")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["space.color.purple"].isSelected)
        picker.click()
        let reset = app.buttons["space.icon.none"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        reset.click()
        app.buttons["Save"].click()
        XCTAssertEqual(space.value as? String, "Current Space · Default dot")
    }

    private func pinAction(_ title: String, on row: XCUIElement) {
        row.rightClick()
        visibleMenuAction(title)
    }

    /// Establish fixture state through native paste, without depending on a
    /// long synthetic key sequence. Preserve every original clipboard type and
    /// wait for the exact value before the action under test can begin.
    private func pasteText(_ text: String, into field: XCUIElement, in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        let pasteboard = NSPasteboard.general
        let original = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        defer {
            let items = original.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        field.click()
        app.typeKey("a", modifierFlags: .command)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string), file: file, line: line)
        app.typeKey("v", modifierFlags: .command)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed,
                       "Native paste must establish the exact fixture text before testing preservation",
                       file: file, line: line)
    }

    func testEmptyFolderIconTogglesWithoutAddingBlankContent() {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        app.scrollViews["sidebar.tabs"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        visibleMenuAction("New Folder")
        let name = app.textFields["folder.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeText("Empty folder")
        app.buttons["Save"].click()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Empty folder'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        XCTAssertEqual(folder.value as? String, "Collapsed")
        let height = folder.frame.height
        let newTabY = app.buttons["sidebar.newTab"].frame.minY
        folder.click()
        XCTAssertEqual(folder.value as? String, "Expanded")
        XCTAssertEqual(folder.frame.height, height, accuracy: 1)
        XCTAssertEqual(app.buttons["sidebar.newTab"].frame.minY, newTabY, accuracy: 1)
        folder.click()
        XCTAssertEqual(folder.value as? String, "Collapsed")
        XCTAssertEqual(app.buttons["sidebar.newTab"].frame.minY, newTabY, accuracy: 1)
        expectRuntime(app, tabs: 0, views: 0, created: 0)
    }

    /// XCTest resolves the destination before mouse-down. Anchor Pins to its
    /// actual scroll viewport (below the Space heading), then account for the
    /// Favorites row that will appear when dragging begins.
    private func savedSectionTarget(_ app: XCUIApplication, favorites: Bool) -> XCUICoordinate {
        let favoriteSection = app.descendants(matching: .any)
            .matching(identifier: "sidebar.favorites").firstMatch
        let favoritesVisible = favoriteSection.exists
        let favoriteRowHeight: CGFloat = 43.2
        let sectionSpacing: CGFloat = 16
        if favorites {
            if favoritesVisible {
                return favoriteSection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            }
            return app.buttons["sidebar.addressBar"]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: sectionSpacing + favoriteRowHeight / 2))
        }
        let revealOffset = favoritesVisible ? 0 : favoriteRowHeight + sectionSpacing
        return app.scrollViews["sidebar.tabs"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: revealOffset + 17)) // Center of the 34-point empty Pins target.
    }

    private func dragSidebarItem(_ element: XCUIElement, to target: XCUICoordinate,
                                 holdDuration: TimeInterval = 0.8,
                                 file: StaticString = #filePath, line: UInt = #line) {
        // A revealed Pins target can overlap the source row's old center.
        // Start off-center so horizontal travel crosses DragGesture's minimum
        // distance even when there is almost no vertical travel before reveal.
        let source = element.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let start = source.screenPoint
        let end = target.screenPoint
        XCTAssertGreaterThan(hypot(end.x - start.x, end.y - start.y), 12,
                             "Drag must move far enough to start: \(start) → \(end)", file: file, line: line)
        source.click(forDuration: 0.2, thenDragTo: target,
                     withVelocity: .slow, thenHoldForDuration: holdDuration)
    }

    /// Native drag destinations are resolved before mouse-down. Account for
    /// the empty saved-section targets that appear once dragging begins.
    private func savedSectionRevealOffset(_ app: XCUIApplication) -> CGFloat {
        let favoritesVisible = app.descendants(matching: .any)
            .matching(identifier: "sidebar.favorites").firstMatch.exists
        let foldersVisible = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.'")).count > 0
        let pinsVisible = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
            .allElementsBoundByIndex.contains { ($0.value as? String)?.hasPrefix("Pinned") == true }
        // Favorite row (43.2) + section spacing (16); empty Pins target
        // (34), end marker (4), and two inter-item spaces (4 each).
        return (favoritesVisible ? 0 : 59.2) + (foldersVisible || pinsVisible ? 0 : 46)
    }

    func testAdaptiveFavoritesAndNestedFolderDropRegions() {
        verifyAdaptiveFavoritesAndNestedFolderDropRegions(appearance: "dark")
    }

    func testAdaptiveFavoritesAndNestedFolderDropRegionsInLightAppearance() {
        verifyAdaptiveFavoritesAndNestedFolderDropRegions(appearance: "light")
    }

    private func verifyAdaptiveFavoritesAndNestedFolderDropRegions(appearance: String) {
        let app = launchFreshApp(appearance: appearance)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sidebar.favorites").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["sidebar.pinned.heading"].exists)
        XCTAssertFalse(app.staticTexts["Pins"].exists)
        XCTAssertTrue(app.buttons["sidebar.newTab"].exists)
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let firstID = rows.firstMatch.identifier
        dragSidebarItem(app.buttons[firstID], to: savedSectionTarget(app, favorites: false))
        expectSidebarStatus(app.buttons[firstID], "Pinned, open")
        dragSidebarItem(app.buttons[firstID], to: savedSectionTarget(app, favorites: true))
        let first = app.buttons["favorite.\(firstID.dropFirst(4))"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        let width = first.frame.width
        XCTAssertGreaterThan(width, 200)

        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let secondID = rows.firstMatch.identifier
        pinAction("Add to Favorites", on: app.buttons[secondID])
        let second = app.buttons["favorite.\(secondID.dropFirst(4))"]
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
        XCTAssertEqual(first.frame.width + second.frame.width + 6, width, accuracy: 1)

        navigate(app, to: "early-test://fixture/one", newTab: true)
        expectPage(app, "One")
        let thirdID = rows.firstMatch.identifier
        pinAction("Add to Favorites", on: app.buttons[thirdID])
        let third = app.buttons["favorite.\(thirdID.dropFirst(4))"]
        XCTAssertTrue(third.waitForExistence(timeout: 3))
        XCTAssertEqual(first.frame.width, third.frame.width, accuracy: 1)
        XCTAssertEqual(first.frame.width + second.frame.width + third.frame.width + 12, width, accuracy: 1)

        app.scrollViews["sidebar.tabs"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        visibleMenuAction("New Folder")
        let name = app.textFields["folder.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click(); name.typeText("Work")
        app.buttons["Save"].click()
        let root = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Work'")).firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        XCTAssertEqual(root.value as? String, "Collapsed")
        pinAction("New Subfolder…", on: root)
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click(); name.typeText("Mails")
        app.buttons["Save"].click()
        let child = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Mails'")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        XCTAssertEqual(root.value as? String, "Expanded")
        XCTAssertEqual(child.value as? String, "Collapsed")
        // Aim at the actual header, not a predicted preview offset: entering
        // the parent changes that preview while the drag is still in flight.
        let childDrop = child.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragSidebarItem(third, to: childDrop)
        XCTAssertTrue(app.buttons[thirdID].waitForExistence(timeout: 3))
        XCTAssertEqual(child.value as? String, "Expanded")
        XCTAssertGreaterThan(app.buttons[thirdID].frame.minY, child.frame.minY)
        XCTAssertEqual(first.frame.width + second.frame.width + 6, width, accuracy: 1)
        expectRuntime(app, tabs: 3, views: 3, created: 3)
        let screenshot = XCTAttachment(screenshot: app.windows["browser"].screenshot())
        screenshot.name = "\(appearance) adaptive Favorites and expanded nested folders"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        root.click()
        XCTAssertFalse(app.buttons[thirdID].exists)
        XCTAssertFalse(child.exists)
    }

    func testMixedPinOrderHoverFolderAndFavoriteInsertion() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let first = rows.firstMatch.identifier
        pinAction("Pin Tab", on: app.buttons[first])
        app.descendants(matching: .any).matching(identifier: "sidebar.tabs").firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        visibleMenuAction("New Folder")
        let name = app.textFields["folder.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click(); name.typeText("Work")
        app.buttons["Save"].click()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Work'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        let folderID = folder.identifier
        XCTAssertEqual(folder.value as? String, "Collapsed") // Hover reserves a slot; only a drop reveals the contents.
        // Both rows use the same full-width island, including their icon column.
        let pinIcon = app.buttons["pinSelect.\(first.dropFirst(4))"]
        let folderIcon = app.buttons["folderToggle.\(folderID.dropFirst(7))"]
        let pinBounds = app.buttons[first].frame.union(pinIcon.frame)
        let folderBounds = folder.frame.union(folderIcon.frame)
        XCTAssertEqual(folderBounds.height, pinBounds.height, accuracy: 0.5)
        XCTAssertEqual(folderBounds.width, pinBounds.width, accuracy: 0.5)
        XCTAssertEqual(folderBounds.minX, pinBounds.minX, accuracy: 0.5)
        XCTAssertEqual(folder.frame.minX, app.buttons[first].frame.minX, accuracy: 0.5)
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let second = rows.allElementsBoundByIndex.first { $0.identifier != first }!.identifier
        func drag(_ id: String, to target: XCUIElement, y: CGFloat = 0.5, x: CGFloat = 0.5) {
            let shift = savedSectionRevealOffset(app)
            app.buttons[id].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.2, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
                    .withOffset(CGVector(dx: 0, dy: shift)),
                       withVelocity: .slow, thenHoldForDuration: 0.8)
        }
        func expectBefore(_ item: XCUIElement, _ next: XCUIElement, horizontally: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) {
            // Cross-section drops remove temporary targets and animate the
            // incoming row. Compare settled ordering, not an in-flight AX frame.
            let settled = NSPredicate { _, _ in
                guard item.exists, next.exists else { return false }
                let first = item.frame, second = next.frame
                guard self.isVisibleSidebarFrame(first), self.isVisibleSidebarFrame(second) else { return false }
                return horizontally ? first.minX < second.minX : first.minY < second.minY
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: app)], timeout: 3),
                           .completed, "Items should settle into the expected order", file: file, line: line)
        }
        drag(second, to: folder, y: 0.05)
        expectSidebarStatus(app.buttons[second], "Pinned, open")
        expectBefore(app.buttons[second], folder)
        XCTAssertEqual(folder.value as? String, "Collapsed")
        // Reorder the root pin above the folder before entering its header.
        // From below, revealing Favorites and the sibling preview move the
        // folder past the pre-resolved center. Keep root insertion and actual
        // header entry as separate gestures with separate assertions.
        drag(first, to: folder, y: 0.05)
        expectBefore(app.buttons[first], folder)
        XCTAssertEqual(folder.value as? String, "Collapsed")
        drag(first, to: folder)
        let expanded = NSPredicate(format: "value == %@", "Expanded")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expanded, object: folder)], timeout: 3), .completed)
        XCTAssertGreaterThan(app.buttons[first].frame.minY, folder.frame.minY)
        folder.click()
        XCTAssertFalse(app.buttons[first].exists)
        XCTAssertTrue(app.buttons[second].exists) // Upper-edge drop stayed at the root, outside this folder.
        folder.click()
        navigate(app, to: "early-test://fixture/one", newTab: true)
        expectPage(app, "One")
        let third = rows.allElementsBoundByIndex.first { ![first, second].contains($0.identifier) }!.identifier
        drag(third, to: app.buttons[first], y: 0.2)
        expectSidebarStatus(app.buttons[third], "Pinned, open")
        expectBefore(app.buttons[third], app.buttons[first])
        folder.click()
        XCTAssertFalse(app.buttons[third].exists)
        folder.click()
        app.buttons[second].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: savedSectionTarget(app, favorites: true),
                   withVelocity: .slow, thenHoldForDuration: 0.8)
        let favorite = "favorite.\(second.dropFirst(4))"
        XCTAssertTrue(app.buttons[favorite].waitForExistence(timeout: 3))
        drag(third, to: app.buttons[favorite], x: 0.15)
        let inserted = "favorite.\(third.dropFirst(4))"
        XCTAssertTrue(app.buttons[inserted].waitForExistence(timeout: 3))
        expectBefore(app.buttons[inserted], app.buttons[favorite], horizontally: true)
        expectRuntime(app, tabs: 3, views: 3, created: 3)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(app.buttons[folderID].waitForExistence(timeout: 8))
        XCTAssertLessThan(app.buttons[inserted].frame.minX, app.buttons[favorite].frame.minX)
        XCTAssertEqual(app.buttons[folderID].value as? String, "Collapsed")
        app.buttons[folderID].click()
        XCTAssertGreaterThan(app.buttons[first].frame.minY, app.buttons[folderID].frame.minY)
    }

    func testDraggingAcrossSectionsPreservesLivePage() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let id = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier.dropFirst(4)
        let field = app.webViews.textFields["Saved text"]
        field.click()
        field.typeText("keep across sections")
        let sidebar = app.descendants(matching: .any).matching(identifier: "browser.sidebar").firstMatch
        let regular = app.scrollViews["sidebar.tabs"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        XCTAssertTrue(sidebar.exists)
        // Recompute for each drag: moving into/out of Favorites changes whether
        // revealing its empty drop target will shift the Pins viewport.
        dragSidebarItem(app.buttons["tab.\(id)"], to: savedSectionTarget(app, favorites: false), holdDuration: 0.2)
        expectSidebarStatus(app.buttons["tab.\(id)"], "Pinned, open")
        dragSidebarItem(app.buttons["tab.\(id)"], to: savedSectionTarget(app, favorites: true), holdDuration: 0.2)
        XCTAssertTrue(app.buttons["favorite.\(id)"].waitForExistence(timeout: 3))
        dragSidebarItem(app.buttons["favorite.\(id)"], to: savedSectionTarget(app, favorites: false), holdDuration: 0.2)
        XCTAssertTrue(app.buttons["tab.\(id)"].waitForExistence(timeout: 3))
        expectSidebarStatus(app.buttons["tab.\(id)"], "Pinned, open")
        dragSidebarItem(app.buttons["tab.\(id)"], to: regular, holdDuration: 0.2)
        expectSidebarStatus(app.buttons["tab.\(id)"], "Today")
        dragSidebarItem(app.buttons["tab.\(id)"], to: savedSectionTarget(app, favorites: true), holdDuration: 0.2)
        XCTAssertTrue(app.buttons["favorite.\(id)"].waitForExistence(timeout: 3))
        dragSidebarItem(app.buttons["favorite.\(id)"], to: regular, holdDuration: 0.2)
        XCTAssertTrue(app.buttons["tab.\(id)"].waitForExistence(timeout: 3))
        expectSidebarStatus(app.buttons["tab.\(id)"], "Today")
        XCTAssertEqual(field.value as? String, "keep across sections")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testNestedFoldersKeepLiveTabAndRestoreHierarchy() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let tabID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        app.descendants(matching: .any).matching(identifier: "sidebar.tabs").firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        visibleMenuAction("New Folder")
        let name = app.textFields["folder.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeText("Work")
        app.buttons["Save"].click()
        let root = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Work'")).firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        let rootID = root.identifier
        root.click()
        pinAction("New Subfolder…", on: root)
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeText("Research")
        app.buttons["Save"].click()
        let child = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Research'")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        let childID = child.identifier
        app.buttons[tabID].rightClick()
        app.menuItems["Move to Folder"].hover()
        visibleMenuAction("Work / Research")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        XCTAssertTrue((app.buttons[tabID].value as? String ?? "").contains("Pinned"))
        app.buttons[rootID].click()
        XCTAssertFalse(app.buttons[childID].exists)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(app.buttons[rootID].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons[childID].exists)
        app.buttons[rootID].click()
        XCTAssertTrue(app.buttons[childID].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons[childID].value as? String, "Collapsed")
        app.buttons[childID].click()
        XCTAssertTrue(app.buttons[tabID].exists)
    }

    func testDragPreviewAcceptsGapsAndTrailingSpace() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let second = rows.allElementsBoundByIndex.first { $0.identifier != first }!.identifier
        navigate(app, to: "early-test://fixture/one", newTab: true)
        expectPage(app, "One")
        let third = rows.allElementsBoundByIndex.first { ![first, second].contains($0.identifier) }!.identifier
        func expectOrder(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
            let settled = NSPredicate { _, _ in
                let rows = ids.map { app.buttons[$0] }
                guard rows.allSatisfy(\.exists) else { return false }
                let frames = rows.map(\.frame)
                guard frames.allSatisfy(self.isVisibleSidebarFrame) else { return false }
                let positions = frames.map(\.minY)
                return zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: app)], timeout: 3),
                           .completed, "Rows should settle into the expected order", file: file, line: line)
        }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let windowFrame = app.windows.firstMatch.frame
        func at(_ point: CGPoint) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: point.x - windowFrame.minX, dy: point.y - windowFrame.minY))
        }
        // Drop in the gap, not on a row or an insertion line. Use absolute
        // coordinates because rows visibly shift while the pointer is held.
        let gap = CGPoint(x: app.buttons[first].frame.midX,
                          y: (app.buttons[first].frame.maxY + app.buttons[second].frame.minY) / 2)
        app.buttons[third].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: at(gap).withOffset(CGVector(dx: 0, dy: savedSectionRevealOffset(app))), withVelocity: .slow, thenHoldForDuration: 0.6)
        expectOrder([first, third, second])
        for id in [first, second, third] { XCTAssertEqual(app.buttons[id].value as? String, "Today") }
        let empty = CGPoint(x: app.buttons[first].frame.midX, y: app.buttons[second].frame.maxY + 70)
        app.buttons[first].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: at(empty).withOffset(CGVector(dx: 0, dy: savedSectionRevealOffset(app))), withVelocity: .slow, thenHoldForDuration: 0.6)
        expectOrder([third, second, first])
        let outside = app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        app.buttons[third].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: outside)
        expectOrder([third, second, first])
        expectRuntime(app, tabs: 3, views: 3, created: 3)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(app.buttons[third].waitForExistence(timeout: 8))
        expectOrder([third, second, first])
    }

    func testDragOrderingPreservesLivePagesAndKeyboardOrder() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let firstID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let secondID = rows.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
        func expectOrder(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
            // Release starts an asynchronous landing animation. A transparent
            // real row can temporarily report CGRect.null through AX; neither
            // infinity nor that intermediate state establishes a valid order.
            let settled = NSPredicate { _, _ in
                let rows = ids.map { app.buttons[$0] }
                guard rows.allSatisfy(\.exists) else { return false }
                let frames = rows.map(\.frame)
                guard frames.allSatisfy(self.isVisibleSidebarFrame) else { return false }
                return zip(frames, frames.dropFirst()).allSatisfy { $0.minY < $1.minY }
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: app)], timeout: 3),
                           .completed, "Rows should finish landing in the expected order: \(ids)", file: file, line: line)
        }
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep during move")
        let source = app.buttons[secondID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = app.buttons[firstID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .withOffset(CGVector(dx: 0, dy: savedSectionRevealOffset(app)))
        source.click(forDuration: 0.3, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(app.textFields["rename.name"].exists, "Dragging must not open the rename editor")
        XCTAssertFalse(app.textFields["folder.name"].exists)
        expectOrder([secondID, firstID])
        XCTAssertEqual(app.buttons[firstID].value as? String, "Today")
        XCTAssertEqual(app.buttons[secondID].value as? String, "Today")
        XCTAssertEqual(saved.value as? String, "keep during move")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "Two")
        pinAction("Move Down", on: app.buttons[secondID])
        expectOrder([firstID, secondID])
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "One")
        // Normal clicks must still select; a drop outside the rows must not reorder.
        app.buttons[secondID].click()
        expectPage(app, "Two")
        XCTAssertEqual(saved.value as? String, "keep during move")
        let outside = app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
        source.click(forDuration: 0.2, thenDragTo: outside)
        expectOrder([firstID, secondID])
        // A second real drag, then relaunch, checks that the saved order is used.
        source.click(forDuration: 0.2, thenDragTo: destination)
        expectOrder([secondID, firstID])
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(app.buttons[secondID].waitForExistence(timeout: 8))
        expectOrder([secondID, firstID])
    }

    private func isVisibleSidebarFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && !frame.isEmpty
            && frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    private func optionClick(_ element: XCUIElement) {
        XCUIElement.perform(withKeyModifiers: .option) { element.click() }
    }

    func testOptionClickRenamesTabsAndFoldersWithoutReplacingLivePage() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let id = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep my page")
        let name = app.textFields["rename.name"]
        func rename(_ row: XCUIElement, from old: String, to new: String) {
            optionClick(row)
            XCTAssertTrue(name.waitForExistence(timeout: 3))
            XCTAssertEqual(name.value as? String, old)
            name.click()
            app.typeKey("a", modifierFlags: .command)
            name.typeText(new)
            app.buttons["Save"].click()
            XCTAssertEqual(row.label, new)
        }
        rename(app.buttons[id], from: "Page One", to: "My page")
        XCTAssertEqual(saved.value as? String, "keep my page")
        pinAction("Pin Tab", on: app.buttons[id])
        rename(app.buttons[id], from: "My page", to: "My pin")
        pinAction("Add to Favorites", on: app.buttons[id])
        let favorite = app.buttons["favorite.\(id.dropFirst(4))"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        rename(favorite, from: "My pin", to: "My favorite")
        optionClick(favorite)
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertEqual(favorite.label, "My favorite")
        XCTAssertEqual(saved.value as? String, "keep my page")
        expectRuntime(app, tabs: 1, views: 1, created: 1)

        app.scrollViews["sidebar.tabs"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        visibleMenuAction("New Folder")
        let folderName = app.textFields["folder.name"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 3))
        folderName.click()
        folderName.typeText("Work")
        app.buttons["Save"].click()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Work'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        let folderID = folder.identifier
        optionClick(folder)
        XCTAssertTrue(folderName.waitForExistence(timeout: 3))
        XCTAssertEqual(folderName.value as? String, "Work")
        folderName.click()
        app.typeKey("a", modifierFlags: .command)
        folderName.typeText("Research")
        app.buttons["Save"].click()
        let renamed = app.buttons[folderID]
        XCTAssertEqual(renamed.label, "Research")
        let beforeClick = renamed.value as? String
        renamed.click()
        XCTAssertEqual(renamed.value as? String, beforeClick == "Expanded" ? "Collapsed" : "Expanded")
        XCTAssertFalse(folderName.exists)
        optionClick(renamed)
        XCTAssertTrue(folderName.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertEqual(renamed.label, "Research")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testOptionClickRenameDoesNotSelectInactiveTabOrOpenClosedSavedPages() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let firstID = rows.firstMatch.identifier
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let secondID = rows.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("stay on this tab")
        let editor = app.textFields["rename.name"]
        optionClick(app.buttons[firstID])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertTrue(app.buttons[secondID].isSelected, "Rename must not select the inactive tab")
        expectPage(app, "Two")
        XCTAssertEqual(saved.value as? String, "stay on this tab")
        expectRuntime(app, tabs: 2, views: 2, created: 2)

        pinAction("Pin Tab", on: app.buttons[firstID])
        pinAction("Close Tab", on: app.buttons[firstID])
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        XCTAssertEqual(app.buttons[firstID].value as? String, "Pinned, closed")
        optionClick(app.buttons[firstID])
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText("Closed pin")
        app.buttons["Save"].click()
        XCTAssertEqual(app.buttons[firstID].label, "Closed pin")
        XCTAssertEqual(app.buttons[firstID].value as? String, "Pinned, closed")
        XCTAssertTrue(app.buttons[secondID].isSelected)
        expectRuntime(app, tabs: 1, views: 1, created: 2)

        pinAction("Add to Favorites", on: app.buttons[firstID])
        let favorite = app.buttons["favorite.\(firstID.dropFirst(4))"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        optionClick(favorite)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertEqual(favorite.value as? String, "Favorite, closed")
        XCTAssertTrue(app.buttons[secondID].isSelected)
        XCTAssertEqual(saved.value as? String, "stay on this tab")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        // An ordinary click must still reopen exactly this saved tab.
        favorite.click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 2, views: 2, created: 3)
    }

    func testOptionClickFolderRenamePreservesExpansionAndDisclosureTogglesOnce() {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        app.scrollViews["sidebar.tabs"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).rightClick()
        visibleMenuAction("New Folder")
        let editor = app.textFields["folder.name"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeText("Work")
        app.buttons["Save"].click()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        let folderID = folder.identifier
        let toggle = app.buttons["folderToggle.\(folderID.dropFirst(7))"]
        let count = app.staticTexts["test.folderToggles"]
        XCTAssertEqual(folder.frame.minY, toggle.frame.minY, accuracy: 0.5)
        XCTAssertEqual(folder.frame.height, toggle.frame.height, accuracy: 0.5)
        XCTAssertEqual(count.value as? String, "0")
        optionClick(folder)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertEqual(folder.value as? String, "Collapsed")
        XCTAssertEqual(count.value as? String, "0", "Rename must not toggle twice and return to the original state")
        toggle.click()
        XCTAssertEqual(folder.value as? String, "Expanded")
        XCTAssertEqual(count.value as? String, "1")
        optionClick(folder)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText("Research")
        app.buttons["Save"].click()
        XCTAssertEqual(app.buttons[folderID].label, "Research")
        XCTAssertEqual(app.buttons[folderID].value as? String, "Expanded")
        XCTAssertEqual(count.value as? String, "1")
        app.buttons[folderID].click()
        XCTAssertEqual(app.buttons[folderID].value as? String, "Collapsed")
        XCTAssertEqual(count.value as? String, "2", "Single-clicking the title should toggle exactly once")
        toggle.click()
        XCTAssertEqual(app.buttons[folderID].value as? String, "Expanded")
        XCTAssertEqual(count.value as? String, "3")
        XCTAssertFalse(editor.exists)
        optionClick(toggle)
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertEqual(app.buttons[folderID].value as? String, "Expanded")
        XCTAssertEqual(count.value as? String, "3", "Option-clicking the icon must rename without toggling")
    }

    func testCustomNameSurvivesPinCloseAndRelaunch() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch
        let id = row.identifier
        pinAction("Rename Tab…", on: row)
        let name = app.textFields["rename.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("My Videos")
        app.buttons["Save"].click()
        XCTAssertEqual(app.buttons[id].label, "My Videos")
        pinAction("Pin Tab", on: app.buttons[id])
        app.webViews.links["Go to Two"].click()
        expectPage(app, "Two")
        XCTAssertEqual(app.buttons[id].label, "My Videos")
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons[id].label, "My Videos")
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        pinAction("Rename Tab…", on: app.buttons[id])
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        app.buttons["Use Page Title"].click()
        XCTAssertEqual(app.buttons[id].label, "Page One")
        expectRuntime(app, tabs: 0, views: 0, created: 0)
    }

    func testFavoritesReuseLiveTabsAndRestoreClosedTiles() {
        let app = launchFreshApp()
        XCTAssertFalse(app.buttons["favorites.add"].exists)
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let firstID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        let firstFavorite = app.buttons["favorite.\(firstID.dropFirst(4))"]
        let saved = app.webViews.textFields["Saved text"]
        pasteText("keep favorite state", into: saved, in: app)
        pinAction("Add to Favorites", on: app.buttons[firstID])
        XCTAssertTrue(firstFavorite.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons[firstID].exists)
        XCTAssertFalse(app.buttons["favorites.add"].exists)
        firstFavorite.click()
        XCTAssertEqual(saved.value as? String, "keep favorite state")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.webViews.links["Go to Two"].click()
        expectPage(app, "Two")
        firstFavorite.click()
        expectPage(app, "Two")
        XCTAssertEqual(firstFavorite.label, "Page One")

        navigate(app, to: "early-test://fixture/one", newTab: true)
        expectPage(app, "One")
        let secondID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        pinAction("Add to Favorites", on: app.buttons[secondID])
        let secondFavorite = app.buttons["favorite.\(secondID.dropFirst(4))"]
        XCTAssertTrue(secondFavorite.waitForExistence(timeout: 3))
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "Two")
        app.typeKey("2", modifierFlags: .command)
        expectPage(app, "One")
        let image = XCTAttachment(screenshot: app.windows["browser"].screenshot())
        image.name = "Favorite tiles above the space"
        image.lifetime = .keepAlways
        add(image)
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        XCTAssertEqual(firstFavorite.value as? String, "Favorite, closed")
        app.menuBars.menuBarItems["Tab"].click()
        visibleMenuAction("Remove from Favorites")
        XCTAssertFalse(secondFavorite.exists)
        XCTAssertEqual(app.buttons[secondID].value as? String, "Today")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 2)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(firstFavorite.waitForExistence(timeout: 8))
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        XCTAssertEqual(firstFavorite.value as? String, "Favorite, closed")
        XCTAssertEqual(firstFavorite.label, "Page One")
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        pinAction("Remove from Favorites", on: firstFavorite)
        XCTAssertFalse(firstFavorite.exists)
        XCTAssertEqual(app.buttons[firstID].value as? String, "Today")
        expectRuntime(app, tabs: 1, views: 0, created: 0)
        pinAction("Add to Favorites", on: app.buttons[firstID])
        XCTAssertTrue(firstFavorite.waitForExistence(timeout: 3))
        firstFavorite.click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        XCTAssertEqual(app.buttons.matching(identifier: firstFavorite.identifier).count, 1)
    }

    func testPinUnpinAndResetReuseTheLivePage() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let id = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        let row = app.buttons[id]
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("preserve pin state")
        app.menuBars.menuBarItems["Tab"].click()
        visibleMenuAction("Pin Tab")
        XCTAssertEqual(row.value as? String, "Pinned, open")
        XCTAssertLessThan(row.frame.maxY, app.buttons["sidebar.newTab"].frame.minY)
        XCTAssertEqual(saved.value as? String, "preserve pin state")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        pinAction("Unpin Tab", on: row)
        XCTAssertEqual(row.value as? String, "Today")
        XCTAssertGreaterThanOrEqual(row.frame.minY, app.buttons["sidebar.newTab"].frame.maxY)
        XCTAssertEqual(saved.value as? String, "preserve pin state")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        pinAction("Pin Tab", on: row)
        app.webViews.links["Go to Two"].click()
        expectPage(app, "Two")
        app.menuBars.menuBarItems["Tab"].click()
        visibleMenuAction("Reset to Pinned URL")
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        XCTAssertEqual(app.buttons["sidebar.addressBar"].value as? String, "early-test://fixture/one")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).count, 1)

        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 1)
        XCTAssertEqual(row.value as? String, "Pinned, closed")
        XCTAssertFalse(row.isSelected)
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
        row.click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 2)
        pinAction("Reset to Pinned URL", on: row)
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 3)
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 3)
        app.typeKey("t", modifierFlags: [.command, .shift])
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 4)
        XCTAssertEqual(app.buttons.matching(identifier: id).count, 1)
    }

    func testPinnedIconResetsButTitleClickPreservesLivePage() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch
        let id = row.identifier
        pinAction("Pin Tab", on: app.buttons[id])
        let reset = app.buttons["pinReset.\(id.dropFirst(4))"]
        let select = app.buttons["pinSelect.\(id.dropFirst(4))"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        XCTAssertFalse(select.isEnabled)
        select.hover()
        XCTAssertFalse(reset.exists)
        app.webViews.links["Go to Two"].click()
        expectPage(app, "Two")
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep video state")
        app.buttons[id].click()
        expectPage(app, "Two")
        XCTAssertEqual(saved.value as? String, "keep video state")
        navigate(app, to: "early-test://fixture/one", newTab: true)
        expectPage(app, "One")
        XCTAssertTrue(reset.exists)
        XCTAssertTrue(reset.isEnabled)
        app.buttons[id].click()
        expectPage(app, "Two")
        XCTAssertEqual(saved.value as? String, "keep video state")
        XCTAssertTrue(reset.exists)
        reset.hover()
        let image = XCTAttachment(screenshot: app.windows["browser"].screenshot())
        image.name = "Pinned icon reset control"
        image.lifetime = .keepAlways
        add(image)
        reset.click()
        expectPage(app, "One")
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        XCTAssertFalse(select.isEnabled)
        select.hover()
        XCTAssertFalse(reset.exists)
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        XCTAssertEqual(app.buttons[id].label, "Page One")
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        XCTAssertFalse(reset.exists)
        XCTAssertFalse(select.isEnabled)
        app.buttons[id].click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 2, views: 2, created: 3)
        XCTAssertEqual(app.buttons.matching(identifier: id).count, 1)
        pinAction("Unpin Tab", on: app.buttons[id])
        XCTAssertFalse(reset.exists)
    }

    func testClosedPinRestoresAndUnpinsWithoutCreatingAWebView() {
        let app = launchFreshApp(appearance: "light")
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let id = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        let row = app.buttons[id]
        pinAction("Pin Tab", on: row)
        app.webViews.links["Go to Two"].click()
        expectPage(app, "Two")
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertEqual(row.value as? String, "Pinned, closed")
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        XCTAssertEqual(row.label, "Page One")
        row.click()
        expectPage(app, "One") // Closing reset the pin to its original URL.
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 1)
        pinAction("Unpin Tab", on: row)
        XCTAssertEqual(row.value as? String, "Today")
        expectRuntime(app, tabs: 1, views: 0, created: 1)
        XCTAssertEqual(app.buttons["sidebar.addressBar"].value as? String, "No active tab")
        app.typeKey("t", modifierFlags: [.command, .shift])
        expectRuntime(app, tabs: 1, views: 0, created: 1)
        row.click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
    }

    func testCloseControlsOnlyAppearWhenHoveringOpenTabs() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let firstID = rows.firstMatch.identifier
        let firstClose = app.buttons["tabClose.\(firstID.dropFirst(4))"]
        app.webViews.firstMatch.hover()
        XCTAssertFalse(firstClose.exists) // Active Today tab also waits for hover.
        app.buttons[firstID].hover()
        XCTAssertTrue(firstClose.waitForExistence(timeout: 3))
        XCTAssertTrue(firstClose.isHittable)
        app.webViews.firstMatch.hover()
        XCTAssertFalse(firstClose.exists)
        pinAction("Pin Tab", on: app.buttons[firstID])

        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let secondID = rows.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
        let secondClose = app.buttons["tabClose.\(secondID.dropFirst(4))"]
        app.webViews.firstMatch.hover()
        XCTAssertFalse(secondClose.exists)
        app.buttons[secondID].hover()
        XCTAssertTrue(secondClose.waitForExistence(timeout: 3))
        XCTAssertFalse(firstClose.exists) // Inactive open pin waits for its own hover.
        app.buttons[firstID].hover()
        XCTAssertTrue(firstClose.waitForExistence(timeout: 3))
        XCTAssertFalse(secondClose.exists) // Active tab hides its close when another row is hovered.
        firstClose.click()
        expectPage(app, "Two")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        expectSidebarStatus(app.buttons[firstID], "Pinned, closed")
        app.buttons[firstID].hover()
        XCTAssertFalse(firstClose.exists) // A closed pin has no close action, even on hover.

        app.buttons[firstID].click()
        expectPage(app, "One")
        app.webViews.firstMatch.hover()
        XCTAssertFalse(firstClose.exists) // Reopened active pin is hover-only too.
        app.buttons[firstID].hover()
        XCTAssertTrue(firstClose.waitForExistence(timeout: 3))
        XCTAssertTrue(firstClose.isHittable)
        XCTAssertFalse(secondClose.exists)
        app.buttons[secondID].hover()
        XCTAssertTrue(secondClose.waitForExistence(timeout: 3))
        app.webViews.firstMatch.hover()
        XCTAssertFalse(secondClose.exists) // Inactive Today tab hides again on exit.
        XCTAssertFalse(firstClose.exists)
        expectRuntime(app, tabs: 2, views: 2, created: 3)
    }

    func testBackgroundPinningPreservesSelectionAndUsesSidebarKeyboardOrder() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let firstID = rows.firstMatch.identifier
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        let secondID = rows.allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "One")
        pinAction("Pin Tab", on: app.buttons[secondID])
        expectPage(app, "One")
        XCTAssertLessThan(app.buttons[secondID].frame.minY, app.buttons[firstID].frame.minY)
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "Two")
        app.typeKey("2", modifierFlags: .command)
        expectPage(app, "One")
        let image = XCTAttachment(screenshot: app.windows["browser"].screenshot())
        image.name = "Pinned and Today sections"
        image.lifetime = .keepAlways
        add(image)
        app.buttons[secondID].hover()
        let close = app.buttons["tabClose.\(secondID.dropFirst(4))"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        XCTAssertEqual(app.buttons[secondID].value as? String, "Pinned, closed")
        XCTAssertFalse(app.buttons["tabClose.\(secondID.dropFirst(4))"].exists)
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "One")
    }

    func testThirtyTwoClosedPinsScrollAndLoadOnlyTheSelectedPage() {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["Test Window"].click()
        visibleMenuAction("Compact Test Window")
        app.menuBars.menuBarItems["Test Window"].click()
        visibleMenuAction("Install Closed Test Pins")
        XCTAssertTrue(app.buttons["Test Pin 1"].waitForExistence(timeout: 5))
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        let scroll = app.scrollViews["sidebar.tabs"]
        let footer = app.descendants(matching: .any).matching(identifier: "sidebar.footer").firstMatch
        XCTAssertTrue(footer.exists)
        XCTAssertEqual(footer.label, "Spaces")
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        XCTAssertGreaterThanOrEqual(footer.frame.minY, scroll.frame.maxY)
        let footerY = footer.frame.minY
        let last = app.buttons["Test Pin 32"]
        let newTab = app.buttons["sidebar.newTab"]
        for _ in 0..<10 {
            if last.exists && last.isHittable && newTab.exists && newTab.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -350)
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertTrue(newTab.isHittable)
        XCTAssertEqual(footer.frame.minY, footerY, accuracy: 1)
        let id = last.identifier
        XCTAssertLessThan(last.frame.maxY, newTab.frame.minY)
        XCTAssertFalse(app.staticTexts["sidebar.today.heading"].exists)
        newTab.click()
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        last.click()
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 1)
        XCTAssertEqual(app.buttons[id].value as? String, "Pinned, closed")
    }

    func testLeadingSpeakerControlsAndMenuOnlyFavoritesPreserveBackgroundSelection() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        let id = String(first.dropFirst("tab.".count))
        navigate(app, to: "early-test://fixture/two", newTab: true)
        expectPage(app, "Two")
        for kind in ["Today", "Pin"] {
            if kind == "Pin" { pinAction("Pin Tab", on: app.buttons[first]) }
            let row = app.buttons[first]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            pinAction("Mute Tab", on: row)
            let speaker = app.buttons["tabMute.\(id)"]
            XCTAssertTrue(speaker.waitForExistence(timeout: 5))
            XCTAssertEqual(speaker.value as? String, "Muted")
            XCTAssertLessThan(speaker.frame.maxX, row.frame.midX, "The speaker belongs next to the leading icon, not the close button")
            XCTAssertFalse(row.isSelected)
            expectPage(app, "Two")
            optionClick(speaker)
            XCTAssertTrue(speaker.waitForNonExistence(timeout: 5))
            XCTAssertFalse(row.isSelected)
            XCTAssertFalse(app.textFields["rename.name"].exists)
            expectPage(app, "Two")
            expectRuntime(app, tabs: 2, views: 2, created: 2)
        }
        pinAction("Add to Favorites", on: app.buttons[first])
        let favorite = app.buttons["favorite.\(id)"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        pinAction("Mute Tab", on: favorite)
        let muted = NSPredicate(format: "value CONTAINS %@", "muted")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: muted, object: favorite)], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["tabMute.\(id)"].exists, "Favorite cards must not show a speaker badge")
        XCTAssertFalse(favorite.isSelected)
        expectPage(app, "Two")
        pinAction("Unmute Tab", on: favorite)
        let unmuted = NSPredicate(format: "NOT (value CONTAINS %@)", "muted")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: unmuted, object: favorite)], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["tabMute.\(id)"].exists)
        XCTAssertFalse(favorite.isSelected)
        expectPage(app, "Two")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
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

    private func expectPage(_ app: XCUIApplication, _ name: String, sidebarHidden: Bool = false,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.webViews.staticTexts["Page \(name)"].firstMatch.waitForExistence(timeout: 10), file: file, line: line)
        if sidebarHidden {
            // Auto-hide deliberately removes navigation controls from the AX
            // tree. Verify the document without revealing the sidebar, and
            // require its controls to remain hidden rather than waiting for
            // Reload to appear on a surface that must stay out of view.
            for identifier in ["sidebar.newTab", "navigation.reload", "navigation.stop"] {
                XCTAssertFalse(app.buttons[identifier].exists,
                               "Sidebar control should stay hidden: \(identifier)", file: file, line: line)
            }
            return
        }
        // DOM content can appear before WebKit finishes loading. Sidebar
        // assertions should observe the completed state, not that brief gap.
        XCTAssertTrue(app.buttons["navigation.reload"].waitForExistence(timeout: 5), file: file, line: line)
    }

    private func expectSidebarStatus(_ element: XCUIElement, _ value: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let check = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 5), .completed,
                       "Expected \(value): \(element.exists ? element.debugDescription : "missing")", file: file, line: line)
    }

    private func expectStaticText(_ element: XCUIElement, _ text: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        // macOS versions expose static-text content through either AXValue or
        // AXLabel. Still require the exact message, not just an existing toast.
        let value = element.value as? String
        XCTAssertTrue(value == text || element.label == text,
                      "Expected static text: \(text). Element: \(element.debugDescription)", file: file, line: line)
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
        app.buttons["sidebar.newTab"].click()
        let query = app.textFields["commandBar.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(query.value as? String, "")
        app.typeText("early-test://fixture/two\n")
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
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 5))
    }

    func testCommandClickOpensRegularAndTargetBlankLinksInBackgroundTabs() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep source state")
        for (index, title) in ["Go to Two", "Open new tab"].enumerated() {
            XCUIElement.perform(withKeyModifiers: .command) {
                app.webViews.links[title].click()
            }
            expectRuntime(app, tabs: index + 2, views: index + 2, created: index + 2)
            expectPage(app, "One")
            XCTAssertTrue(app.buttons[source].isSelected)
            XCTAssertEqual(saved.value as? String, "keep source state")
            XCTAssertEqual(app.windows.count, 1)
        }
        let others = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", source))
        XCTAssertEqual(others.count, 2)
        for row in others.allElementsBoundByIndex {
            row.click()
            expectPage(app, "Two")
        }
        app.buttons[source].click()
        XCTAssertEqual(saved.value as? String, "keep source state")
        // An unmodified link still navigates the existing view, not a new tab.
        app.webViews.links["Go to Two"].click()
        expectPage(app, "Two")
        expectRuntime(app, tabs: 3, views: 3, created: 3)
    }

    func testLinkContextMenuOpensBackgroundTabWithoutChangingCurrentPage() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        app.webViews.links["Open new tab"].rightClick()
        XCTAssertTrue(app.menuItems["Open Link in New Tab"].waitForExistence(timeout: 3))
        // Scope to the link menu: the application menu also owns Services.
        let linkMenu = app.menus.containing(.menuItem, identifier: "Open Link in New Tab").firstMatch
        XCTAssertTrue(linkMenu.waitForExistence(timeout: 3))
        XCTAssertFalse(linkMenu.menuItems["Open Link"].exists)
        XCTAssertTrue(linkMenu.menuItems["Open Link in New Window"].exists)
        XCTAssertTrue(linkMenu.menuItems["Share"].exists)
        XCTAssertTrue(linkMenu.menuItems["Copy Link"].exists)
        for title in ["Download Linked File", "Services", "Share…"] {
            XCTAssertFalse(linkMenu.menuItems[title].exists,
                           "Unsupported action is visible in the link menu: \(title)")
        }
        linkMenu.menuItems["Open Link in New Tab"].click()
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        expectPage(app, "One")
        XCTAssertTrue(app.buttons[source].isSelected)
        let other = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", source)).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.click()
        expectPage(app, "Two")
    }

    func testHiddenSidebarShowsNewTabConfirmationForLinks() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let confirmation = app.staticTexts["browser.newTabCreated"]
        // A visible sidebar already provides feedback for the new tab.
        XCUIElement.perform(withKeyModifiers: .command) {
            app.webViews.links["Go to Two"].click()
        }
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        XCTAssertFalse(confirmation.exists)

        app.buttons["sidebar.toggle"].click()
        app.webViews.firstMatch.hover()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForNonExistence(timeout: 3))
        for (index, title) in ["Go to Two", "Open new tab"].enumerated() {
            XCUIElement.perform(withKeyModifiers: .command) {
                app.webViews.links[title].click()
            }
            XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
            expectStaticText(confirmation, "New Tab Created")
            expectRuntime(app, tabs: index + 3, views: index + 3, created: index + 3)
            expectPage(app, "One", sidebarHidden: true)
        }
        // Unmodified target=_blank links use the same confirmation while
        // retaining their normal foreground-tab behavior.
        app.webViews.links["Open new tab"].click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        expectStaticText(confirmation, "New Tab Created")
        expectPage(app, "Two", sidebarHidden: true)
        expectRuntime(app, tabs: 5, views: 5, created: 5)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 4))
        XCTAssertFalse(app.buttons["sidebar.newTab"].exists)
    }

    func testBrowserIdentityMatchesAcrossBackgroundAndPopupTabs() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/identity")
        func identity(file: StaticString = #filePath, line: UInt = #line) -> String {
            var result: String?
            let ready = NSPredicate { _, _ in
                // WebKit exposes some static-text values as numbers on older
                // macOS releases. A string predicate over every value throws
                // before it reaches the actual user-agent paragraph.
                result = app.webViews.staticTexts.allElementsBoundByIndex.lazy.compactMap { text in
                    [text.value as? String, text.label].compactMap { $0 }
                        .first { $0.hasPrefix("Mozilla/5.0") }
                }.first
                return result != nil
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 5),
                           .completed, file: file, line: line)
            return result ?? ""
        }
        let original = identity()
        XCTAssertTrue(original.contains(" Version/"))
        XCTAssertTrue(original.contains(" Safari/605.1.15 Early/"))
        XCTAssertFalse(original.contains(" Chrome/"))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        let source = rows.firstMatch.identifier

        // The owned link action creates a background view through normal setup.
        app.webViews.links["Open identity tab"].rightClick()
        visibleMenuAction("Open Link in New Tab")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        XCTAssertTrue(app.buttons[source].isSelected)
        XCTAssertEqual(identity(), original)
        let background = rows.matching(NSPredicate(format: "identifier != %@", source)).firstMatch
        background.click()
        XCTAssertEqual(identity(), original)

        // A target=_blank click supplies WebKit's own configuration. It must
        // receive the same identity without changing its store or duplicating loads.
        app.webViews.links["Open identity tab"].click()
        expectRuntime(app, tabs: 3, views: 3, created: 3)
        XCTAssertEqual(identity(), original)
    }

    func testLinkShareShowsNativePickerAndCanCancel() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        app.webViews.links["Go to Two"].rightClick()
        visibleMenuAction("Share")
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        expectPage(app, "One")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }

    func testNewWindowsHaveIsolatedTodayTabsAndRestoreTogether() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let main = app.windows["browser"]
        let pinID = main.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        main.buttons[pinID].rightClick()
        visibleMenuAction("Pin Tab")
        app.typeKey("t", modifierFlags: .command)
        app.typeText("early-test://fixture/two\n")
        expectPage(app, "Two")
        main.webViews.links["Go to Two"].rightClick()
        visibleMenuAction("Open Link in New Window")
        let newWindow = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser.'")).firstMatch
        XCTAssertTrue(newWindow.waitForExistence(timeout: 15))
        let childID = newWindow.identifier
        // A firstMatch query is live and changes when the next window comes to
        // the front. Bind the original window by ID before opening another.
        let child = app.windows[childID]
        XCTAssertTrue(child.webViews.staticTexts["Page Two"].waitForExistence(timeout: 10))
        XCTAssertTrue(child.buttons["navigation.reload"].waitForExistence(timeout: 5))
        let childRuntime = child.staticTexts["test.runtime"]
        expectation(for: NSPredicate(format: "value == %@ OR label == %@", "Tabs 1 · Views 1 · Created 1 · Saved", "Tabs 1 · Views 1 · Created 1 · Saved"), evaluatedWith: childRuntime)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(child.buttons[pinID].exists)
        XCTAssertEqual(child.buttons[pinID].value as? String, "Pinned, closed")
        let copied = child.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", pinID)).firstMatch
        XCTAssertTrue(copied.exists)
        let childText = child.webViews.textFields["Saved text"]
        let savedText = "keep original window state"
        childText.click()
        childText.typeText(savedText)
        // WebKit's out-of-process accessibility tree may still expose a typed
        // prefix after event synthesis returns. Require the complete value
        // before opening another window and checking live-state isolation.
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", savedText), object: childText)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 8), .completed,
                       "The complete typed value must reach the original page")
        XCTAssertEqual(childText.value as? String, savedText)
        copied.rightClick()
        visibleMenuAction("Open Tab in New Window")
        let third = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser.' AND identifier != %@", childID)).firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 15))
        XCTAssertTrue(third.webViews.staticTexts["Page Two"].waitForExistence(timeout: 10))
        XCTAssertEqual(childText.value as? String, savedText)
        XCTAssertEqual(third.webViews.textFields["Saved text"].value as? String, "")
        XCTAssertEqual(third.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", pinID)).count, 1)
        XCTAssertEqual(main.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", pinID)).count, 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        expectation(for: NSPredicate { _, _ in app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser'")).count == 3 }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        for window in app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser.'")).allElementsBoundByIndex {
            XCTAssertTrue(window.buttons[pinID].exists)
            XCTAssertEqual(window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", pinID)).count, 1)
        }
        // Closing a secondary window removes only its own session.
        app.typeKey("w", modifierFlags: [.command, .shift])
        expectation(for: NSPredicate { _, _ in app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser'")).count == 2 }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        expectation(for: NSPredicate { _, _ in app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser'")).count == 2 }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let primary = app.windows["browser"]
        if !primary.buttons["_XCUI:CloseWindow"].isHittable {
            app.typeKey("`", modifierFlags: .command)
        }
        primary.buttons["_XCUI:CloseWindow"].click()
        expectation(for: NSPredicate { _, _ in app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser'")).count == 1 }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.windows["browser"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.windows["browser"].webViews.staticTexts["Page Two"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser'")).count, 1)
        XCTAssertEqual(app.windows["browser"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", pinID)).count, 1)
    }

    func testSidebarResizeClampsPersistsAndKeepsSameWebView() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let sidebar = app.descendants(matching: .any)["browser.sidebar"]
        let handle = app.descendants(matching: .any)["sidebar.resize"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        XCTAssertEqual(sidebar.frame.width, 240, accuracy: 2)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 500, dy: 0)))
        XCTAssertEqual(sidebar.frame.width, 360, accuracy: 2)
        let wide = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        wide.click(forDuration: 0.1, thenDragTo: wide.withOffset(CGVector(dx: -250, dy: 0)))
        XCTAssertEqual(sidebar.frame.width, 220, accuracy: 2)
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
        XCTAssertEqual(sidebar.frame.width, 220, accuracy: 2)
    }

    func testWebsiteVideoContainerCanEnterAndExitFullscreen() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/fullscreen")
        let enter = app.buttons["Enter video fullscreen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        enter.click()
        XCTAssertTrue(app.staticTexts["Fullscreen active"].waitForExistence(timeout: 8))
        app.buttons["Exit video fullscreen"].click()
        XCTAssertTrue(app.staticTexts["Fullscreen closed"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["sidebar.newTab"].exists)
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandBar.query"].waitForExistence(timeout: 3))
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
        let loading = app.descendants(matching: .any).matching(identifier: "browser.loading").firstMatch
        navigate(app, to: "early-test://fixture/failure")
        let retry = app.buttons["browser.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(loading.exists)
        retry.click()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch
        let id = String(row.identifier.dropFirst(4))
        expectSidebarStatus(row, "Today, load failed")
        navigate(app, to: "early-test://fixture/slow")
        XCTAssertTrue(app.buttons["navigation.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        expectSidebarStatus(row, "Today, loading")
        pinAction("Pin Tab", on: row)
        expectSidebarStatus(app.buttons["tab.\(id)"], "Pinned, open, loading")
        pinAction("Add to Favorites", on: app.buttons["tab.\(id)"])
        let favorite = app.buttons["favorite.\(id)"]
        expectSidebarStatus(favorite, "Favorite, open, loading")
        XCTAssertTrue(loading.exists)
        // Loading belongs to the tab, not whichever page is currently selected.
        navigate(app, to: "early-test://fixture/one", newTab: true)
        expectPage(app, "One")
        XCTAssertFalse(loading.exists) // A background load does not draw over the visible page.
        expectSidebarStatus(favorite, "Favorite, open, loading")
        pinAction("Stop Loading", on: favorite)
        expectSidebarStatus(favorite, "Favorite, open")
        favorite.click()
        XCTAssertTrue(app.buttons["navigation.reload"].waitForExistence(timeout: 5))
        app.buttons["navigation.reload"].click()
        XCTAssertTrue(app.buttons["navigation.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        app.buttons["navigation.stop"].click()
        XCTAssertTrue(app.buttons["navigation.reload"].waitForExistence(timeout: 5))
        XCTAssertFalse(loading.exists)
        expectSidebarStatus(favorite, "Favorite, open")
        XCTAssertEqual(app.buttons["sidebar.addressBar"].value as? String, "early-test://fixture/slow")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("w", modifierFlags: .command)
        expectSidebarStatus(favorite, "Favorite, closed")
        expectRuntime(app, tabs: 1, views: 1, created: 2)
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
        for identifier in ["navigation.back", "navigation.forward", "navigation.reload"] {
            let frame = app.buttons[identifier].frame
            XCTAssertEqual(frame.width, 32, accuracy: 0.5)
            XCTAssertEqual(frame.height, 32, accuracy: 0.5)
        }
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
        // Keep the pointer at the reveal edge through several animation lengths.
        // A moving-sidebar exit event used to cancel and restart the reveal here.
        let unexpectedlyHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["sidebar.newTab"])
        unexpectedlyHidden.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedlyHidden], timeout: 1.5), .completed)
        // Cross the gutter into the panel, then leave it. Only the actual edge
        // can reveal it again; the old sidebar footprint must remain inactive.
        for x in [5.0, 120.0, 250.0] {
            origin.withOffset(CGVector(dx: x, dy: window.frame.height / 2)).hover()
            XCTAssertTrue(app.buttons["sidebar.newTab"].exists)
        }
        origin.withOffset(CGVector(dx: 280, dy: window.frame.height / 2)).hover()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForNonExistence(timeout: 3))
        origin.withOffset(CGVector(dx: 120, dy: window.frame.height / 2)).hover()
        XCTAssertFalse(app.buttons["sidebar.newTab"].exists)
        origin.withOffset(CGVector(dx: 1, dy: window.frame.height / 2)).hover()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 3))
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

    func testTrafficLightsAreMonochromeUntilHovered() throws {
        try verifyTrafficLightRollover(appearance: "dark")
    }

    func testTrafficLightsAreMonochromeUntilHoveredInLightAppearance() throws {
        try verifyTrafficLightRollover(appearance: "light")
    }

    private func verifyTrafficLightRollover(appearance: String) throws {
        // Validate the image assertion without a separate UI-test session.
        XCTAssertEqual(strokePixels(width: 32, height: 32) { _, _ in 0.8 }, 0)
        XCTAssertEqual(strokePixels(width: 32, height: 32) { x, y in 0.5 + CGFloat(x + y) / 128 }, 0)
        XCTAssertGreaterThan(strokePixels(width: 32, height: 32) { _, y in
            (15...16).contains(y) ? 0.65 : 0.9
        }, 3)
        // At 1x a glyph stroke can span several whole pixels. Sampling only
        // the immediately adjacent pixel misses that stroke entirely.
        XCTAssertGreaterThanOrEqual(strokePixels(width: 16, height: 16) { x, y in
            abs(x - y) <= 1 || abs(x + y - 15) <= 1 ? 0.3 : 0.9
        }, 3)
        XCTAssertEqual(strokePixels(width: 16, height: 16) { _, _ in 0.8 }, 0)
        XCTAssertEqual(strokePixels(width: 16, height: 16) { x, y in 0.5 + CGFloat(x + y) / 64 }, 0)
        // A neutral translucent circle inherits the chrome hue. It must not
        // fail merely because the theme or the wallpaper is colorful. Still
        // detect all three native hover colors over each representative tint.
        let backdrops: [SIMD3<Double>] = [
            SIMD3(0.1, 0.1, 0.1), SIMD3(0.04, 0.08, 0.14), SIMD3(0.9, 0.9, 0.9),
            SIMD3(0.76, 0.82, 0.90), SIMD3(0.92, 0.84, 0.74), SIMD3(0.90, 0.76, 0.84)
        ]
        for backdrop in backdrops {
            for alpha in [0.0, 0.12, 0.25, 1.0] {
                for neutral in [SIMD3<Double>(repeating: 0), SIMD3<Double>(repeating: 1)] {
                    let pixel = backdrop * (1 - alpha) + neutral * alpha
                    XCTAssertLessThan(neutralOverlayColorExcess(pixel, over: backdrop), 0.000_001)
                }
            }
            for colored in [SIMD3(0.98, 0.36, 0.30), SIMD3(0.99, 0.76, 0.18), SIMD3(0.24, 0.80, 0.16)] {
                XCTAssertGreaterThan(neutralOverlayColorExcess(colored, over: backdrop), 0.25)
            }
        }
        let app = launchFreshApp(appearance: appearance)
        app.typeKey(.escape, modifierFlags: [])
        let close = app.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let lights = [close, app.buttons["_XCUI:MinimizeWindow"], app.buttons["_XCUI:FullScreenWindow"]]
        let window = app.windows["browser"]
        let away = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))

        func colorBeyondBackdrop(_ button: XCUIElement) throws -> CGFloat {
            let shot = button.screenshot()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
            func rgb(_ x: Int, _ y: Int) throws -> SIMD3<Double> {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                return SIMD3(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
            }
            let lastX = bitmap.pixelsWide - 1, lastY = bitmap.pixelsHigh - 1
            // The crop corners lie outside the circular widget. Interpolate
            // them so a smooth theme/backdrop gradient is not measured as a
            // colored button. Sampling the whole crop's raw RGB spread used to
            // count the blue light-theme background as an idle colored widget.
            let topLeft = try rgb(0, 0), topRight = try rgb(lastX, 0)
            let bottomLeft = try rgb(0, lastY), bottomRight = try rgb(lastX, lastY)
            var largest = 0.0
            for y in 0..<bitmap.pixelsHigh {
                let ty = Double(y) / Double(max(1, lastY))
                for x in 0..<bitmap.pixelsWide {
                    let tx = Double(x) / Double(max(1, lastX))
                    let top = topLeft * (1 - tx) + topRight * tx
                    let bottom = bottomLeft * (1 - tx) + bottomRight * tx
                    let backdrop = top * (1 - ty) + bottom * ty
                    largest = max(largest, neutralOverlayColorExcess(try rgb(x, y), over: backdrop))
                }
            }
            return CGFloat(largest)
        }

        away.hover()
        for light in lights { XCTAssertLessThan(try colorBeyondBackdrop(light), 0.12) }
        let idle = XCTAttachment(screenshot: window.screenshot())
        idle.name = "\(appearance) muted native traffic lights"
        idle.lifetime = .keepAlways
        add(idle)
        close.hover()
        for light in lights {
            XCTAssertGreaterThan(try colorBeyondBackdrop(light), 0.25)
            try assertHoverSymbol(light)
        }
        let hovered = XCTAttachment(screenshot: window.screenshot())
        hovered.name = "\(appearance) hovered native traffic lights"
        hovered.lifetime = .keepAlways
        add(hovered)
        away.hover()
        for light in lights { XCTAssertLessThan(try colorBeyondBackdrop(light), 0.12) }
        XCTAssertTrue(close.isEnabled)
        XCTAssertTrue(close.isHittable)

        // Each native widget invalidates its own drawing during rollover. The
        // idle mask must survive those redraws, not just the first hover cycle.
        for light in lights {
            light.hover()
            XCTAssertGreaterThan(try colorBeyondBackdrop(light), 0.25)
            away.hover()
            for idleLight in lights {
                XCTAssertLessThan(try colorBeyondBackdrop(idleLight), 0.12)
                XCTAssertTrue(idleLight.isHittable)
            }
        }

        // Relaunch while the cursor is parked over content. Assert the first
        // appearance without any hover event to initialize the control state.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.newTab"].waitForExistence(timeout: 10))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        for light in lights { XCTAssertLessThan(try colorBeyondBackdrop(light), 0.12) }
        app.typeKey(.escape, modifierFlags: [])
        close.click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
    }

    /// A black/white translucent overlay can only scale the backdrop's chroma
    /// toward zero. Measure color outside that segment: this rejects colored
    /// widgets even when they share a theme hue, without requiring gray chrome.
    private func neutralOverlayColorExcess(_ pixel: SIMD3<Double>, over backdrop: SIMD3<Double>) -> Double {
        let color = pixel - SIMD3(repeating: (pixel.x + pixel.y + pixel.z) / 3)
        let base = backdrop - SIMD3(repeating: (backdrop.x + backdrop.y + backdrop.z) / 3)
        let length = base.x * base.x + base.y * base.y + base.z * base.z
        let projection = color.x * base.x + color.y * base.y + color.z * base.z
        let scale = length > 0.000_000_001 ? min(1, max(0, projection / length)) : 0
        let excess = color - base * scale
        return max(excess.x, max(excess.y, excess.z)) - min(excess.x, min(excess.y, excess.z))
    }

    // Native glass glyphs are tinted, not black. Detect a local dark stroke
    // against its two neighbours, rejecting a solid circle or smooth gradient.
    private func strokePixels(width: Int, height: Int, brightness: (Int, Int) -> CGFloat) -> Int {
        let steps = Set([max(1, width / 10), max(1, width / 5)])
        var count = 0
        for y in (height / 3)..<(height * 2 / 3) {
            for x in (width / 3)..<(width * 2 / 3) {
                let center = brightness(x, y)
                if steps.contains(where: { step in
                    let horizontal = min(brightness(x - step, y), brightness(x + step, y)) - center
                    let vertical = min(brightness(x, y - step), brightness(x, y + step)) - center
                    return max(horizontal, vertical) > 0.08
                }) { count += 1 }
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
        // Bound by the test-only menu to NSWindow.toggleFullScreen, rather
        // than assuming the host OS assigns this shortcut to its native item.
        XCTAssertTrue(app.menuBars.menuBarItems["Test Window"].exists)
        app.typeKey("f", modifierFlags: [.control, .command])
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

        // A loaded page must keep receiving wheel events outside the card.
        app.typeKey(.escape, modifierFlags: [])
        navigate(app, to: "early-test://fixture/scroll")
        XCTAssertTrue(app.webViews.staticTexts["Scroll fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["navigation.reload"].waitForExistence(timeout: 5))
        let page = app.webViews.firstMatch
        // WebKit may expose paragraph text through AXValue rather than AXLabel
        // (or as a container). Use named, read-only controls with stable roles,
        // and wait for them before sending a wheel event to the real webpage.
        let position = page.textFields["Scroll position"]
        let clicks = page.textFields["Page clicks"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertTrue(clicks.waitForExistence(timeout: 5))
        XCTAssertEqual(position.value as? String, "0")
        XCTAssertEqual(clicks.value as? String, "0")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        let draft = "keep query while scrolling"
        query.typeText(draft)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", draft), object: query)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
        let card = app.descendants(matching: .any).matching(identifier: "commandBar.card").firstMatch
        // WebKit's AX WebView frame can cover the entire 3000-point document,
        // not just the viewport. Anchor the real wheel event to the visible
        // native content host, clipped to this window, so it stays on-screen.
        let window = app.windows["browser"]
        let viewport = content.frame.intersection(window.frame)
        XCTAssertFalse(viewport.isEmpty)
        let point = CGPoint(x: viewport.minX + viewport.width * 0.90, y: viewport.minY + viewport.height * 0.85)
        XCTAssertTrue(window.frame.contains(point), "The wheel must target the visible browser window")
        let scrollPoint = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
        XCTAssertFalse(card.frame.contains(point), "The wheel must target the website, not the editor")
        scrollPoint.scroll(byDeltaX: 0, deltaY: -400)
        let moved = NSPredicate { _, _ in
            guard position.exists, let text = position.value as? String else { return false }
            return Int(text).map { $0 > 0 } ?? false
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(query.exists)
        XCTAssertEqual(query.value as? String, draft)

        // One physical click must both dismiss the card and activate its target.
        let pageButton = page.buttons["Count page click"]
        XCTAssertTrue(pageButton.isHittable)
        XCTAssertFalse(card.frame.contains(CGPoint(x: pageButton.frame.midX, y: pageButton.frame.midY)))
        pageButton.click()
        XCTAssertTrue(query.waitForNonExistence(timeout: 3))
        let clickedOnce = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: clicks)
        XCTAssertEqual(XCTWaiter.wait(for: [clickedOnce], timeout: 5), .completed)
        expectRuntime(app, tabs: 1, views: 1, created: 1)
    }
}
