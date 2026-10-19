// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import Testing

/// Exercise the native action owner without presenting windows or synthesizing
/// UI events. All pages are ephemeral local fixtures; no network is needed.
@Suite(.serialized) @MainActor
struct BrowserActionTests {
    private let firstURL = URL(string: "early-test://fixture/one")!
    private let secondURL = URL(string: "early-test://fixture/two")!

    @MainActor private final class Fixture {
        let suite = "local.early.tests.actions.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel
        var saves = 0

        init(session: BrowserSession = BrowserSession()) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            defaults.set(false, forKey: "haptics")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlyActions-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
                input: input, isTesting: true, restorationError: nil, defaults: defaults)
            model.onSave = { [weak self] _ in self?.saves += 1 }
        }

        func cleanup() {
            model.cancelCommandBarQueries()
            for id in Array(model.webViews.pages.keys) { model.webViews.discard(tabID: id) }
            defaults.removePersistentDomain(forName: suite)
        }

        func open(_ url: URL) throws -> UUID {
            #expect(model.perform(.presentCommandBar(.newTab)))
            model.updateQuery(url.absoluteString)
            #expect(model.perform(.submit()))
            return try #require(model.coordinator.activeTabID)
        }
    }

    @Test func presentingAndCancellingExplicitIntentsNeverCreatePlaceholderTabs() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        for _ in 0..<3 {
            #expect(model.perform(.presentCommandBar(.newTab)))
            #expect(model.coordinator.commandBar?.intent == .newTab)
        }
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        #expect(model.coordinator.commandBar?.query == "")
        #expect(model.coordinator.commandBar?.intent == .navigateCurrentTab)
        #expect(!model.perform(.submit()))
        #expect(model.perform(.dismissCommandBar(restoreFocus: false)))
        #expect(model.coordinator.tabStore.tabs.isEmpty && model.webViews.creationCount == 0)
        #expect(fixture.saves == 0)
    }

    @Test func newAndCurrentNavigationShareEffectsWithoutDuplicatingCurrentViews() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let first = try fixture.open(firstURL)
        let view = try #require(model.webViews.existingView(for: first))
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        #expect(model.coordinator.commandBar?.query == firstURL.absoluteString)
        model.updateQuery(secondURL.absoluteString)
        #expect(model.perform(.submit(), source: .commandBar))
        #expect(model.coordinator.activeTabID == first)
        #expect(model.coordinator.tabStore.tabs.count == 1 && model.webViews.creationCount == 1)
        #expect(model.webViews.existingView(for: first) === view)
        let second = try fixture.open(secondURL)
        #expect(second != first)
        #expect(model.coordinator.tabStore.tabs.count == 2 && model.webViews.creationCount == 2)
        #expect(model.coordinator.commandBar == nil)
        #expect(fixture.saves == 3)
    }

    @Test func rightArrowSuggestionCompletionOnlyEditsInputAndKeepsNavigationIntent() throws {
        let fixture = Fixture()
        let control = CommandBarInputControl(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        defer { control.invalidate(); fixture.cleanup() }
        let model = fixture.model
        let active = try fixture.open(firstURL)
        let view = try #require(model.webViews.existingView(for: active))
        var focusChanges = 0
        control.onFocusChange = { _ in focusChanges += 1 }
        control.onTextChange = { model.updateQuery($0) }
        control.onCompleteSuggestion = { "early browser" }

        for intent: CommandBarIntent in [.newTab, .navigateCurrentTab] {
            #expect(model.perform(.presentCommandBar(intent)))
            model.updateQuery("ear")
            control.updateText("ear")
            let before = model.coordinator.session
            let contentFocus = model.contentFocusRequest
            let presentationFocus = model.coordinator.commandBarFocusRequest
            let saves = fixture.saves

            #expect(control.handleCommand(#selector(NSResponder.moveRight(_:))))
            #expect(model.coordinator.commandBar?.query == "early browser")
            #expect(model.coordinator.commandBar?.intent == intent)
            #expect(model.coordinator.session == before)
            #expect(model.coordinator.activeTabID == active)
            #expect(model.webViews.creationCount == 1 && model.webViews.existingView(for: active) === view)
            #expect(model.contentFocusRequest == contentFocus)
            #expect(model.coordinator.commandBarFocusRequest == presentationFocus)
            #expect(fixture.saves == saves && focusChanges == 0)
        }
    }

    @Test func selectingAndResettingAClosedPinReuseItsSavedIdentity() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = try fixture.open(firstURL)
        #expect(model.perform(.setPinned(id, true)))
        #expect(model.perform(.closeTab(id)))
        #expect(model.coordinator.tabStore.tab(id: id)?.isOpen == false)
        #expect(model.webViews.liveViewCount == 0)
        #expect(model.perform(.selectTab(id)))
        #expect(model.coordinator.activeTabID == id && model.coordinator.tabStore.tabs.count == 1)
        #expect(model.webViews.creationCount == 2)
        #expect(model.perform(.closeActiveTab))
        #expect(model.perform(.resetPinnedTab(id), source: .commandBar))
        #expect(model.coordinator.activeTabID == id && model.coordinator.tabStore.tabs.count == 1)
        #expect(model.webViews.creationCount == 3)
        #expect(model.coordinator.recentlyClosed.isEmpty)
    }

    @Test func interfaceMetadataActionsKeepTheVisiblePageAndPendingEditorFocus() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let background = try fixture.open(firstURL)
        let foreground = try fixture.open(secondURL)
        let view = try #require(model.webViews.existingView(for: foreground))
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("pending input")
        let bar = model.coordinator.commandBar
        let focus = model.contentFocusRequest
        #expect(model.perform(.setPinned(background, true)))
        #expect(model.perform(.setFavorite(background, true)))
        #expect(model.perform(.setFavorite(background, false)))
        #expect(model.coordinator.activeTabID == foreground)
        #expect(model.webViews.existingView(for: foreground) === view)
        #expect(model.webViews.creationCount == 2)
        #expect(model.coordinator.commandBar == bar && model.contentFocusRequest == focus)
    }

    @Test func completedCommandBarMetadataActionDismissesAndRestoresContentFocusOnce() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = try fixture.open(firstURL)
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        let focus = model.contentFocusRequest
        #expect(model.perform(.setPinned(id, true), source: .commandBar))
        #expect(model.coordinator.commandBar == nil && model.contentFocusRequest == focus + 1)
        #expect(model.coordinator.activeTabID == id && model.webViews.creationCount == 1)
        #expect(!model.suggestions.isRefreshing)
    }

    @Test func promotingOrDemotingAClosedSavedPageNeverAllocatesOrSelectsIt() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let saved = try fixture.open(firstURL)
        #expect(model.perform(.setPinned(saved, true)))
        let foreground = try fixture.open(secondURL)
        #expect(model.perform(.closeTab(saved)))
        let focus = model.contentFocusRequest, creations = model.webViews.creationCount
        #expect(model.perform(.setFavorite(saved, true)))
        #expect(model.coordinator.tabStore.tab(id: saved)?.isOpen == false)
        #expect(model.perform(.setFavorite(saved, false)))
        #expect(model.coordinator.tabStore.tab(id: saved)?.pinnedURL == nil)
        #expect(model.coordinator.tabStore.tab(id: saved)?.isOpen == true)
        #expect(model.webViews.existingView(for: saved) == nil)
        #expect(model.coordinator.activeTabID == foreground && model.contentFocusRequest == focus)
        #expect(model.webViews.creationCount == creations)
    }

    @Test func staleForeignAndOutOfSpaceActionsAreRejectedWithoutSideEffects() throws {
        let profile = UUID(), personal = UUID(), other = UUID()
        let local = BrowserTab(spaceID: personal, profileID: profile, title: "Local", currentURL: firstURL)
        let inaccessible = BrowserTab(spaceID: other, profileID: profile, title: "Other", currentURL: secondURL)
        let foreign = BrowserTab(spaceID: personal, profileID: UUID(), title: "Foreign", currentURL: secondURL)
        let session = BrowserSession(profileID: profile, activeSpaceID: personal,
            tabs: [local, inaccessible, foreign], selectionBySpace: [personal: local.id],
            spaces: [BrowserSpace(id: personal, profileID: profile, name: "Personal"),
                     BrowserSpace(id: other, profileID: profile, name: "Other")])
        let fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("Keep this input")
        let before = model.coordinator.session, bar = model.coordinator.commandBar
        let focus = model.contentFocusRequest, creations = model.webViews.creationCount
        for id in [UUID(), foreign.id, inaccessible.id] {
            for action: BrowserAction in [.selectTab(id), .closeTab(id), .setPinned(id, true),
                                           .setFavorite(id, true), .requestRename(id), .resetPinnedTab(id),
                                           .moveTab(id, toSpace: other), .openTabInNewWindow(id)] {
                #expect(!model.canPerform(action))
                #expect(!model.perform(action, source: .commandBar))
            }
        }
        #expect(!model.perform(.switchSpace(UUID()), source: .commandBar))
        #expect(!model.perform(.openProfile(UUID()), source: .commandBar))
        #expect(model.coordinator.session == before && model.coordinator.commandBar == bar)
        #expect(model.contentFocusRequest == focus && model.webViews.creationCount == creations)
        #expect(model.renamingTabID == nil && fixture.saves == 0)
    }

    @Test func invalidAndComposingInputNeverNavigatesOrCreatesViews() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.updateQuery("git", isComposing: true)
        #expect(!model.canPerform(.submit()))
        #expect(!model.perform(.submit(), source: .commandBar))
        #expect(!model.submit())
        #expect(model.coordinator.commandBar?.query == "git" && model.commandBarIsComposing)
        #expect(model.submissionMessage == nil && !model.suggestions.isRefreshing)
        model.updateQuery("file:///etc/passwd", isComposing: false)
        #expect(!model.perform(.submit(), source: .commandBar))
        #expect(model.coordinator.commandBar != nil && model.submissionMessage != nil)
        #expect(model.coordinator.tabStore.tabs.isEmpty && model.webViews.creationCount == 0)
        #expect(fixture.saves == 0)
    }

    @Test func choosingASuggestionAlwaysSearchesEvenWhenItLooksLikeAURL() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.updateQuery("github")
        #expect(model.perform(.submit(searchSuggestion: "github.com"), source: .commandBar))
        let tab = try #require(model.activeTab)
        let expected = try model.input.searchURL(for: "github.com")
        #expect(tab.currentURL == expected && tab.currentURL.host != "github.com")
        #expect(model.coordinator.tabStore.tabs.count == 1 && model.webViews.creationCount == 1)
        #expect(model.coordinator.commandBar == nil && fixture.saves == 1)
    }

    @Test func interactionLocksDisableActionsButDismissalRemainsSafe() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = try fixture.open(firstURL)
        #expect(model.perform(.presentCommandBar(.newTab)))
        let before = model.coordinator.session
        model.sidebarInteractionInProgress = true
        for action: BrowserAction in [.closeActiveTab, .setPinned(id, true), .newSpace, .toggleSidebar,
                                       .presentCommandBar(.navigateCurrentTab), .selectTab(id)] {
            #expect(!model.canPerform(action) && !model.perform(action))
        }
        #expect(model.perform(.dismissCommandBar(restoreFocus: false)))
        #expect(model.coordinator.session == before)
        model.sidebarInteractionInProgress = false
        model.activePage?.hasDialog = true
        #expect(!model.canPerform(.closeActiveTab))
        #expect(!model.canPerform(.reload))
        model.activePage?.hasDialog = false
        #expect(model.canPerform(.closeActiveTab))
    }

    @Test func closingABackgroundTabDoesNotStealFocusOrDismissTheEditor() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let background = try fixture.open(firstURL)
        let foreground = try fixture.open(secondURL)
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("Keep typing")
        let focus = model.contentFocusRequest, bar = model.coordinator.commandBar
        #expect(model.perform(.closeTab(background)))
        #expect(model.coordinator.activeTabID == foreground && model.contentFocusRequest == focus)
        #expect(model.coordinator.commandBar == bar && model.webViews.liveViewCount == 1)
    }

    @Test func siblingMoveActionsChangeOnlyOrderAndRejectInvalidDirectionsOrEdges() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let first = try fixture.open(firstURL)
        let second = try fixture.open(secondURL)
        let foreground = try fixture.open(firstURL)
        let view = try #require(model.webViews.existingView(for: foreground))
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("Keep typing")
        let focus = model.contentFocusRequest, bar = model.coordinator.commandBar
        let creations = model.webViews.creationCount, saves = fixture.saves
        #expect(!model.canPerform(.moveTabBy(first, -1)))
        #expect(!model.canPerform(.moveTabBy(foreground, 1)))
        for direction in [Int.min, 0, 2, Int.max] {
            #expect(!model.perform(.moveTabBy(first, direction)))
        }
        #expect(!model.perform(.moveTabBy(UUID(), 1)))
        #expect(model.perform(.moveTabBy(first, 1)))
        #expect(model.todayTabs.map(\.id) == [second, first, foreground])
        #expect(model.coordinator.activeTabID == foreground && model.contentFocusRequest == focus)
        #expect(model.coordinator.commandBar == bar && model.webViews.creationCount == creations)
        #expect(model.webViews.existingView(for: foreground) === view)
        #expect(fixture.saves == saves + 1)
    }

    @Test func commandBarRenameHandsFocusToTheSheetInsteadOfThePage() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = try fixture.open(firstURL)
        #expect(model.perform(.presentCommandBar(.newTab)))
        let focus = model.contentFocusRequest
        #expect(model.perform(.requestRename(id), source: .commandBar))
        #expect(model.coordinator.commandBar == nil && model.renamingTabID == id)
        #expect(model.contentFocusRequest == focus)
    }

    @Test func tabShortcutsRejectInvalidNumbersAndDirectionsAndKeepExistingIdentity() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let first = try fixture.open(firstURL)
        let last = try fixture.open(secondURL)
        for number in [Int.min, -1, 0, 3, 8, 10, Int.max] {
            #expect(!model.perform(.selectTabNumber(number)))
        }
        for direction in [Int.min, 0, 2, Int.max] { #expect(!model.perform(.cycleTab(direction))) }
        #expect(model.perform(.selectTabNumber(1)))
        #expect(model.coordinator.activeTabID == first)
        #expect(model.perform(.selectTabNumber(9)))
        #expect(model.coordinator.activeTabID == last)
        #expect(model.perform(.cycleTab(1)))
        #expect(model.coordinator.activeTabID == first && model.webViews.creationCount == 2)
    }


    @Test func commandSearchSelectionReusesLiveAndClosedPinsWithoutDuplicatesAndKeepsUnselectedReturnNavigating() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let pinned = try fixture.open(firstURL)
        #expect(model.perform(.setPinned(pinned, true)))
        #expect(model.coordinator.renameTab(pinned, to: "Pinned Guide"))
        let current = try fixture.open(secondURL)
        let pinnedView = try #require(model.webViews.existingView(for: pinned))

        // Unedited Cmd-L prefill does not surface local search rows.
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        #expect(model.visibleCommandResults.isEmpty)

        // Searching and selecting a live pin switches to its existing view.
        model.updateQuery("pinned")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.visibleCommandResults.map(\.id) == ["tab.\(pinned.uuidString)"])
        #expect(model.moveCommandBarSelection(1))
        #expect(model.selectedCommandResult?.id == "tab.\(pinned.uuidString)")
        #expect(model.performCommandBarSelection())
        #expect(model.coordinator.activeTabID == pinned && model.coordinator.commandBar == nil)
        #expect(model.coordinator.tabStore.tabs.count == 2 && model.webViews.creationCount == 2)
        #expect(model.webViews.existingView(for: pinned) === pinnedView)

        // Close the pin, switch back to the other tab, and select the closed pin from search.
        #expect(model.perform(.closeTab(pinned)))
        #expect(model.coordinator.activeTabID == current && model.webViews.liveViewCount == 1)
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("fixture/one")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.visibleCommandResults.map(\.id) == ["tab.\(pinned.uuidString)"])
        #expect(model.moveCommandBarSelection(1))
        #expect(model.performCommandBarSelection())
        #expect(model.coordinator.activeTabID == pinned && model.coordinator.tabStore.tabs.count == 2)
        #expect(model.coordinator.tabStore.tab(id: pinned)?.isOpen == true)
        #expect(model.webViews.creationCount == 3 && model.webViews.liveViewCount == 2)

        // Typing matching words without selecting a row still performs the explicit search/navigation.
        #expect(model.perform(.selectTab(current)))
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("pinned")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.visibleCommandResults.isEmpty && model.selectedCommandResult == nil)
        #expect(model.performCommandBarSelection())
        #expect(model.coordinator.tabStore.tabs.count == 3 && model.coordinator.activeTabID != pinned)
    }

    @Test func commandSearchCandidatesRespectSpaceProfileAndAvailabilityAndWalkIntoSuggestions() async throws {
        let profile = UUID(), work = UUID(), personal = UUID()
        let active = BrowserTab(spaceID: work, profileID: profile, title: "Active Work", currentURL: firstURL)
        let sibling = BrowserTab(spaceID: work, profileID: profile, title: "Swift Docs", currentURL: secondURL)
        let otherSpace = BrowserTab(spaceID: personal, profileID: profile, title: "Swift Personal", currentURL: secondURL)
        let foreign = BrowserTab(spaceID: work, profileID: UUID(), title: "Swift Foreign", currentURL: secondURL)
        let session = BrowserSession(profileID: profile, activeSpaceID: work,
            tabs: [active, sibling, otherSpace, foreign], selectionBySpace: [work: active.id],
            spaces: [BrowserSpace(id: work, profileID: profile, name: "Work"),
                     BrowserSpace(id: personal, profileID: profile, name: "Personal")])
        let fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model
        model.onlineSuggestionsEnabled = true

        let candidates = model.commandSearchCandidates()
        #expect(candidates.contains { $0.id == "tab.\(sibling.id.uuidString)" })
        #expect(!candidates.contains { $0.id == "tab.\(active.id.uuidString)" })
        #expect(!candidates.contains { $0.id == "tab.\(otherSpace.id.uuidString)" })
        #expect(!candidates.contains { $0.id == "tab.\(foreign.id.uuidString)" })
        #expect(candidates.contains { $0.id == "space.\(personal.uuidString)" })
        #expect(!candidates.contains { $0.id == "space.\(work.uuidString)" })
        #expect(candidates.contains { $0.id == "action.pin.\(active.id.uuidString)" })
        #expect(!candidates.contains { $0.id == "action.reopenLastTab" })

        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("swift")
        for _ in 0..<50 where model.commandSearch.isRefreshing || model.suggestions.isRefreshing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.visibleCommandResults.map(\.id) == ["tab.\(sibling.id.uuidString)"])
        #expect(model.suggestions.results.first == "swift guide")

        // Arrow navigation walks local tab rows first, then Google suggestions, then clears.
        #expect(model.moveCommandBarSelection(1))
        #expect(model.selectedCommandResult?.id == "tab.\(sibling.id.uuidString)" && model.suggestions.selectedIndex == nil)
        #expect(model.moveCommandBarSelection(1))
        #expect(model.selectedCommandResult == nil && model.suggestions.selectedIndex == 0)
        #expect(model.moveCommandBarSelection(-1))
        #expect(model.selectedCommandResult?.id == "tab.\(sibling.id.uuidString)" && model.suggestions.selectedIndex == nil)
        #expect(model.moveCommandBarSelection(-1))
        #expect(model.selectedCommandResult == nil && model.suggestions.selectedIndex == nil)
    }
}
