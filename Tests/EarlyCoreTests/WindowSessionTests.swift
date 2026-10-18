import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct WindowSessionTests {
    private func coordinator(_ session: BrowserSession) -> BrowserCoordinator {
        BrowserCoordinator(startup: .returningSession, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders),
            selectionBySpace: session.selectionBySpace, profileID: session.profileID, spaces: session.spaces)
    }

    @Test func newWindowHasOneTodayTabAndUnloadedSavedContents() throws {
        let profile = UUID(), space = UUID()
        let folder = BrowserFolder(spaceID: space, name: "Work")
        let home = URL(string: "https://example.com/")!
        var pin = BrowserTab(spaceID: space, profileID: profile, title: "Live detour",
            currentURL: home.appendingPathComponent("detour"), pinnedURL: home, pinnedTitle: "Home")
        pin.folderID = folder.id
        let favorite = BrowserTab(spaceID: space, profileID: profile, title: "Favorite",
            currentURL: home, pinnedURL: home, isFavorite: true)
        let today = BrowserTab(spaceID: space, profileID: profile, title: "Other", currentURL: home)
        let original = BrowserSession(profileID: profile, activeSpaceID: space,
            tabs: [pin, favorite, today], selectionBySpace: [space: today.id], folders: [folder])
        let child = original.openingWindow(at: pin.currentURL, title: pin.displayTitle)
        try child.validate()
        #expect(child.folders == [folder])
        #expect(child.tabs.count == 3)
        #expect(child.tabs.filter { $0.pinnedURL != nil }.allSatisfy { !$0.isOpen && $0.currentURL == $0.pinnedURL })
        let onlyToday = try #require(child.tabs.first { $0.pinnedURL == nil })
        #expect(onlyToday.id != pin.id && onlyToday.id != today.id)
        #expect(onlyToday.currentURL == pin.currentURL)
        #expect(child.selectionBySpace[space] == onlyToday.id)
        #expect(original.tabs == [pin, favorite, today])
        #expect(child.recentlyClosed.isEmpty)
    }

    @Test func savedOrganizationSharesWithoutNavigationSelectionOrTodayLeakage() throws {
        let source = BrowserCoordinator(startup: .returningSession)
        let home = URL(string: "https://example.com/")!
        let pin = try #require(source.navigate(to: home, target: .newTab(spaceID: source.activeSpaceID)))
        source.setPinned(pin, pinned: true)
        let child = coordinator(source.session.openingWindow(at: home.appendingPathComponent("child")))
        let today = try #require(child.activeTabID)
        child.openTab(pin)
        let detour = home.appendingPathComponent("child-detour")
        child.navigate(to: detour, target: .currentTab(pin))
        source.renameTab(pin, to: "Shared name")
        source.setFavorite(pin, favorite: true)
        child.synchronizeSavedItems(from: source.session)
        #expect(child.activeTabID == pin)
        #expect(child.tabStore.tab(id: pin)?.currentURL == detour)
        #expect(child.tabStore.tab(id: pin)?.isFavorite == true)
        #expect(child.tabStore.tab(id: pin)?.displayTitle == "Shared name")
        #expect(child.tabStore.todayTabs(in: child.activeSpaceID).map(\.id) == [today])
        source.synchronizeSavedItems(from: child.session)
        #expect(source.tabStore.tab(id: pin)?.currentURL == home)
        #expect(source.tabStore.tab(id: today) == nil)
        source.setFavorite(pin, favorite: false)
        child.synchronizeSavedItems(from: source.session)
        #expect(child.tabStore.tab(id: pin)?.pinnedURL == nil)
        #expect(child.tabStore.tab(id: pin)?.currentURL == detour)
        #expect(child.activeTabID == pin)
        try child.session.validate()
    }

    @Test func windowSnapshotsRoundTripAndRejectForeignOrNestedWindows() throws {
        var root = BrowserSession()
        root.additionalWindows = [root.openingWindow(at: URL(string: "https://example.com")!)]
        try root.validate()
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(root))
        #expect(decoded == root)
        var invalid = root
        invalid.additionalWindows[0].additionalWindows = root.additionalWindows
        #expect(throws: SessionError.self) { try invalid.validate() }
        invalid = root
        invalid.additionalWindows[0].profileID = UUID()
        #expect(throws: SessionError.self) { try invalid.validate() }
    }

    @Test func windowSnapshotsPersistTogetherAndLegacySnapshotsStillDecode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyWindowTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(fileURL: directory.appendingPathComponent("session.sqlite"))
        var root = BrowserSession()
        root.additionalWindows = [root.openingWindow(at: URL(string: "https://example.com/child")!)]
        try await repository.save(root, revision: 1)
        #expect(try await repository.load() == root)
        root.additionalWindows = []
        try await repository.save(root, revision: 2)
        #expect(try await repository.load() == root)
        let encoded = try JSONEncoder().encode(root)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "additionalWindows")
        let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.additionalWindows.isEmpty)
        #expect(restored == root)
    }

    @Test func deletingSharedFolderRemovesItsPagesButNotLocalTodayOrOtherProfile() throws {
        let source = BrowserCoordinator(startup: .returningSession)
        let home = URL(string: "https://example.com")!
        let folder = try #require(source.createFolder(name: "Shared"))
        let pin = try #require(source.navigate(to: home, target: .newTab(spaceID: source.activeSpaceID)))
        source.moveTab(pin, toFolder: folder)
        let child = coordinator(source.session.openingWindow(at: home))
        let local = try #require(child.activeTabID)
        child.openTab(pin)
        source.deleteFolder(folder)
        child.synchronizeSavedItems(from: source.session)
        #expect(child.tabStore.tab(id: pin) == nil)
        #expect(child.tabStore.tab(id: local) != nil)
        #expect(child.activeTabID == nil)
        #expect(child.folders.isEmpty)
        let previous = child.session
        child.synchronizeSavedItems(from: BrowserSession())
        #expect(child.session == previous)
        try child.session.validate()
    }

    @Test func sidebarWidthIsBoundedAndRejectsNonFiniteValues() {
        #expect(SidebarWidth.defaultValue == 240)
        #expect(SidebarWidth.clamped(-1000) == SidebarWidth.minimum)
        #expect(SidebarWidth.clamped(1000) == SidebarWidth.maximum)
        #expect(SidebarWidth.clamped(278) == 278)
        #expect(SidebarWidth.clamped(.nan) == SidebarWidth.defaultValue)
        #expect(SidebarWidth.clamped(.infinity) == SidebarWidth.defaultValue)
    }
}
