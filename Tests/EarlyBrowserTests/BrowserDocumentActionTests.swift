// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
@testable import EarlyWeb
import Testing

/// Window-level downloads, file opening and document commands without
/// presenting windows, panels or print sheets. Local fixture pages only.
@Suite(.serialized) @MainActor
struct BrowserDocumentActionTests {
    @MainActor private final class Fixture {
        let suite = "local.early.tests.documents.\(UUID())"
        let defaults: UserDefaults
        let model: BrowserWindowModel

        init(session: BrowserSession = BrowserSession()) {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "onlineSearchSuggestions")
            let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])
            let repository = SessionRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("EarlyDocuments-\(UUID()).sqlite"), input: input)
            model = BrowserWindowModel(startup: .returningSession, session: session, repository: repository,
                input: input, isTesting: true, restorationError: nil, defaults: defaults)
        }

        func cleanup() {
            model.cancelCommandBarQueries()
            model.webViews.discardAll()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test func openedAndDroppedLocationsBecomeNewTodayTabsWithoutReplacingSavedPages() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let pinned = try #require(model.openLocations([URL(string: "early-test://fixture/one")!]) ? model.coordinator.activeTabID : nil)
        model.setPinned(pinned, pinned: true)
        #expect(model.perform(.presentCommandBar(.newTab)))
        let urls = (0..<12).map { URL(string: "early-test://fixture/two?item=\($0)")! }
            + [URL(string: "javascript:alert(1)")!, URL(string: "ftp://example.com/file")!]
        #expect(model.openLocations(urls))
        let today = model.todayTabs
        #expect(today.count == 10, "Drops are bounded to ten new tabs")
        #expect(model.coordinator.activeTabID == today.last?.id && model.coordinator.commandBar == nil)
        #expect(model.coordinator.tabStore.tab(id: pinned)?.currentURL == URL(string: "early-test://fixture/one")!)
        #expect(!model.openLocations([URL(string: "javascript:alert(1)")!]), "Nothing valid, nothing opened")
    }

    @Test func documentCommandsShareAvailabilityWithMenusAndTheCommandBar() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        #expect(model.openLocations([URL(string: "early-test://fixture/one")!]))
        // Without a window there is nowhere to attach a print or save sheet.
        for action in [BrowserAction.savePage, .exportPDF, .printPage] {
            #expect(!model.canPerform(action) && !model.perform(action))
        }
        #expect(model.canPerform(.openFile) && model.canPerform(.showDownloads))
        #expect(model.perform(.showDownloads) && model.downloadsPresented)
        let titles = model.commandSearchCandidates().map(\.title)
        #expect(titles.contains("Show Downloads") && titles.contains("Open File…"))
        #expect(!titles.contains("Print Page…") && !titles.contains("Save Page As…"))
        model.documentPanelIsPresented = true
        #expect(!model.canPerform(.showDownloads) && !model.canPerform(.newWindow), "An open panel blocks other commands")
    }

    @Test func downloadConfirmationAppearsOnlyWhileTheSidebarIsHidden() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let item = DownloadItem(source: URL(string: "https://example.com/a.zip"), origin: nil, requestedDestination: nil, listed: true)
        model.sidebarIsHidden = false
        model.webViews.onDownloadStarted?(item)
        #expect(model.toast == nil, "The visible footer already shows progress")
        model.sidebarIsHidden = true
        model.webViews.onDownloadStarted?(item)
        #expect(model.toast?.kind == .downloadStarted && model.toast?.message == "Download Started")
    }

    @Test func downloadStatusTextDescribesEachState() {
        let item = DownloadItem(source: URL(string: "https://files.example.com/a.zip"), origin: nil, requestedDestination: nil, listed: true)
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Starting…")
        item.state = .downloading
        item.completedBytes = 1_000_000
        item.expectedBytes = 4_000_000
        #expect(DownloadStatus.text(for: item, fileExists: false).contains(" of "))
        item.state = .finished
        #expect(DownloadStatus.text(for: item, fileExists: true).hasSuffix("— files.example.com"))
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Moved or deleted")
        item.state = .failed
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Failed")
        item.state = .cancelled
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Cancelled")
        #expect(item.filename == "a.zip")
    }
}
