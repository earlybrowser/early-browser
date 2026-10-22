// SPDX-License-Identifier: MPL-2.0

import AppKit
import UniformTypeIdentifiers
import WebKit

/// A native upload, save or print sheet owned by one page. While it is attached
/// the page counts as presenting a dialog: shared commands, Space gestures and
/// background discard wait, exactly as for website alerts.
struct PendingPanel {
    let window: NSWindow
    let sheet: NSWindow?
    let owner: AnyObject?
    let cancel: () -> Void
}

/// AppKit reports print completion through an Objective-C selector.
private final class PrintCompletion: NSObject {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion()
    }
}

@MainActor
extension WebViewManager {
    public func canPresentDocumentPanel(for id: UUID) -> Bool {
        guard let page = pages[id], let window = page.view.window else { return false }
        return !page.hasDialog && window.attachedSheet == nil && page.view.url != nil
    }

    private func beginDocumentPanel(_ id: UUID, window: NSWindow, sheet: NSWindow?, owner: AnyObject? = nil,
                                    cancel: @escaping () -> Void = {}) {
        documentPanels[id] = PendingPanel(window: window, sheet: sheet, owner: owner, cancel: cancel)
        pages[id]?.hasDialog = true
    }

    private func endDocumentPanel(_ id: UUID) {
        guard documentPanels.removeValue(forKey: id) != nil else { return }
        pages[id]?.hasDialog = false
        scheduleRetention()
    }

    /// Closing or deleting the page answers a pending upload with "cancel".
    func cancelDocumentPanel(_ id: UUID) {
        guard let pending = documentPanels.removeValue(forKey: id) else { return }
        pages[id]?.hasDialog = false
        pending.cancel()
        if let sheet = pending.sheet ?? pending.window.attachedSheet { pending.window.endSheet(sheet) }
    }

