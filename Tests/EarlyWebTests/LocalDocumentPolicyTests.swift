// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import UniformTypeIdentifiers
import WebKit

/// Navigation policy for local files and downloads, page-owned panels and
/// printing setup. Unshown views only; no panel or print sheet is presented.
@Suite(.serialized) @MainActor
struct LocalDocumentPolicyTests {
    private final class Action: WKNavigationAction {
        private let fakeRequest: URLRequest
        private let type: WKNavigationType
        private let download: Bool
        init(_ url: URL, type: WKNavigationType = .other, download: Bool = false) {
            fakeRequest = URLRequest(url: url)
            self.type = type
            self.download = download
            super.init()
        }
        override var request: URLRequest { fakeRequest }
        override var navigationType: WKNavigationType { type }
        override var shouldPerformDownload: Bool { download }
        override var targetFrame: WKFrameInfo? { nil }
        override var buttonNumber: Int { 0 }
        override var modifierFlags: NSEvent.ModifierFlags { [] }
    }

    private let input = NavigationInput(allowedSchemes: ["http", "https", "file"])

    private func fixture() -> (WebViewManager, BrowserTab, BrowserPage) {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true, input: input, observesMemoryPressure: false)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Page", currentURL: URL(string: "https://example.com/page")!)
        return (manager, tab, manager.prepare(tab))
    }

    private func decision(_ manager: WebViewManager, _ page: BrowserPage, _ action: WKNavigationAction) -> WKNavigationActionPolicy? {
        var result: WKNavigationActionPolicy?
        manager.webView(page.view, decidePolicyFor: action) { result = $0 }
        return result
    }

    @Test func localFileAddressesAreValidOnlyWhenAllowedAndHostless() throws {
        let file = URL(filePath: "/Users/example/Documents/page.html")
        #expect(try input.validate(file) == file)
        #expect(try input.resolve("file:///Users/example/Documents/page.html") == file)
        #expect(throws: NavigationInputError.unsupportedScheme) { try NavigationInput().validate(file) }
        #expect(throws: NavigationInputError.invalidAddress) { try input.validate(URL(string: "file://server.example/share/page.html")!) }
        #expect(throws: NavigationInputError.invalidAddress) { try input.validate(URL(string: "file:///")!) }
    }

    @Test func webContentCannotOpenLocalFilesButDropsOpenANewTab() {
        let (manager, _, page) = fixture()
        defer { manager.discardAll() }
        let file = URL(filePath: "/Users/example/Documents/notes.pdf")
        var opened: [[URL]] = []
        manager.onOpenFiles = { opened.append($0) }
        #expect(decision(manager, page, Action(file, type: .linkActivated)) == .cancel)
        #expect(decision(manager, page, Action(file, type: .formSubmitted)) == .cancel)
        #expect(opened.isEmpty, "A web page's link or form never opens a local file")
        #expect(decision(manager, page, Action(file, type: .other)) == .cancel)
        #expect(opened == [[file]], "An unhandled drop opens the file as a new tab instead of replacing the page")
        #expect(page.navigationNotice == nil && page.failure == nil)
        #expect(manager.contextLinkURL(href: file.absoluteString, in: page.view) == nil)
    }

    @Test func earlysOwnLocalLoadAndHistoryAreAllowed() {
        let (manager, _, page) = fixture()
        defer { manager.discardAll() }
        let file = URL(filePath: "/Users/example/Documents/notes.html")
        page.requestedURL = file
        #expect(decision(manager, page, Action(file)) == .allow)
        let other = URL(filePath: "/Users/example/Documents/other.html")
        #expect(decision(manager, page, Action(other, type: .backForward)) == .allow)
    }

    @Test func downloadLinksDownloadWhileUnsupportedSchemesStayBlocked() {
        let (manager, tab, page) = fixture()
        defer { manager.discardAll() }
        for source in ["data:text/plain;base64,aGk=", "blob:https://example.com/id", "https://example.com/report.pdf"] {
            // The person's click lets the download follow without asking.
            (page.view as? BrowserWebView)?.notePersonInput()
            #expect(decision(manager, page, Action(URL(string: source)!, type: .linkActivated, download: true)) == .download, "\(source)")
        }
        // No app opens ftp: links here, so the link is refused with a notice.
        manager.appForLink = { _ in nil }
        #expect(decision(manager, page, Action(URL(string: "ftp://example.com/file.zip")!, type: .linkActivated, download: true)) == .cancel)
        #expect(page.requestedURL == tab.currentURL, "A download keeps the visible page as the reload target")
        #expect(page.navigationNotice?.contains("unsupported address type") == true)
    }

    @Test func localHTMLFileLoadsWithReadAccessToThatFile() async throws {
        let (manager, tab, page) = fixture()
        defer { manager.discardAll() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "early-local-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "local.html")
        try "<!doctype html><title>Local Document</title><p>Saved locally</p>".write(to: file, atomically: true, encoding: .utf8)
        manager.load(file, in: tab)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while page.view.title != "Local Document" || page.isLoading {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(page.view.title == "Local Document" && page.view.url?.standardizedFileURL == file.standardizedFileURL)
        #expect(page.failure == nil && page.documentMIMEType == "text/html")
    }

    @Test func documentPanelsRequireAWindowAndPrintingUsesTheLoadedPage() async throws {
        let (manager, tab, page) = fixture()
        defer { manager.discardAll() }
        #expect(!manager.canPresentDocumentPanel(for: tab.id) && !manager.printPage(tab.id))
        #expect(!manager.savePage(tab.id) && !manager.exportPDF(tab.id))
        #expect(WebViewManager.documentName(for: page.view, extension: "pdf") == "Page.pdf", "An unloaded page falls back to a neutral name")
        page.view.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        page.view.loadHTMLString("<title>Quarterly: Report/2026.pdf</title><p>Printable</p>", baseURL: tab.currentURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while page.view.isLoading || page.view.title?.hasPrefix("Quarterly") != true {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let operation = manager.makePrintOperation(for: page.view)
        // WebKit's print view needs the page's real frame, or AppKit prints blank pages.
        #expect(operation.view != nil && operation.view?.frame == page.view.bounds)
        #expect(operation.showsPrintPanel && operation.showsProgressPanel)
        #expect(WebViewManager.documentName(for: page.view, extension: "pdf") == "Quarterly- Report-2026.pdf")
        #expect(WebViewManager.imageName(for: URL(string: "https://example.com/a/photo.png")!) == "photo.png")
        #expect(WebViewManager.imageName(for: URL(string: "data:image/png;base64,AAAA")!) == "Image")
    }
}
