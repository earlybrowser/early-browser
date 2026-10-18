// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing

@Suite @MainActor
struct SpaceLifecycleTests {
    @Test func movingFolderKeepsLiveViewsAndDoesNotLoadItsClosedPins() throws {
        _ = NSApplication.shared
        let browser = BrowserCoordinator(startup: .returningSession)
        let manager = WebViewManager(profileID: browser.profileID, ephemeral: true)
        defer { manager.discardAll() }
        let folder = try #require(browser.createFolder(name: "Move"))
        let nested = try #require(browser.createFolder(name: "Nested", parentID: folder))
        let url = URL(string: "https://example.com/")!
        let live = try #require(browser.navigate(to: url, target: .newTab(spaceID: browser.activeSpaceID)))
        browser.moveTab(live, toFolder: folder)
        let view = manager.prepare(try #require(browser.tabStore.tab(id: live))).view
        let closed = try #require(browser.navigate(to: url, target: .newTab(spaceID: browser.activeSpaceID)))
        browser.moveTab(closed, toFolder: nested)
        browser.closeTab(closed)
        let destination = try #require(browser.createSpace(name: "Destination"))
        #expect(browser.moveFolder(folder, toSpace: destination, follow: true))
        #expect(browser.activeSpaceID == destination && browser.activeTabID == live)
        #expect(manager.creationCount == 1 && manager.liveViewCount == 1)
        #expect(manager.existingView(for: closed) == nil)
        #expect(manager.prepare(try #require(browser.tabStore.tab(id: live))).view === view)
        browser.switchSpace(to: destination)
        browser.openTab(live)
        manager.activate(try #require(browser.tabStore.tab(id: live)))
        #expect(manager.existingView(for: live) === view && manager.creationCount == 1)
    }

    @Test func spacesDoNotAllocateViewsAndMovingPinKeepsTheSameLiveView() throws {
        _ = NSApplication.shared
        let browser = BrowserCoordinator(startup: .returningSession)
        let manager = WebViewManager(profileID: browser.profileID, ephemeral: true)
        defer { manager.discardAll() }
        let original = browser.activeSpaceID
        let empty = try #require(browser.createSpace(name: "Empty"))
        browser.switchSpace(to: empty)
        #expect(browser.activeTabID == nil && manager.liveViewCount == 0)
        browser.switchSpace(to: original)
        let id = try #require(browser.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: original)))
        browser.setPinned(id, pinned: true)
        let view = manager.prepare(try #require(browser.tabStore.tab(id: id))).view
        let copy = try #require(browser.duplicateSpace(original, name: "Copy"))
        browser.switchSpace(to: copy)
        #expect(browser.activeTabID == nil && manager.creationCount == 1)
        #expect(manager.liveViewCount == 1)
        #expect(browser.moveTab(id, toSpace: empty))
        #expect(manager.prepare(try #require(browser.tabStore.tab(id: id))).view === view)
        #expect(manager.creationCount == 1)
        browser.switchSpace(to: empty)
        browser.openTab(id)
        manager.activate(try #require(browser.tabStore.tab(id: id)))
        #expect(manager.existingView(for: id) === view)
        let removed = try #require(browser.deleteSpace(empty))
        for removedID in removed { manager.discard(tabID: removedID) }
        #expect(removed == Set([id]) && manager.liveViewCount == 0)
        #expect(manager.creationCount == 1 && browser.activeTabID == nil)
    }
}
