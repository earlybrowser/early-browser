// SPDX-License-Identifier: MPL-2.0

import WebKit

/// One tab's find-in-page state. A page whose `find` is nil has no find bar.
public struct PageFindState: Equatable, Sendable {
    public static let matchLimit = 1000
    public var query: String
    /// Visible matches, at most `matchLimit`.
    public var matchCount = 0
    /// The highlighted match, 0-based; nil with no matches.
    public var currentIndex: Int?
    public var isCapped = false
    /// A search for `query` has not answered yet.
    public var isSearching = false

    public init(query: String) { self.query = query }
}

/// Find runs in an isolated script world: the page cannot observe or alter the
/// search, and matches are shown with CSS highlights instead of DOM changes.
@MainActor
extension WebViewManager {
    static let findWorld = WKContentWorld.world(name: "Early.Find")

    private enum FindRequest {
        case update
        case step(Int)
    }

    public func canFind(_ id: UUID) -> Bool { pages[id]?.view.url != nil }

    /// Opens the find bar, prefilled with the last search, and searches again.
    @discardableResult
    public func showFind(_ id: UUID) -> Bool {
        guard canFind(id), let page = pages[id] else { return false }
        if page.find == nil {
            page.find = PageFindState(query: lastFindQuery)
            if !lastFindQuery.isEmpty { runFind(id, .update) }
        }
        return true
    }

    public func updateFind(_ id: UUID, query: String) {
        guard let page = pages[id], page.find != nil, page.find?.query != query else { return }
        page.find?.query = query
        lastFindQuery = query
        runFind(id, .update)
    }

