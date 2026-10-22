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
        let quarantine = try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Early")
        #expect(quarantine?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
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
        try await waitUntil("resumed") { item.state == .finished }
        let resumed = try Data(contentsOf: destination)
        #expect(item.destination == destination && resumed == body)
        #expect(fixture.store.items.count == 1, "Resume continues the same row and file")
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
        let fixture = Fixture(page: "<meta charset='iso-8859-1'><meta http-equiv='refresh' content='0;url=https://example.com/away'>"
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
        #expect(fixture.store.startedRevision == before + 1, "The footer reacts to a saved file")
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
}
