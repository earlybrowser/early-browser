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
        decidePermission(permissions, origin: SitePermissions.origin(scheme: origin.protocol, host: origin.host, port: origin.port),
                         host: origin.host, in: webView) { decisionHandler($0 ? .grant : .deny) }
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
        guard !permissions.isEmpty, let origin, let store = sitePermissions else { decide(false); return }
        switch store.decision(for: origin, permissions) {
        case .allow: decide(true)
        case .block: decide(false)
        case .ask:
            let asked = permissions.filter { store.decision(for: origin, $0) == .ask }
            let alert = NSAlert()
            alert.messageText = "Allow “\(host)” to use \(Self.permissionPhrase(asked))?"
            alert.informativeText = "Early remembers your choice for this website. You can change it in Site Controls in the address bar."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don’t Allow")
            presentAlert(alert, in: view) { response, _ in
                guard let response else { decide(false); return }
                let allowed = response == .alertFirstButtonReturn
                store.set(allowed ? .allow : .block, for: asked, origin: origin)
                decide(allowed)
            }
        }
    }

    static func permissionPhrase(_ permissions: [SitePermission]) -> String {
        let names = permissions.map { permission -> String in
            switch permission {
            case .camera: "camera"
            case .microphone: "microphone"
            case .location: "location"
            }
        }
        return "your " + ListFormatter.localizedString(byJoining: names)
    }

    /// Ends camera or microphone capture in one tab.
    public func stopCapture(_ permission: SitePermission, in id: UUID) {
        guard let view = pages[id]?.view else { return }
        switch permission {
        case .camera: view.setCameraCaptureState(.none, completionHandler: nil)
        case .microphone: view.setMicrophoneCaptureState(.none, completionHandler: nil)
        case .location: break
        }
    }

    /// A newly blocked camera or microphone stops in every tab of the site.
    public func applySitePermissions() {
        guard let store = sitePermissions else { return }
        for (id, page) in pages {
            guard let origin = page.view.url.flatMap(SitePermissions.origin(of:)) else { continue }
            if page.cameraCapture != .none, store.decision(for: origin, .camera) == .block { stopCapture(.camera, in: id) }
            if page.microphoneCapture != .none, store.decision(for: origin, .microphone) == .block { stopCapture(.microphone, in: id) }
        }
    }
}

// MARK: Automatic Picture in Picture

extension WebViewManager {
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
            // Still entering: the request below returns it once it lands.
            guard case .entered(let frame) = automaticPictureInPictureTabs.removeValue(forKey: id),
                  let view = pages[id]?.view else { continue }
            Task { @MainActor [runPageScript] in _ = await runPageScript(view, Self.exitPictureInPictureScript, frame) }
        }
        guard automaticPictureInPicture() else { return }
        for id in hidden {
            guard let page = pages[id], page.isPlayingMedia, !page.isFullscreen, !page.hasDialog,
                  automaticPictureInPictureTabs[id] == nil else { continue }
            // Each frame playing media, then the main frame if none is known.
            var frames: [WKFrameInfo?] = page.playingFrames.compactMap { page.mediaFrames[$0] }
            if frames.isEmpty { frames = [nil] }
            automaticPictureInPictureTabs[id] = .entering
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

enum AutomaticPictureInPicture {
    case entering
    /// In Picture in Picture from this frame; nil is the main frame.
    case entered(WKFrameInfo?)
}
