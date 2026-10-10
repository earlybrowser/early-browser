import AppKit
import EarlyCore
import Observation
import WebKit

@MainActor @Observable
public final class BrowserPage {
    public let view: WKWebView
    public var isLoading = false
    public var progress = 0.0
    public var canGoBack = false
    public var canGoForward = false
    public var failure: String?
    public var hasDialog = false
    public var requestedURL: URL
    fileprivate var observations: [NSKeyValueObservation] = []
    fileprivate var reportedURL: URL?
    fileprivate var reportedTitle: String?
    fileprivate init(view: WKWebView, url: URL) { self.view = view; requestedURL = url }
}

@MainActor @Observable
public final class WebViewManager: NSObject, WKNavigationDelegate, WKUIDelegate {
    public private(set) var pages: [UUID: BrowserPage] = [:]
    public private(set) var creationCount = 0
    public var onMetadata: ((UUID, URL?, String?) -> Void)?
    public var onNewWindow: ((URL, WKWebViewConfiguration) -> WKWebView?)?
    public var onClose: ((UUID) -> Void)?
    public var onNotice: ((String) -> Void)?
    private let profileID: UUID
    private let ephemeral: Bool
    private let input: NavigationInput
    private let configure: (WKWebViewConfiguration) -> Void
    private var store: WKWebsiteDataStore?
    private var identities: [ObjectIdentifier: UUID] = [:]
    private var dialogs: [UUID: PendingDialog] = [:]

    public init(profileID: UUID, ephemeral: Bool = false,
                input: NavigationInput = NavigationInput(),
                configure: @escaping (WKWebViewConfiguration) -> Void = { _ in }) {
        self.profileID = profileID
        self.ephemeral = ephemeral
        self.input = input
        self.configure = configure
        super.init()
    }

    public var liveViewCount: Int { pages.count }
    public func existingView(for id: UUID) -> WKWebView? { pages[id]?.view }

    /// Called by accepted navigation/selection, never by SwiftUI rendering.
    @discardableResult
    public func prepare(_ tab: BrowserTab, configuration supplied: WKWebViewConfiguration? = nil) -> BrowserPage {
        if let page = pages[tab.id] { return page }
        precondition(tab.profileID == profileID, "A manager owns exactly one profile")
        let configuration: WKWebViewConfiguration
        if let supplied {
            // WebKit requires the exact supplied configuration for window.open.
            configuration = supplied
        } else {
            configuration = WKWebViewConfiguration()
            if store == nil {
                store = ephemeral ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: profileID)
            }
            configuration.websiteDataStore = store!
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configure(configuration)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        let page = BrowserPage(view: view, url: tab.currentURL)
        pages[tab.id] = page
        identities[ObjectIdentifier(view)] = tab.id
        creationCount += 1
        // KVO has a nonisolated signature. Coalesce its burst of property changes
        // into at most one queued MainActor refresh per view, without retaining it.
        let gate = RefreshGate()
        let changed: @Sendable () -> Void = { [weak self] in
            gate.schedule { [weak self] in self?.refresh(tab.id) }
        }
        page.observations = [
            view.observe(\.title) { _, _ in changed() },
            view.observe(\.url) { _, _ in changed() },
            view.observe(\.isLoading) { _, _ in changed() },
            view.observe(\.estimatedProgress) { _, _ in changed() },
            view.observe(\.canGoBack) { _, _ in changed() },
            view.observe(\.canGoForward) { _, _ in changed() }
        ]
        return page
    }

    public func load(_ url: URL, in tab: BrowserTab) {
        let page = prepare(tab)
        page.requestedURL = url
        page.failure = nil
        page.view.load(URLRequest(url: url))
    }

    public func activate(_ tab: BrowserTab) {
        guard pages[tab.id] == nil else { return }
        load(tab.currentURL, in: tab)
    }

    public func reload(_ id: UUID) {
        guard let page = pages[id] else { return }
        if page.failure != nil || page.view.url == nil {
            page.failure = nil
            page.view.load(URLRequest(url: page.requestedURL))
        } else { page.view.reload() }
    }

    public func stop(_ id: UUID) { pages[id]?.view.stopLoading(); refresh(id) }
    public func back(_ id: UUID) { pages[id]?.view.goBack() }
    public func forward(_ id: UUID) { pages[id]?.view.goForward() }

    public func discard(tabID: UUID) {
        guard let page = pages.removeValue(forKey: tabID) else { return }
        identities.removeValue(forKey: ObjectIdentifier(page.view))
        cancelDialog(tabID)
        page.observations.forEach { $0.invalidate() }
        page.observations.removeAll()
        page.view.stopLoading()
        page.view.navigationDelegate = nil
        page.view.uiDelegate = nil
        page.view.removeFromSuperview()
    }

