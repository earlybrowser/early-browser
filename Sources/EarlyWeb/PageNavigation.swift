// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import WebKit

/// WebKit's navigation delegate: what a page may load or download, and how
/// loads start, finish, fail and recover after a web process ends.
extension WebViewManager {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload, isDownloadable(url) {
            guard let id = identities[ObjectIdentifier(webView)], let page = pages[id] else { decisionHandler(.cancel); return }
            // WebKit ends the navigation once it becomes a download; that
            // expected interruption is not a page failure.
            cancelForPolicy(id, url: url, mainFrame: mainFrame, notice: nil)
            recordNavigation(.init(tabID: id, event: "download-action", url: url, isMainFrame: mainFrame))
            if page.earlyRequested == url || Self.takeDownloadAllowance(of: webView) {
                decisionHandler(.download)
            } else {
                decideAutomaticDownload(url, in: webView, id: id) { decisionHandler($0 ? .download : .cancel) }
            }
            return
        }
        if url.isFileURL {
            decideLocalNavigation(to: url, action: action, in: webView, mainFrame: mainFrame, decisionHandler: decisionHandler)
            return
        }
        if (try? input.validate(url)) != nil {
            // A website cannot obtain an extension's configuration by linking
            // or redirecting to its origin. Trusted browser/extension commands
            // already prepared the correct view before starting navigation.
            // Subresources stay under WebKit's web_accessible_resources checks.
            if mainFrame, let origin = Self.extensionOrigin(of: url),
               let id = identities[ObjectIdentifier(webView)], let page = pages[id],
               !page.hasExtensionConfiguration || page.extensionOrigin != origin {
                decisionHandler(.cancel)
                cancelForPolicy(id, url: url, mainFrame: true,
                                notice: "This page can only be opened from its extension.")
                keepCurrentDocument(id)
                return
            }
            if openCommandClickedLink(action, in: webView) {
                decisionHandler(.cancel)
                return
            }
            // Leaving an extension drops its privileged configuration. The
            // reverse must never promote a website into an extension page.
            if mainFrame, action.targetFrame != nil, let id = identities[ObjectIdentifier(webView)],
               let page = pages[id], page.hasExtensionConfiguration, page.extensionOrigin != nil,
               Self.extensionOrigin(of: url) == nil {
                decisionHandler(.cancel)
                cancelForPolicy(id, url: url, mainFrame: true, notice: nil)
                DispatchQueue.main.async { [weak self] in self?.onNeedsNewView?(id, url) }
                return
            }
            if mainFrame, let id = identities[ObjectIdentifier(webView)], let page = pages[id] {
                // Redirects keep what the navigation's start decided.
                if !page.inServerRedirect {
                    page.downloadsFromPerson = page.earlyRequested == url || Self.takeDownloadAllowance(of: webView)
                }
                page.inServerRedirect = false
                page.earlyRequested = nil
            }
            if mainFrame, action.targetFrame != nil,
               let id = identities[ObjectIdentifier(webView)] {
                pages[id]?.requestedURL = url
                if action.navigationType != .other {
                    cancelRecovery(id)
                    pages[id]?.automaticRecoveryAttempted = false
                    pages[id]?.processTerminated = false
                }
            }
            decisionHandler(.allow)
        } else if !mainFrame, ["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if let id = identities[ObjectIdentifier(webView)] {
                let offered = offerToOpenInApp(url, action: action, from: webView)
                cancelForPolicy(id, url: url, mainFrame: mainFrame,
                    notice: mainFrame && !offered ? "This link uses an unsupported address type (\(url.scheme ?? "unknown"))." : nil)
            }
        }
    }

    /// Web addresses are validated; data/blob documents are page-local files.
    func isDownloadable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "data", "blob": true
        case "http", "https": (try? input.validate(url)) != nil
        default: false
        }
    }

    /// Local documents load only from Early's own requests (Open File, drops,
    /// restoration, reload), from another local page, or through history. A
    /// web page can never open a local file.
    func decideLocalNavigation(to url: URL, action: WKNavigationAction, in webView: WKWebView, mainFrame: Bool,
                                       decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard (try? input.validate(url)) != nil, let id = identities[ObjectIdentifier(webView)], let page = pages[id] else {
            decisionHandler(.cancel)
            return
        }
        let fromLocalPage = webView.url?.isFileURL == true
        if page.requestedURL == url || fromLocalPage || action.navigationType == .backForward || action.navigationType == .reload {
            if mainFrame { page.requestedURL = url }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        cancelForPolicy(id, url: url, mainFrame: mainFrame, notice: nil)
        // A file dropped on a page that does not accept it opens as a new tab,
        // leaving a pinned or saved page in place.
        if mainFrame, action.navigationType == .other { onOpenFiles?([url]) }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let policy = navigationResponsePolicy(for: webView, response: response.response,
            canShowMIMEType: response.canShowMIMEType, isMainFrame: response.isForMainFrame)
        guard policy == .download, response.isForMainFrame, let id = identities[ObjectIdentifier(webView)],
              let page = pages[id], let url = response.response.url else { decisionHandler(policy); return }
        let fromPerson = page.downloadsFromPerson
        page.downloadsFromPerson = false
        if fromPerson { decisionHandler(.download) }
        else { decideAutomaticDownload(url, in: webView, id: id) { decisionHandler($0 ? .download : .cancel) } }
    }

    /// Same path for the delegate and deterministic response fixtures. Embedded
    /// responses cannot produce a top-level download warning or page failure.
    func navigationResponsePolicy(for view: WKWebView, response: URLResponse,
                                  canShowMIMEType: Bool, isMainFrame: Bool) -> WKNavigationResponsePolicy {
        guard let id = identities[ObjectIdentifier(view)], pages[id] != nil else { return .cancel }
        let disposition = NavigationResponseDisposition.classify(response, canShowMIMEType: canShowMIMEType, isMainFrame: isMainFrame)
        recordNavigation(.init(tabID: id, event: "response-\(disposition.rawValue)", url: response.url,
            status: (response as? HTTPURLResponse)?.statusCode, mimeType: response.mimeType, isMainFrame: isMainFrame))
        guard disposition != .allow else {
            if isMainFrame { pages[id]?.pendingDocumentMIMEType = response.mimeType?.lowercased() }
            return .allow
        }
        // A download ends this navigation with WebKit's expected interruption;
        // the current page stays as it was, without a notice or failure.
        cancelForPolicy(id, url: response.url, mainFrame: isMainFrame, notice: nil)
        if isMainFrame { keepCurrentDocument(id) }
        return disposition == .download && response.url.map(isDownloadable) == true ? .download : .cancel
    }

    /// Reload must reload the page still on screen, not repeat a download.
    func keepCurrentDocument(_ id: UUID) {
        guard let page = pages[id] else { return }
        page.pendingDocumentMIMEType = nil
        guard let current = page.view.url.flatMap({ try? input.validate($0) }) else { return }
        page.requestedURL = current
        page.awaitsNavigationCommit = false
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adoptDownload(download, from: webView)
        closeBlankPageAfterDownload(webView)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adoptDownload(download, from: webView)
        closeBlankPageAfterDownload(webView)
    }

    /// A tab opened only for a download (a target-blank file link, or an address
    /// that turned out to be a file) has nothing to show; close it as other
    /// browsers do. The download continues.
    func closeBlankPageAfterDownload(_ view: WKWebView) {
        guard let id = tabID(for: view), view.url == nil, !view.canGoBack else { return }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.pages[id]?.view === view, view.url == nil else { return }
            self.onClose?(id)
        }
    }

    /// Downloads outlive their page; while active they protect it from
    /// background discard, because a blob/data source belongs to its document.
    @discardableResult
    func adoptDownload(_ download: WKDownload, from view: WKWebView?, destination: URL? = nil, listed: Bool = true,
                       settled: ((DownloadItem) -> Void)? = nil) -> DownloadItem {
        let id = view.flatMap { identities[ObjectIdentifier($0)] }
        let origin = id.flatMap { pages[$0]?.view.url }
        let item = downloads.adopt(download, source: download.originalRequest?.url, origin: origin,
                                   destination: destination, listed: listed)
        if let id, let token = protect(tabID: id, reason: .download) {
            item.onSettled.append { [weak self] _ in self?.releaseProtection(tabID: id, token: token) }
        }
        if let settled { item.onSettled.append(settled) }
        if listed { onDownloadStarted?(item) }
        return item
    }

    /// Download Linked File, Save Image As and saving a viewed PDF.
    @discardableResult
    public func startDownload(_ url: URL, from tabID: UUID, to destination: URL? = nil, listed: Bool = true,
                              settled: ((DownloadItem) -> Void)? = nil) -> Bool {
        guard let page = pages[tabID], isDownloadable(url) else { return false }
        // Adopt inside WebKit's callback. WebKit can ask for a destination right
        // after it, and a delegate set from an awaited continuation may be too
        // late: the download would then be dropped while it shows "Starting…".
        page.view.startDownload(using: URLRequest(url: url)) { [weak self, weak view = page.view] download in
            guard let self else { download.cancel { _ in }; return }
            self.adoptDownload(download, from: view, destination: destination, listed: listed, settled: settled)
        }
        return true
    }

    func hasProtection(tabID: UUID, reason: Protection) -> Bool {
        protections[tabID]?.values.contains(reason) == true
    }

    func cancelForPolicy(_ id: UUID, url: URL?, mainFrame: Bool, notice: String?) {
        guard let page = pages[id] else { return }
        page.policyCancellations.append(.init(generation: page.navigationGeneration, url: url, isMainFrame: mainFrame))
        if page.policyCancellations.count > 8 { page.policyCancellations.removeFirst() }
        if mainFrame { page.navigationNotice = notice }
    }

    public func dismissNavigationNotice(for id: UUID) { pages[id]?.navigationNotice = nil }

    func showNavigationNotice(_ notice: String, for id: UUID) { pages[id]?.navigationNotice = notice }

    func recordNavigation(_ event: NavigationDiagnostic) {
        navigationDiagnostics.append(event)
        if navigationDiagnostics.count > 24 { navigationDiagnostics.removeFirst(navigationDiagnostics.count - 24) }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        beginLoading(id)
        pages[id]?.activeNavigation = navigation.map(ObjectIdentifier.init)
        refresh(id)
    }
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        pages[id]?.playingFrames.removeAll()
        pages[id]?.mediaFrames.removeAll()
        pages[id]?.isPlayingMedia = false
        pages[id]?.editedFrames.removeAll()
        pages[id]?.hasUnsavedInput = false
        pages[id]?.awaitsNavigationCommit = false
        pages[id]?.suppressesDialogs = false
        pages[id]?.dialogRequests = 0
        pages[id]?.unshownDialogs = 0
        // Left the local file for a website: its permission closes.
        if let page = pages[id], webView.url?.isFileURL != true { releaseLocalFile(of: page) }
        pages[id]?.policyCancellations.removeAll()
        pages[id]?.navigationNotice = nil
        pages[id]?.documentMIMEType = pages[id]?.pendingDocumentMIMEType
        pages[id]?.pendingDocumentMIMEType = nil
        resetFindForNewDocument(id)
        if focusedPasswordField?.tabID == id { hidePasswordSuggestions() }
        pages[id]?.hoveredLink = nil
        // Reader shows one document; a new one returns to the page.
        hideReader(id)
        pages[id]?.isReaderAvailable = false
        resetTranslationForNewDocument(id)
        if let url = webView.url.flatMap({ try? input.validate($0) }) { pages[id]?.requestedURL = url }
    }
    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)] else { return }
        pages[id]?.inServerRedirect = true
        recordNavigation(.init(tabID: id, event: "redirect", url: webView.url, isMainFrame: true))
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = identities[ObjectIdentifier(webView)], let page = pages[id] else { return }
        page.navigationNotice = nil
        page.policyCancellations.removeAll()
        transition(id, .finishLoading)
        refresh(id)
        captureSnapshot(id)
        scheduleRetention()
        refreshFindAfterLoad(id)
        checkReaderAvailability(id)
        detectPageLanguage(id)
        checkPendingLogin(id)
        guard let url = webView.url else { return }
        let generation = page.navigationGeneration
        // Read only the loaded document, in an isolated JS world. No injected
        // observers, external discovery service, or off-screen page loads.
        webView.evaluateJavaScript("""
            Array.from(document.querySelectorAll('link[rel]'))
                .filter(link => link.rel.toLowerCase().split(/\\s+/).includes('icon'))
                .slice(0, 8).map(link => link.href)
            """, in: nil, in: .defaultClient) { [weak self, weak page] result in
                guard let self, let page, self.pages[id] === page,
                      page.navigationGeneration == generation, page.view.url == url else { return }
                let links = (try? result.get()) as? [String] ?? []
                self.favicons.request(url, discovered: links)
            }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation: navigation, error)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation: navigation, error)
    }
    func failed(_ view: WKWebView, navigation: WKNavigation?, _ error: Error) {
        guard let id = identities[ObjectIdentifier(view)], let page = pages[id] else { return }
        let nsError = error as NSError
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        if let navigation, let active = page.activeNavigation, active != ObjectIdentifier(navigation) {
            recordNavigation(.init(tabID: id, event: "stale-navigation-error", url: failingURL, isMainFrame: true, error: nsError))
            return
        }
        // WebKit reports intentional policy cancellation with its legacy error
        // domain/code (WebKitErrors.h). Suppress only our matching decision, not
        // every policy error, and never match an unrelated NSError by code alone.
        let interruption = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
        let match = interruption ? page.policyCancellations.firstIndex { cancellation in
            cancellation.generation == page.navigationGeneration
                && (failingURL == nil ? cancellation.isMainFrame : cancellation.url == failingURL)
        } : nil
        if let match {
            let cancelled = page.policyCancellations.remove(at: match)
            recordNavigation(.init(tabID: id, event: "expected-policy-cancellation", url: failingURL ?? cancelled.url,
                isMainFrame: cancelled.isMainFrame, error: nsError))
            if cancelled.isMainFrame { refresh(id) }
            return
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            recordNavigation(.init(tabID: id, event: "cancelled", url: failingURL, isMainFrame: true, error: nsError))
            refresh(id)
            return
        }
        recordNavigation(.init(tabID: id, event: "failure", url: failingURL ?? page.requestedURL, isMainFrame: true, error: nsError))
        if Self.isCertificateError(nsError) {
            page.certificateFailure = .init(url: failingURL ?? page.requestedURL, trust: Self.peerTrust(nsError))
        }
        page.failure = error.localizedDescription
        transition(id, .fail)
        refresh(id)
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = identities[ObjectIdentifier(webView)], let page = pages[id] else { return }
        cancelRecovery(id)
        snapshots.invalidate(tabID: id)
        page.navigationGeneration = UUID()
        page.failure = "The web content process stopped. Reload to reopen this page."
        page.processTerminated = true
        page.isLoading = false
        page.isPlayingMedia = false
        page.playingFrames.removeAll()
        page.mediaFrames.removeAll()
        cancelDialog(id)
        transition(id, .fail)
        // Background failures do not generate network requests. Selection can
        // recover them later. Only one automatic retry is allowed until the
        // user explicitly navigates/reloads, including repeated crash loops.
        if visibleTabIDs.contains(id) { recoverIfNeeded(id) }
        scheduleRetention()
    }

    func cancelRecovery(_ id: UUID) {
        recoveryTasks.removeValue(forKey: id)?.cancel()
    }

    func recoverIfNeeded(_ id: UUID) {
        guard let page = pages[id], page.processTerminated, !page.automaticRecoveryAttempted,
              !page.hasUnsavedInput, recoveryTasks[id] == nil else { return }
        page.automaticRecoveryAttempted = true
        let generation = page.navigationGeneration
        recoveryTasks[id] = Task { @MainActor [weak self, weak page] in
            await Task.yield()
            guard !Task.isCancelled, let self, let page, self.pages[id] === page,
                  page.navigationGeneration == generation else { return }
            self.recoveryTasks[id] = nil
            guard self.visibleTabIDs.contains(id), page.processTerminated else {
                page.automaticRecoveryAttempted = false
                return
            }
            page.processTerminated = false
            self.beginLoading(id)
            // Reload the last validated address as a GET; never replay POST
            // bodies, dialogs, or claim that dead form/JavaScript state survived.
            page.activeNavigation = startNavigation(to: page.requestedURL, in: page.view).map(ObjectIdentifier.init)
        }
    }

    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Never accepts invalid certificates or makes up credentials; a
        // website's own sign-in asks the person.
        handleAuthentication(challenge, in: webView, completionHandler: completionHandler)
    }
}
