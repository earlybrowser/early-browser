// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import WebKit

/// WebKit's UI delegate: windows a page opens or closes, and its alert,
/// confirm and prompt dialogs, one sheet per window.
extension WebViewManager {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if identities[ObjectIdentifier(webView)] != nil, let url = action.request.url,
           offerToOpenInApp(url, action: action, from: webView) { return nil }
        guard identities[ObjectIdentifier(webView)] != nil,
              let url = action.request.url, (try? input.validate(url)) != nil,
              !url.isFileURL || webView.url?.isFileURL == true else { return nil }
        // Do not create a tab whose stored URL could later restore a protected
        // extension page. Only that extension's own frame can open such a popup.
        if let origin = Self.extensionOrigin(of: url) {
            guard let id = identities[ObjectIdentifier(webView)], let page = pages[id],
                  page.hasExtensionConfiguration, page.extensionOrigin == origin,
                  action.sourceFrame.securityOrigin.protocol.lowercased() == url.scheme?.lowercased(),
                  action.sourceFrame.securityOrigin.host.lowercased() == url.host?.lowercased()
            else { return nil }
        }
        // Target-blank links may arrive through the new-window delegate first.
        // Returning nil consumes the gesture without creating a second tab.
        if openCommandClickedLink(action, in: webView) { return nil }
        let opened = onNewWindow?(url, configuration)
        // WebKit opens windows only on the person's click, so what the new
        // tab loads first is theirs, even if it turns out to be a download.
        if let opened, let id = identities[ObjectIdentifier(opened)] { pages[id]?.earlyRequested = url }
        return opened
    }

    func openCommandClickedLink(_ action: WKNavigationAction, in view: WKWebView) -> Bool {
        guard Self.isCommandClick(navigationType: action.navigationType, buttonNumber: action.buttonNumber,
                                  modifiers: action.modifierFlags),
              let url = action.request.url else { return false }
        return openContextLink(url, in: view, background: true)
    }

    static func isCommandClick(navigationType: WKNavigationType, buttonNumber: Int,
                               modifiers: NSEvent.ModifierFlags) -> Bool {
        // WKNavigationAction uses WebKit's button mask: left = 1, none = 0.
        // It is not NSEvent's zero-based buttonNumber (or DOM MouseEvent.button).
        navigationType == .linkActivated && buttonNumber == 1 && modifiers.contains(.command)
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

    enum DialogKind { case alert, confirm, prompt(String) }
    struct PendingDialog {
        let alert: NSAlert
        let parent: NSWindow
        /// The button chosen, or nil when the dialog was dismissed without one.
        let complete: (NSApplication.ModalResponse?, String?) -> Void
        let field: NSTextField?
    }
    /// Unanswered dialogs in a row before the rest are answered at once: a
    /// page asking faster than anyone could answer, usually from the background.
    static let unshownDialogLimit = 30

    enum DialogPresentation: Equatable { case answerNow, present(offersSuppression: Bool) }

    /// Whether a page's next dialog shows, and whether it offers to stop the
    /// rest. Answered at once, as Cancel: when the person chose not to see
    /// more from this document, or where no one can answer it (a background
    /// tab, another sheet), and for good once that keeps happening.
    static func nextDialog(of page: BrowserPage, canShow: Bool) -> DialogPresentation {
        page.dialogRequests += 1
        guard !page.suppressesDialogs else { return .answerNow }
        guard canShow else {
            page.unshownDialogs += 1
            if page.unshownDialogs >= unshownDialogLimit { page.suppressesDialogs = true }
            return .answerNow
        }
        page.unshownDialogs = 0
        // From its second dialog on, as in Chrome.
        return .present(offersSuppression: page.dialogRequests > 1)
    }

    func showDialog(_ view: WKWebView, frame: WKFrameInfo, message: String, kind: DialogKind,
                            complete: @escaping (Bool, String?) -> Void) {
        let canShow = view.window.map { $0.attachedSheet == nil } ?? false
        guard let id = identities[ObjectIdentifier(view)], let page = pages[id],
              case .present(let offersSuppression) = Self.nextDialog(of: page, canShow: canShow) else {
            complete(false, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(frame.request.url?.host ?? "Website") says"
        alert.informativeText = String(message.prefix(4000))
        alert.addButton(withTitle: "OK")
        if offersSuppression {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t show more dialogs from this page"
            alert.suppressionButton?.setAccessibilityIdentifier("dialog.suppress")
        }
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
        presentAlert(alert, field: field, in: view) { [weak page] response, value in
            if alert.suppressionButton?.state == .on { page?.suppressesDialogs = true }
            complete(response == .alertFirstButtonReturn, value)
        }
    }

    /// Leaving a tab answers its website dialog as Cancel, so a dialog never
    /// keeps anyone in its tab.
    public func dismissDialog(_ id: UUID) { cancelDialog(id) }

    /// One sheet per window: website dialogs and permission prompts alike.
    func presentAlert(_ alert: NSAlert, field: NSTextField? = nil, in view: WKWebView,
                      complete: @escaping (NSApplication.ModalResponse?, String?) -> Void) {
        guard let id = identities[ObjectIdentifier(view)], let window = view.window,
              window.attachedSheet == nil else { complete(nil, nil); return }
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
            pending.complete(response, pending.field?.stringValue)
            self?.scheduleRetention()
        }
    }
    func cancelDialog(_ id: UUID) {
        guard let pending = dialogs.removeValue(forKey: id) else { return }
        pages[id]?.view.setAccessibilityHidden(false)
        pages[id]?.hasDialog = false
        pending.parent.endSheet(pending.alert.window)
        pending.complete(nil, nil)
    }
}
