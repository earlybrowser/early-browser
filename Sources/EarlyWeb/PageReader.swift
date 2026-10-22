// SPDX-License-Identifier: MPL-2.0

import AppKit
import WebKit

/// A readable copy of an article, extracted by Mozilla Readability.
public struct ReaderArticle: Equatable, Sendable {
    public let title: String
    public let byline: String?
    public let siteName: String?
    public let language: String?
    public let isRightToLeft: Bool
    /// Cleaned article HTML: no scripts, frames, forms, styles or handlers.
    public let content: String
    public let wordCount: Int

    public var readingMinutes: Int { max(1, Int((Double(wordCount) / 230).rounded())) }

    init?(_ value: Any?) {
        guard let values = value as? [String: Any], let content = values["content"] as? String,
              !content.isEmpty, content.utf8.count <= 4_000_000 else { return nil }
        func text(_ key: String) -> String? {
            let value = (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? String(value!.prefix(300)) : nil
        }
        title = text("title") ?? ""
        byline = text("byline")
        siteName = text("siteName")
        language = text("lang").flatMap { $0.count <= 35 ? $0 : nil }
        isRightToLeft = (values["dir"] as? String)?.lowercased() == "rtl"
        self.content = content
        wordCount = (values["words"] as? NSNumber)?.intValue ?? 0
    }
}

/// Theme colors for Reader's links and accents, as `#rrggbb`.
public struct ReaderAccent: Equatable, Sendable {
    public let light: String
    public let dark: String
    public init(light: String, dark: String) {
        let valid = { (value: String) in value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }
        self.light = valid(light) ? light : "#3a6fb0"
        self.dark = valid(dark) ? dark : "#7aa7e0"
    }
}

/// Reader's own view: the article with page JavaScript disabled and a strict
/// content policy. Links leave Reader; only working menu items remain.
@MainActor
public final class ReaderWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    var onOpenLink: ((URL, Bool) -> Void)?
    var onExit: (() -> Void)?
    let documentURL: URL?
    private var loadedDocument = false

