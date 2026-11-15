// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import WebKit

// MARK: Security state

extension WebViewManager {
    /// A refused certificate wins until the next navigation starts; otherwise
    /// the committed page's scheme and WebKit's secure-content flag decide.
    func updateSecurity(_ page: BrowserPage) {
        let failure = page.certificateFailure
        let security = PageSecurity.classify(url: failure.map { $0.url ?? page.view.url } ?? page.view.url,
                                             hasOnlySecureContent: page.view.hasOnlySecureContent,
                                             certificateFailed: failure != nil)
        let trust = failure?.trust ?? (security == .secure || security == .mixedContent ? page.view.serverTrust : nil)
        if page.security != security { page.security = security }
        if page.serverTrust !== trust { page.serverTrust = trust }
    }

    /// TLS failures, from a failed handshake to an untrusted or expired certificate.
    static func isCertificateError(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain
            && (NSURLErrorClientCertificateRequired...NSURLErrorSecureConnectionFailed).contains(error.code)
    }

    static func peerTrust(_ error: NSError) -> SecTrust? {
        guard let value = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] as CFTypeRef?,
              CFGetTypeID(value) == SecTrustGetTypeID() else { return nil }
        return (value as! SecTrust)
    }
}

// MARK: Site permissions

extension WebViewManager {
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let permissions: [SitePermission] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: []
        }
        decideCapturePermission(permissions, origin: SitePermissions.origin(scheme: origin.protocol, host: origin.host, port: origin.port),
                                host: origin.host, frame: frame, in: webView) { decisionHandler($0 ? .grant : .deny) }
    }

    /// A frame's isolated token lasts only for its document. Check it on both
    /// sides of the prompt, so a navigated or removed frame cannot inherit an
    /// answer. Record the actual requesting origin, including embedded sites.
    func decideCapturePermission(_ permissions: [SitePermission], origin: String?, host: String,
                                 frame: WKFrameInfo, in view: WKWebView,
                                 decide: @escaping @MainActor (Bool) -> Void) {
        guard let id = tabID(for: view), let page = pages[id], let origin, let store = sitePermissions,
              !permissions.isEmpty, permissions.allSatisfy({ $0 == .camera || $0 == .microphone }) else {
            decide(false); return
        }
        let documentID = page.captureDocumentID
        let isCurrent = { [weak self, weak page] in
            guard let self, let page else { return false }
            return self.pages[id] === page && page.captureDocumentID == documentID && self.sitePermissions === store
        }
        captureFrameToken(in: view, frame: frame) { [weak self, weak page] token in
            guard let self, let token, isCurrent() else { decide(false); return }
            self.decidePermission(permissions, origin: origin, host: host, in: view) { [weak self, weak page] allowed in
                guard let self, allowed, isCurrent() else { decide(false); return }
                self.captureFrameToken(in: view, frame: frame) { [weak page] currentToken in
                    guard let page, isCurrent(), currentToken == token,
                          store.decision(for: origin, permissions) == .allow else { decide(false); return }
                    var grant = page.captureGrants[token] ?? .init(origin: origin, permissions: [])
                    grant.permissions.formUnion(permissions)
                    page.captureGrants[token] = grant
                    decide(true)
                }
            }
        }
    }

    private func captureFrameToken(in view: WKWebView, frame: WKFrameInfo, completion: @escaping @MainActor (String?) -> Void) {
        view.evaluateJavaScript("globalThis.__earlyMediaControl?.documentToken ?? null", in: frame, in: .defaultClient) { result in
            let token = (try? result.get()) as? String
            completion(token.flatMap { !$0.isEmpty && $0.count <= 64 ? $0 : nil })
        }
    }

    /// WebKit asks this from macOS 27; earlier systems never offer location.
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    public func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo,
                        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decidePermission([.location], origin: SitePermissions.origin(scheme: origin.protocol, host: origin.host, port: origin.port),
                         host: origin.host, in: webView) { decisionHandler($0 ? .grant : .deny) }
    }

    /// Location reaches websites only where WebKit asks Early about it.
    public static var offersLocation: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    /// A saved choice answers at once. Otherwise the site's tab asks, and the
    /// answer is saved for the site; a dismissed prompt saves nothing.
    func decidePermission(_ permissions: [SitePermission], origin: String?, host: String, in view: WKWebView,
                          decide: @escaping @MainActor (Bool) -> Void) {
        guard !permissions.isEmpty, let origin, let store = sitePermissions,
              let id = tabID(for: view), let page = pages[id], !page.processTerminated,
              store.acceptsChanges else { decide(false); return }
        if !store.isReady {
            let document = page.captureDocumentID
            Task { [weak self, weak page] in
                guard await store.load(), let self, let page, self.pages[id] === page,
                      page.captureDocumentID == document, self.sitePermissions === store else { decide(false); return }
                self.decidePermission(permissions, origin: origin, host: host, in: view, decide: decide)
            }
            return
        }
        switch store.decision(for: origin, permissions) {
        case .allow: decide(true)
        case .block: decide(false)
        case .ask:
            let asked = permissions.filter { store.decision(for: origin, $0) == .ask }
            let choices = permissions.map { store.decision(for: origin, $0) }
            let versions = permissions.map { store.version(for: origin, $0) }
            let documentID = page.captureDocumentID
            let alert = NSAlert()
            alert.messageText = "Allow “\(host)” to use \(Self.permissionPhrase(asked))?"
            alert.informativeText = "Early remembers your choice for this website. You can change it in Site Controls in the address bar."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don’t Allow")
            presentAlert(alert, in: view) { [weak self, weak page] response, _ in
                guard let self, let page, self.pages[id] === page, page.captureDocumentID == documentID,
                      self.sitePermissions === store, store.acceptsChanges, let response,
                      permissions.map({ store.version(for: origin, $0) }) == versions,
                      permissions.map({ store.decision(for: origin, $0) }) == choices else { decide(false); return }
                let allowed = response == .alertFirstButtonReturn
                store.set(allowed ? .allow : .block, for: asked, origin: origin)
                decide(allowed && store.decision(for: origin, permissions) == .allow)
            }
        }
    }

    /// Downloads a page starts without the person's click or key press: at
    /// most this many transfers in all may be running for one to start.
    static let automaticDownloadLimit = 6

    /// The person's latest click or key press in the view, if recent; used up.
    static func takeDownloadAllowance(of view: WKWebView) -> Bool {
        (view as? BrowserWebView)?.takeDownloadAllowance() ?? false
    }

    /// A download the page started by itself asks first, once per website, as
    /// in Safari, and none starts while many are already running. A refused
    /// one leaves a notice on the page.
    func decideAutomaticDownload(_ url: URL, in view: WKWebView, id: UUID, request: AnyObject,
                                 decide: @escaping @MainActor (Bool) -> Void) {
        guard let page = pages[id], page.view === view, !page.processTerminated,
              let store = sitePermissions, store.acceptsChanges else { decide(false); return }
        let document = page.captureDocumentID, navigation = page.navigationGeneration
        let isCurrent = { [weak self, weak page] in
            guard let self, let page else { return false }
            return self.pages[id] === page && page.captureDocumentID == document
                && page.navigationGeneration == navigation && !page.processTerminated
                && self.sitePermissions === store && store.isReady && store.acceptsChanges
        }
        if !store.isReady {
            Task { [weak self] in
                guard await store.load(), isCurrent(), let self else { decide(false); return }
                self.decideAutomaticDownload(url, in: view, id: id, request: request, decide: decide)
            }
            return
        }
        let site = view.url ?? url
        let host = site.host ?? "This page"
        let origin = SitePermissions.origin(of: site)
        let choice = origin.map { store.decision(for: $0, .downloads) } ?? .ask
        let version = origin.map { store.version(for: $0, .downloads) }
        let unchanged = {
            isCurrent() && origin.map { store.version(for: $0, .downloads) } == version
                && (origin.map { store.decision(for: $0, .downloads) } ?? .ask) == choice
        }
        let refuse = { [weak self] (notice: String) in
            if isCurrent() { self?.showNavigationNotice(notice, for: id) }
            decide(false)
        }
        let full = "“\(host)” tried to start another download while many are running, so Early stopped it."
        guard downloads.canReserveAutomaticDownload else { refuse(full); return }
        let blocked = "Early blocked a download from “\(host)” that started without your click. You can allow its downloads in Site Controls."
        let allow = { [weak self] in
            guard let self, unchanged() else { decide(false); return }
            guard let slot = self.downloads.reserveAutomaticDownload() else { refuse(full); return }
            if let origin { store.set(.allow, for: [.downloads], origin: origin) }
            let allowedVersion = origin.map { store.version(for: $0, .downloads) }
            self.authorizeDownload(request, tabID: id, slot: slot) {
                isCurrent() && origin.map { store.version(for: $0, .downloads) } == allowedVersion
                    && (origin.map { store.decision(for: $0, .downloads) == .allow } ?? true)
            }
            decide(true)
        }
        switch choice {
        case .allow: allow()
        case .block: refuse(blocked)
        case .ask:
            var answered = false
            let answer: @MainActor (Bool?) -> Void = { allowed in
                guard !answered else { return }
                answered = true
                guard let allowed, unchanged() else { decide(false); return }
                if allowed { allow() }
                else {
                    if let origin { store.set(.block, for: [.downloads], origin: origin) }
                    refuse(blocked)
                }
            }
            if let askForDownloads { askForDownloads(host, answer); return }
            let alert = NSAlert()
            alert.messageText = "Allow “\(host)” to download files?"
            alert.informativeText = "It started a download without your click. Early remembers your choice for this website. You can change it in Site Controls in the address bar."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don’t Allow")
            presentAlert(alert, in: view) { response, _ in answer(response.map { $0 == .alertFirstButtonReturn }) }
        }
    }

    /// Retain the policy object through WebKit's matching didBecome callback.
    /// Each authorization is consumed once; an expired/cancelled one cannot
    /// fall back to being treated as a user-initiated download.
    func authorizeDownload(_ request: AnyObject, tabID: UUID, slot: UUID? = nil,
                           isCurrent: @escaping @MainActor () -> Bool = { true }) {
        let key = ObjectIdentifier(request), store = downloads
        if let old = downloadAuthorizations.removeValue(forKey: key) {
            old.expiry.cancel()
            if let slot = old.slot { store.releaseAutomaticDownload(slot) }
        }
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            if let slot { store.releaseAutomaticDownload(slot) }
            self?.downloadAuthorizations[key] = nil
        }
        downloadAuthorizations[key] = DownloadAuthorization(request: request, tabID: tabID,
            slot: slot, isCurrent: isCurrent, expiry: expiry)
    }

    func consumeDownloadAuthorization(_ request: AnyObject) -> Bool {
        guard let authorization = downloadAuthorizations.removeValue(forKey: ObjectIdentifier(request)) else { return false }
        authorization.expiry.cancel()
        guard let slot = authorization.slot else { return true }
        let hasRoom = downloads.consumeAutomaticDownload(slot)
        return hasRoom && authorization.isCurrent()
    }

    func cancelAutomaticDownloadAuthorizations(for id: UUID) {
        for (key, authorization) in downloadAuthorizations where authorization.tabID == id && authorization.slot != nil {
            authorization.expiry.cancel()
            if let slot = authorization.slot { downloads.releaseAutomaticDownload(slot) }
            downloadAuthorizations[key] = nil
        }
    }

    static func permissionPhrase(_ permissions: [SitePermission]) -> String {
        let names = permissions.map { permission -> String in
            switch permission {
            case .camera: "camera"
            case .microphone: "microphone"
            case .location: "location"
            case .downloads: "downloads"
            }
        }
        return "your " + ListFormatter.localizedString(byJoining: names)
    }

    /// Ends camera or microphone capture in one tab.
    public func stopCapture(_ permission: SitePermission, in id: UUID) {
        guard let view = pages[id]?.view else { return }
        endCapture(view, permission)
    }

    /// Includes embedded origins and grants that have not begun capture yet.
    /// WebKit can stop one device type per tab, but not one frame's stream:
    /// blocking a frame's camera also ends other camera streams in that tab.
    /// The microphone, other tabs, and other profiles are independent.
    public func applySitePermissions() {
        for id in pages.keys { applySitePermissions(in: id) }
    }

    func applySitePermissions(in id: UUID) {
        guard let store = sitePermissions, let page = pages[id] else { return }
        for permission in [SitePermission.camera, .microphone] {
            let blockedFrame = page.captureGrants.values.contains {
                $0.permissions.contains(permission) && store.decision(for: $0.origin, permission) == .block
            }
            let active = permission == .camera ? page.cameraCapture : page.microphoneCapture
            let blockedPage = active != .none && page.view.url.flatMap(SitePermissions.origin(of:)).map {
                store.decision(for: $0, permission) == .block
            } == true
            if blockedFrame || blockedPage { stopCapture(permission, in: id) }
        }
    }
}