    // MARK: File upload

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let id = tabID(for: webView), let page = pages[id], let window = webView.window,
              window.attachedSheet == nil, !page.hasDialog else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        configureUploadPanel(panel, parameters: parameters, host: frame.securityOrigin.host)
        var answered = false
        let answer: @MainActor ([URL]?) -> Void = { urls in
            guard !answered else { return }
            answered = true
            completionHandler(urls)
        }
        beginDocumentPanel(id, window: window, sheet: panel) { answer(nil) }
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            self?.endDocumentPanel(id)
            answer(response == .OK ? panel?.urls : nil)
        }
    }

    func configureUploadPanel(_ panel: NSOpenPanel, parameters: WKOpenPanelParameters, host: String) {
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true
        panel.prompt = "Choose"
        let subject = parameters.allowsMultipleSelection ? "files" : "a file"
        panel.message = host.isEmpty ? "Choose \(subject) to upload." : "Choose \(subject) to upload to \(host)."
    }

    // MARK: Printing and saving

    @discardableResult
    public func printPage(_ id: UUID) -> Bool {
        guard canPresentDocumentPanel(for: id), let page = pages[id], let window = page.view.window else { return false }
        let operation = makePrintOperation(for: page.view)
        let completion = PrintCompletion { [weak self] in self?.endDocumentPanel(id) }
        beginDocumentPanel(id, window: window, sheet: nil, owner: completion)
        operation.runModal(for: window, delegate: completion,
                           didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        return true
    }

    func makePrintOperation(for view: WKWebView) -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation = view.printOperation(with: info)
        // WebKit's print view needs a real frame, or AppKit prints blank pages.
        operation.view?.frame = view.bounds
        operation.jobTitle = Self.documentName(for: view, extension: nil)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    /// The print panel's PDF menu also saves paginated PDFs; this keeps the
    /// whole page as one continuous document.
    @discardableResult
    public func exportPDF(_ id: UUID) -> Bool {
        guard canPresentDocumentPanel(for: id), let page = pages[id], let window = page.view.window else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.documentName(for: page.view, extension: "pdf")
        beginDocumentPanel(id, window: window, sheet: panel)
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.endDocumentPanel(id)
            guard response == .OK, let destination = panel?.url, let view = self.pages[id]?.view else { return }
            view.createPDF { [weak self] result in
                self?.write(result, to: destination, failure: "The PDF could not be saved.")
            }
        }
        return true
    }

    /// Web pages save as a Web Archive; a viewed PDF saves its original file.
    @discardableResult
    public func savePage(_ id: UUID) -> Bool {
        guard canPresentDocumentPanel(for: id), let page = pages[id], let window = page.view.window,
              let url = page.view.url else { return false }
        let isPDF = page.documentMIMEType == "application/pdf"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [isPDF ? .pdf : .webArchive]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.documentName(for: page.view, extension: isPDF ? "pdf" : "webarchive")
        beginDocumentPanel(id, window: window, sheet: panel)
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.endDocumentPanel(id)
            guard response == .OK, let destination = panel?.url, let view = self.pages[id]?.view else { return }
            if isPDF {
                self.saveOriginal(url, from: id, to: destination, failure: "The PDF could not be saved.")
            } else {
                view.createWebArchiveData { [weak self] result in
                    self?.write(result, to: destination, failure: "The page could not be saved.")
                }
            }
        }
        return true
    }

    func write(_ result: Result<Data, Error>, to destination: URL, failure: String) {
        do {
            try result.get().write(to: destination, options: .atomic)
        } catch {
            onNotice?(failure)
        }
    }

    /// An explicit save goes to the chosen file and is not added to Downloads.
    private func saveOriginal(_ url: URL, from id: UUID, to destination: URL, failure: String) {
        if url.isFileURL {
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch { onNotice?(failure) }
            return
        }
        let started = startDownload(url, from: id, to: destination, listed: false) { [weak self] item in
            if item.state == .failed { self?.onNotice?(failure) }
        }
        if !started { onNotice?(failure) }
    }

    static func documentName(for view: WKWebView, extension ext: String?) -> String {
        let title = view.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = view.url?.deletingPathExtension().lastPathComponent ?? ""
        var name = DownloadStore.sanitizedFilename(title.isEmpty ? (fallback.isEmpty || fallback == "/" ? "Page" : fallback) : title)
        if let ext, !ext.isEmpty {
            if (name as NSString).pathExtension.lowercased() == ext { name = (name as NSString).deletingPathExtension }
            name += "." + ext
        }
        return name
    }

    // MARK: Context-menu actions

    func performContextAction(_ action: BrowserWebView.ContextAction, in view: BrowserWebView) {
        guard let id = tabID(for: view) else { return }
        switch action {
        case .back: back(id)
        case .forward: forward(id)
        case .reload: reload(id)
        case .savePage: savePage(id)
        case .printPage: printPage(id)
        case .downloadLink(let url): startDownload(url, from: id)
        case .openImageInNewTab(let url): openContextLink(url, in: view, background: true)
        case .saveImage(let url): saveImage(url, from: id)
        case .copyImage(let url): copyImage(url, from: id)
        case .searchSelection(let text): onOpenSearch?(text)
        }
    }

    private func saveImage(_ url: URL, from id: UUID) {
        guard canPresentDocumentPanel(for: id), let window = pages[id]?.view.window else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.imageName(for: url)
        beginDocumentPanel(id, window: window, sheet: panel)
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            self.endDocumentPanel(id)
            guard response == .OK, let destination = panel?.url else { return }
            self.saveOriginal(url, from: id, to: destination, failure: "The image could not be saved.")
        }
    }

    /// Fetched through the page's own profile, then placed on the pasteboard.
    private func copyImage(_ url: URL, from id: UUID) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Early-Image-\(UUID().uuidString)", directoryHint: .isDirectory)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            onNotice?("The image could not be copied.")
            return
        }
        let destination = folder.appending(path: Self.imageName(for: url), directoryHint: .notDirectory)
        let started = startDownload(url, from: id, to: destination, listed: false) { [weak self] item in
            defer { try? FileManager.default.removeItem(at: folder) }
            guard item.state == .finished, let image = NSImage(contentsOf: destination) else {
                if item.state == .failed { self?.onNotice?("The image could not be copied.") }
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
        if !started { try? FileManager.default.removeItem(at: folder) }
    }

    static func imageName(for url: URL) -> String {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return "Image" }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? "Image" : DownloadStore.sanitizedFilename(name)
    }
}