    static let menuItems: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink",
        "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierShareMenu",
        "WKMenuItemIdentifierSpeechMenu"]

    init(configuration: WKWebViewConfiguration, documentURL: URL?) {
        self.documentURL = documentURL
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        uiDelegate = self
        allowsMagnification = true
        allowsBackForwardNavigationGestures = false
        setAccessibilityIdentifier("reader.view")
        matchPageColor()
    }

    /// The pane paints this behind the view, so it must be Reader's own page
    /// color, or another page's shows through the rounded corners. WebKit keeps
    /// a fixed color, so follow light and dark here.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        matchPageColor()
    }

    private func matchPageColor() {
        underPageBackgroundColor = ReaderDocument.pageColor(for: effectiveAppearance)
    }

    required init?(coder: NSCoder) { nil }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if !loadedDocument && navigationAction.navigationType == .other {
            loadedDocument = true
            decisionHandler(.allow)
        } else if let url, navigationAction.targetFrame?.isMainFrame == true, Self.sameDocument(url, documentURL) {
            decisionHandler(.allow) // A table-of-contents jump within the article.
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let url {
                onOpenLink?(url, navigationAction.modifierFlags.contains(.command))
            }
        }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { onOpenLink?(url, true) }
        return nil
    }

    static func sameDocument(_ url: URL, _ document: URL?) -> Bool {
        guard let document, url.fragment != nil,
              var left = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var right = URLComponents(url: document, resolvingAgainstBaseURL: false) else { return false }
        left.fragment = nil
        right.fragment = nil
        return left == right
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where !item.isSeparatorItem && !Self.menuItems.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        // No leading, trailing or doubled separators after filtering.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            else { previousWasSeparator = item.isSeparatorItem }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(menu.items.last!) }
        super.willOpenMenu(menu, with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty, let onExit {
            onExit()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
extension WebViewManager {
    static let readerWorld = WKContentWorld.world(name: "Early.Reader")
    static let readabilitySource = readabilityResource("Readability")
    static let readerableSource = readabilityResource("Readability-readerable")

    private static func readabilityResource(_ name: String) -> String? {
        Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Readability")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    public func canToggleReader(_ id: UUID) -> Bool {
        guard let page = pages[id] else { return false }
        return page.isReaderShown || (page.isReaderAvailable && !page.isPreparingReader)
    }

    /// Readability's own quick check, run after each load in an isolated world.
    func checkReaderAvailability(_ id: UUID) {
        guard let page = pages[id], let source = Self.readerableSource,
              let url = page.view.url, (try? input.validate(url)) != nil else {
            pages[id]?.isReaderAvailable = false
            return
        }
        let generation = page.navigationGeneration
        page.view.callAsyncJavaScript("\(source)\nreturn isProbablyReaderable(document);",
            arguments: [:], in: nil, in: Self.readerWorld) { [weak self, weak page] result in
                guard let self, let page, self.pages[id] === page, page.navigationGeneration == generation else { return }
                let available = (try? result.get()) as? Bool ?? false
                if page.isReaderAvailable != available { page.isReaderAvailable = available }
            }
    }

    /// Extracts the article from a copy of the page and shows it in Reader.
    @discardableResult
    public func showReader(_ id: UUID, accent: ReaderAccent) async -> Bool {
        // Only a page that passed the article check: Readability would extract
        // something from almost any page.
        guard let page = pages[id], page.isReaderAvailable, !page.isReaderShown, !page.isPreparingReader,
              let source = Self.readabilitySource, let url = page.view.url else { return false }
        page.isPreparingReader = true
        defer { page.isPreparingReader = false }
        let generation = page.navigationGeneration
        let value = try? await page.view.callAsyncJavaScript("\(source)\n\(Self.readerExtraction)",
            arguments: [:], in: nil, contentWorld: Self.readerWorld)
        guard pages[id] === page, page.navigationGeneration == generation, !page.isReaderShown,
              let article = ReaderArticle(value) else { return false }
        hideFind(id)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        let reader = ReaderWebView(configuration: configuration, documentURL: url)
        reader.pageZoom = page.zoom
        reader.onOpenLink = { [weak self] link, newTab in self?.openReaderLink(link, from: id, newTab: newTab) }
        reader.onExit = { [weak self] in self?.hideReader(id) }
        reader.loadHTMLString(ReaderDocument.html(article, accent: accent), baseURL: url)
        readerViews[id] = reader
        page.readerArticle = article
        page.isReaderShown = true
        return true
    }

    public func readerView(for id: UUID) -> WKWebView? { readerViews[id] }

    public func hideReader(_ id: UUID) {
        if pages[id]?.isReaderShown == true { hideFind(id) }
        if let reader = readerViews.removeValue(forKey: id) as? ReaderWebView {
            reader.stopLoading()
            reader.onOpenLink = nil
            reader.onExit = nil
            reader.navigationDelegate = nil
            reader.uiDelegate = nil
        }
        guard let page = pages[id], page.isReaderShown || page.readerArticle != nil else { return }
        page.isReaderShown = false
        page.readerArticle = nil
    }

    /// A link leaves Reader and opens in this tab (Command-click: a new tab),
    /// like a link on the page. Only web addresses are followed.
    func openReaderLink(_ url: URL, from id: UUID, newTab: Bool) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let valid = try? input.validate(url),
              let page = pages[id] else { return }
        if newTab {
            onOpenBackgroundLink?(valid)
        } else {
            hideReader(id)
            page.view.load(URLRequest(url: valid))
        }
    }

    /// Appended to Readability in the same function body.
    static let readerExtraction = #"""
    const parsed = new Readability(document.cloneNode(true), { charThreshold: 500 }).parse();
    if (!parsed || !parsed.content) return null;
    const holder = new DOMParser().parseFromString('<!doctype html><body></body>', 'text/html');
    holder.body.innerHTML = parsed.content;
    holder.querySelectorAll('script, style, link, meta, base, iframe, frame, frameset, object, embed, applet, '
        + 'form, input, button, select, textarea, noscript, template, dialog, portal').forEach(node => node.remove());
    const unsafe = /^(javascript|vbscript|file|data:text\/html)/;
    for (const element of holder.body.querySelectorAll('*')) {
        for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name.toLowerCase();
            const value = attribute.value.replace(/\s+/g, '').toLowerCase();
            if (name.startsWith('on') || ['style', 'srcdoc', 'formaction', 'action', 'ping', 'autofocus',
                'contenteditable', 'tabindex', 'target'].includes(name)) {
                element.removeAttribute(attribute.name);
            } else if (['href', 'src', 'xlink:href', 'poster', 'data', 'srcset'].includes(name) && unsafe.test(value)) {
                element.removeAttribute(attribute.name);
            }
        }
    }
    const text = holder.body.textContent || '';
    return {
        title: parsed.title || document.title || '',
        byline: parsed.byline || null,
        siteName: parsed.siteName || null,
        lang: parsed.lang || document.documentElement.lang || null,
        dir: parsed.dir || null,
        content: holder.body.innerHTML,
        words: (text.match(/\S+/g) || []).length
    };
    """#
}

/// The Reader page: the cleaned article in readable type, light or dark with
/// the system, accented in the Space's theme.
enum ReaderDocument {
    /// Matches `--page` in the stylesheet below, for light and dark.
    static func pageColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1b / 255, green: 0x1b / 255, blue: 0x1d / 255, alpha: 1)
            : NSColor(srgbRed: 0xfb / 255, green: 0xfb / 255, blue: 0xf9 / 255, alpha: 1)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func html(_ article: ReaderArticle, accent: ReaderAccent) -> String {
        let language = article.language.map { " lang=\"\(escape($0))\"" } ?? ""
        let direction = article.isRightToLeft ? " dir=\"rtl\"" : ""
        let site = article.siteName.map { "<p class=\"site\">\(escape($0))</p>" } ?? ""
        let title = article.title.isEmpty ? "" : "<h1 class=\"title\">\(escape(article.title))</h1>"
        let meta = ([article.byline].compactMap { $0.map(escape) } + ["\(article.readingMinutes) min read"])
            .joined(separator: " · ")
        return """
        <!doctype html><html\(language)\(direction)><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data: blob:; media-src * data: blob:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(article.title))</title>
        <style>
        :root { color-scheme: light dark; --accent: \(accent.light); --text: #1d1d1f; --muted: #6e6e73; --page: #fbfbf9; --rule: rgba(0,0,0,.12); }
        @media (prefers-color-scheme: dark) { :root { --accent: \(accent.dark); --text: #e8e8ea; --muted: #9a9aa0; --page: #1b1b1d; --rule: rgba(255,255,255,.14); } }
        html { background: var(--page); }
        body { margin: 0; color: var(--text); font: 20px/1.62 ui-serif, "New York", Georgia, serif; -webkit-font-smoothing: antialiased; }
        main { max-width: 38em; margin: 0 auto; padding: 64px 32px 120px; }
        .site { margin: 0 0 14px; font: 600 13px/1.3 -apple-system, system-ui, sans-serif; letter-spacing: .04em; text-transform: uppercase; color: var(--accent); }
        .title { margin: 0 0 .35em; font-size: 1.85em; line-height: 1.18; font-weight: 700; }
        .meta { margin: 0 0 2.4em; padding-bottom: 1.6em; border-bottom: 1px solid var(--rule); font: 14px/1.4 -apple-system, system-ui, sans-serif; color: var(--muted); }
        h2, h3, h4 { line-height: 1.25; margin: 1.6em 0 .5em; }
        p, ul, ol, figure, blockquote, pre, table { margin: 0 0 1.1em; }
        a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
        img, video, svg, figure { max-width: 100%; height: auto; }
        figure img { display: block; margin: 0 auto; border-radius: 6px; }
        figcaption { font: 14px/1.45 -apple-system, system-ui, sans-serif; color: var(--muted); margin-top: .5em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid var(--accent); color: var(--muted); }
        pre, code { font: .82em/1.5 ui-monospace, Menlo, monospace; }
        pre { white-space: pre-wrap; padding: 12px 14px; border-radius: 8px; background: var(--rule); }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        td, th { border: 1px solid var(--rule); padding: .35em .6em; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        </style></head>
        <body><main><header>\(site)\(title)<p class="meta">\(meta)</p></header>
        <article>\(article.content)</article></main></body></html>
        """
    }
}
