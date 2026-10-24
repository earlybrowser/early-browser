// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreServices
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Real WebKit downloads of local data: URLs into a temporary folder. Nothing
/// touches the user's Downloads folder or the network.
@Suite(.serialized) @MainActor
struct DownloadStoreTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "early-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store: DownloadStore
        let manager: WebViewManager
        let tab: BrowserTab
        let page: BrowserPage
        var started: [DownloadItem] = []

        @MainActor init(page html: String? = nil) {
            _ = NSApplication.shared
            store = DownloadStore(directory: directory)
            let profile = UUID()
            manager = WebViewManager(profileID: profile, ephemeral: true,
                input: NavigationInput(allowedSchemes: ["http", "https", "early-test"]),
                downloads: store, observesMemoryPressure: false) { configuration in
                configuration.setURLSchemeHandler(LocalPage(html: html ?? "<p>Source</p>"), forURLScheme: "early-test")
            }
            tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Source", currentURL: URL(string: "https://example.com/source")!)
            page = manager.prepare(tab)
            manager.onDownloadStarted = { [unowned self] in self.started.append($0) }
        }

        @MainActor func cleanup() {
            manager.discardAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class LocalPage: NSObject, WKURLSchemeHandler {
        let html: String
        init(html: String) { self.html = html }
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let data = Data("<!doctype html><title>Source</title>\(html)".utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    private enum WaitFailure: Error { case timeout(String) }

    private func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitFailure.timeout(label) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Synchronous on purpose: nothing else on the main thread runs meanwhile.
    private func blockMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private let hello = URL(string: "data:text/plain;base64,aGVsbG8gd29ybGQ=")! // "hello world"

    @Test func filenamesAreSanitizedAndNeverReplaceExistingOrReservedFiles() {
        for suggested in ["../../etc/passwd", ".hidden", "a:b\\c", " \n ", ""] {
            let name = DownloadStore.sanitizedFilename(suggested)
            #expect(!name.contains("/") && !name.contains(":") && !name.hasPrefix(".") && !name.isEmpty, "\(suggested) -> \(name)")
        }
        #expect(DownloadStore.sanitizedFilename("Report.pdf") == "Report.pdf")
        #expect(DownloadStore.sanitizedFilename(String(repeating: "x", count: 300) + ".zip").count <= 200)
        let folder = URL(filePath: "/tmp/early-downloads", directoryHint: .isDirectory)
        let existing: Set<String> = ["/tmp/early-downloads/Report.pdf", "/tmp/early-downloads/Report 2.pdf"]
        let reserved: Set<String> = ["/tmp/early-downloads/Report 3.pdf"]
        let unique = DownloadStore.uniqueDestination(for: "Report.pdf", in: folder, reserved: reserved) { existing.contains($0.path) }
        #expect(unique.lastPathComponent == "Report 4.pdf")
        #expect(DownloadStore.uniqueDestination(for: "notes", in: folder, reserved: []) { $0.lastPathComponent == "notes" }
            .lastPathComponent == "notes 2")
    }

    @Test func downloadFinishesInTheProfileFolderWithQuarantineAndReleasesItsPageProtection() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        var protectedWhileActive = false
        fixture.manager.onDownloadStarted = { [manager = fixture.manager, id = fixture.tab.id] item in
            protectedWhileActive = manager.hasProtection(tabID: id, reason: .download)
            fixture.started.append(item)
        }
        #expect(fixture.manager.startDownload(hello, from: fixture.tab.id))
        try await waitUntil("finished") { fixture.store.items.first?.state == .finished }
        let item = try #require(fixture.store.items.first)
        let destination = try #require(item.destination)
        #expect(destination.deletingLastPathComponent().standardizedFileURL == fixture.directory.standardizedFileURL)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "hello world")
        #expect(item.completedBytes == 11 && item.fractionCompleted == 1)
        #expect(fixture.started.count == 1 && protectedWhileActive, "The page is protected while its download runs")
        #expect(!fixture.manager.hasProtection(tabID: fixture.tab.id, reason: .download))
        #expect(!fixture.store.hasActiveDownloads && item.sourceURL == nil, "data: sources are not kept")
        #expect(fixture.store.startedRevision == 1 && fixture.store.finishedRevision == 1, "The footer reacts to start and finish")
        let quarantine = try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Early")
        #expect(quarantine?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
    }

    @Test func aBusyMainThreadCannotLoseTheDownloadBeforeItsDelegateIsSet() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        for count in 1...3 {
            #expect(fixture.manager.startDownload(hello, from: fixture.tab.id))
            // Let the request go out, then keep the main thread busy so WebKit's
            // start and destination messages arrive together.
            await Task.yield()
            blockMainThread(for: 0.3)
            try await waitUntil("download \(count)") {
                fixture.store.items.count == count && fixture.store.items.allSatisfy { $0.state == .finished }
            }
        }
    }

    @Test func privateDownloadsKeepTheirQuarantineButNotTheAddressesTheyCameFrom() async throws {
        let body = Data("private file".utf8)
        let server = try LocalHTTPServer(body: body, initialChunk: body.count)
        let fixture = Fixture()
        defer { server.stop(); fixture.cleanup() }
        for records in [true, false] {
            fixture.store.recordsSourceAddresses = records
            let count = fixture.store.items.count
            #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id))
            try await waitUntil("download") {
                fixture.store.items.count == count + 1 && fixture.store.items.first?.state == .finished
            }
            let item = try #require(fixture.store.items.first)
            let destination = try #require(item.destination)
            let quarantine = try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Early", "Gatekeeper still checks it")
            // macOS keeps the address in its quarantine-event log, not the file.
            #expect(fixture.store.quarantineAddresses(for: item).source == (records ? server.url : nil),
                    records ? "Ordinary downloads say where they came from" : "Private downloads never do")
        }
    }

    @Test func downloadLinksBecomeUniqueFilesWithoutChangingThePage() async throws {
        let fixture = Fixture(page: "<a id='file' download='note.txt' href='data:text/plain;base64,bm90ZQ=='>Note</a>")
        defer { fixture.cleanup() }
        let source = URL(string: "early-test://fixture/source")!
        fixture.manager.load(source, in: fixture.tab)
        try await waitUntil("page") { !fixture.page.isLoading && fixture.page.view.title == "Source" }
        for count in 1...2 {
            _ = try await fixture.page.view.evaluateJavaScript("document.getElementById('file').click()")
            try await waitUntil("download \(count)") { fixture.store.items.filter { $0.state == .finished }.count == count }
        }
        #expect(Set(fixture.store.items.map(\.filename)) == ["note.txt", "note 2.txt"])
        #expect(fixture.page.view.url == source && fixture.page.requestedURL == source)
        #expect(fixture.page.failure == nil && fixture.page.navigationNotice == nil)
        #expect(fixture.manager.navigationDiagnostics.contains { $0.event == "download-action" })
    }

    @Test func explicitSaveReplacesOnlyTheChosenFileAndIsNotListed() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let chosen = fixture.directory.appending(path: "Chosen.txt")
        let neighbor = fixture.directory.appending(path: "Neighbor.txt")
        try "old".write(to: chosen, atomically: true, encoding: .utf8)
        try "keep".write(to: neighbor, atomically: true, encoding: .utf8)
        var settled: DownloadItem?
        #expect(fixture.manager.startDownload(hello, from: fixture.tab.id, to: chosen, listed: false) { settled = $0 })
        try await waitUntil("saved") { settled != nil }
        #expect(settled?.state == .finished && settled?.destination == chosen)
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "hello world")
        #expect(try String(contentsOf: neighbor, encoding: .utf8) == "keep")
        #expect(fixture.store.items.isEmpty && fixture.started.isEmpty)
        #expect(fixture.store.startedRevision == 0 && fixture.store.finishedRevision == 0, "An internal save stays quiet")
    }

    @Test func stoppingKeepsThePartialFileAndResumeFinishesTheSameFile() async throws {
        let body = Data((0..<600_000).map { UInt8($0 % 251) })
        let server = try LocalHTTPServer(body: body, initialChunk: 120_000)
        let fixture = Fixture()
        defer { server.stop(); fixture.cleanup() }
        #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id))
        try await waitUntil("partial transfer") {
            fixture.store.items.first.map { $0.state == .downloading && $0.completedBytes >= 120_000 } == true
        }
        let item = try #require(fixture.store.items.first)
        let destination = try #require(item.destination)
        fixture.store.stop(item)
        #expect(item.state == .paused && !fixture.store.hasActiveDownloads)
        #expect(!fixture.manager.hasProtection(tabID: fixture.tab.id, reason: .download), "A stopped transfer no longer holds the page")
        try await waitUntil("resume data") { item.canResume }
        #expect(FileManager.default.fileExists(atPath: destination.path), "Stopping keeps the partial file")
        #expect(fixture.store.canReveal(item) && !fixture.store.fileExists(item))
        fixture.store.clearInactive()
        #expect(fixture.store.items.contains { $0 === item }, "Clear keeps a resumable transfer")

        // Resuming works even after the source page is gone.
        fixture.manager.discard(tabID: fixture.tab.id)
        #expect(fixture.store.resume(item) && item.state == .downloading)
        // WebKit's finish may arrive while the main thread is busy.
        await Task.yield()
        blockMainThread(for: 0.3)
        try await waitUntil("resumed") { item.state == .finished }
        let resumed = try Data(contentsOf: destination)
        #expect(item.destination == destination && resumed == body)
        #expect(fixture.store.items.count == 1, "Resume continues the same row and file")
    }

    @Test func anActiveDownloadFinishesAfterItsSourceTabIsClosed() async throws {
        let body = Data(repeating: 19, count: 400_000)
        let server = try LocalHTTPServer(body: body, initialChunk: 80_000)
        let fixture = Fixture()
        defer { server.stop(); fixture.cleanup() }
        #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id))
        try await waitUntil("transfer started") {
            fixture.store.items.first.map { $0.state == .downloading && $0.completedBytes >= 80_000 } == true
        }
        let item = try #require(fixture.store.items.first)
        fixture.manager.discard(tabID: fixture.tab.id)
        #expect(fixture.manager.liveViewCount == 0 && fixture.store.hasActiveDownloads)
        server.finishTransfers()
        try await waitUntil("transfer after tab close") { item.state == .finished }
        let destination = try #require(item.destination)
        #expect(try Data(contentsOf: destination) == body)
        #expect(fixture.manager.liveViewCount == 0 && fixture.manager.creationCount == 1)
    }

    @Test func anInterruptedDownloadReportsFailureAndReleasesItsPageLease() async throws {
        let server = try LocalHTTPServer(body: Data(repeating: 19, count: 400_000), initialChunk: 80_000)
        let fixture = Fixture()
        defer { server.stop(); fixture.cleanup() }
        #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id))
        try await waitUntil("transfer started") {
            fixture.store.items.first.map { $0.state == .downloading && $0.completedBytes >= 80_000 } == true
        }
        let item = try #require(fixture.store.items.first)
        server.finishTransfers(sendingRemaining: false)
        try await waitUntil("network failure") { item.state == .failed }
        #expect(item.failureReason != nil && !fixture.store.hasActiveDownloads)
        #expect(!fixture.manager.hasProtection(tabID: fixture.tab.id, reason: .download))
        #expect(fixture.manager.pages[fixture.tab.id] === fixture.page, "A failed transfer must keep its source page")
    }

    @Test func cancellingAStoppedTransferDeletesOnlyItsPartialFile() async throws {
        let server = try LocalHTTPServer(body: Data(repeating: 7, count: 400_000), initialChunk: 80_000)
        let fixture = Fixture()
        defer { server.stop(); fixture.cleanup() }
        #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id))
        try await waitUntil("partial transfer") {
            fixture.store.items.first.map { $0.state == .downloading && $0.completedBytes >= 80_000 } == true
        }
        let item = try #require(fixture.store.items.first)
        let destination = try #require(item.destination)
        fixture.store.stop(item)
        try await waitUntil("resume data") { item.canResume }
        fixture.store.cancel(item)
        #expect(item.state == .cancelled && !item.canResume)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        fixture.store.remove(item)
        #expect(fixture.store.items.isEmpty)
    }

    @Test func savedDocumentsAreListedAndPagesSaveAsStaticUTF8HTML() async throws {
        // The refresh only has to be there for saving to strip it; an hour's
        // delay keeps it from leaving the page (and reaching the network)
        // before the test reads it.
        let fixture = Fixture(page: "<meta charset='iso-8859-1'><meta http-equiv='refresh' content='3600;url=https://example.com/away'>"
            + "<script>document.title = 'changed'</script><p><a href='next.html'>Next</a> Café</p>")
        defer { fixture.cleanup() }
        let source = URL(string: "early-test://fixture/article/page")!
        fixture.manager.load(source, in: fixture.tab)
        try await waitUntil("page") { !fixture.page.isLoading && fixture.page.view.url == source }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let destination = fixture.directory.appending(path: "Saved Page.html")
        let before = fixture.store.startedRevision
        fixture.manager.saveHTMLSnapshot(of: fixture.page.view, source: source, to: destination)
        try await waitUntil("saved") { fixture.store.items.first?.destination == destination }
        let html = try String(contentsOf: destination, encoding: .utf8)
        #expect(html.hasPrefix("<!DOCTYPE html>") || html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<meta charset=\"utf-8\">") && html.contains("<base href=\"\(source.absoluteString)\">"))
        #expect(!html.contains("<script") && !html.contains("http-equiv") && !html.contains("iso-8859-1"))
        #expect(html.contains("href=\"next.html\"") && html.contains("Café"))
        let item = try #require(fixture.store.items.first)
        #expect(item.state == .finished && item.filename == "Saved Page.html" && fixture.store.fileExists(item))
        #expect(fixture.store.startedRevision == before + 1 && fixture.store.finishedRevision == 1, "A save starts and finishes at once")
        #expect(item.wasSaved)
    }

    @Test func cancellingBeforeADestinationCreatesNoFileAndClearingKeepsFinishedFiles() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.manager.onDownloadStarted = { [store = fixture.store] item in store.cancel(item) }
        #expect(fixture.manager.startDownload(hello, from: fixture.tab.id))
        try await waitUntil("cancelled") { fixture.store.items.first?.state == .cancelled }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = try #require(fixture.store.items.first)
        #expect(cancelled.state == .cancelled && cancelled.destination == nil)
        #expect(!fixture.manager.hasProtection(tabID: fixture.tab.id, reason: .download))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)) ?? []).isEmpty)

        fixture.manager.onDownloadStarted = nil
        #expect(fixture.manager.startDownload(hello, from: fixture.tab.id))
        try await waitUntil("finished") { fixture.store.items.first?.state == .finished }
        let finished = try #require(fixture.store.items.first)
        #expect(fixture.store.fileExists(finished))
        fixture.store.clearInactive()
        #expect(fixture.store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: try #require(finished.destination).path), "Clearing never deletes files")
    }

    @Test func theListLimitDropsSettledEntriesButKeepsPausedAndResumableDownloads() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store
        let file = fixture.directory.appending(path: "saved.html")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("<p>Saved</p>".utf8).write(to: file)
        let paused = store.recordSavedFile(at: file, source: nil)
        paused.state = .paused
        paused.resumeData = Data([1])
        let interrupted = store.recordSavedFile(at: file, source: nil)
        interrupted.state = .failed
        interrupted.resumeData = Data([2])
        let broken = store.recordSavedFile(at: file, source: nil)
        broken.state = .failed
        let cancelled = store.recordSavedFile(at: file, source: nil)
        cancelled.state = .cancelled
        #expect(!paused.canBeTrimmed && !interrupted.canBeTrimmed && broken.canBeTrimmed && cancelled.canBeTrimmed)

        for _ in 0..<DownloadStore.maximumListedItems { store.recordSavedFile(at: file, source: nil) }
        let ids = Set(store.items.map(\.id))
        #expect(store.items.count == DownloadStore.maximumListedItems)
        #expect(ids.contains(paused.id) && ids.contains(interrupted.id), "Downloads that can continue are kept")
        #expect(!ids.contains(broken.id) && !ids.contains(cancelled.id))
        #expect(paused.resumeData == Data([1]), "With their resume data")

        // Past the limit, kept downloads stay; only settled entries make room.
        for _ in 0..<5 { store.recordSavedFile(at: file, source: nil) }
        #expect(store.items.count == DownloadStore.maximumListedItems && Set(store.items.map(\.id)).isSuperset(of: [paused.id, interrupted.id]))
    }

    @Test func savingAFileKeepsTheOriginalAndReplacesOthersOnlyWithACompleteCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlySave-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "report.pdf"), other = folder.appending(path: "other.pdf")
        try Data("%PDF original".utf8).write(to: report)
        try Data("%PDF other".utf8).write(to: other)

        // Choosing the original itself, under any spelling, changes nothing.
        try WebViewManager.copyFile(report, replacing: report)
        try WebViewManager.copyFile(report, replacing: folder.appending(path: "REPORT.pdf"))
        let link = folder.appending(path: "link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: report)
        try WebViewManager.copyFile(report, replacing: link)
        #expect(try Data(contentsOf: report) == Data("%PDF original".utf8))
        #expect(WebViewManager.isSameFile(report, link) && !WebViewManager.isSameFile(report, other))

        // A failed copy leaves the chosen file as it was.
        #expect(throws: (any Error).self) { try WebViewManager.copyFile(folder.appending(path: "missing.pdf"), replacing: other) }
        #expect(try Data(contentsOf: other) == Data("%PDF other".utf8))
        try WebViewManager.copyFile(report, replacing: other)
        #expect(try Data(contentsOf: other) == Data("%PDF original".utf8) && FileManager.default.fileExists(atPath: report.path))

        // Saving beside the original suggests the first unused number.
        try Data().write(to: folder.appending(path: "report (1).pdf"))
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        #expect(WebViewManager.unusedName("report.pdf", in: folder, exists: exists) == "report (2).pdf")
        #expect(WebViewManager.unusedName("notes.pdf", in: folder, exists: exists) == "notes.pdf")
        #expect(WebViewManager.unusedName("README", in: folder) { $0.lastPathComponent == "README" } == "README (1)")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "report.pdf"
        WebViewManager.suggestUnusedName(for: report, in: panel)
        #expect(panel.nameFieldStringValue == "report (2).pdf" && panel.directoryURL?.standardizedFileURL == folder.standardizedFileURL)

        // A web page's name is checked in whatever folder the panel opens in.
        try Data().write(to: folder.appending(path: "sector 36 - Google Search.html"))
        let page = NSSavePanel()
        page.directoryURL = folder
        page.nameFieldStringValue = "sector 36 - Google Search.html"
        WebViewManager.suggestUnusedName(for: URL(string: "https://www.google.com/search?q=sector+36"), in: page)
        #expect(page.nameFieldStringValue == "sector 36 - Google Search (1).html" && page.directoryURL?.standardizedFileURL == folder.standardizedFileURL)
    }
}
