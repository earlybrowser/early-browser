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

    private func visibleMenuAction(_ title: String) {
        let items = XCUIApplication().menuItems.matching(identifier: title)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 3))
        let item = items.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(item, "No visible menu action: \(title)")
        item?.click()
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
        visibleMenuAction("Rename Space…")
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
        expectRuntime(app, tabs: 0, views: 2, created: 2)
        app.menuBarItems["Space"].click()
        visibleMenuAction("Delete Space…")
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertTrue(spaceDot(app, named: "Research").exists)
        app.menuBarItems["Space"].click()
        visibleMenuAction("Delete Space…")
        XCTAssertTrue(app.buttons["Delete Space"].waitForExistence(timeout: 5))
        app.buttons["Delete Space"].click()
        XCTAssertFalse(spaceDot(app, named: "Research").exists)
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        expectRuntime(app, tabs: 2, views: 2, created: 2)
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
        visibleMenuAction("Rename Space…")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["space.color.green"].isSelected)
        app.buttons["Cancel"].click()
    }

    func testSpaceFooterOverflowStaysCenteredAndExposesAllSpaces() {
        let app = launchFreshApp()
        app.typeKey(.escape, modifierFlags: [])
        for number in 1...6 { createSpace(app, named: "Space \(number)") }
        let overflow = app.descendants(matching: .any).matching(identifier: "space.overflow").firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
        let footer = app.descendants(matching: .any).matching(identifier: "sidebar.footer").firstMatch
        let dots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@ AND identifier != %@", "space.", "space.new", "space.overflow")).allElementsBoundByIndex
        XCTAssertLessThanOrEqual(dots.count, 4)
        let cluster = dots.map(\.frame).reduce(overflow.frame) { $0.union($1) }
        XCTAssertEqual(cluster.midX, footer.frame.midX, accuracy: 2)
        overflow.click()
        visibleMenuAction("Personal")
        XCTAssertTrue(spaceDot(app, named: "Personal").waitForExistence(timeout: 5))
        XCTAssertTrue(spaceDot(app, named: "Personal").isSelected)
        expectRuntime(app, tabs: 0, views: 0, created: 0)
        app.typeKey("9", modifierFlags: [.command, .option])
        XCTAssertTrue(spaceDot(app, named: "Space 6").isSelected)
    }

    private func pinAction(_ title: String, on row: XCUIElement) {
        row.rightClick()
        visibleMenuAction(title)
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

    /// Empty saved-section targets appear after the drag starts. Aim within
    /// their revealed bounds using the persistent address control as the anchor.
    private func savedSectionTarget(_ app: XCUIApplication, favorites: Bool) -> XCUICoordinate {
        app.buttons["sidebar.addressBar"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: favorites ? 24 : 100))
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
        func drag(_ element: XCUIElement, to target: XCUICoordinate) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.8)
        }
        drag(app.buttons[firstID], to: savedSectionTarget(app, favorites: false))
        expectSidebarStatus(app.buttons[firstID], "Pinned, open")
        drag(app.buttons[firstID], to: savedSectionTarget(app, favorites: true))
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
        drag(third, to: child.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
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
                return horizontally ? item.frame.minX < next.frame.minX : item.frame.minY < next.frame.minY
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
        let pinned = savedSectionTarget(app, favorites: false)
        let favorites = savedSectionTarget(app, favorites: true)
        let regular = app.scrollViews["sidebar.tabs"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        func drag(_ element: XCUIElement, to destination: XCUICoordinate) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.2, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(sidebar.exists)
        drag(app.buttons["tab.\(id)"], to: pinned)
        XCTAssertEqual(app.buttons["tab.\(id)"].value as? String, "Pinned, open")
        drag(app.buttons["tab.\(id)"], to: favorites)
        XCTAssertTrue(app.buttons["favorite.\(id)"].waitForExistence(timeout: 3))
        drag(app.buttons["favorite.\(id)"], to: pinned)
        XCTAssertTrue(app.buttons["tab.\(id)"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["tab.\(id)"].value as? String, "Pinned, open")
        drag(app.buttons["tab.\(id)"], to: regular)
        XCTAssertEqual(app.buttons["tab.\(id)"].value as? String, "Today")
        drag(app.buttons["tab.\(id)"], to: favorites)
        XCTAssertTrue(app.buttons["favorite.\(id)"].waitForExistence(timeout: 3))
        drag(app.buttons["favorite.\(id)"], to: regular)
        XCTAssertTrue(app.buttons["tab.\(id)"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["tab.\(id)"].value as? String, "Today")
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
        let saved = app.webViews.textFields["Saved text"]
        saved.click()
        saved.typeText("keep during move")
        let source = app.buttons[secondID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = app.buttons[firstID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            .withOffset(CGVector(dx: 0, dy: savedSectionRevealOffset(app)))
        source.click(forDuration: 0.3, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(app.textFields["rename.name"].exists, "Dragging must not open the rename editor")
        XCTAssertFalse(app.textFields["folder.name"].exists)
        XCTAssertLessThan(app.buttons[secondID].frame.minY, app.buttons[firstID].frame.minY)
        XCTAssertEqual(app.buttons[firstID].value as? String, "Today")
        XCTAssertEqual(app.buttons[secondID].value as? String, "Today")
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
        saved.click()
        saved.typeText("keep favorite state")
        pinAction("Add to Favorites", on: app.buttons[firstID])
        XCTAssertTrue(firstFavorite.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons[firstID].exists)
        XCTAssertFalse(app.buttons["favorites.add"].exists)
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
        let select = app.buttons["pinSelect.\(id.dropFirst(4))"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        XCTAssertFalse(select.isEnabled)
        select.hover()
        XCTAssertFalse(reset.exists)
        navigate(app, to: "early-test://fixture/two")
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
        navigate(app, to: "early-test://fixture/two")
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
        // DOM content can appear before WebKit finishes loading. Sidebar
        // assertions should observe the completed state, not that brief gap.
        XCTAssertTrue(app.buttons["navigation.reload"].waitForExistence(timeout: 5), file: file, line: line)
    }

    private func expectSidebarStatus(_ element: XCUIElement, _ value: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let check = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 5), .completed, file: file, line: line)
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
            XCTAssertEqual(confirmation.label, "New Tab Created")
            expectRuntime(app, tabs: index + 3, views: index + 3, created: index + 3)
            expectPage(app, "One")
        }
        // Unmodified target=_blank links use the same confirmation while
        // retaining their normal foreground-tab behavior.
        app.webViews.links["Open new tab"].click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        expectPage(app, "Two")
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
        let childRuntime = child.staticTexts["test.runtime"]
        expectation(for: NSPredicate(format: "value == %@ OR label == %@", "Tabs 1 · Views 1 · Created 1 · Saved", "Tabs 1 · Views 1 · Created 1 · Saved"), evaluatedWith: childRuntime)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(child.buttons[pinID].exists)
        XCTAssertEqual(child.buttons[pinID].value as? String, "Pinned, closed")
        let copied = child.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.' AND identifier != %@", pinID)).firstMatch
        XCTAssertTrue(copied.exists)
        child.webViews.textFields["Saved text"].click()
        child.webViews.textFields["Saved text"].typeText("keep original window state")
        XCTAssertEqual(child.webViews.textFields["Saved text"].value as? String, "keep original window state")
        copied.rightClick()
        visibleMenuAction("Open Tab in New Window")
        let third = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser.' AND identifier != %@", childID)).firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 15))
        XCTAssertTrue(third.webViews.staticTexts["Page Two"].waitForExistence(timeout: 10))
        XCTAssertEqual(child.webViews.textFields["Saved text"].value as? String, "keep original window state")
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
        navigate(app, to: "early-test://fixture/slow")
        XCTAssertTrue(app.buttons["navigation.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        app.buttons["navigation.stop"].click()
        XCTAssertTrue(app.buttons["navigation.reload"].waitForExistence(timeout: 5))
        XCTAssertFalse(loading.exists)
        expectSidebarStatus(favorite, "Favorite, open")
        navigate(app, to: "early-test://fixture/one")
        expectPage(app, "One")
        expectSidebarStatus(favorite, "Favorite, open")
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
        let app = launchFreshApp(appearance: appearance)
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
        idle.name = "\(appearance) muted native traffic lights"
        idle.lifetime = .keepAlways
        add(idle)
        close.hover()
        for light in lights {
            XCTAssertGreaterThan(try colorSpread(light), 0.25)
            try assertHoverSymbol(light)
        }
        let hovered = XCTAttachment(screenshot: window.screenshot())
        hovered.name = "\(appearance) hovered native traffic lights"
        hovered.lifetime = .keepAlways
        add(hovered)
        away.hover()
        for light in lights { XCTAssertLessThan(try colorSpread(light), 0.12) }
        XCTAssertTrue(close.isEnabled)
        XCTAssertTrue(close.isHittable)

        // Each native widget invalidates its own drawing during rollover. The
        // idle mask must survive those redraws, not just the first hover cycle.
        for light in lights {
            light.hover()
            XCTAssertGreaterThan(try colorSpread(light), 0.25)
            away.hover()
            for idleLight in lights {
                XCTAssertLessThan(try colorSpread(idleLight), 0.12)
                XCTAssertTrue(idleLight.isHittable)
            }
        }

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
    }
}
