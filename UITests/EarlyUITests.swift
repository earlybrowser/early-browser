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
        app.typeText("example.com")
        XCTAssertEqual(query.value as? String, "example.com")
        app.typeKey(.escape, modifierFlags: [])
        expectRuntime(app, tabs: 0, views: 0, created: 0)
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
        app.typeKey(.escape, modifierFlags: [])
        let address = app.buttons["sidebar.addressBar"]
        XCTAssertEqual(address.value as? String, "No active tab")
        address.click()
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(query.value as? String, "")
    }

    private func visibleMenuAction(_ title: String) {
        let items = XCUIApplication().menuItems.matching(identifier: title)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 3))
        let item = items.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(item, "No visible menu action: \(title)")
        item?.click()
    }

    private func pinAction(_ title: String, on row: XCUIElement) {
        row.rightClick()
        visibleMenuAction(title)
    }

    func testNestedFoldersKeepLiveTabAndRestoreHierarchy() {
        let app = launchFreshApp()
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let tabID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        app.buttons["folder.add"].click()
        let name = app.textFields["folder.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeText("Work")
        app.buttons["Save"].click()
        let root = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label == 'Work'")).firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 3))
        let rootID = root.identifier
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
                let positions = ids.map { app.buttons[$0].frame.minY }
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
            .click(forDuration: 0.2, thenDragTo: at(gap), withVelocity: .slow, thenHoldForDuration: 0.6)
        expectOrder([first, third, second])
        let empty = CGPoint(x: app.buttons[first].frame.midX, y: app.buttons[second].frame.maxY + 70)
        app.buttons[first].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: at(empty), withVelocity: .slow, thenHoldForDuration: 0.6)
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
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep during move")
        let source = app.buttons[secondID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = app.buttons[firstID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        source.click(forDuration: 0.3, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertLessThan(app.buttons[secondID].frame.minY, app.buttons[firstID].frame.minY)
        XCTAssertEqual(saved.value as? String, "keep during move")
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "Two")
        pinAction("Move Down", on: app.buttons[secondID])
        XCTAssertLessThan(app.buttons[firstID].frame.minY, app.buttons[secondID].frame.minY)
        app.typeKey("1", modifierFlags: .command)
        expectPage(app, "One")
        // Normal clicks must still select; a drop outside the rows must not reorder.
        app.buttons[secondID].click()
        expectPage(app, "Two")
        XCTAssertEqual(saved.value as? String, "keep during move")
        let outside = app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
        source.click(forDuration: 0.2, thenDragTo: outside)
        XCTAssertLessThan(app.buttons[firstID].frame.minY, app.buttons[secondID].frame.minY)
        // A second real drag, then relaunch, checks that the saved order is used.
        source.click(forDuration: 0.2, thenDragTo: destination)
        XCTAssertLessThan(app.buttons[secondID].frame.minY, app.buttons[firstID].frame.minY)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(app.buttons[secondID].waitForExistence(timeout: 8))
        XCTAssertLessThan(app.buttons[secondID].frame.minY, app.buttons[firstID].frame.minY)
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
        navigate(app, to: "early-test://fixture/two")
        expectPage(app, "Two")
        XCTAssertEqual(app.buttons[id].label, "My Videos")
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons[id].label, "My Videos")
        pinAction("Rename Tab…", on: app.buttons[id])
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        app.buttons["Use Page Title"].click()
        XCTAssertEqual(app.buttons[id].label, "Page One")
        expectRuntime(app, tabs: 0, views: 0, created: 0)
    }

    func testFavoritesReuseLiveTabsAndRestoreClosedTiles() {
        let app = launchFreshApp()
        XCTAssertFalse(app.buttons["favorites.add"].isEnabled)
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        let firstID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).firstMatch.identifier
        let firstFavorite = app.buttons["favorite.\(firstID.dropFirst(4))"]
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep favorite state")
        app.buttons["favorites.add"].click()
        XCTAssertTrue(firstFavorite.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons[firstID].exists)
        XCTAssertFalse(app.buttons["favorites.add"].isEnabled)
        firstFavorite.click()
        XCTAssertEqual(saved.value as? String, "keep favorite state")
        expectRuntime(app, tabs: 1, views: 1, created: 1)
        navigate(app, to: "early-test://fixture/two")
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
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
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
        navigate(app, to: "early-test://fixture/two")
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
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        navigate(app, to: "early-test://fixture/two")
        expectPage(app, "Two")
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep video state")
        app.buttons[id].click()
        expectPage(app, "Two")
        XCTAssertEqual(saved.value as? String, "keep video state")
        navigate(app, to: "early-test://fixture/one", newTab: true)
        expectPage(app, "One")
        XCTAssertFalse(reset.exists)
        let select = app.buttons["pinSelect.\(id.dropFirst(4))"]
        XCTAssertTrue(select.exists)
        select.hover()
        XCTAssertFalse(reset.exists)
        select.click()
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
        expectRuntime(app, tabs: 2, views: 2, created: 2)
        XCTAssertEqual(app.buttons[id].label, "Page One")
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 1, views: 1, created: 2)
        XCTAssertFalse(reset.exists)
        select.click()
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
        navigate(app, to: "early-test://fixture/two")
        expectPage(app, "Two")
        app.typeKey("w", modifierFlags: .command)
        expectRuntime(app, tabs: 0, views: 0, created: 1)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertEqual(row.value as? String, "Pinned, closed")
        XCTAssertFalse(app.textFields["commandBar.query"].exists)
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
        app.buttons["tabClose.\(secondID.dropFirst(4))"].click()
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
        let last = app.buttons["Test Pin 32"]
        let newTab = app.buttons["sidebar.newTab"]
        for _ in 0..<10 {
            if last.exists && last.isHittable && newTab.exists && newTab.isHittable { break }
            scroll.scroll(byDeltaX: 0, deltaY: -350)
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertTrue(newTab.isHittable)
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

    func testTrafficLightsAreMonochromeUntilHovered() throws {
        // Validate the image assertion without a separate UI-test session.
        XCTAssertEqual(strokePixels(width: 32, height: 32) { _, _ in 0.8 }, 0)
        XCTAssertEqual(strokePixels(width: 32, height: 32) { x, y in 0.5 + CGFloat(x + y) / 128 }, 0)
        XCTAssertGreaterThan(strokePixels(width: 32, height: 32) { _, y in
            (15...16).contains(y) ? 0.65 : 0.9
        }, 3)
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