    public func canFindNext(_ id: UUID) -> Bool {
        guard canFind(id), let page = pages[id] else { return false }
        return !(page.find?.query ?? lastFindQuery).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Command-G works with the bar closed, as in Safari: it reopens the bar.
    @discardableResult
    public func findNext(_ id: UUID, backwards: Bool = false) -> Bool {
        guard canFindNext(id), let page = pages[id] else { return false }
        if page.find == nil { page.find = PageFindState(query: lastFindQuery) }
        runFind(id, .step(backwards ? -1 : 1))
        return true
    }

    /// Closing leaves the current match selected, like Safari.
    public func hideFind(_ id: UUID) {
        guard let page = pages[id], page.find != nil else { return }
        page.find = nil
        page.findRevision += 1
        findTarget(for: id)?.callAsyncJavaScript("if (window.__earlyFind) window.__earlyFind.clear(true);",
            arguments: [:], in: nil, in: Self.findWorld) { _ in }
    }

    /// The page's selected text, for Use Selection for Find.
    public func findSelection(_ id: UUID) async -> String? {
        guard let view = findTarget(for: id) else { return nil }
        let value = try? await view.callAsyncJavaScript(
            "return String(window.getSelection() || '').replace(/\\s+/g, ' ').trim().slice(0, 1000);",
            arguments: [:], in: nil, contentWorld: Self.findWorld)
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The document being read: Reader's view while it is shown.
    func findTarget(for id: UUID) -> WKWebView? {
        pages[id].map { readerViews[id] ?? $0.view }
    }

    /// A new document starts without matches; the bar stays open and searches
    /// it again once loaded.
    func resetFindForNewDocument(_ id: UUID) {
        guard let page = pages[id], page.find != nil else { return }
        page.findRevision += 1
        page.find?.matchCount = 0
        page.find?.currentIndex = nil
        page.find?.isCapped = false
        page.find?.isSearching = false
    }

    func refreshFindAfterLoad(_ id: UUID) {
        guard let query = pages[id]?.find?.query, !query.isEmpty else { return }
        runFind(id, .update)
    }

    private func runFind(_ id: UUID, _ request: FindRequest) {
        guard let page = pages[id], let query = page.find?.query, let view = findTarget(for: id) else { return }
        page.findRevision += 1
        let revision = page.findRevision
        page.find?.isSearching = true
        var arguments: [String: Any] = ["query": query, "limit": PageFindState.matchLimit, "delta": 0]
        if case .step(let delta) = request { arguments["delta"] = delta }
        let operation = if case .step = request { "step" } else { "update" }
        view.callAsyncJavaScript("\(Self.findLibrary)\nreturn window.__earlyFind.\(operation)(query, delta, limit);",
            arguments: arguments, in: nil, in: Self.findWorld) { [weak self, weak page] result in
                guard let self, let page, self.pages[id] === page, page.findRevision == revision, page.find != nil else { return }
                let answer = (try? result.get()) as? [String: Any]
                let count = (answer?["count"] as? NSNumber)?.intValue ?? 0
                let index = (answer?["index"] as? NSNumber)?.intValue ?? -1
                page.find?.matchCount = count
                page.find?.currentIndex = count > 0 && index >= 0 ? index : nil
                page.find?.isCapped = (answer?["capped"] as? Bool) ?? false
                page.find?.isSearching = false
            }
    }

    /// Installed once per document in the find world, then reused.
    static let findLibrary = #"""
    if (!window.__earlyFind) window.__earlyFind = (() => {
        const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'SELECT', 'OPTION',
            'HEAD', 'TITLE', 'IFRAME', 'OBJECT', 'EMBED', 'CANVAS']);
        const blocks = new Set(['ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'BODY', 'BUTTON', 'CAPTION', 'DD',
            'DETAILS', 'DIALOG', 'DIV', 'DL', 'DT', 'FIELDSET', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'FORM', 'H1', 'H2',
            'H3', 'H4', 'H5', 'H6', 'HEADER', 'HTML', 'LABEL', 'LEGEND', 'LI', 'MAIN', 'NAV', 'OL', 'P', 'PRE',
            'SECTION', 'SUMMARY', 'TABLE', 'TBODY', 'TD', 'TFOOT', 'TH', 'THEAD', 'TR', 'UL']);
        let query = '', ranges = [], index = -1, capped = false, dirty = true, observer = null, sheet = null;

        const blockOf = node => {
            let element = node.parentElement;
            while (element && !blocks.has(element.tagName)) element = element.parentElement;
            return element;
        };
        // All visible text as one string, with an unmatchable separator between
        // blocks so a match can span inline tags but not two paragraphs.
        const collect = () => {
            const segments = [];
            let text = '', lastBlock;
            const visit = root => {
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                    acceptNode(node) {
                        if (node.nodeType !== Node.ELEMENT_NODE) return NodeFilter.FILTER_ACCEPT;
                        if (skipped.has(node.tagName)) return NodeFilter.FILTER_REJECT;
                        return node.shadowRoot ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
                    }
                });
                for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                    if (node.nodeType === Node.ELEMENT_NODE) { visit(node.shadowRoot); continue; }
                    if (!node.data) continue;
                    const block = blockOf(node);
                    if (text.length && block !== lastBlock) text += '\u0000';
                    lastBlock = block;
                    segments.push({ node, start: text.length });
                    text += node.data;
                }
            };
            if (document.body) visit(document.body);
            return { text, segments };
        };
        const pattern = value => {
            const words = value.trim().split(/\s+/).filter(Boolean)
                .map(word => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
            return words.length ? new RegExp(words.join('[\\s\\u00a0]+'), 'giu') : null;
        };
        const locate = (segments, offset, end) => {
            const target = end ? offset - 1 : offset;
            let low = 0, high = segments.length - 1;
            while (low < high) {
                const middle = (low + high + 1) >> 1;
                if (segments[middle].start <= target) low = middle; else high = middle - 1;
            }
            return [segments[low].node, offset - segments[low].start];
        };
        const visible = range => {
            const element = range.startContainer.parentElement;
            if (!element) return false;
            if (typeof element.checkVisibility === 'function'
                && !element.checkVisibility({ visibilityProperty: true, checkVisibilityCSS: true })) return false;
            return range.getClientRects().length > 0;
        };
        const unpaint = () => {
            try {
                CSS.highlights.delete('early-find');
                CSS.highlights.delete('early-find-current');
            } catch (_) {}
        };
        const search = limit => {
            unpaint();
            ranges = [];
            capped = false;
            dirty = false;
            const expression = pattern(query);
            if (!expression) return;
            const { text, segments } = collect();
            for (let match = expression.exec(text); match; match = expression.exec(text)) {
                if (!match[0].length) { expression.lastIndex++; continue; }
                const range = document.createRange();
                try {
                    const [startNode, startOffset] = locate(segments, match.index, false);
                    const [endNode, endOffset] = locate(segments, match.index + match[0].length, true);
                    range.setStart(startNode, startOffset);
                    range.setEnd(endNode, endOffset);
                } catch (_) { continue; }
                if (!visible(range)) continue;
                if (ranges.length >= limit) { capped = true; break; }
                ranges.push(range);
            }
            if (!observer) {
                observer = new MutationObserver(() => { dirty = true; });
                observer.observe(document.documentElement, { childList: true, characterData: true, subtree: true });
            }
        };
        const firstInView = () => {
            const found = ranges.findIndex(range => range.getBoundingClientRect().bottom >= 0);
            return found < 0 ? 0 : found;
        };
        const paint = () => {
            try {
                if (!sheet) {
                    sheet = new CSSStyleSheet();
                    sheet.replaceSync('::highlight(early-find){background-color:rgba(255,212,0,.45);color:inherit}'
                        + '::highlight(early-find-current){background-color:#ff9500;color:#000}');
                }
                if (!document.adoptedStyleSheets.includes(sheet)) {
                    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
                }
                CSS.highlights.set('early-find', new Highlight(...ranges));
                if (index >= 0) {
                    const current = new Highlight(ranges[index]);
                    current.priority = 1;
                    CSS.highlights.set('early-find-current', current);
                } else {
                    CSS.highlights.delete('early-find-current');
                }
            } catch (_) {
                // Without CSS highlights, select the current match instead.
                const selection = window.getSelection();
                if (selection && index >= 0) {
                    selection.removeAllRanges();
                    selection.addRange(ranges[index].cloneRange());
                }
            }
        };
        const reveal = () => {
            const range = ranges[index];
            const element = range && range.startContainer.parentElement;
            if (!element) return;
            const outside = rect => rect.top < 0 || rect.bottom > innerHeight || rect.left < 0 || rect.right > innerWidth;
            if (!outside(range.getBoundingClientRect())) return;
            element.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            const rect = range.getBoundingClientRect();
            if (outside(rect)) window.scrollBy(0, rect.top - innerHeight / 2);
        };
        const answer = () => { paint(); reveal(); return { count: ranges.length, index, capped }; };

        return {
            update(value, delta, limit) {
                query = value;
                search(limit);
                index = ranges.length ? firstInView() : -1;
                return answer();
            },
            step(value, delta, limit) {
                if (value !== query) { query = value; search(limit); index = -1; }
                else if (dirty) {
                    // Keep the place in a changed page: resume at the old match.
                    const previous = ranges[index];
                    search(limit);
                    index = -1;
                    if (previous && ranges.length) {
                        let next = ranges.findIndex(range => {
                            try { return range.compareBoundaryPoints(Range.START_TO_START, previous) >= 0; }
                            catch (_) { return false; }
                        });
                        if (next < 0) next = ranges.length;
                        let same = false;
                        try { same = !!ranges[next] && ranges[next].compareBoundaryPoints(Range.START_TO_START, previous) === 0; }
                        catch (_) {}
                        index = same ? next : (delta > 0 ? next - 1 : next);
                    }
                }
                if (!ranges.length) { index = -1; return answer(); }
                if (index < 0 && delta < 0) index = ranges.length;
                index = ((index + delta) % ranges.length + ranges.length) % ranges.length;
                return answer();
            },
            clear(selectCurrent) {
                const current = ranges[index];
                unpaint();
                if (observer) { observer.disconnect(); observer = null; }
                if (selectCurrent && current) {
                    const selection = window.getSelection();
                    if (selection) { selection.removeAllRanges(); selection.addRange(current.cloneRange()); }
                }
                ranges = [];
                index = -1;
                query = '';
                dirty = true;
            }
        };
    })();
    """#
}