// MARK: Other apps' links

extension WebViewManager {
    /// Addresses the browser itself shows or refuses never go to another app.
    static let browserSchemes: Set<String> = ["http", "https", "file", "about", "blob", "data", "javascript"]

    /// A clicked link for another app (mailto:, tel:, an app's own link) opens
    /// it once the person agrees, as in Safari. Nothing opens without a click.
    func offerToOpenInApp(_ url: URL, action: WKNavigationAction, from view: WKWebView) -> Bool {
        offerToOpenInApp(url, clicked: action.navigationType == .linkActivated, from: view)
    }

    func offerToOpenInApp(_ url: URL, clicked: Bool, from view: WKWebView) -> Bool {
        guard clicked, let scheme = url.scheme?.lowercased(), !Self.browserSchemes.contains(scheme),
              !input.allowedSchemes.contains(scheme), let app = appForLink(url) else { return false }
        let name = FileManager.default.displayName(atPath: app.path)
        let alert = NSAlert()
        alert.messageText = "Allow “\(view.url?.host ?? "this page")” to open “\((name as NSString).deletingPathExtension)”?"
        alert.informativeText = String(url.absoluteString.prefix(300))
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        presentAlert(alert, in: view) { [openInApp] response, _ in
            if response == .alertFirstButtonReturn { openInApp(url) }
        }
        return true
    }
}

