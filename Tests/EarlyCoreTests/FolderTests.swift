import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct FolderTests {
    @Test func folderMovesPreserveIdentityAndRoundTrip() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let id = try #require(browser.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: browser.activeSpaceID)))
        let root = try #require(browser.createFolder(name: " Work "))
        let child = try #require(browser.createFolder(name: "Videos", parentID: root))
        #expect(browser.moveTab(id, toFolder: child))
        #expect(browser.activeTabID == id)
        #expect(browser.tabStore.tabs.count == 1)
        #expect(browser.tabStore.tab(id: id)?.pinnedURL != nil)
        #expect(!browser.moveFolder(root, to: child))
        #expect(!browser.moveFolder(root, to: root))
        #expect(!browser.moveFolder(child, to: UUID()))
        #expect(browser.renameFolder(child, to: "Clips"))
        browser.toggleFolder(root)
        var session = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(browser.session))
        try session.validate()
        #expect(session.folders.first?.isExpanded == false)
        #expect(session.folders.last?.name == "Clips")
        #expect(session.tabs.first?.folderID == child)
        let restored = BrowserCoordinator(startup: .returningSession, activeSpaceID: session.activeSpaceID,
            tabStore: TabStore(tabs: session.tabs, folders: session.folders), profileID: session.profileID)
        #expect(restored.moveFolder(child, to: nil))
        #expect(restored.moveTab(id, toFolder: nil))
        #expect(restored.tabStore.tab(id: id)?.pinnedURL != nil)
        #expect(restored.moveTab(id, toFolder: child))
        #expect(restored.setFavorite(id, favorite: true))
        #expect(restored.tabStore.tab(id: id)?.folderID == nil)
        #expect(!restored.moveTab(id, toFolder: child))
        session.folders[0].parentID = child
        #expect(throws: SessionError.self) { try session.validate() }
    }

    @Test func legacySessionsAndFolderBoundaries() throws {
        let old = BrowserSession()
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        payload.removeValue(forKey: "folders")
        let legacy = try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.folders.isEmpty)
        let space = UUID(), other = UUID()
        var store = TabStore()
        let rootResult = store.createFolder(name: "A", parentID: nil, spaceID: space)
        let foreignResult = store.createFolder(name: "B", parentID: nil, spaceID: other)
        let root = try #require(rootResult)
        let foreign = try #require(foreignResult)
        #expect(!store.canMoveFolder(root, to: foreign))
        let invalid = store.createFolder(name: " ", parentID: nil, spaceID: space)
        #expect(invalid == nil)
        var parent = root
        for _ in 1..<32 {
            let result = store.createFolder(name: "Nested", parentID: parent, spaceID: space)
            parent = try #require(result)
        }
        let tooDeep = store.createFolder(name: "Too deep", parentID: parent, spaceID: space)
        #expect(tooDeep == nil)
    }
}
