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

    @Test func downloadRingStartsFromZeroOnlyGrowsAndNeverInventsProgress() {
        #expect(DownloadRing.next(current: 0, active: true, progress: nil) == 0, "Unknown size shows no fake progress")
        #expect(DownloadRing.next(current: 0, active: true, progress: 0.4) == 0.4)
        #expect(DownloadRing.next(current: 0.6, active: true, progress: 0.3) == 0.6, "A newly added download cannot shrink the ring")
        #expect(DownloadRing.next(current: 0.6, active: true, progress: 1.4) == 1)
        #expect(DownloadRing.next(current: 0.8, active: false, progress: 0.8) == 0, "The next burst starts again from zero")
    }

    @Test func onlyARecentPageClickFliesToAVisibleDownloadsButton() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let item = DownloadItem(source: URL(string: "https://example.com/files/report.pdf"), origin: nil, requestedDestination: nil, listed: true)
        let now = Date()
        model.prefersReducedMotion = { false }
        model.sidebarIsHidden = false
        model.downloadsButtonFrame = CGRect(x: 20, y: 600, width: 28, height: 28)

        model.beginDownloadFlight(now: now)
        #expect(model.downloadFlight == nil, "No click, no flight")
        model.recordPagePress(at: CGPoint(x: 500, y: 300), time: now.addingTimeInterval(-5))
        model.beginDownloadFlight(now: now)
        #expect(model.downloadFlight == nil, "A stale click does not fly")
        model.recordPagePress(at: CGPoint(x: 500, y: 300), time: now.addingTimeInterval(-0.2))
        model.sidebarIsHidden = true
        model.beginDownloadFlight(now: now)
        #expect(model.downloadFlight == nil, "No visible button to land on")
        model.sidebarIsHidden = false
        model.prefersReducedMotion = { true }
        model.recordPagePress(at: CGPoint(x: 500, y: 300), time: now.addingTimeInterval(-0.2))
        model.beginDownloadFlight(now: now)
        #expect(model.downloadFlight == nil, "Reduce Motion skips the flight")
        model.prefersReducedMotion = { false }

        model.recordPagePress(at: CGPoint(x: 500, y: 300))
        model.webViews.onDownloadStarted?(item)
        let flight = try #require(model.downloadFlight)
        #expect(flight.start == CGPoint(x: 500, y: 300) && flight.end == CGPoint(x: 34, y: 614))
        model.beginDownloadFlight()
        #expect(model.downloadFlight == flight, "Each click flies once")

        model.finishDownloadFlight(UUID())
        #expect(model.downloadFlight == flight && model.downloadLandingRevision == 0, "A stale landing is ignored")
        model.finishDownloadFlight(flight.id)
        #expect(model.downloadFlight == nil && model.downloadLandingRevision == 1)
    }

    @Test func flightArcsAboveBothEndsAndLandsAtTheButtonIconSize() {
        let start = CGPoint(x: 600, y: 300)
        let end = CGPoint(x: 30, y: 700)
        #expect(DownloadFlightPath.point(at: 0, start: start, end: end) == start)
        #expect(DownloadFlightPath.point(at: 1, start: start, end: end) == end)
        #expect(DownloadFlightPath.point(at: 0.25, start: start, end: end).y < start.y, "Rises before falling")
        let middle = DownloadFlightPath.point(at: 0.5, start: start, end: end)
        #expect(middle.x < start.x && middle.x > end.x)
        #expect(DownloadFlightPath.point(at: 2, start: start, end: end) == end, "Overshoot is clamped")
        let nearTop = CGPoint(x: 600, y: 10)
        #expect((0...10).allSatisfy { DownloadFlightPath.point(at: Double($0) / 10, start: nearTop, end: end).y >= 10 },
                "A click near the top never arcs out of the window")
        #expect(DownloadFlightPath.scale(at: 0) == 1)
        #expect(abs(DownloadFlightPath.scale(at: 1) * DownloadFlightPath.size - 18) < 0.001, "Matches the footer icon")
        #expect(DownloadFlightPath.opacity(at: 0.5) == 1 && DownloadFlightPath.opacity(at: 1) == 0)
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
        item.state = .paused
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Stopping…")
        item.resumeData = Data([1])
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Resume downloading" && item.canResume)
        item.state = .failed
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Interrupted — resume to try again")
        item.resumeData = nil
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Failed" && !item.canResume)
        item.state = .cancelled
        #expect(DownloadStatus.text(for: item, fileExists: false) == "Cancelled")
        #expect(item.filename == "a.zip")
    }
}