// MARK: Automatic Picture in Picture

extension WebViewManager {
    /// macOS has no public switch for Picture in Picture in a web view (the
    /// configuration property is iOS-only). WebKit's own preference, the one
    /// Safari uses, enables it; it is set only where WebKit still has it, so a
    /// WebKit without it simply offers no Picture in Picture.
    static let pictureInPicturePreference = "allowsPictureInPictureMediaPlayback"
    public static let supportsPictureInPicture =
        WKPreferences().responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:"))

    static func enablePictureInPicture(_ preferences: WKPreferences) {
        guard supportsPictureInPicture else { return }
        preferences.setValue(true, forKey: pictureInPicturePreference)
    }

    /// The largest playing video goes into Picture in Picture. Scripts run by
    /// the app count as a user action, so no click is needed.
    static let enterPictureInPictureScript = """
        if (!document.pictureInPictureEnabled || document.pictureInPictureElement) return false;
        const area = v => { const r = v.getBoundingClientRect(); return r.width * r.height; };
        const videos = Array.from(document.querySelectorAll('video')).filter(v => !v.paused && !v.ended
            && v.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA && v.videoWidth > 0 && !v.disablePictureInPicture);
        if (!videos.length) return false;
        videos.sort((a, b) => area(b) - area(a));
        try { await videos[0].requestPictureInPicture(); return true; } catch (e) { return false; }
        """

