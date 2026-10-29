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

    /// A different process creates the chosen file after Early returns its
    /// destination, before WebKit tries to open it.
    private final class DestinationCollision: NSObject, WKDownloadDelegate {
        let store: DownloadStore
        let contents = Data("Another process owns this file".utf8)
        var destination: URL?
        var creationError: Error?
        var downloadError: NSError?
        var cancelsAfterChoosing = false

        init(store: DownloadStore) { self.store = store }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String) async -> URL? {
            guard let chosen = await store.download(download, decideDestinationUsing: response,
                                                  suggestedFilename: suggestedFilename) else { return nil }
            do { try contents.write(to: chosen, options: .withoutOverwriting) }
            catch { creationError = error; return nil }
            destination = chosen
            if cancelsAfterChoosing, let item = store.items.first(where: { $0.download === download }) { store.cancel(item) }
            return chosen
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadError = error as NSError
            store.download(download, didFailWithError: error, resumeData: resumeData)
        }

        func downloadDidFinish(_ download: WKDownload) { store.downloadDidFinish(download) }
    }

    @Test func filenamesAreSanitizedAndNeverReplaceExistingOrReservedFiles() {
        for suggested in ["../../etc/passwd", ".hidden", "a:b\\c", " \n ", ""] {
            let name = DownloadStore.sanitizedFilename(suggested)
            #expect(!name.contains("/") && !name.contains(":") && !name.hasPrefix(".") && !name.isEmpty, "\(suggested) -> \(name)")
        }
        #expect(DownloadStore.sanitizedFilename("Report.pdf") == "Report.pdf")
        let long = DownloadStore.sanitizedFilename(String(repeating: "x", count: 300) + ".zip")
        #expect(long.utf16.count <= DownloadStore.filenameLimit && long.hasSuffix(".zip"))
        let folder = URL(filePath: "/tmp/early-downloads", directoryHint: .isDirectory)
        let existing: Set<String> = ["/tmp/early-downloads/Report.pdf", "/tmp/early-downloads/Report 2.pdf"]
        let reserved: Set<String> = ["/tmp/early-downloads/Report 3.pdf"]
        let unique = DownloadStore.uniqueDestination(for: "Report.pdf", in: folder, reserved: reserved) { existing.contains($0.path) }
        #expect(unique.lastPathComponent == "Report 4.pdf")
        #expect(DownloadStore.uniqueDestination(for: "notes", in: folder, reserved: []) { $0.lastPathComponent == "notes" }
            .lastPathComponent == "notes 2")
    }

    @Test func filenameProbeKeepsAFileCreatedAfterNameSelection() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyNameRace-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = DownloadStore.uniqueDestination(for: "résumé.txt", in: folder, reserved: [])
        let contents = Data("A file created after the name was selected".utf8)
        try contents.write(to: chosen)

        #expect(DownloadStore.acceptsName(chosen))
        #expect(try Data(contentsOf: chosen) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [chosen.lastPathComponent])
        #expect(DownloadStore.uniqueDestination(for: "résumé.txt", in: folder, reserved: []).lastPathComponent == "résumé 2.txt")
    }

    @Test func filenameProbeDoesNotFollowOrRemoveDestinationLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyNameLink-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "original.txt"), link = folder.appending(path: "résumé.txt")
        let contents = Data("Keep the original and its link".utf8)
        try contents.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(DownloadStore.acceptsName(link))
        #expect(try Data(contentsOf: target) == contents)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test func filenameProbeChecksTheFilesystemWithoutLeavingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyNameProbe-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["plain.txt", "résumé.txt", String(repeating: "日", count: 100) + ".pdf"] {
            #expect(DownloadStore.acceptsName(folder.appending(path: name)))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
        #expect(!DownloadStore.acceptsName(folder.appending(path: String(repeating: "x", count: 300) + ".txt")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        // A directory with the same name does not make the basename invalid.
        let existing = folder.appending(path: "résumé.txt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let neighbor = existing.appending(path: "keep.txt")
        try Data("Keep".utf8).write(to: neighbor)
        #expect(DownloadStore.acceptsName(existing))
        #expect(try Data(contentsOf: neighbor) == Data("Keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [existing.lastPathComponent])
    }

    @Test(arguments: [false, true])
    func aCollisionAfterChoosingTheDownloadDestinationKeepsTheOtherFile(cancel: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let collision = DestinationCollision(store: fixture.store)
        collision.cancelsAfterChoosing = cancel
        fixture.manager.onDownloadStarted = { item in item.download?.delegate = collision }
        #expect(fixture.manager.startDownload(hello, from: fixture.tab.id))
        try await waitUntil("destination collision") { fixture.store.items.first.map { !$0.state.isActive } == true }

        #expect(collision.creationError == nil)
        let destination = try #require(collision.destination)
        if cancel {
            // Explicit cancellation cleans up in WebKit's completion callback.
            try await Task.sleep(for: .milliseconds(150))
        } else { #expect(collision.downloadError != nil, "WebKit refuses the other process's file") }
        #expect(fixture.store.items.first?.state != .finished)
        #expect(try Data(contentsOf: destination) == collision.contents)
        #expect(!fixture.manager.hasProtection(tabID: fixture.tab.id, reason: .download))
    }

    @Test func filenameProbeDoesNotTreatStorageFailuresAsInvalidNames() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyNameUnavailable-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = Data("A file, not a directory".utf8)
        let file = folder.appending(path: "file")
        try contents.write(to: file)
        #expect(DownloadStore.acceptsName(file.appending(path: "résumé.txt")), "Let WebKit report the storage error without renaming")
        #expect(try Data(contentsOf: file) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["file"])
    }

    @Test func cancellingBeforeTheBodyArrivesDoesNotLeaveAnEmptyPartialFile() async throws {
        let server = try LocalHTTPServer(body: Data(repeating: 1, count: 1000), initialChunk: 0)
        let fixture = Fixture()
        defer { server.stop(); fixture.cleanup() }
        #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id))
        try await waitUntil("empty partial file") {
            fixture.store.items.first?.destination.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        let item = try #require(fixture.store.items.first)
        let destination = try #require(item.destination)
        #expect(item.completedBytes == 0)
        fixture.store.cancel(item)
        try await waitUntil("WebKit removes its empty partial file") { !FileManager.default.fileExists(atPath: destination.path) }
        #expect(item.state == .cancelled)
    }

    /// The disk counts UTF-16 units (255 at most), not characters or bytes:
    /// 255 Japanese characters fit, 128 emoji or 128 combined accents don't.
    @Test func longUnicodeNamesAndExtensionsFitTheDiskWithRoomForANumber() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "early-names-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let japanese = String(repeating: "日", count: 100) + ".pdf"
        #expect(DownloadStore.sanitizedFilename(japanese) == japanese, "Names that fit stay as they are")
        let names = [String(repeating: "😀", count: 200) + ".png", String(repeating: "e\u{301}", count: 200) + ".txt",
                     String(repeating: "日", count: 300), "report." + String(repeating: "x", count: 300),
                     String(repeating: "a", count: 240) + ".longextension"]
        for suggested in names {
            let name = DownloadStore.sanitizedFilename(suggested)
            #expect(name.utf16.count <= DownloadStore.filenameLimit, "\(name.utf16.count)")
            #expect(name.unicodeScalars.first.map { $0.properties.generalCategory != .nonspacingMark } ?? false)
            // The longest number a duplicate might get still fits.
            let numbered = folder.appending(path: (name as NSString).deletingPathExtension + " 99999"
                + ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension))
            #expect(FileManager.default.createFile(atPath: numbered.path, contents: nil), "\(numbered.lastPathComponent.utf16.count)")
        }
        #expect(DownloadStore.sanitizedFilename(String(repeating: "😀", count: 200) + ".png").hasSuffix("😀.png"),
                "An emoji is never cut in half")
        #expect(DownloadStore.sanitizedFilename("report." + String(repeating: "x", count: 300)).hasPrefix("report."),
                "An overlong extension is cut as part of the name")
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
            // As after the person's click on the link.
            (fixture.page.view as? BrowserWebView)?.notePersonInput()
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

    /// A download a page starts by itself (no click or key press from the
    /// person) asks once per website, and the answer is remembered. The
    /// person's own click, or an address Early opened, never asks.
    @Test func downloadsAPageStartsByItselfAskOncePerWebsite() async throws {
        let link = "<title>Files</title><a id='file' download='note.txt' href='data:text/plain;base64,bm90ZQ=='>Note</a>"
        let site = try BasicAuthServer(username: "x", password: "y", realm: "r", pages: ["/files": link])
        let fixture = Fixture()
        defer { site.stop(); fixture.cleanup() }
        let permissions = SitePermissions(fileURL: nil)
        fixture.manager.sitePermissions = permissions
        var asked: [String] = []
        var answer: Bool? = false
        fixture.manager.askForDownloads = { host, reply in
            asked.append(host)
            reply(answer)
        }
        let page = URL(string: "http://127.0.0.1:\(site.port)/files")!
        fixture.manager.load(page, in: fixture.tab)
        try await waitUntil("page") { !fixture.page.isLoading && fixture.page.view.title == "Files" }
        func clickByScript() async throws { _ = try await fixture.page.view.evaluateJavaScript("document.getElementById('file').click()") }
        func finished() -> Int { fixture.store.items.filter { $0.state == .finished }.count }

        try await clickByScript()
        try await waitUntil("asked") { asked.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(asked == ["127.0.0.1"] && fixture.store.items.isEmpty, "Refused, nothing downloaded")
        #expect(permissions.decision(for: "http://127.0.0.1:\(site.port)", .downloads) == .block, "The answer is kept for the website")
        #expect(fixture.page.navigationNotice?.contains("blocked a download") == true)
        try await clickByScript()
        try await Task.sleep(for: .milliseconds(300))
        #expect(asked.count == 1 && fixture.store.items.isEmpty, "Blocked: refused again without asking")

        // The person's own click downloads, even on a blocked website.
        (fixture.page.view as? BrowserWebView)?.notePersonInput()
        try await clickByScript()
        try await waitUntil("person's download") { finished() == 1 }
        #expect(asked.count == 1)

        permissions.set(.allow, for: [.downloads], origin: "http://127.0.0.1:\(site.port)")
        try await clickByScript()
        try await waitUntil("allowed download") { finished() == 2 }
        #expect(asked.count == 1, "Allowed: no question")

        // Dismissed (no answer) saves nothing and downloads nothing.
        permissions.set(.ask, for: [.downloads], origin: "http://127.0.0.1:\(site.port)")
        answer = nil
        try await clickByScript()
        try await waitUntil("asked again") { asked.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished() == 2 && permissions.decision(for: "http://127.0.0.1:\(site.port)", .downloads) == .ask)
    }

    @Test func aPageCantStartADownloadWhileManyAreRunning() async throws {
        let server = try LocalHTTPServer(body: Data(repeating: 1, count: 400_000), initialChunk: 50_000)
        let fixture = Fixture(page: "<a id='file' download='note.txt' href='data:text/plain;base64,bm90ZQ=='>Note</a>")
        defer { server.stop(); fixture.cleanup() }
        fixture.manager.sitePermissions = SitePermissions(fileURL: nil)
        var asked = 0
        fixture.manager.askForDownloads = { _, reply in asked += 1; reply(true) }
        fixture.manager.load(URL(string: "early-test://fixture/source")!, in: fixture.tab)
        try await waitUntil("page") { !fixture.page.isLoading && fixture.page.view.title == "Source" }
        for _ in 0..<WebViewManager.automaticDownloadLimit { #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id)) }
        try await waitUntil("all running") { fixture.store.activeCount == WebViewManager.automaticDownloadLimit }
        _ = try await fixture.page.view.evaluateJavaScript("document.getElementById('file').click()")
        try await waitUntil("refused") { fixture.page.navigationNotice != nil }
        #expect(asked == 0 && fixture.store.items.count == WebViewManager.automaticDownloadLimit)
        #expect(fixture.page.navigationNotice?.contains("many are running") == true)
        fixture.store.cancelAll()
    }

    @Test func savingOverAFileKeepsItUntilTheNewOneIsCompleteThroughStopAndResume() async throws {
        let body = Data((0..<600_000).map { UInt8($0 % 241) })
        let server = try LocalHTTPServer(body: body, initialChunk: 120_000)
        let fixture = Fixture()
        defer { server.stop(); fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let chosen = fixture.directory.appending(path: "Report.bin")
        try "old".write(to: chosen, atomically: true, encoding: .utf8)
        #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id, to: chosen))
        try await waitUntil("partial transfer") {
            fixture.store.items.first.map { $0.state == .downloading && $0.completedBytes >= 120_000 } == true
        }
        let item = try #require(fixture.store.items.first)
        let staging = try #require(item.destination)
        #expect(staging != chosen && item.filename == "Report.bin")
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "old", "The chosen file stays while the new one arrives")
        fixture.store.stop(item)
        try await waitUntil("resume data") { item.canResume }
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "old")
        #expect(fixture.store.canReveal(item), "A stopped replacement reveals the file it will replace")
        #expect(fixture.store.resume(item))
        try await waitUntil("resumed") { item.state == .finished }
        let replaced = try Data(contentsOf: chosen)
        #expect(item.destination == chosen && replaced == body)
        #expect(!FileManager.default.fileExists(atPath: staging.deletingLastPathComponent().path), "The staging folder goes")
    }

    @Test func aCancelledOrFailedSaveOverAFileLeavesItAsItWas() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let chosen = fixture.directory.appending(path: "Report.bin")
        try "old".write(to: chosen, atomically: true, encoding: .utf8)
        for failing in [false, true] {
            let server = try LocalHTTPServer(body: Data(repeating: 3, count: 400_000), initialChunk: 80_000)
            defer { server.stop() }
            #expect(fixture.manager.startDownload(server.url, from: fixture.tab.id, to: chosen))
            try await waitUntil("partial transfer") {
                fixture.store.items.first.map { $0.state == .downloading && $0.completedBytes >= 80_000 } == true
            }
            let item = try #require(fixture.store.items.first)
            let staging = try #require(item.destination).deletingLastPathComponent()
            if failing {
                server.finishTransfers(sendingRemaining: false)
                try await waitUntil("network failure") { item.state == .failed }
                if item.canResume { fixture.store.cancel(item) }
            } else {
                fixture.store.cancel(item)
            }
            try await waitUntil("staging removed") { !FileManager.default.fileExists(atPath: staging.path) }
            #expect(try String(contentsOf: chosen, encoding: .utf8) == "old", failing ? "A failed save keeps the file" : "Cancel keeps the file")
        }
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
            + "<script>document.title = 'changed'</script><p><a href='next.html'>Next</a> Café</p>"
            // Active content that must not survive or run in the saved copy.
            + "<img id='photo' src='data:,' onerror='window.ran = (window.ran || 0) + 1'>"
            + "<a id='bad' href='javascript:window.ran = 99'>Bad</a><button formaction='javascript:1'>Go</button>"
            + "<iframe srcdoc='<p>framed</p>'></iframe><object data='movie.swf'></object><embed src='movie.swf'>"
            + "<svg><a xlink:href='javascript:1'><text>x</text></a></svg>")
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
        #expect(!html.contains("<script") && !html.contains("refresh") && !html.contains("iso-8859-1"))
        #expect(html.contains("href=\"next.html\"") && html.contains("Café"))
        for active in ["onerror", "javascript:", "formaction", "<iframe", "<object", "<embed", "srcdoc"] {
            #expect(!html.contains(active), "\(active) is gone")
        }
        #expect(html.contains("Content-Security-Policy") && html.contains("script-src 'none'"))
        #expect(html.contains("id=\"photo\"") && html.contains("id=\"bad\""), "The elements stay, without what made them run")

        // Opened later, nothing in the saved copy runs.
        let viewer = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        viewer.loadFileURL(destination, allowingReadAccessTo: fixture.directory)
        try await waitUntil("saved copy") { !viewer.isLoading && viewer.url != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await viewer.evaluateJavaScript("window.ran ?? 0") as? Int == 0, "No handler ran in the saved copy")
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
