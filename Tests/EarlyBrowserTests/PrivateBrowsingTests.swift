// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import EarlyWeb
import SwiftUI
import Testing
import WebKit

/// Private windows through the real application controller: no windows are
/// presented, storage is a temporary folder, and WebKit stores are ephemeral.
@Suite(.serialized) @MainActor
struct PrivateBrowsingTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPrivate-\(UUID())", isDirectory: true)
        let suite = "local.early.tests.private.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let application = EarlyAppDelegate()
        var opened: [UUID] = []

        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            application.presentWindow = { [weak self] in self?.opened.append($0) }
        }

        func start() async {
            _ = await application.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                defaults: defaults, storageDirectory: directory, isTesting: true)
        }

        func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw Failure.timeout(label) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func cleanup() async {
            for id in opened { application.closeWindow(id) }
            application.closeWindow(nil)
            _ = await application.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private enum Failure: Error { case timeout(String) }

    @Test func privateSessionsHaveOneSpaceNamedPrivateAndSuggestionsStartOff() throws {
        let session = BrowserSession.privateWindow()
        #expect(session.spaces.map(\.name) == ["Private"] && session.spaces.first?.icon == .symbol(.masks))
        #expect(session.activeSpaceID == session.spaces.first?.id && session.tabs.isEmpty)
        try session.validate()
        let defaults = UserDefaults(suiteName: "local.early.tests.private.prefs.\(UUID())")!
        #expect(!BrowserPreferences(defaults: defaults).privateOnlineSuggestions)
    }

    @Test func privateWindowsShareAMemoryOnlyStoreSaveNothingAndReleaseItWhenTheLastCloses() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let normal = try #require(app.model)
        let activeProfile = app.workspace?.activeProfileID

        let first = try #require(app.openPrivateWindow())
        let model = try #require(app.windowModel(first))
        let profile = try #require(app.privateProfileID)
        #expect(model.isPrivate && model.coordinator.profileID == profile && !normal.isPrivate)
        #expect(model.coordinator.spaces.map(\.name) == ["Private"] && model.coordinator.activeSpace?.color == .gray)
        #expect(model.history == nil && !model.canPerform(.showHistory), "Private windows record no history")
        #expect(!model.webViews.websiteDataStore.isPersistent)
        #expect(!model.downloads.recordsSourceAddresses && normal.downloads.recordsSourceAddresses)
        #expect(model.downloads !== normal.downloads, "Private downloads are listed apart")
        #expect(!app.profiles.contains { $0.id == profile }, "The private profile is never a saved profile")

        let second = try #require(app.openPrivateWindow())
        let sibling = try #require(app.windowModel(second))
        #expect(sibling.coordinator.profileID == profile && sibling.webViews.websiteDataStore === model.webViews.websiteDataStore,
                "Private windows share one session until the last one closes")

        // Browse privately; nothing reaches the session file or the profile's history.
        #expect(model.openLocations([URL(string: "early-test://fixture/two?private=1")!]))
        let tab = try #require(model.coordinator.focusedTabID)
        try await fixture.waitUntil("private page") { model.webViews.pages[tab]?.isLoading == false && model.webViews.pages[tab]?.view.url != nil }
        app.focusedWindow(first)
        #expect(app.workspace?.activeProfileID == activeProfile, "Focusing a private window never changes the active profile")
        app.saveAll()
        #expect(await app.persistence?.flush() == true)
        let saved = try #require(try await SessionRepository(fileURL: fixture.directory.appending(path: "session.sqlite"),
            input: NavigationInput(allowedSchemes: ["http", "https", "file", "early-test"])).loadWorkspace())
        #expect(!saved.sessions.contains { $0.profileID == profile })
        let savedURLs = saved.sessions.flatMap { [$0] + $0.additionalWindows }.flatMap(\.tabs).map(\.currentURL.absoluteString)
        #expect(!savedURLs.contains { $0.contains("private=1") })
        await normal.flushHistory()
        if let history = normal.history { #expect(try await history.visits(matching: "private").isEmpty) }

        // New Window from a private window is an ordinary window.
        let ordinary = try #require(app.openNewWindow(from: model))
        #expect(app.windowModel(ordinary)?.isPrivate == false)
        app.closeWindow(ordinary)

        // Closing the last private window releases the session; the next is fresh.
        app.closeWindow(first)
        #expect(app.privateProfileID == profile, "Still in use by the other private window")
        app.closeWindow(second)
        #expect(app.privateProfileID == nil)
        let third = try #require(app.openPrivateWindow())
        let fresh = try #require(app.windowModel(third))
        #expect(fresh.coordinator.profileID != profile && fresh.webViews.websiteDataStore !== model.webViews.websiteDataStore)
        fixture.opened.removeAll { [first, second, ordinary].contains($0) }
        await fixture.cleanup()
    }

    @Test func reopenClosedWindowRestoresTodayTabsButNeverPrivateOrEmptyWindows() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        #expect(!app.canReopenClosedWindow)
        let id = try #require(app.openNewWindow())
        let window = try #require(app.windowModel(id))
        #expect(window.openLocations([URL(string: "early-test://fixture/one")!, URL(string: "early-test://fixture/two")!]))
        let urls = window.todayTabs.map(\.currentURL)
        app.closeWindow(id)
        #expect(app.canReopenClosedWindow && app.closedWindows.count == 1)

        // Windows with nothing of their own, and private windows, are not kept.
        let empty = try #require(app.openNewWindow())
        app.closeWindow(empty)
        let privateID = try #require(app.openPrivateWindow())
        #expect(app.windowModel(privateID)?.openLocations([URL(string: "early-test://fixture/one?private=1")!]) == true)
        app.closeWindow(privateID)
        #expect(app.closedWindows.count == 1)

        #expect(app.model?.canPerform(.reopenClosedWindow) == true)
        #expect(app.model?.commandSearchCandidates().map(\.title).contains("Reopen Closed Window") == true)
        let reopenedID = try #require(app.reopenClosedWindow())
        let reopened = try #require(app.windowModel(reopenedID))
        #expect(reopened.todayTabs.map(\.currentURL) == urls && !reopened.isPrivate)
        #expect(!app.canReopenClosedWindow && app.reopenClosedWindow() == nil)

        for _ in 0..<(EarlyAppDelegate.closedWindowLimit + 2) {
            let extra = try #require(app.openNewWindow())
            _ = app.windowModel(extra)?.openLocations([URL(string: "early-test://fixture/one")!])
            app.closeWindow(extra)
        }
        #expect(app.closedWindows.count == EarlyAppDelegate.closedWindowLimit, "The list is bounded")
        fixture.opened.removeAll { $0 != reopenedID }
        await fixture.cleanup()
    }

    @Test func everyBorderOfOrdinaryAndEmptyPrivateWindowsMovesAndZoomsTheWindow() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let normal = try #require(app.model)
        let privateID = try #require(app.openPrivateWindow())
        let empty = try #require(app.windowModel(privateID))
        #expect(empty.coordinator.tabStore.tabs.isEmpty, "Its explanation is showing")
        for model in [normal, empty] {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AnyView(BrowserWindowView(model: model).transaction { $0.disablesAnimations = true }))
            window.contentView = hosting
            hosting.frame.size = CGSize(width: 1000, height: 700)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let frame = try #require(hosting.superview)
            let bounds = frame.bounds
            // Inside the 6 pt chrome border on each side, past the few points at
            // the outer edge that macOS keeps for resizing the window.
            for point in [CGPoint(x: bounds.midX, y: bounds.maxY - 5), CGPoint(x: bounds.midX, y: 5),
                          CGPoint(x: 5, y: bounds.midY), CGPoint(x: bounds.maxX - 5, y: bounds.midY)] {
                #expect(frame.hitTest(point) is WindowDragRegion.DragView,
                        "\(model.isPrivate ? "Private" : "Ordinary") border at \(point) belongs to the window, not \(frame.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil")")
            }
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
        }
        await fixture.cleanup()
    }

    @Test func privateChromeIsAlwaysLightGrayWhilePagesKeepEarlysAppearance() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let normal = try #require(app.model)
        let id = try #require(app.openPrivateWindow())
        let model = try #require(app.windowModel(id))
        fixture.preferences.spaceThemes = false
        #expect(model.chromeTheme == .privateBrowsing && model.tintsChrome, "Gray even without Space themes")
        #expect(normal.chromeTheme == .space(.gray) && !normal.tintsChrome)
        let gray = WindowTheme.space(.gray)
        #expect(model.readerAccent == ReaderAccent(light: gray.focusBorder(isDark: false).hex, dark: gray.focusBorder(isDark: true).hex),
                "Reader follows the page's appearance, not the private chrome")
        fixture.preferences.spaceThemes = true

        func scheme(_ view: NSView) -> NSAppearance.Name? { view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) }
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        for window in [model, normal] {
            #expect(window.openLocations([URL(string: "early-test://fixture/one")!]))
        }
        var windows: [NSWindow] = []
        var hosts: [NSHostingView<AnyView>] = []
        for window in [model, normal] {
            let native = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
            native.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: AnyView(BrowserWindowView(model: window).transaction { $0.disablesAnimations = true }))
            native.contentView = hosting
            hosting.frame.size = CGSize(width: 1000, height: 700)
            windows.append(native)
            hosts.append(hosting)
        }
        let page = try #require(model.coordinator.focusedTabID.flatMap { model.webViews.pages[$0]?.view })
        let ordinaryPage = try #require(normal.coordinator.focusedTabID.flatMap { normal.webViews.pages[$0]?.view })
        func settle(_ label: String, _ condition: () -> Bool) async throws {
            try await fixture.waitUntil(label) {
                hosts.forEach { $0.layoutSubtreeIfNeeded() }
                return condition()
            }
        }

        try await settle("dark page in light private chrome") { page.window === windows[0] && scheme(page) == .darkAqua }
        #expect(windows[0].appearance?.name == .aqua && scheme(hosts[0]) == .aqua, "The private chrome stays light in dark mode")
        try await settle("ordinary window follows dark mode") { ordinaryPage.window === windows[1] && scheme(ordinaryPage) == .darkAqua }
        #expect(windows[1].appearance == nil && scheme(hosts[1]) == .darkAqua)

        NSApp.appearance = NSAppearance(named: .aqua)
        try await settle("light pages") { scheme(page) == .aqua && scheme(ordinaryPage) == .aqua }
        #expect(scheme(hosts[0]) == .aqua)
        #expect(scheme(hosts[1]) == .aqua)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await settle("dark again") { scheme(page) == .darkAqua && scheme(ordinaryPage) == .darkAqua }
        #expect(scheme(hosts[0]) == .aqua)

        NSApp.appearance = previous
        for (hosting, window) in zip(hosts, windows) {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            window.close()
        }
        await fixture.cleanup()
    }

    @Test func privateWindowsOfferNoSavedPagesSpacesOrOnlineSuggestionsByDefault() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        fixture.preferences.onlineSuggestions = true
        let id = try #require(app.openPrivateWindow())
        let model = try #require(app.windowModel(id))
        #expect(!model.onlineSuggestionsEnabled && app.model?.onlineSuggestionsEnabled == true)
        fixture.preferences.privateOnlineSuggestions = true
        #expect(model.onlineSuggestionsEnabled, "Both settings allow it")
        fixture.preferences.onlineSuggestions = false
        #expect(!model.onlineSuggestionsEnabled)

        #expect(model.openLocations([URL(string: "early-test://fixture/one")!]))
        let tab = try #require(model.coordinator.focusedTabID)
        #expect(!model.canPerform(.setPinned(tab, true)) && !model.canPerform(.setFavorite(tab, true)))
        #expect(!model.placeTab(tab, in: .pinned) && !model.placeTab(tab, in: .favorites))
        #expect(!model.canPerform(.newSpace) && !model.canManageSpaces)
        #expect(model.canPerform(.closeTab(tab)) && model.canPerform(.newPrivateWindow))
        let titles = model.commandSearchCandidates().map(\.title)
        #expect(!titles.contains("Pin Tab") && !titles.contains("Add to Favorites") && !titles.contains("New Space"))
        #expect(app.model?.commandSearchCandidates().map(\.title).contains("New Private Window") == true)
        await fixture.cleanup()
    }
}
