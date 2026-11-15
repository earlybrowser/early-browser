// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing

/// Deterministic approval/admission timing; real navigation and adoption also
/// run in DownloadStoreTests. These fixtures never start a network request.
@Suite(.serialized) @MainActor
struct AutomaticDownloadApprovalTests {
    @MainActor private final class Fixture {
        let manager: WebViewManager
        let store: SitePermissions
        let tab: BrowserTab
        let page: BrowserPage
        let url = URL(string: "https://downloads.example/file")!
        let origin = "https://downloads.example"
        let request = NSObject()
        var replies: [Bool] = []
        var answer: (@MainActor (Bool?) -> Void)?
        init(downloads: DownloadStore = DownloadStore(), permissions: SitePermissions = SitePermissions(fileURL: nil)) {
            _ = NSApplication.shared
            store = permissions
            let profile = UUID()
            manager = WebViewManager(profileID: profile, ephemeral: true, downloads: downloads, observesMemoryPressure: false)
            manager.sitePermissions = permissions
            tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Downloads", currentURL: url)
            page = manager.prepare(tab)
            manager.askForDownloads = { [weak self] _, reply in self?.answer = reply }
        }
        func ask(_ request: NSObject? = nil) {
            manager.decideAutomaticDownload(url, in: page.view, id: tab.id, request: request ?? self.request) { self.replies.append($0) }
        }
        func cleanup() { manager.discardAll() }
        func fillCapacity() {
            // A synthetic active transfer exercises the real store's capacity
            // accounting without waiting on network traffic.
            for _ in 0..<WebViewManager.automaticDownloadLimit {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyAdmission-\(UUID()).bin")
                manager.downloads.recordSavedFile(at: file, source: nil).state = .downloading
            }
        }
    }

    enum Change: CaseIterable { case block, blockThenAsk, storeReplacement, navigation, close, processEnd }

    @Test(arguments: Change.allCases)
    func aLateAllowCannotRestoreAnObsoletePermission(change: Change) throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.ask()
        let answer = try #require(fixture.answer)
        switch change {
        case .block: fixture.store.set(.block, for: [.downloads], origin: fixture.origin)
        case .blockThenAsk:
            fixture.store.set(.block, for: [.downloads], origin: fixture.origin)
            fixture.store.set(.ask, for: [.downloads], origin: fixture.origin)
        case .storeReplacement: fixture.manager.sitePermissions = SitePermissions(fileURL: nil)
        case .navigation: fixture.manager.beginLoading(fixture.tab.id)
        case .close: fixture.manager.discardAll()
        case .processEnd: fixture.page.processTerminated = true
        }
        answer(true)
        answer(true) // A duplicate callback must not settle twice.
        #expect(fixture.replies == [false])
        #expect(fixture.store.decision(for: fixture.origin, .downloads) == (change == .block ? .block : .ask))
        #expect(fixture.manager.downloadAuthorizations.isEmpty)
        #expect(fixture.manager.downloads.canReserveAutomaticDownload)
    }

    @Test func ordinaryAllowWorksOnceAndDismissalSavesNothing() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.ask()
        let allow = try #require(fixture.answer)
        allow(true)
        #expect(fixture.replies == [true] && fixture.store.decision(for: fixture.origin, .downloads) == .allow)
        #expect(fixture.manager.consumeDownloadAuthorization(fixture.request))
        #expect(!fixture.manager.consumeDownloadAuthorization(fixture.request))
        fixture.store.set(.ask, for: [.downloads], origin: fixture.origin)
        fixture.ask()
        let dismiss = try #require(fixture.answer)
        dismiss(nil)
        #expect(fixture.replies == [true, false] && fixture.store.decision(for: fixture.origin, .downloads) == .ask)
    }

    @Test func capacityIsRecheckedWhenThePromptIsAnswered() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.ask()
        fixture.fillCapacity()
        let allow = try #require(fixture.answer)
        allow(true)
        #expect(fixture.replies == [false])
        #expect(fixture.store.decision(for: fixture.origin, .downloads) == .ask)
        #expect(fixture.page.navigationNotice?.contains("many are running") == true)
    }

    @Test func overlappingWindowsReserveOnlySixAutomaticAdmissions() {
        let downloads = DownloadStore(), permissions = SitePermissions(fileURL: nil)
        let first = Fixture(downloads: downloads, permissions: permissions), second = Fixture(downloads: downloads, permissions: permissions)
        defer { first.cleanup(); second.cleanup() }
        permissions.set(.allow, for: [.downloads], origin: first.origin)
        let requests = (0..<8).map { _ in NSObject() }
        for index in requests.indices { (index.isMultiple(of: 2) ? first : second).ask(requests[index]) }
        #expect(first.replies == [true, true, true, false])
        #expect(second.replies == [true, true, true, false])
        #expect(!downloads.canReserveAutomaticDownload && downloads.activeCount == 0,
                "Authorized but not yet adopted transfers still consume capacity")
        first.manager.beginLoading(first.tab.id)
        #expect(!first.manager.consumeDownloadAuthorization(requests[0]))
        #expect(downloads.canReserveAutomaticDownload, "Navigation releases outstanding reservations")
        second.ask(NSObject())
        #expect(second.replies.last == true)
    }

    @Test func adoptionChecksNewBlocksAndNewUserInitiatedTransfers() {
        for block in [true, false] {
            let fixture = Fixture()
            defer { fixture.cleanup() }
            fixture.store.set(.allow, for: [.downloads], origin: fixture.origin)
            fixture.ask()
            #expect(fixture.replies == [true])
            if block { fixture.store.set(.block, for: [.downloads], origin: fixture.origin) }
            else { fixture.fillCapacity() }
            #expect(!fixture.manager.consumeDownloadAuthorization(fixture.request))
            let clicked = NSObject()
            fixture.manager.authorizeDownload(clicked, tabID: fixture.tab.id)
            #expect(fixture.manager.consumeDownloadAuthorization(clicked), "Explicit user downloads keep their exemption")
        }
    }
}
