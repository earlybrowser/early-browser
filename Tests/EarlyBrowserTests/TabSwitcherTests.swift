// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
@testable import EarlyWeb
import Testing

/// Windowless controller/input/layout checks. No keyboard events are posted and
/// no view is prepared solely to manufacture a thumbnail.
@Suite(.serialized) @MainActor
struct TabSwitcherTests {
    @MainActor private final class Fixture {
        let suite = "local.early.tests.switcher.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel
        let tabs: [BrowserTab]

        init(count: Int = 4, split: Bool = false, selected: Bool = true) {
            _ = NSApplication.shared
            let profile = UUID(), space = UUID()
            tabs = (0..<count).map { index in
                BrowserTab(spaceID: space, profileID: profile, title: "Page \(index)",
                           currentURL: URL(string: "early-test://fixture/one?tab=\(index)")!)
            }
            let group = split && count >= 2 ? BrowserSplitGroup(spaceID: space,
                panes: tabs.prefix(2).map { BrowserSplitPane(tabID: $0.id) }) : nil
            let session = BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs,
                selectionBySpace: selected && !tabs.isEmpty ? [space: tabs[0].id] : [:],
                splitGroups: group.map { [$0] } ?? [],
                focusedPaneByGroupID: group.map { [$0.id: $0.panes[0].id] } ?? [:])
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            defaults.set(false, forKey: "haptics")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlySwitcher-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
                input: input, isTesting: true, restorationError: nil, defaults: defaults)
        }

        func cleanup() {
            model.cancelTabSwitcher(restoreFocus: false)
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test func repeatedHighlightAndCacheFallbackNeverLoadSaveSelectOrChangeMRU() throws {
        let fixture = Fixture(count: 100)
        defer { fixture.cleanup() }
        let model = fixture.model, initial = model.coordinator.session
        let page = try #require(model.activePage), focus = model.contentFocusRequest
        let work = model.webViews.workMetrics
        var saves = 0
        model.onSave = { _ in saves += 1 }
        #expect(model.advanceTabSwitcher(1, commitsOnControlRelease: true))
        let order = try #require(model.tabSwitcher?.tabIDs)
        #expect(model.tabSwitcher?.selectedTabID == fixture.tabs[1].id)
        for index in 0..<250 {
            #expect(model.advanceTabSwitcher(index.isMultiple(of: 3) ? -1 : 1, commitsOnControlRelease: true))
            let id = try #require(model.tabSwitcher?.selectedTabID)
            #expect(model.webViews.snapshots.image(for: id) == nil)
        }
        #expect(model.tabSwitcher?.tabIDs == order && model.tabSwitcherCommitsOnControlRelease)
        #expect(model.coordinator.session == initial && model.activePage === page)
        #expect(model.webViews.creationCount == 1 && model.webViews.liveViewCount == 1)
        #expect(model.webViews.snapshots.count == 0 && model.webViews.snapshots.pendingCount == 0)
        #expect(model.webViews.workMetrics.retentionPasses == work.retentionPasses)
        #expect(model.webViews.workMetrics.presentationVisits == work.presentationVisits)
        #expect(model.webViews.workMetrics.inspectedPages == work.inspectedPages)
        #expect(model.contentFocusRequest == focus && saves == 0)
        model.cancelTabSwitcher()
        #expect(model.tabSwitcher == nil && !model.tabSwitcherCommitsOnControlRelease)
        #expect(model.coordinator.session == initial && model.contentFocusRequest == focus + 1)
        #expect(!model.commitTabSwitcher())
        #expect(model.webViews.creationCount == 1 && saves == 0)
    }

    @Test func pointerAndReturnCommitThroughSharedSelectionOnceAndRejectForeignCandidate() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, initial = fixture.tabs[0].id
        let page = try #require(model.activePage)
        #expect(model.advanceTabSwitcher(1))
        let focus = model.contentFocusRequest
        #expect(!model.commitTabSwitcher(selecting: UUID()))
        #expect(model.tabSwitcher != nil && model.webViews.creationCount == 1)
        #expect(model.selectTabSwitcherCandidate(fixture.tabs[3].id))
        #expect(model.coordinator.activeTabID == initial && model.activePage === page)
        #expect(model.commitTabSwitcher())
        #expect(model.coordinator.activeTabID == fixture.tabs[3].id)
        #expect(model.webViews.creationCount == 2 && model.contentFocusRequest == focus + 1)
        #expect(model.webViews.existingView(for: initial) === page.view)
        #expect(model.tabSwitcher == nil && !model.commitTabSwitcher())
        #expect(model.advanceTabSwitcher(-1))
        #expect(model.commitTabSwitcher(selecting: initial))
        #expect(model.activePage === page && model.webViews.creationCount == 2)
    }

    @Test func committingOriginalCandidateIsANoOpAndCancellationCannotCommitOnRelease() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model, initial = model.coordinator.session
        let page = try #require(model.activePage)
        #expect(model.advanceTabSwitcher(1, commitsOnControlRelease: true))
        #expect(model.selectTabSwitcherCandidate(fixture.tabs[0].id))
        #expect(model.commitTabSwitcher())
        #expect(model.coordinator.session == initial && model.activePage === page && model.webViews.creationCount == 1)
        #expect(model.advanceTabSwitcher(-1, commitsOnControlRelease: true))
        model.cancelTabSwitcher(restoreFocus: false)
        #expect(!model.tabSwitcherCommitsOnControlRelease && !model.commitTabSwitcher())
        #expect(model.coordinator.session == initial)
    }

    @Test func metadataUpdatesKeepFrozenOrderButClosingCandidateInvalidatesIt() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.advanceTabSwitcher(1))
        let selection = try #require(model.tabSwitcher)
        #expect(model.coordinator.renameTab(selection.selectedTabID, to: "Renamed candidate"))
        model.save()
        #expect(model.tabSwitcher == selection)
        // Simulate an asynchronous catalog change before the next rendered frame.
        #expect(model.coordinator.closeTab(selection.selectedTabID) != nil)
        #expect(!model.commitTabSwitcher())
        #expect(model.tabSwitcher == nil && model.coordinator.activeTabID == fixture.tabs[0].id)
        #expect(model.webViews.creationCount == 1)
    }

    @Test func commandBarSpaceChangeAndModalAvailabilityCancelWithoutStealingFocus() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.advanceTabSwitcher(1))
        #expect(model.perform(.presentCommandBar(.navigateCurrentTab)))
        #expect(model.tabSwitcher == nil && !model.advanceTabSwitcher(1))
        #expect(model.perform(.dismissCommandBar(restoreFocus: false)))
        let other = try #require(model.createSpace(name: "Other"))
        #expect(model.advanceTabSwitcher(1))
        #expect(model.switchSpace(to: other))
        #expect(model.tabSwitcher == nil && !model.commitTabSwitcher())
        #expect(model.switchSpace(to: fixture.tabs[0].spaceID))
        #expect(model.advanceTabSwitcher(1))
        let focus = model.contentFocusRequest
        model.folderEditorIsPresented = true
        #expect(!model.advanceTabSwitcher(1) && model.tabSwitcher == nil)
        #expect(!model.commitTabSwitcher() && model.contentFocusRequest == focus)
        model.folderEditorIsPresented = false
        model.sidebarInteractionInProgress = true
        #expect(!model.canPresentTabSwitcher)
        model.sidebarInteractionInProgress = false
        model.activePage?.hasDialog = true
        #expect(!model.canPresentTabSwitcher)
        model.activePage?.hasDialog = false
        #expect(model.canPresentTabSwitcher)
    }

    @Test func splitCandidateFocusesItsExistingPaneWithoutAllocation() throws {
        let fixture = Fixture(split: true)
        defer { fixture.cleanup() }
        let model = fixture.model, selected = fixture.tabs[1].id
        let group = try #require(model.coordinator.activeSplitGroup)
        let page = try #require(model.webViews.pages[selected])
        #expect(model.advanceTabSwitcher(1))
        #expect(model.webViews.creationCount == 2 && model.coordinator.focusedTabID == fixture.tabs[0].id)
        #expect(model.commitTabSwitcher(selecting: selected))
        #expect(model.coordinator.focusedTabID == selected && model.activePage === page)
        #expect(model.coordinator.activeSplitGroup?.id == group.id && model.webViews.creationCount == 2)
    }

    @Test func selectionAndDismissalAreWindowAndProfileLocal() throws {
        let first = Fixture(), second = Fixture()
        defer { first.cleanup(); second.cleanup() }
        let otherSession = second.model.coordinator.session
        #expect(first.model.advanceTabSwitcher(1))
        #expect(second.model.tabSwitcher == nil && second.model.coordinator.session == otherSession)
        #expect(!first.model.commitTabSwitcher(selecting: second.tabs[0].id))
        #expect(first.model.commitTabSwitcher())
        #expect(second.model.coordinator.session == otherSession && second.model.webViews.creationCount == 1)
        #expect(second.model.webViews.snapshots.image(for: first.tabs[1].id) == nil)
    }

    @Test func zeroAndSingleTabsKeepTheQuietEmptyAndFirstLaunchContracts() {
        for count in [0, 1] {
            let fixture = Fixture(count: count)
            defer { fixture.cleanup() }
            let model = fixture.model
            #expect(!model.advanceTabSwitcher(1) && model.tabSwitcher == nil)
            if count == 0 {
                #expect(model.coordinator.commandBar?.intent == .newTab)
                #expect(model.perform(.dismissCommandBar(restoreFocus: false)))
                #expect(model.coordinator.commandBar == nil && model.coordinator.content == .empty)
                #expect(model.webViews.creationCount == 0 && model.webViews.liveViewCount == 0)
            } else {
                #expect(model.webViews.creationCount == 1)
            }
        }
    }

    @Test func unselectedCatalogStartsAtFirstOrLastAndClosedItemsAreExcluded() throws {
        let fixture = Fixture(selected: false)
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.perform(.dismissCommandBar(restoreFocus: false)))
        #expect(model.advanceTabSwitcher(1))
        #expect(model.tabSwitcher?.selectedTabID == fixture.tabs[0].id && model.webViews.creationCount == 0)
        model.cancelTabSwitcher(restoreFocus: false)
        #expect(model.advanceTabSwitcher(-1))
        #expect(model.tabSwitcher?.selectedTabID == fixture.tabs.last?.id && model.webViews.creationCount == 0)
        var closed = fixture.tabs[0]
        closed.isOpen = false
        closed.pinnedURL = closed.currentURL
        let selection = try #require(TabSwitcher(openTabs: [closed, fixture.tabs[1], fixture.tabs[1]], activeTabID: nil))
        #expect(selection.tabIDs == [fixture.tabs[1].id])
    }

    @Test func keyRoutingLeavesWebsiteKeysAndSystemShortcutsAloneUntilPresented() {
        #expect(TabSwitcherKeyRouting.action(keyCode: 48, modifiers: .control, presented: false) == .advance(1))
        #expect(TabSwitcherKeyRouting.action(keyCode: 48, modifiers: [.control, .shift], presented: false) == .advance(-1))
        #expect(TabSwitcherKeyRouting.action(keyCode: 48, modifiers: [], presented: false) == .pass)
        #expect(TabSwitcherKeyRouting.action(keyCode: 17, modifiers: [], presented: false) == .pass) // website T
        #expect(TabSwitcherKeyRouting.action(keyCode: 123, modifiers: [], presented: false) == .pass)
        for code: UInt16 in [36, 76] {
            #expect(TabSwitcherKeyRouting.action(keyCode: code, modifiers: [], presented: true) == .commit)
        }
        #expect(TabSwitcherKeyRouting.action(keyCode: 53, modifiers: .control, presented: true) == .cancel)
        #expect(TabSwitcherKeyRouting.action(keyCode: 123, modifiers: [], presented: true) == .advance(-1))
        #expect(TabSwitcherKeyRouting.action(keyCode: 124, modifiers: [], presented: true) == .advance(1))
        #expect(TabSwitcherKeyRouting.action(keyCode: 48, modifiers: .shift, presented: true) == .advance(-1))
        #expect(TabSwitcherKeyRouting.action(keyCode: 17, modifiers: [], presented: true) == .cancelAndPass)
        #expect(TabSwitcherKeyRouting.action(keyCode: 124, modifiers: [.control, .option], presented: true) == .pass)
        for flags: NSEvent.ModifierFlags in [.command, [.control, .command], .option] {
            #expect(TabSwitcherKeyRouting.action(keyCode: 48, modifiers: flags, presented: false) == .pass)
            #expect(TabSwitcherKeyRouting.action(keyCode: 48, modifiers: flags, presented: true) == .cancelAndPass)
        }
    }

    @Test func stripFitsCompactWideAndExtremeWidthsAndKeepsCardsBounded() {
        for width in [1.0, 220, 288, 380, 800, 2_000] {
            for count in [1, 2, 10, 100, Int.max] {
                let layout = TabSwitcherLayout(availableWidth: width, count: count)
                #expect(layout.panelWidth > 0 && layout.panelWidth <= max(1, width - 32))
                #expect(layout.panelWidth <= 960 && layout.cardWidth <= 192 && layout.cardWidth > 0)
                #expect(layout.cardWidth <= layout.panelWidth)
            }
        }
        for width in [Double.nan, .infinity, -.infinity, -200] {
            let layout = TabSwitcherLayout(availableWidth: width, count: 100)
            #expect(layout.panelWidth.isFinite && layout.cardWidth.isFinite && layout.panelWidth > 0)
        }
    }
}
