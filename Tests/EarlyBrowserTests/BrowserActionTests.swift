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

    @Test func dragPlacementAcrossSectionsAndFoldersKeepsTheLivePageAndFocus() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = try fixture.open(firstURL)
        let page = try #require(model.webViews.pages[id])
        let created = model.webViews.creationCount
        let focus = model.contentFocusRequest
        let folder = try #require(model.coordinator.createFolder(name: "Drop folder"))
        for section in [TabStore.Section.pinned, .favorites, .regular, .favorites, .pinned, .regular] {
            #expect(model.placeTab(id, in: section))
            #expect(model.webViews.pages[id] === page && model.webViews.creationCount == created)
            #expect(model.coordinator.activeTabID == id && model.contentFocusRequest == focus)
        }
        #expect(model.placeTab(id, in: .pinned, folderID: folder))
        #expect(model.coordinator.tabStore.tab(id: id)?.folderID == folder)
        #expect(model.placeTab(id, in: .regular))
        #expect(model.coordinator.tabStore.tab(id: id)?.folderID == nil)
        #expect(model.webViews.pages[id] === page && model.webViews.creationCount == created)
        #expect(model.coordinator.activeTabID == id && model.contentFocusRequest == focus)
        #expect(model.coordinator.tabStore.tabs.count == 1 && model.coordinator.commandBar == nil)
    }

    @Test func restoringASplitActivatesEveryVisibleMemberAndResumesAnEvictedPaneWithoutChangingFocus() throws {
        let profile = UUID(), space = UUID()
        let tabs = ["left", "right", "background"].map { side in
            BrowserTab(spaceID: space, profileID: profile, title: side,
                       currentURL: URL(string: "early-test://fixture/one?pane=\(side)")!)
        }
        var closed = BrowserTab(spaceID: space, profileID: profile, title: "Closed saved page",
                               currentURL: firstURL, pinnedURL: firstURL, isOpen: false)
        closed.sidebarPosition = 5
        let group = BrowserSplitGroup(spaceID: space,
            panes: tabs.prefix(2).map { BrowserSplitPane(tabID: $0.id) })
        let session = BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs + [closed],
            selectionBySpace: [space: tabs[0].id], splitGroups: [group],
            focusedPaneByGroupID: [group.id: group.panes[0].id])
        let fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model
        let left = try #require(model.webViews.pages[tabs[0].id])
        let right = try #require(model.webViews.pages[tabs[1].id])
        #expect(model.activePage === left && model.coordinator.focusedTabID == tabs[0].id)
        #expect(model.webViews.creationCount == 2 && model.webViews.liveViewCount == 2)
        #expect(model.webViews.pages[tabs[2].id] == nil && model.webViews.pages[closed.id] == nil)
        #expect(model.webViews.visibleTabIDs == [tabs[0].id, tabs[1].id])
        model.webViews.handleMemoryPressure(.critical)
        #expect(model.webViews.pages[tabs[0].id] === left && model.webViews.pages[tabs[1].id] === right)
        #expect(model.webViews.creationCount == 2)

        model.webViews.discard(tabID: tabs[1].id)
        #expect(model.webViews.pages[tabs[1].id] == nil)
        model.activateSelection()
        let resumed = try #require(model.webViews.pages[tabs[1].id])
        #expect(resumed !== right && model.webViews.pages[tabs[0].id] === left)
        #expect(model.webViews.creationCount == 3 && model.webViews.liveViewCount == 2)
        #expect(model.coordinator.focusedTabID == tabs[0].id && model.activePage === left)
        #expect(model.webViews.visibleTabIDs == [tabs[0].id, tabs[1].id])
        #expect(model.coordinator.splitGroups == [group] && model.coordinator.commandBar == nil)
        #expect(model.coordinator.tabStore.tabs.map(\.id) == session.tabs.map(\.id))
        #expect(model.webViews.pages[tabs[2].id] == nil && model.webViews.pages[closed.id] == nil)
    }

    @Test func commandWClosesAWindowOnlyWhenNoTabIsOpenInIt() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        var closed = 0
        model.onCloseWindow = { closed += 1 }
        #expect(model.isEmptyWindow, "A fresh window has no tabs")
        let tab = try fixture.open(firstURL)
        #expect(!model.isEmptyWindow)
        #expect(model.perform(.setPinned(tab, true)))
        #expect(model.perform(.closeActiveTab))
        #expect(model.isEmptyWindow, "A closed pin isn't an open tab")

        // A Today tab in another Space keeps the window open.
        let space = model.coordinator.activeSpaceID
        let other = try #require(model.coordinator.createSpace(name: "Other"))
        #expect(model.switchSpace(to: other))
        _ = try fixture.open(secondURL)
        #expect(model.switchSpace(to: space))
        #expect(model.coordinator.activeTabID == nil && !model.isEmptyWindow)
        model.closeWindow()
        #expect(closed == 1, "Closing is the window's own, as its close button")
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

    @Test func muteActionsDoNotSelectBackgroundTabsOrChangeTheirOrganization() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let background = try fixture.open(firstURL)
        let foreground = try fixture.open(secondURL)
        let page = try #require(model.webViews.pages[background])
        let before = model.coordinator.session
        let focus = model.contentFocusRequest
        let saves = fixture.saves
        #expect(model.canPerform(.setMuted(background, true)))
        #expect(model.perform(.setMuted(background, true)))
        #expect(page.isMuted && model.coordinator.activeTabID == foreground)
        #expect(model.coordinator.session == before && model.contentFocusRequest == focus)
        #expect(fixture.saves == saves && model.webViews.creationCount == 2)
        #expect(!model.canPerform(.setMuted(background, true)))
        #expect(model.perform(.setMuted(background, false)))
        #expect(!page.isMuted && model.coordinator.activeTabID == foreground)
        #expect(!model.perform(.setMuted(UUID(), true)))
        #expect(model.perform(.closeTab(background)))
        #expect(!model.canPerform(.setMuted(background, true)))
    }

    @Test func muteCommandCandidatesFollowCurrentStateAndRejectStaleResults() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = try fixture.open(firstURL)
        let mute = try #require(model.commandSearchCandidates().first { $0.title == "Mute Tab" })
        #expect(mute.target == .action(.setMuted(id, true)))
        #expect(model.perform(.setMuted(id, true)))
        #expect(!model.canPerform(.setMuted(id, true)))
        #expect(model.commandSearchCandidates().allSatisfy { $0.title != "Mute Tab" })
        let unmute = try #require(model.commandSearchCandidates().first { $0.title == "Unmute Tab" })
        #expect(unmute.target == .action(.setMuted(id, false)))
        #expect(model.perform(.setMuted(id, false), source: .commandBar))
        #expect(model.activePage?.isMuted == false)
    }

    @Test func interactionLocksDisableActionsButDismissalRemainsSafe() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let id = try fixture.open(firstURL)
        #expect(model.perform(.presentCommandBar(.newTab)))
        let before = model.coordinator.session
        model.sidebarInteractionInProgress = true
        for action: BrowserAction in [.closeActiveTab, .setPinned(id, true), .setMuted(id, true), .newSpace, .toggleSidebar,
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
        #expect(candidates.contains { $0.id == "tab.\(active.id.uuidString)" })
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


    @Test func currentTabResultsRemainSearchableAndOnlyDismissWithoutSavingOrReloading() async throws {
        for section in [TabStore.Section.regular, .pinned, .favorites] {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            let model = fixture.model, id = try fixture.open(firstURL)
            if section != .regular { #expect(model.placeTab(id, in: section)) }
            #expect(model.coordinator.renameTab(id, to: "Unicorn guide"))
            let page = try #require(model.activePage)
            #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
            #expect(model.visibleCommandResults.isEmpty, "Untouched address prefill should remain quiet")
            model.updateQuery("unicorn")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while model.commandSearch.isRefreshing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!model.commandSearch.isRefreshing)
            let result = try #require(model.visibleCommandResults.first)
            #expect(result.candidate.target == .tab(id))
            #expect(model.commandResultBadge(for: result.candidate) == "Current tab")
            let before = model.coordinator.session, saves = fixture.saves, focus = model.contentFocusRequest
            let location = page.requestedURL
            #expect(model.moveCommandBarSelection(1))
            #expect(model.performCommandBarSelection())
            #expect(model.coordinator.commandBar == nil && model.coordinator.session == before)
            #expect(model.activePage === page && model.webViews.creationCount == 1)
            #expect(page.requestedURL == location && fixture.saves == saves)
            #expect(model.contentFocusRequest == focus + 1)
            // An explicitly entered URL must be searchable even when identical
            // to the prefill; only the untouched prefill suppresses results.
            #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
            model.updateQuery(firstURL.absoluteString)
            let urlDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while model.commandSearch.isRefreshing && ContinuousClock.now < urlDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let exact = try #require(model.visibleCommandResults.first { $0.candidate.target == .tab(id) })
            #expect(model.commandResultBadge(for: exact.candidate) == "Current tab")
            #expect(model.perform(exact))
            #expect(model.webViews.creationCount == 1 && model.coordinator.commandBar == nil)
        }
    }

    @Test func savedLocationSubmissionsCreateTodayAndUneditedPrefillDoesNotDuplicate() throws {
        for section in [TabStore.Section.pinned, .favorites] {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            let model = fixture.model, saved = try fixture.open(firstURL)
            #expect(model.placeTab(saved, in: section))
            let page = try #require(model.activePage), before = model.coordinator.session
            let location = page.requestedURL, saves = fixture.saves
            #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
            #expect(model.performCommandBarSelection()) // Unedited address: no-op.
            #expect(model.coordinator.commandBar == nil && model.coordinator.session == before)
            #expect(model.webViews.creationCount == 1 && page.requestedURL == location && fixture.saves == saves)

            #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
            model.updateQuery(secondURL.absoluteString)
            #expect(model.performCommandBarSelection())
            let today = try #require(model.activeTab)
            #expect(today.id != saved && today.pinnedURL == nil && !today.isFavorite)
            #expect(today.currentURL == secondURL && today.spaceID == model.coordinator.activeSpaceID)
            #expect(model.webViews.pages[saved] === page && page.requestedURL == location)
            #expect(model.coordinator.tabStore.tab(id: saved)?.currentURL == firstURL)
            #expect(model.coordinator.tabStore.tab(id: saved)?.pinnedURL == firstURL)
            #expect(model.webViews.creationCount == 2 && model.coordinator.tabStore.tabs.count == 2)
            #expect(model.perform(.selectTab(saved)))
            #expect(model.perform(.presentCommandBar(.newTab)))
            model.updateQuery(secondURL.absoluteString)
            #expect(model.performCommandBarSelection())
            #expect(model.coordinator.tabStore.tabs.count == 3 && model.activeTab?.pinnedURL == nil)
        }
    }

    @Test func untouchedSavedPrefillDoesNotNavigateAfterAnAsynchronousURLUpdate() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, id = try fixture.open(firstURL)
        #expect(model.perform(.setFavorite(id, true)))
        let page = try #require(model.activePage)
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        #expect(model.coordinator.updateMetadata(id, url: secondURL, title: "Redirected"))
        let before = model.coordinator.session, saves = fixture.saves
        #expect(model.performCommandBarSelection())
        #expect(model.coordinator.commandBar == nil && model.coordinator.session == before)
        #expect(model.activePage === page && model.webViews.creationCount == 1 && fixture.saves == saves)
    }

    @Test func currentResultCannotBypassAvailabilityOrActOnAStaleClosedTab() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, saved = try fixture.open(firstURL)
        #expect(model.perform(.setFavorite(saved, true)))
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("fixture/one")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.commandSearch.isRefreshing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try #require(model.visibleCommandResults.first)
        model.folderEditorIsPresented = true
        #expect(!model.perform(result) && model.coordinator.commandBar != nil)
        model.folderEditorIsPresented = false
        #expect(model.perform(.closeTab(saved)))
        #expect(model.perform(.presentCommandBar(.newTab)))
        #expect(model.commandResultBadge(for: result.candidate) != "Current tab")
        #expect(model.perform(result)) // A still-saved closed Favorite reopens once.
        #expect(model.coordinator.activeTabID == saved && model.webViews.creationCount == 2)
        #expect(model.coordinator.tabStore.tabs.count == 1)
    }

    @Test func commandBarSurfacesAndExecutesActionsSpacesProfilesDuplicateAndSettingsWithProperFocus() async throws {
        let profile = UUID(), work = UUID(), personal = UUID()
        let active = BrowserTab(spaceID: work, profileID: profile, title: "Active Work", currentURL: firstURL)
        let session = BrowserSession(profileID: profile, activeSpaceID: work,
            tabs: [active], selectionBySpace: [work: active.id],
            spaces: [BrowserSpace(id: work, profileID: profile, name: "Work"),
                     BrowserSpace(id: personal, profileID: profile, name: "Personal")])
        let fixture = Fixture(session: session)
        defer { fixture.cleanup() }
        let model = fixture.model
        model.activateSelection()
        var openedSettings = 0
        model.onOpenSettings = { openedSettings += 1 }

        // 1. Search and run "Pin Tab" from the command bar -> pins active tab without creating a tab, restores content focus.
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("pin tab")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        let pinResult = try #require(model.visibleCommandResults.first { $0.id == "action.pin.\(active.id.uuidString)" })
        let focusBeforePin = model.contentFocusRequest
        #expect(model.perform(pinResult, source: .commandBar))
        #expect(model.coordinator.tabStore.tab(id: active.id)?.pinnedURL == firstURL)
        #expect(model.coordinator.tabStore.tabs.count == 1 && model.coordinator.commandBar == nil)
        #expect(model.contentFocusRequest == focusBeforePin + 1)

        // 2. Search and run "Duplicate Tab" -> creates a second open tab with the same URL and focuses content.
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("duplicate tab")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        model.selectCommandResult(id: "action.duplicate.\(active.id.uuidString)")
        #expect(model.selectedCommandResult?.id == "action.duplicate.\(active.id.uuidString)")
        #expect(model.performCommandBarSelection())
        #expect(model.coordinator.tabStore.tabs.count == 2 && model.coordinator.activeTabID != active.id)
        #expect(model.activeTab?.currentURL == firstURL && model.coordinator.commandBar == nil)

        // 3. Search and run "Open Settings" -> invokes settings handler and does not steal focus back to web content.
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("open settings")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        model.selectCommandResult(id: "action.openSettings")
        let focusBeforeSettings = model.contentFocusRequest
        #expect(model.performCommandBarSelection())
        #expect(openedSettings == 1 && model.coordinator.commandBar == nil)
        #expect(model.contentFocusRequest == focusBeforeSettings)

        // 4. Disabling commandBarActions hides actions, Spaces, and profiles while keeping tab/pin matches.
        model.commandBarActionsEnabled = false
        #expect(model.commandSearchCandidates().allSatisfy { $0.kind.isTab })
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("open settings")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.visibleCommandResults.isEmpty)
        model.commandBarActionsEnabled = true

        // 5. Selecting a tab inside collapsed nested folders expands all ancestor folders and reveals the tab in the sidebar.
        let parentFolder = try #require(model.coordinator.createFolder(name: "Parent"))
        let childFolder = try #require(model.coordinator.createFolder(name: "Child", parentID: parentFolder))
        #expect(model.coordinator.moveTab(active.id, toFolder: childFolder))
        model.coordinator.setFolderExpanded(parentFolder, expanded: false)
        model.coordinator.setFolderExpanded(childFolder, expanded: false)
        #expect(model.perform(.selectTab(active.id), source: .commandBar))
        #expect(model.coordinator.folders.first(where: { $0.id == parentFolder })?.isExpanded == true)
        #expect(model.coordinator.folders.first(where: { $0.id == childFolder })?.isExpanded == true)
        #expect(model.sidebarReveal?.itemID == "tab-\(active.id)")

        // 6. Search and switch Space from the command bar -> switches to Personal without creating a tab.
        #expect(model.perform(.presentCommandBar(.newTab)))
        model.updateQuery("personal")
        for _ in 0..<50 where model.commandSearch.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        model.selectCommandResult(id: "space.\(personal.uuidString)")
        #expect(model.performCommandBarSelection())
        #expect(model.coordinator.activeSpaceID == personal && model.coordinator.commandBar == nil)
    }
}