    static let exitPictureInPictureScript = """
        if (!document.pictureInPictureElement) return false;
        try { await document.exitPictureInPicture(); return true; } catch (e) { return false; }
        """

    /// Leaving a tab that plays media moves its video into Picture in Picture;
    /// coming back returns it to the page. Only videos Early moved come back.
    func updateAutomaticPictureInPicture(hidden: Set<UUID>, shown: Set<UUID>) {
        for id in shown {
            guard let state = automaticPictureInPictureTabs.removeValue(forKey: id), let view = pages[id]?.view else { continue }
            // Still entering: return it from every frame tried, in case the
            // request stalled; one that lands later is returned by its task.
            let frames: [WKFrameInfo?] = switch state {
            case .entering(let frames): frames
            case .entered(let frame): [frame]
            }
            Task { @MainActor [runPageScript] in
                for frame in frames { _ = await runPageScript(view, Self.exitPictureInPictureScript, frame) }
            }
        }
        guard Self.supportsPictureInPicture, automaticPictureInPicture() else { return }
        for id in hidden {
            guard let page = pages[id], page.isPlayingMedia, !page.isFullscreen, !page.hasDialog,
                  automaticPictureInPictureTabs[id] == nil else { continue }
            // Each frame playing media, then the main frame if none is known.
            let playing: [WKFrameInfo?] = page.playingFrames.compactMap { page.mediaFrames[$0] }
            let frames = playing.isEmpty ? [nil] : playing
            automaticPictureInPictureTabs[id] = .entering(frames)
            let view = page.view
            Task { @MainActor [weak self, runPageScript] in
                var entered: WKFrameInfo??
                for frame in frames where await runPageScript(view, Self.enterPictureInPictureScript, frame) {
                    entered = .some(frame)
                    break
                }
                guard let self else { return }
                let stillHidden = self.automaticPictureInPictureTabs[id] != nil
                if let entered, stillHidden {
                    self.automaticPictureInPictureTabs[id] = .entered(entered)
                } else {
                    self.automaticPictureInPictureTabs[id] = nil
                    // The tab came back while its video was moving out.
                    if let entered { _ = await runPageScript(view, Self.exitPictureInPictureScript, entered) }
                }
            }
        }
    }
}

extension WebViewManager {
    /// The return button in Picture in Picture's window. WebKit returns the
    /// video only once its page is visible, and asks the browser to show it
    /// through this delegate method (Safari's; not public API, like the
    /// preference that enables Picture in Picture). Without it the button
    /// does nothing.
    @objc(_webViewFullscreenMayReturnToInline:)
    public func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let id = tabID(for: webView) else { return }
        // WebKit is already returning it; showing the tab needn't ask again.
        automaticPictureInPictureTabs[id] = nil
        onReturnFromPictureInPicture?(id)
    }
}

enum AutomaticPictureInPicture {
    /// Requested from these frames; nil is the main frame.
    case entering([WKFrameInfo?])
    /// In Picture in Picture from this frame; nil is the main frame.
    case entered(WKFrameInfo?)
}

/// Authorization waiting for WebKit to hand the transfer to the profile store.
@MainActor
struct DownloadAuthorization {
    let request: AnyObject
    let tabID: UUID
    let slot: UUID?
    let isCurrent: @MainActor () -> Bool
    let expiry: Task<Void, Never>
}
