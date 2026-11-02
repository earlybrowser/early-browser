// SPDX-License-Identifier: MPL-2.0

import EarlyCore
@testable import EarlyBrowser
import Foundation
import Testing

@Suite(.serialized) @MainActor
struct CollectionIndexApplicationTests {
    @Test func bulkTabCandidatesKeepScopeMetadataAndWindowGatesWithoutLoadingPages() throws {
        let suite = "local.early.tests.collection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "onlineSearchSuggestions")
        let profile = UUID(), space = UUID(), other = UUID(), root = BrowserFolder(spaceID: space, name: "Root")
        let tabs = (0..<2_000).map { index in
            let url = URL(string: "https://example.invalid/\(index)")!
            var tab = BrowserTab(spaceID: index.isMultiple(of: 2) ? space : other, profileID: profile,
                title: "Pin \(index)", currentURL: url, pinnedURL: url, isOpen: false)
            if tab.spaceID == space { tab.folderID = root.id }
            if index == 1 { tab.isFavorite = true }
            return tab
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyCollection-\(UUID()).sqlite")
        let model = BrowserWindowModel(startup: .returningSession,
            session: BrowserSession(profileID: profile, activeSpaceID: space, tabs: tabs, folders: [root],
                spaces: [BrowserSpace(id: space, profileID: profile, name: "Personal"), BrowserSpace(id: other, profileID: profile, name: "Work")]),
            repository: SessionRepository(fileURL: path), input: NavigationInput(), isTesting: true,
            restorationError: nil, defaults: defaults)
        model.onSave = { _ in }
        defer {
            model.cancelWindowInteractions(); model.cancelCommandBarQueries(); model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + suffix) }
        }
        func candidates() -> [CommandSearchCandidate] { model.commandSearchCandidates().filter { $0.kind.isTab } }
        let expected = [tabs[1]] + tabs.filter { $0.spaceID == space }
        #expect(candidates().map(\.target) == expected.map { .tab($0.id) })
        #expect(candidates().map(\.title) == expected.map(\.displayTitle))
        #expect(model.coordinator.renameTab(tabs[0].id, to: "Updated pin"))
        #expect(candidates().first { $0.target == .tab(tabs[0].id) }?.title == "Updated pin")
        model.sidebarInteractionInProgress = true
        #expect(candidates().isEmpty)
        model.sidebarInteractionInProgress = false
        model.historyPresented = true
        #expect(candidates().isEmpty)
        model.historyPresented = false
        #expect(candidates().count == expected.count)
        #expect(model.perform(.switchSpace(other)))
        #expect(candidates().map(\.target) == ([tabs[1]] + tabs.filter { $0.spaceID == other && !$0.isFavorite }).map { .tab($0.id) })
        #expect(model.webViews.liveViewCount == 0 && model.webViews.creationCount == 0)
    }
}
