// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import Observation
import WebKit

@MainActor @Observable
public final class BrowserPage {
    public let view: WKWebView
    /// Unique per live page; a reopened tab's new page never shares it (unlike
    /// an object address, which a new page can reuse).
    public let instanceID = UUID()
    /// "scheme://host" of the extension whose page this view was made for;
    /// nil for websites. The two never share a view.
    var extensionOrigin: String?
    /// Made from that extension's own configuration, so its pages load.
    var hasExtensionConfiguration = false
    public var isLoading = false
    public var isPlayingMedia = false
    public internal(set) var isMuted = false
    var playingFrames: Set<String> = []
    var mediaFrames: [String: WKFrameInfo] = [:]
    var muteRevision = 0
    public var progress = 0.0
    public var canGoBack = false
    public var canGoForward = false
    public var failure: String?
    public internal(set) var navigationNotice: String?
    public var hasDialog = false
    /// This document's website dialogs: whether the person chose not to see
    /// more, and how many in a row went unanswered (asked from a background
    /// tab, or while another sheet showed). A new document starts over.
    public internal(set) var suppressesDialogs = false
    var dialogRequests = 0
    var unshownDialogs = 0
    /// A navigation Early started for the person (the address bar, a restored
    /// tab, a link they opened), and whether the current main-frame navigation
    /// came from them, so a download it becomes doesn't ask.
    var earlyRequested: URL?
    var downloadsFromPerson = false
    var inServerRedirect = false
    /// The local file whose permission this page holds open.
    var localFile: URL?
    public internal(set) var hasUnsavedInput = false
    public internal(set) var processTerminated = false
    var editedFrames: Set<String> = []
    var automaticRecoveryAttempted = false
    var awaitsNavigationCommit = false
    public var requestedURL: URL
    /// This tab's page zoom; 1 is actual size. Not remembered per site.
    public internal(set) var zoom = 1.0
    /// The find bar's state; nil while it is closed.
    public internal(set) var find: PageFindState?
    var findRevision = 0
    /// The link under the pointer, for the pane's address preview.
    public internal(set) var hoveredLink: LinkHover?
    public internal(set) var isFullscreen = false
    /// Readability judged this document an article.
    public internal(set) var isReaderAvailable = false
    public internal(set) var isPreparingReader = false
    public internal(set) var isReaderShown = false
    public internal(set) var readerArticle: ReaderArticle?
    /// The page's language (BCP 47), detected from its text after loading.
    public internal(set) var language: String?
    public internal(set) var translation = PageTranslationPhase.original
    /// The running translation; an older one, or its error, changes nothing.
    var translationRun: UUID?
    /// The connection's trust, from WebKit's public secure-content state.
    public internal(set) var security = PageSecurity.none
    /// The certificate behind `security`, for the certificate panel.
    public internal(set) var serverTrust: SecTrust?
    /// A navigation refused for its certificate, until the next one starts.
    var certificateFailure: CertificateFailure?
    /// A sign-in Early offers to save or update, until it is answered.
    public internal(set) var passwordOffer: PasswordOffer?
    var pendingLogin: PendingLogin?
    var recentUsername: RecentUsername?
    public internal(set) var cameraCapture = WKMediaCaptureState.none
    public internal(set) var microphoneCapture = WKMediaCaptureState.none
    /// The committed main document's MIME type, e.g. a viewed PDF.
    public internal(set) var documentMIMEType: String?
    var pendingDocumentMIMEType: String?
    var observations: [NSKeyValueObservation] = []
    var reportedURL: URL?
    var reportedTitle: String?
    var navigationGeneration = UUID()
    var activeNavigation: ObjectIdentifier?
    var policyCancellations: [NavigationPolicyCancellation] = []
    init(view: WKWebView, url: URL) { self.view = view; requestedURL = url }

    struct CertificateFailure {
        let url: URL?
        let trust: SecTrust?
    }
}
