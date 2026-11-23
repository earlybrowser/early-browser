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

    @MainActor
    private final class DraggingInfo: NSObject, @MainActor NSDraggingInfo {
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = .copy
        var draggingLocation: NSPoint
        var draggedImageLocation: NSPoint = .zero
        var draggedImage: NSImage?
        var draggingPasteboard: NSPasteboard
        var draggingSource: Any?
        var draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            self.draggingDestinationWindow = window
            self.draggingLocation = location
            self.draggingPasteboard = pasteboard
        }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
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

    private func fileDecision(_ manager: WebViewManager, _ page: BrowserPage, _ file: URL,
                              type: WKNavigationType = .other, mainFrame: Bool? = true) -> WKNavigationActionPolicy? {
        var result: WKNavigationActionPolicy?
        manager.decideLocalNavigation(to: file, type: type, in: page.view, targetIsMainFrame: mainFrame) { result = $0 }
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

    @Test func unprovenNavigationDoesNotOpenLocalFiles() {
        let (manager, _, page) = fixture()
        defer { manager.discardAll() }
        let file = URL(filePath: "/Users/example/Documents/notes.pdf")
        var opened: [[URL]] = []
        manager.onOpenFiles = { opened.append($0) }
        for type: WKNavigationType in [.linkActivated, .formSubmitted, .other] {
            #expect(fileDecision(manager, page, file, type: type) == .cancel)
        }
        #expect(opened.isEmpty)
        #expect(page.navigationNotice == nil && page.failure == nil)
        #expect(manager.contextLinkURL(href: file.absoluteString, in: page.view) == nil)
    }

    @Test func anUnhandledDropOpensOnlyTheMatchingFileOnce() throws {
        let (manager, _, page) = fixture()
        defer { manager.discardAll() }
        let view = try #require(page.view as? BrowserWebView)
        let file = URL(filePath: "/Users/example/Documents/notes.pdf")
        let other = URL(filePath: "/Users/example/Documents/other.pdf")
        let pasteboard = NSPasteboard(name: .init("EarlyFileDrop-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        try #require(pasteboard.writeObjects([file as NSURL]))
        var opened: [[URL]] = []
        manager.onOpenFiles = { opened.append($0) }

        view.noteFileDrop(from: pasteboard, now: .now.advanced(by: .seconds(-10)))
        #expect(fileDecision(manager, page, file) == .cancel)
        #expect(opened.isEmpty, "An expired drop can no longer open a file")

        view.noteFileDrop(from: pasteboard)
        #expect(fileDecision(manager, page, other) == .cancel)
        #expect(decision(manager, page, Action(file)) == .cancel)
        #expect(fileDecision(manager, page, file, mainFrame: false) == .cancel)
        #expect(fileDecision(manager, page, file, type: .linkActivated) == .cancel)
        #expect(opened.isEmpty)

        #expect(fileDecision(manager, page, file) == .cancel)
        #expect(opened == [[file]], "The file opens in a different tab")
        #expect(fileDecision(manager, page, file) == .cancel)
        #expect(opened == [[file]])

        // Finder file-reference URLs under /var/folders resolve to /private/var/folders
        // while coordinated paths may stay under /var/folders; both refer to the same file.
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "early-drop-alias-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let tempFile = tempDir.appending(path: "Drop Document.html")
        try Data("<!doctype html><p>Alias</p>".utf8).write(to: tempFile)
        let privateFile = URL(filePath: "/private" + tempFile.standardizedFileURL.resolvingSymlinksInPath().path)
        let aliasPasteboard = NSPasteboard(name: .init("EarlyFileDropAlias-\(UUID())"))
        defer { aliasPasteboard.releaseGlobally() }
        try #require(aliasPasteboard.writeObjects([privateFile as NSURL]))
        view.noteFileDrop(from: aliasPasteboard)
        #expect(fileDecision(manager, page, tempFile) == .cancel)
        #expect(opened.count == 2)
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

    @Test func nativeFileDropAcceptsUnhandledPagesAndPreservesPageUploadZones() async throws {
        let (manager, tab, page) = fixture()
        defer { manager.discardAll() }
        let view = try #require(page.view as? BrowserWebView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        window.contentView = view
        defer { window.contentView = nil }

        let folder = FileManager.default.temporaryDirectory.appending(path: "early-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Drop Document.html")
        try Data("<!doctype html><title>Dropped</title><p>Opened</p>".utf8).write(to: file)

        // Finder puts a file reference URL alongside NSFilenamesPboardType; under /var/folders
        // those resolve to /private/var/folders vs /var/folders unless symlinks are normalized.
        let filePasteboard = NSPasteboard(name: .init("EarlyFinderDrop-\(UUID())"))
        defer { filePasteboard.releaseGlobally() }
        filePasteboard.clearContents()
        let reference = try #require((file as NSURL).fileReferenceURL())
        try #require(filePasteboard.writeObjects([reference as NSURL]))
        filePasteboard.addTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")], owner: nil)
        filePasteboard.setPropertyList([file.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        let linkPasteboard = NSPasteboard(name: .init("EarlyLinkDrop-\(UUID())"))
        defer { linkPasteboard.releaseGlobally() }
        linkPasteboard.clearContents()
        try #require(linkPasteboard.writeObjects([URL(string: "https://example.com/other")! as NSURL]))

        func loadHTML(_ html: String, title: String) async throws {
            view.loadHTMLString(html, baseURL: tab.currentURL)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while view.isLoading || view.title != title {
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(view.title == title)
        }

        func settleDragUpdated(_ info: DraggingInfo) async throws -> NSDragOperation {
            _ = view.draggingEntered(info)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var updated: NSDragOperation = []
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                updated = view.draggingUpdated(info)
                if !updated.isEmpty { break }
            }
            return updated
        }

        var opened: [[URL]] = []
        manager.onOpenFiles = { opened.append($0) }

        // 1. Plain page: WebKit accepts the file drag and routes the unhandled drop to onOpenFiles.
        try await loadHTML("<!doctype html><title>Plain</title><p>Plain page</p>", title: "Plain")
        let fileDrop = DraggingInfo(window: window, location: NSPoint(x: 200, y: 200), pasteboard: filePasteboard)
        let plainUpdated = try await settleDragUpdated(fileDrop)
        #expect(!plainUpdated.isEmpty, "Live pages must accept Finder file drops during draggingUpdated")
        #expect(view.prepareForDragOperation(fileDrop))
        #expect(view.performDragOperation(fileDrop))
        let dropDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while opened.isEmpty, ContinuousClock.now < dropDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(opened.count == 1)
        #expect(opened.first?.first?.standardizedFileURL.resolvingSymlinksInPath().path == file.standardizedFileURL.resolvingSymlinksInPath().path)

        // 2. Non-file drag: do not opt into drop-to-navigate on a live page.
        let linkDrop = DraggingInfo(window: window, location: NSPoint(x: 200, y: 200), pasteboard: linkPasteboard)
        #expect(manager.webView(view, dragDestinationActionMaskForDraggingInfo: linkDrop) == (1 | 2))
        #expect(manager.webView(view, dragDestinationActionMaskForDraggingInfo: fileDrop) == (1 | 2 | 4))

        // 3. Page upload drop zone: the page handles the drop and Early does not open a new tab.
        opened.removeAll()
        try await loadHTML("""
            <!doctype html><title>Upload</title>
            <body style="margin:0;width:100vw;height:100vh">
            <div id="zone" style="width:100%;height:100%">Drop files here</div>
            <script>
            window.droppedCount = 0;
            const zone = document.getElementById('zone');
            zone.addEventListener('dragover', e => { e.preventDefault(); });
            zone.addEventListener('drop', e => { e.preventDefault(); window.droppedCount = e.dataTransfer.files.length; });
            </script></body>
            """, title: "Upload")
        let uploadUpdated = try await settleDragUpdated(fileDrop)
        #expect(!uploadUpdated.isEmpty)
        #expect(view.performDragOperation(fileDrop))
        let uploadDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        var droppedCount = 0
        while droppedCount == 0, ContinuousClock.now < uploadDeadline {
            try await Task.sleep(for: .milliseconds(30))
            droppedCount = (try? await view.evaluateJavaScript("window.droppedCount") as? Int) ?? 0
        }
        #expect(droppedCount == 1, "HTML5 upload zones must still receive dropped files")
        #expect(opened.isEmpty, "A file handled by the page must not also open in a new tab")
    }
}