    public func discardAll() { for id in Array(pages.keys) { discard(tabID: id) } }

    private func refresh(_ id: UUID) {
        guard let page = pages[id] else { return }
        let view = page.view
        page.isLoading = view.isLoading
        page.progress = view.estimatedProgress
        page.canGoBack = view.canGoBack
        page.canGoForward = view.canGoForward
        let url = view.url.flatMap { try? input.validate($0) }
        let title = view.title
        if url != page.reportedURL || title != page.reportedTitle {
            page.reportedURL = url
            page.reportedTitle = title
            onMetadata?(id, url, title)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if (try? input.validate(url)) != nil {
            if mainFrame, action.targetFrame != nil,
               let id = identities[ObjectIdentifier(webView)] { pages[id]?.requestedURL = url }
            decisionHandler(.allow)
        } else if !mainFrame, ["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            onNotice?("This link uses an unsupported address type (\(url.scheme ?? "unknown")).")
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard response.canShowMIMEType else {
            decisionHandler(.cancel)
            onNotice?("This file needs download support, which is not available yet.")
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        pages[id]?.failure = nil
        refresh(id)
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = identities[ObjectIdentifier(webView)] { refresh(id) }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }
    private func failed(_ view: WKWebView, _ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled,
              let id = identities[ObjectIdentifier(view)] else { return }
        pages[id]?.failure = error.localizedDescription
        refresh(id)
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        pages[id]?.failure = "The web content process stopped. Reload to reopen this page."
        pages[id]?.isLoading = false
    }

    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Never accept invalid certificates or manufacture credentials.
        completionHandler(.performDefaultHandling, nil)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard identities[ObjectIdentifier(webView)] != nil,
              let url = action.request.url, (try? input.validate(url)) != nil else { return nil }
        return onNewWindow?(url, configuration)
    }

    public func webViewDidClose(_ webView: WKWebView) {
        if let id = identities[ObjectIdentifier(webView)] { onClose?(id) }
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        showDialog(webView, frame: frame, message: message, kind: .alert) { _, _ in completionHandler() }
    }
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        showDialog(webView, frame: frame, message: message, kind: .confirm) { accepted, _ in completionHandler(accepted) }
    }
    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor (String?) -> Void) {
        showDialog(webView, frame: frame, message: prompt, kind: .prompt(defaultText ?? "")) {
            accepted, value in completionHandler(accepted ? value : nil)
        }
    }

    private enum DialogKind { case alert, confirm, prompt(String) }
    private struct PendingDialog {
        let alert: NSAlert
        let parent: NSWindow
        let complete: (Bool, String?) -> Void
        let field: NSTextField?
    }
    private func showDialog(_ view: WKWebView, frame: WKFrameInfo, message: String, kind: DialogKind,
                            complete: @escaping (Bool, String?) -> Void) {
        guard let id = identities[ObjectIdentifier(view)], let window = view.window,
              window.attachedSheet == nil else { complete(false, nil); return }
        let alert = NSAlert()
        alert.messageText = "\(frame.request.url?.host ?? "Website") says"
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        var field: NSTextField?
        switch kind {
        case .alert: break
        case .confirm: alert.addButton(withTitle: "Cancel")
        case .prompt(let value):
            alert.addButton(withTitle: "Cancel")
            let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            inputField.stringValue = String(value.prefix(4096))
            inputField.setAccessibilityLabel("Website prompt response")
            alert.accessoryView = inputField
            alert.window.initialFirstResponder = inputField
            field = inputField
        }
        dialogs[id] = PendingDialog(alert: alert, parent: window, complete: complete, field: field)
        // JavaScript is suspended until this sheet completes. Hide the blocked
        // page's accessibility subtree while the native modal owns interaction;
        // traversing it can otherwise wait on the suspended WebKit process.
        view.setAccessibilityHidden(true)
        pages[id]?.hasDialog = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let pending = self?.dialogs.removeValue(forKey: id) else { return }
            self?.pages[id]?.view.setAccessibilityHidden(false)
            self?.pages[id]?.hasDialog = false
            pending.complete(response == .alertFirstButtonReturn, pending.field?.stringValue)
        }
    }
    private func cancelDialog(_ id: UUID) {
        guard let pending = dialogs.removeValue(forKey: id) else { return }
        pages[id]?.view.setAccessibilityHidden(false)
        pages[id]?.hasDialog = false
        pending.parent.endSheet(pending.alert.window)
        pending.complete(false, nil)
    }
}

/// The lock protects only this one flag; no UI work runs under the lock.
private final class RefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false

    func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        guard !queued else { lock.unlock(); return }
        queued = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            queued = false
            lock.unlock()
            work()
        }
    }
}
