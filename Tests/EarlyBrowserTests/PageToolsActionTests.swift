// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
@testable import EarlyWeb
import Testing

/// Window-level find, zoom, Reader, translation and Paste and Go commands with
/// local fixture pages, unshown windows and no UI automation.
@Suite(.serialized) @MainActor
struct PageToolsActionTests {
    @MainActor private final class Fixture {
        let suite = "local.early.tests.pagetools.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel

        init(session: BrowserSession = BrowserSession()) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlyPageTools-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
                input: input, isTesting: true, restorationError: nil, defaults: defaults)
        }

        func cleanup() {
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
        }

        func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func waitForLoad(_ id: UUID?) async throws {
            try await waitUntil("load") {
                guard let id, let page = model.webViews.pages[id] else { return false }
                return page.view.url != nil && !page.isLoading && !page.view.isLoading
            }
        }
    }

    private enum Failure: Error { case timeout(String) }

    private func splitSession() -> BrowserSession {
        let profile = UUID(), space = UUID()
        let tabs = ["left", "right"].map { side in
            BrowserTab(spaceID: space, profileID: profile, title: side,
                       currentURL: URL(string: "early-test://fixture/one?pane=\(side)")!)
        }
        let group = BrowserSplitGroup(spaceID: space, panes: tabs.map { BrowserSplitPane(tabID: $0.id) })
        return BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs,
            selectionBySpace: [space: tabs[0].id], splitGroups: [group],
            focusedPaneByGroupID: [group.id: group.panes[0].id])
    }

    @Test func zoomCommandsTargetTheFocusedPaneAndConfirmTheLevel() async throws {
        let fixture = Fixture(session: splitSession())
        defer { fixture.cleanup() }
        let model = fixture.model
        let group = try #require(model.coordinator.activeSplitGroup)
        let left = group.panes[0].tabID, right = group.panes[1].tabID
        try await fixture.waitForLoad(left)
        try await fixture.waitForLoad(right)
        #expect(!model.canPerform(.resetZoom) && model.canPerform(.zoomIn))
        #expect(model.perform(.focusSplitPane(group.panes[1].id)))
        #expect(model.perform(.zoomIn) && model.perform(.zoomIn))
        #expect(model.webViews.pages[right]?.zoom == 1.25 && model.webViews.pages[left]?.zoom == 1)
        #expect(model.zoomNotice?.tabID == right && model.zoomNotice?.zoom == 1.25)
        #expect(ZoomNoticeView.text(for: 1.25) == "125%" && ZoomNoticeView.text(for: 0.85) == "85%")
        let titles = model.commandSearchCandidates().map(\.title)
        #expect(titles.contains("Zoom In") && titles.contains("Zoom Out") && titles.contains("Actual Size"))
        #expect(model.perform(.resetZoom) && model.webViews.pages[right]?.zoom == 1)
        #expect(!model.commandSearchCandidates().map(\.title).contains("Actual Size"), "Only working commands are offered")

        #expect(PageShortcutMonitor.isZoomIn(characters: "=", modifiers: .command))
        #expect(!PageShortcutMonitor.isZoomIn(characters: "=", modifiers: [.command, .option]))
        #expect(!PageShortcutMonitor.isZoomIn(characters: "=", modifiers: []), "Typing = in a page is never taken")
        #expect(!PageShortcutMonitor.isZoomIn(characters: "-", modifiers: .command))
    }
}
