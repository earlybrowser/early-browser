// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct SplitMetadataTests {
    private func session() -> BrowserSession {
        let profile = UUID(), space = UUID(), other = UUID()
        let tabs = (0..<4).map { index in
            BrowserTab(spaceID: index == 3 ? other : space, profileID: profile,
                title: "Page \(index)", currentURL: URL(string: "https://example.com/\(index)")!)
        }
        return BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs,
            selectionBySpace: [space: tabs[0].id],
            spaces: [BrowserSpace(id: space, profileID: profile, name: "First"),
                     BrowserSpace(id: other, profileID: profile, name: "Second")])
    }

    private func coordinator(_ session: BrowserSession) -> BrowserCoordinator {
        BrowserCoordinator(startup: .returningSession, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders), selectionBySpace: session.selectionBySpace,
            profileID: session.profileID, spaces: session.spaces, splitGroups: session.splitGroups,
            focusedPaneByGroupID: session.focusedPaneByGroupID)
    }

    @Test func splitFocusResizeAndExitKeepTheSameTabIdentities() throws {
        let state = session(), browser = coordinator(state)
        let first = state.tabs[0].id, second = state.tabs[1].id
        let id = try #require(browser.createSplit(between: first, and: second))
        let group = try #require(browser.activeSplitGroup)
        #expect(group.id == id && group.panes.map(\.tabID) == [first, second])
        #expect(Set(group.panes.map(\.id)).count == 2)
        #expect(browser.visibleTabIDs == [first, second] && browser.focusedTabID == first)
        #expect(browser.focusPane(group.panes[1].id))
        #expect(browser.focusedTabID == second)
        browser.presentCommandBar(.navigateCurrentTab)
        #expect(browser.navigationRequest()?.target == .currentTab(second))
        #expect(browser.resizeSplit(id, leadingFraction: 0.65))
        #expect(browser.activeSplitGroup?.leadingFraction == 0.65)
        #expect(!browser.resizeSplit(id, leadingFraction: .nan))
        #expect(!browser.resizeSplit(id, leadingFraction: 0.95))
        try browser.session.validate()
        #expect(browser.exitSplit(id))
        #expect(browser.focusedTabID == second && browser.visibleTabIDs == [second])
        #expect(browser.tabStore.tabs.map(\.id) == state.tabs.map(\.id))
        #expect(browser.tabStore.tabs.allSatisfy { $0.isOpen })
    }

    @Test func invalidMembershipAndDuplicatePageOwnershipAreRejectedAtomically() throws {
        let state = session(), browser = coordinator(state)
        let first = state.tabs[0].id, second = state.tabs[1].id
        #expect(browser.createSplit(between: first, and: first) == nil)
        #expect(browser.createSplit(between: first, and: state.tabs[3].id) == nil)
        #expect(browser.createSplit(between: first, and: UUID()) == nil)
        #expect(browser.createSplit(between: first, and: second, leadingFraction: .infinity) == nil)
        let id = try #require(browser.createSplit(between: first, and: second))
        let before = browser.session
        #expect(browser.createSplit(between: second, and: state.tabs[2].id) == nil)
        #expect(!browser.focusPane(UUID()))
        #expect(browser.session == before && browser.activeSplitGroup?.id == id)
        browser.closeTab(second)
        #expect(browser.createSplit(between: first, and: second) == nil)
    }

    @Test(arguments: [0, 1])
    func swappingKeepsFocusPaneIdentitiesDividerPositionAndTabHistory(_ focusedIndex: Int) throws {
        let state = session(), browser = coordinator(state)
        let id = try #require(browser.createSplit(between: state.tabs[0].id, and: state.tabs[1].id, leadingFraction: 0.65))
        let original = try #require(browser.activeSplitGroup)
        #expect(browser.focusPane(original.panes[focusedIndex].id))
        let before = browser.session
        #expect(browser.swapSplit(id))
        let swapped = try #require(browser.activeSplitGroup)
        #expect(swapped.id == id && swapped.panes == Array(original.panes.reversed()))
        #expect(swapped.leadingFraction == original.leadingFraction)
        #expect(browser.focusedTabID == original.panes[focusedIndex].tabID)
        #expect(browser.focusedPaneByGroupID == before.focusedPaneByGroupID)
        #expect(browser.session.tabs == before.tabs && browser.session.selectionBySpace == before.selectionBySpace)
        let restored = coordinator(try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session)))
        #expect(restored.activeSplitGroup == swapped && restored.focusedTabID == browser.focusedTabID)
        try restored.session.validate()
        #expect(browser.swapSplit(id) && browser.session == before)
    }

    @Test func swappingRejectsMissingClosedAndForeignSpaceGroupsWithoutMutation() throws {
        let state = session(), browser = coordinator(state)
        let id = try #require(browser.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        let before = browser.session
        #expect(!browser.swapSplit(UUID()) && browser.session == before)
        browser.switchSpace(to: state.spaces[1].id)
        let otherSpace = browser.session
        #expect(!browser.swapSplit(id) && browser.session == otherSpace)
        browser.switchSpace(to: state.activeSpaceID)
        browser.closeTab(state.tabs[1].id)
        let closed = browser.session
        #expect(!browser.swapSplit(id) && browser.session == closed)
    }

    @Test func layoutAndFocusedPaneRoundTripWithoutRuntimeState() throws {
        let state = session(), browser = coordinator(state)
        _ = try #require(browser.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        let group = try #require(browser.activeSplitGroup)
        browser.focusPane(group.panes[1].id)
        browser.resizeSplit(group.id, leadingFraction: 0.7)
        let saved = browser.session
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: data)
        try decoded.validate()
        #expect(decoded == saved)
        let restored = coordinator(decoded)
        #expect(restored.focusedTabID == state.tabs[1].id)
        #expect(restored.activeSplitGroup?.id == group.id)
        #expect(restored.activeSplitGroup?.leadingFraction == 0.7)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("lifecycles") && !json.contains("isLoading") && !json.contains("isMuted"))

        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "splitGroups")
        legacy.removeValue(forKey: "focusedPaneByGroupID")
        let old = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.splitGroups.isEmpty && old.focusedPaneByGroupID.isEmpty)
        #expect(old.tabs == saved.tabs && old.selectionBySpace == saved.selectionBySpace)
    }

    @Test(arguments: ["missing", "closed", "foreign", "otherSpace", "duplicateTab", "duplicatePane", "size"])
    func staleOrInvalidLayoutIsPrunedWithoutLosingTabs(kind: String) throws {
        var state = session()
        let first = state.tabs[0].id, second = state.tabs[1].id
        var panes = [BrowserSplitPane(tabID: first), BrowserSplitPane(tabID: second)]
        switch kind {
        case "missing": panes[1] = BrowserSplitPane(tabID: UUID())
        case "closed": state.tabs[1].isOpen = false
        case "foreign": state.tabs[1] = BrowserTab(id: second, spaceID: state.activeSpaceID, profileID: UUID(), title: "Foreign", currentURL: state.tabs[1].currentURL)
        case "otherSpace": state.tabs[1].spaceID = state.spaces[1].id
        case "duplicateTab": panes[1] = BrowserSplitPane(tabID: first)
        case "duplicatePane": panes[1] = BrowserSplitPane(id: panes[0].id, tabID: second)
        default: break
        }
        let group = BrowserSplitGroup(spaceID: state.activeSpaceID, panes: panes, leadingFraction: kind == "size" ? 0.99 : 0.5)
        state.splitGroups = [group]
        state.focusedPaneByGroupID = [group.id: panes[1].id]
        #expect(throws: SessionError.self) { try state.validate() }
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(state))
        #expect(decoded.splitGroups.isEmpty && decoded.focusedPaneByGroupID.isEmpty)
        #expect(decoded.tabs == state.tabs, "Pruning layout never deletes or changes a tab")
    }

    @Test func duplicateGroupsArePrunedAndInvalidFocusUsesTheWindowSelection() throws {
        var state = session()
        let group = BrowserSplitGroup(spaceID: state.activeSpaceID,
            panes: [BrowserSplitPane(tabID: state.tabs[0].id), BrowserSplitPane(tabID: state.tabs[1].id)])
        state.splitGroups = [group, group]
        state.selectionBySpace[state.activeSpaceID] = state.tabs[1].id
        state.focusedPaneByGroupID = [group.id: UUID(), UUID(): UUID()]
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(state))
        #expect(decoded.splitGroups == [group])
        #expect(decoded.focusedPaneByGroupID == [group.id: group.panes[1].id])
        try decoded.validate()
    }

    @Test func closingFocusedPaneCollapsesToItsSiblingRatherThanAnUnrelatedTab() throws {
        let state = session(), browser = coordinator(state)
        let first = state.tabs[0].id, sibling = state.tabs[2].id
        _ = try #require(browser.createSplit(between: first, and: sibling))
        browser.closeActiveTab()
        #expect(browser.focusedTabID == sibling)
        #expect(browser.splitGroups.isEmpty && browser.focusedPaneByGroupID.isEmpty)
        #expect(browser.visibleTabIDs == [sibling])
        try browser.session.validate()
    }

    @Test func splitFocusIsWindowLocalAndNeverCopiedAsSavedOrganization() throws {
        let state = session(), source = coordinator(state)
        _ = try #require(source.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        let group = try #require(source.activeSplitGroup)
        let sibling = coordinator(source.session)
        sibling.focusPane(group.panes[1].id)
        sibling.synchronizeSavedItems(from: source.session)
        #expect(source.focusedTabID == state.tabs[0].id && sibling.focusedTabID == state.tabs[1].id)
        #expect(source.focusedPaneByGroupID != sibling.focusedPaneByGroupID)
        #expect(source.session.openingWindow(at: state.tabs[0].currentURL).splitGroups.isEmpty)
        #expect(source.session.savedItemsOnly.splitGroups.isEmpty)
        #expect(source.session.savedItemsOnly.focusedPaneByGroupID.isEmpty)
    }

    @Test func spaceMovesPruneBrokenGroupsWithoutChangingTabIdentity() throws {
        let state = session(), browser = coordinator(state)
        _ = try #require(browser.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        #expect(browser.moveTab(state.tabs[1].id, toSpace: state.spaces[1].id))
        #expect(browser.splitGroups.isEmpty && browser.focusedPaneByGroupID.isEmpty)
        #expect(browser.tabStore.tab(id: state.tabs[1].id)?.spaceID == state.spaces[1].id)
        try browser.session.validate()

        let source = coordinator(state)
        _ = try #require(source.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        var workspace = BrowserWorkspace(session: source.session)
        let created = workspace.createProfile(name: "Other")
        let destination = try #require(created)
        #expect(workspace.moveSpace(state.activeSpaceID, from: state.profileID, to: destination) == true)
        #expect(workspace.session(for: state.profileID)?.splitGroups.isEmpty == true)
        #expect(workspace.session(for: destination)?.splitGroups.isEmpty == true)
        try workspace.validate()
    }

    @Test func emptySelectionDoesNotSelectASplitOnRestoration() throws {
        let state = session(), browser = coordinator(state)
        _ = try #require(browser.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        var saved = browser.session
        saved.selectionBySpace = [:]
        let restored = coordinator(saved)
        #expect(restored.content == .empty && restored.focusedTabID == nil && restored.visibleTabIDs.isEmpty)
        #expect(restored.splitGroups.count == 1)
    }

    @Test func splitWindowsPersistAtomicallyWithoutSharingTheirFocus() async throws {
        let state = session(), first = coordinator(state)
        _ = try #require(first.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        let group = try #require(first.activeSplitGroup)
        let second = coordinator(first.session)
        second.focusPane(group.panes[1].id)
        var saved = first.session
        saved.additionalWindows = [second.session]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlySplitTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(fileURL: directory.appendingPathComponent("session.sqlite"))
        try await repository.save(saved, revision: 1)
        let restored = try #require(try await repository.load())
        #expect(restored == saved)
        #expect(coordinator(restored).focusedTabID == state.tabs[0].id)
        #expect(coordinator(restored.additionalWindows[0]).focusedTabID == state.tabs[1].id)
    }

    @Test func malformedOptionalLayoutDoesNotPreventRestoringOrdinaryTabs() throws {
        let state = session()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["splitGroups"] = [["panes": "invalid"]]
        json["focusedPaneByGroupID"] = "invalid"
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == state)
        try decoded.validate()
    }

    @Test func closingAFavoriteOutsideItsSplitSpaceNeverSelectsAForeignPane() throws {
        var state = session()
        state.tabs[0].pinnedURL = state.tabs[0].currentURL
        state.tabs[0].isFavorite = true
        let browser = coordinator(state)
        _ = try #require(browser.createSplit(between: state.tabs[0].id, and: state.tabs[1].id))
        browser.switchSpace(to: state.spaces[1].id)
        browser.openTab(state.tabs[0].id)
        browser.closeActiveTab()
        #expect(browser.focusedTabID == state.tabs[3].id)
        #expect(browser.splitGroups.isEmpty)
        try browser.session.validate()
    }

    @Test func deletingAFolderCollapsesItsSplitToTheUnremovedPane() throws {
        let state = session(), browser = coordinator(state)
        let folder = try #require(browser.createFolder(name: "Remove"))
        #expect(browser.moveTab(state.tabs[0].id, toFolder: folder))
        _ = try #require(browser.createSplit(between: state.tabs[0].id, and: state.tabs[2].id))
        #expect(browser.deleteFolder(folder) == [state.tabs[0].id])
        #expect(browser.focusedTabID == state.tabs[2].id && browser.splitGroups.isEmpty)
        #expect(browser.tabStore.tab(id: state.tabs[0].id) == nil)
        try browser.session.validate()
    }
}
