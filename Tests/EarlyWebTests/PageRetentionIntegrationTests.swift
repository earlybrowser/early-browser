// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct PageRetentionIntegrationTests {
    @Test func preparedPagesUseBoundedRecencyAndEveryVisibleSplitPaneSurvives() throws {
        let profile = UUID(), manager = manager(profile: profile, allowance: 2)
        defer { manager.discardAll() }
        let tabs = (0..<5).map { tab(profile: profile, path: String($0)) }
        manager.reconcile(tabs: tabs)
        manager.setPresentation(visibleTabIDs: [tabs[0].id, tabs[1].id], focusedTabID: tabs[0].id)
        let pages = tabs.map { manager.prepare($0) }
        #expect(manager.enforceRetention() == [tabs[2].id])
        #expect(manager.liveViewCount == 4 && manager.creationCount == 5)
        #expect(manager.pages[tabs[0].id] === pages[0] && manager.pages[tabs[1].id] === pages[1])
        #expect(manager.focusedTabID == tabs[0].id && manager.visibleTabIDs == [tabs[0].id, tabs[1].id])
        #expect(manager.lifecycle(for: tabs[2].id).state == .discarded)
        #expect(pages[2].view.navigationDelegate == nil && pages[2].view.uiDelegate == nil)

        manager.setPresentation(visibleTabIDs: [tabs[3].id], focusedTabID: tabs[3].id)
        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        #expect(manager.enforceRetention() == [tabs[0].id, tabs[1].id])
        #expect(manager.pages[tabs[3].id] === pages[3] && manager.pages[tabs[4].id] === pages[4])
        #expect(manager.creationCount == 5 && manager.registeredControllerCount == 2)
        #expect(manager.enforceRetention().isEmpty)
    }

    @Test func loadingMediaDirtyFormsAndDialogsRemainProtectedUntilTheirOwnersReleaseThem() throws {
        let profile = UUID(), manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        let tabs = (0..<5).map { tab(profile: profile, path: String($0)) }
        manager.reconcile(tabs: tabs)
        let pages = tabs.map { manager.prepare($0) }
        pages[0].isLoading = true
        _ = manager.updateMediaActivity(in: pages[1].view, token: "audio", playing: true)
        manager.updatePageInteraction(in: pages[2].view, token: "edited-frame", removed: false)
        pages[3].hasDialog = true
        #expect(pages[2].hasUnsavedInput && pages[1].isPlayingMedia)
        #expect(manager.enforceRetention() == [tabs[4].id])
        manager.handleMemoryPressure(.critical)
        #expect(manager.liveViewCount == 4)

        pages[0].isLoading = false
        _ = manager.updateMediaActivity(in: pages[1].view, token: "audio", playing: false)
        manager.updatePageInteraction(in: pages[2].view, token: "edited-frame", removed: true)
        pages[3].hasDialog = false
        #expect(manager.enforceRetention() == Array(tabs.prefix(4).map(\.id)))
        #expect(manager.liveViewCount == 0 && manager.registeredControllerCount == 0)
        #expect(manager.updateMediaActivity(in: pages[1].view, token: "late", playing: true) == nil)
        manager.updatePageInteraction(in: pages[2].view, token: "late-edit", removed: false)
        #expect(manager.liveViewCount == 0)
    }

    @Test func independentDownloadAndInteractionLeasesCannotReleaseEachOthersProtection() throws {
        let profile = UUID(), manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        let tab = tab(profile: profile)
        manager.reconcile(tabs: [tab])
        manager.prepare(tab)
        let first = try #require(manager.protect(tabID: tab.id, reason: .download))
        let second = try #require(manager.protect(tabID: tab.id, reason: .download))
        let interaction = try #require(manager.protect(tabID: tab.id, reason: .interaction))
        manager.handleMemoryPressure(.critical)
        #expect(manager.liveViewCount == 1)
        manager.releaseProtection(tabID: tab.id, token: first)
        #expect(manager.enforceRetention().isEmpty)
        manager.releaseProtection(tabID: tab.id, token: second)
        #expect(manager.enforceRetention().isEmpty)
        manager.releaseProtection(tabID: tab.id, token: interaction)
        #expect(manager.enforceRetention() == [tab.id])
        #expect(manager.protect(tabID: tab.id, reason: .download) == nil)

        manager.prepare(tab)
        let replacementLease = try #require(manager.protect(tabID: tab.id, reason: .download))
        manager.releaseProtection(tabID: tab.id, token: first)
        manager.releaseProtection(tabID: tab.id, token: second)
        #expect(manager.enforceRetention().isEmpty)
        manager.releaseProtection(tabID: tab.id, token: replacementLease)
        #expect(manager.enforceRetention() == [tab.id])
        #expect(manager.creationCount == 2)
    }

    @Test func metadataCallbackCanProtectOrSelectAnEvictionCandidateBeforeItsViewIsReleased() async throws {
        let profile = UUID(), manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        let tab = tab(profile: profile)
        manager.reconcile(tabs: [tab])
        manager.interactionInProgress = true
        manager.load(tab.currentURL, in: tab)
        let page = try #require(manager.pages[tab.id])
        try await waitUntil { !page.isLoading && page.view.title == "Retention fixture" }
        var updates = 0
        var lease: UUID?
        manager.onMetadata = { id, _, _ in
            updates += 1
            manager.setPresentation(visibleTabIDs: [id], focusedTabID: id)
        }
        // Make one report stale without depending on KVO-task scheduling. The
        // title read itself remains the real local document's native title.
        page.reportedTitle = "Prior title"
        manager.interactionInProgress = false
        #expect(manager.enforceRetention().isEmpty)
        #expect(updates == 1 && manager.pages[tab.id] === page && manager.focusedTabID == tab.id)

        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        manager.onMetadata = { id, _, _ in
            updates += 1
            lease = manager.protect(tabID: id, reason: .download)
        }
        page.reportedTitle = "Another prior title"
        #expect(manager.enforceRetention().isEmpty)
        #expect(updates == 2 && lease != nil && manager.pages[tab.id] === page)
        manager.onMetadata = nil
        let token = try #require(lease)
        manager.releaseProtection(tabID: tab.id, token: token)
        #expect(manager.enforceRetention() == [tab.id])
    }

    @Test func mutedChoiceSurvivesPolicyEvictionButClosingTheTabClearsIt() throws {
        let profile = UUID(), manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        let tab = tab(profile: profile)
        manager.reconcile(tabs: [tab])
        let original = manager.prepare(tab)
        #expect(manager.setMuted(true, for: tab.id))
        #expect(original.isMuted && manager.enforceRetention() == [tab.id])
        let resumed = manager.prepare(tab)
        #expect(resumed !== original && resumed.isMuted)
        #expect(manager.updateMediaActivity(in: resumed.view, token: "restored-frame", playing: false)?["muted"] as? Bool == true)
        manager.discard(tabID: tab.id)
        let reopened = manager.prepare(tab)
        #expect(reopened !== resumed && !reopened.isMuted)
        #expect(manager.creationCount == 3)
    }

    @Test func browserInteractionDefersEvictionAndReleasesTheWholeBatchAfterward() {
        let profile = UUID(), manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        let tabs = (0..<3).map { tab(profile: profile, path: String($0)) }
        manager.reconcile(tabs: tabs)
        manager.interactionInProgress = true
        for tab in tabs { manager.prepare(tab) }
        manager.handleMemoryPressure(.critical)
        #expect(manager.enforceRetention().isEmpty && manager.liveViewCount == 3)
        manager.interactionInProgress = false
        #expect(manager.enforceRetention() == tabs.map(\.id))
        #expect(manager.liveViewCount == 0 && manager.creationCount == 3)
    }

    @Test func closedPinsAndSnapshotReadsStayMetadataOnly() {
        let profile = UUID(), manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        let tabs = (0..<80).map { number in
            var tab = tab(profile: profile, path: "saved-\(number)")
            tab.pinnedURL = tab.currentURL
            tab.isOpen = false
            return tab
        }
        #expect(manager.reconcile(tabs: tabs))
        for tab in tabs { #expect(manager.snapshots.image(for: tab.id) == nil) }
        manager.handleMemoryPressure(.critical)
        #expect(manager.enforceRetention().isEmpty)
        #expect(manager.creationCount == 0 && manager.liveViewCount == 0)
        #expect(manager.snapshots.count == 0 && manager.snapshots.pendingCount == 0)
        #expect(manager.lifecycles.values.allSatisfy { $0.state == .unloaded })
        manager.reconcile(tabs: [])
        #expect(manager.lifecycles.isEmpty)
    }

    @Test func discardedPageRecreatesOnlyOnActivationWithoutChangingSavedOrganization() async throws {
        let profile = UUID(), space = UUID(), folder = BrowserFolder(spaceID: space, name: "Research")
        var saved = tab(profile: profile, space: space, path: "visited")
        saved.pinnedURL = URL(string: "early-retention://fixture/original")!
        saved.pinnedTitle = "Original"
        saved.customTitle = "My research"
        saved.folderID = folder.id
        saved.sidebarPosition = 7
        let other = tab(profile: profile, space: space, path: "other")
        var store = TabStore(tabs: [saved, other], folders: [folder])
        let original = store
        let manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        manager.onMetadata = { id, url, title in _ = store.update(id, url: url, title: title) }
        manager.reconcile(tabs: store.tabs)
        manager.setPresentation(visibleTabIDs: [other.id], focusedTabID: other.id)
        let retired = manager.prepare(saved)
        let otherPage = manager.prepare(other)
        #expect(manager.enforceRetention() == [saved.id])
        #expect(manager.pages[other.id] === otherPage && manager.creationCount == 2)
        #expect(store == original)
        #expect(manager.snapshots.image(for: saved.id) == nil && manager.creationCount == 2)

        manager.reconcile(tabs: store.tabs)
        #expect(manager.pages[saved.id] == nil && manager.creationCount == 2)
        manager.setPresentation(visibleTabIDs: [saved.id], focusedTabID: saved.id)
        manager.activate(saved)
        let replacement = try #require(manager.pages[saved.id])
        #expect(replacement !== retired && replacement.view !== retired.view)
        #expect(manager.creationCount == 3)
        try await waitUntil {
            replacement.view.url == saved.currentURL && replacement.view.title == "Retention fixture"
                && !replacement.isLoading && manager.lifecycle(for: saved.id).state == .active
        }
        let restored = try #require(store.tab(id: saved.id))
        #expect(restored.id == saved.id && restored.currentURL == saved.currentURL)
        #expect(restored.pinnedURL == saved.pinnedURL && restored.pinnedTitle == saved.pinnedTitle)
        #expect(restored.customTitle == saved.customTitle && restored.folderID == folder.id)
        #expect(restored.spaceID == space && restored.profileID == profile && restored.sidebarPosition == 7)
        #expect(restored.isOpen && store.tabs.map(\.id) == original.tabs.map(\.id) && store.folders == original.folders)
        #expect(manager.focusedTabID == saved.id && manager.visibleTabIDs == [saved.id])
    }

    @Test func memoryPressureShrinksInactiveBudgetWhileKeepingAllVisibleMembers() {
        let profile = UUID(), manager = manager(profile: profile, allowance: 4)
        defer { manager.discardAll() }
        let tabs = (0..<8).map { tab(profile: profile, path: String($0)) }
        manager.reconcile(tabs: tabs)
        manager.setPresentation(visibleTabIDs: [tabs[0].id, tabs[1].id], focusedTabID: tabs[1].id)
        for tab in tabs { manager.prepare(tab) }
        #expect(manager.enforceRetention() == [tabs[2].id, tabs[3].id])
        manager.handleMemoryPressure(.warning)
        #expect(Set(manager.pages.keys) == Set([tabs[0].id, tabs[1].id, tabs[6].id, tabs[7].id]))
        manager.handleMemoryPressure(.critical)
        #expect(Set(manager.pages.keys) == Set([tabs[0].id, tabs[1].id]))
        #expect(manager.creationCount == 8 && manager.focusedTabID == tabs[1].id)
        manager.setPresentation(visibleTabIDs: [], focusedTabID: nil)
        #expect(Set(manager.enforceRetention()) == Set([tabs[0].id, tabs[1].id]))
        #expect(manager.liveViewCount == 0 && manager.registeredControllerCount == 0)
    }

    @Test func repeatedDiscardRecreationAndCloseLeaveNoRuntimeOwnersOrProtectionLeases() throws {
        let profile = UUID(), manager = manager(profile: profile, allowance: 0)
        defer { manager.discardAll() }
        for number in 0..<16 {
            try autoreleasepool {
                let tab = tab(profile: profile, path: String(number))
                manager.reconcile(tabs: [tab])
                weak var owner: BrowserPage?
                do {
                    let page = manager.prepare(tab)
                    owner = page
                    let lease = try #require(manager.protect(tabID: tab.id, reason: .download))
                    manager.discard(tabID: tab.id)
                    manager.releaseProtection(tabID: tab.id, token: lease)
                    #expect(page.view.navigationDelegate == nil && page.view.uiDelegate == nil)
                }
                #expect(owner == nil)
                manager.prepare(tab)
                #expect(manager.enforceRetention() == [tab.id])
                manager.reconcile(tabs: [])
                #expect(manager.lifecycles.isEmpty && manager.liveViewCount == 0)
                #expect(manager.registeredControllerCount == 0 && manager.snapshots.count == 0)
            }
        }
        #expect(manager.creationCount == 32)
    }

    private func manager(profile: UUID, allowance: Int) -> WebViewManager {
        _ = NSApplication.shared
        return WebViewManager(profileID: profile, ephemeral: true,
            input: NavigationInput(allowedSchemes: ["early-retention"]),
            faviconStore: FaviconStore { _, _, _ in nil },
            retentionPolicy: PageRetentionPolicy(maximumInactivePages: allowance),
            observesMemoryPressure: false) {
            $0.setURLSchemeHandler(RetentionPages(), forURLScheme: "early-retention")
        }
    }

    private func tab(profile: UUID, space: UUID = UUID(), path: String = "one") -> BrowserTab {
        BrowserTab(spaceID: space, profileID: profile, title: path,
                   currentURL: URL(string: "early-retention://fixture/\(path)")!)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RetentionPages.Failure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class RetentionPages: NSObject, WKURLSchemeHandler {
    enum Failure: Error { case timeout }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let data = Data("<!doctype html><title>Retention fixture</title><p>Local page</p>".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
