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
        // The DOM Standard allows these HTML elements and custom elements to host a shadow root.
        const shadowHostNames = new Set(['ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'BODY', 'DIV', 'FOOTER', 'H1', 'H2',
            'H3', 'H4', 'H5', 'H6', 'HEADER', 'MAIN', 'NAV', 'P', 'SECTION', 'SPAN']);
        let query = '', ranges = [], index = -1, capped = false, dirty = true, sheet = null;
        let hiddenRanges = [], hiddenOverflow = false;
        let roots = new Set(), potentialHosts = [];
        const invalidate = () => { dirty = true; };
        const observer = new MutationObserver(invalidate);
        const stylesheetLoaded = event => { if (event.target.localName === 'link') invalidate(); };

        const observe = nextRoots => {
            observer.disconnect();
            for (const root of roots) {
                if (nextRoots.has(root)) continue;
                root.removeEventListener('load', stylesheetLoaded, true);
                if (sheet && root.adoptedStyleSheets.includes(sheet)) {
                    root.adoptedStyleSheets = root.adoptedStyleSheets.filter(candidate => candidate !== sheet);
                }
            }
            for (const root of nextRoots) {
                // Any attribute can participate in a CSS selector that changes visibility.
                observer.observe(root, { childList: true, characterData: true, attributes: true, subtree: true });
                root.addEventListener('load', stylesheetLoaded, true);
            }
            roots = nextRoots;
            if (roots.size) {
                window.addEventListener('resize', invalidate);
                window.addEventListener('pagehide', leave);
            } else {
                window.removeEventListener('resize', invalidate);
                window.removeEventListener('pagehide', leave);
                potentialHosts = [];
            }
        };

        const blockOf = node => {
            let element = node.parentElement;
            while (element && !blocks.has(element.tagName)) element = element.parentElement;
            return element;
        };
        // All visible text as one string, with an unmatchable separator between
        // blocks so a match can span inline tags but not two paragraphs.
        const collect = () => {
            const segments = [], walkers = [], searchedRoots = new Set([document]);
            let text = '', lastBlock, newRoot = false;
            potentialHosts = [];
            const walk = root => document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                acceptNode: node => skipped.has(node.tagName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
            });
            const visitHost = element => {
                const root = element.shadowRoot;
                if (root) {
                    walkers.push(walk(root));
                    searchedRoots.add(root);
                    newRoot = true;
                } else if (element instanceof HTMLElement
                    && (shadowHostNames.has(element.tagName) || element.localName.includes('-'))) {
                    potentialHosts.push(element);
                }
            };
            if (document.body) {
                walkers.push(walk(document.body));
                visitHost(document.body);
            }
            while (walkers.length) {
                const node = walkers[walkers.length - 1].nextNode();
                if (!node) { walkers.pop(); newRoot = true; continue; }
                if (node.nodeType === Node.ELEMENT_NODE) { visitHost(node); continue; }
                if (!node.length) continue;
                const block = blockOf(node);
                if (text.length && (newRoot || block !== lastBlock)) text += '\u0000';
                newRoot = false;
                lastBlock = block;
                segments.push({ node, start: text.length });
                text += node.data;
            }
            observe(searchedRoots);
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
            const start = range.startContainer, end = range.endContainer;
            const rendered = node => {
                const element = node.parentElement || node.getRootNode().host;
                if (!element || !node.isConnected) return false;
                if (element.checkVisibility?.({ visibilityProperty: true, checkVisibilityCSS: true }) !== false) return true;
                // display:contents has no box of its own but can render text.
                const style = getComputedStyle(element);
                return style.display === 'contents' && style.visibility === 'visible';
            };
            return !range.collapsed && rendered(start) && (end === start || rendered(end)) && range.getClientRects().length > 0;
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
            hiddenRanges = [];
            hiddenOverflow = false;
            capped = false;
            dirty = false;
            const expression = pattern(query);
            if (!expression) { observe(new Set()); return; }
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
                if (!visible(range)) {
                    if (hiddenRanges.length < limit) hiddenRanges.push(range);
                    else hiddenOverflow = true;
                    continue;
                }
                if (ranges.length >= limit) { capped = true; break; }
                ranges.push(range);
            }
        };
        const firstInView = () => {
            const found = ranges.findIndex(range => range.getBoundingClientRect().bottom >= 0);
            return found < 0 ? 0 : found;
        };
        const paint = () => {
            if (!ranges.length) return;
            try {
                if (!sheet) {
                    sheet = new CSSStyleSheet();
                    sheet.replaceSync('::highlight(early-find){background-color:rgba(255,212,0,.45);color:inherit}'
                        + '::highlight(early-find-current){background-color:#ff9500;color:#000}');
                }
                for (const root of roots) {
                    if (!root.adoptedStyleSheets.includes(sheet)) root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
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
            const element = range && (range.startContainer.parentElement || range.startContainer.getRootNode().host);
            if (!element) return;
            const outside = rect => rect.top < 0 || rect.bottom > innerHeight || rect.left < 0 || rect.right > innerWidth;
            if (!outside(range.getBoundingClientRect())) return;
            element.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            const rect = range.getBoundingClientRect();
            if (outside(rect)) window.scrollBy(0, rect.top - innerHeight / 2);
        };
        const answer = () => { paint(); reveal(); return { count: ranges.length, index, capped }; };

        // Positions in different trees cannot be compared directly. A shadow
        // range sorts at the start of its host when viewed from the outer tree.
        function* startPositions(range) {
            for (let position = range; position;) {
                const root = position.startContainer.getRootNode();
                yield [root, position];
                if (!root.host?.isConnected) return;
                position = document.createRange();
                position.setStart(root.host, 0);
            }
        }
        const positionAfterSearch = (previous, ordinal, delta) => {
            if (!previous) return -1;
            const anchors = new Map(startPositions(previous));
            for (const [next, range] of ranges.entries()) {
                for (const [root, position] of startPositions(range)) {
                    const anchor = anchors.get(root);
                    if (!anchor) continue;
                    const order = position.compareBoundaryPoints(Range.START_TO_START, anchor);
                    if (order > 0) return delta > 0 ? next - 1 : next;
                    if (order === 0) return next;
                    break;
                }
            }
            const next = previous.startContainer.isConnected ? ranges.length : Math.min(ordinal, ranges.length);
            return delta > 0 ? next - 1 : next;
        };
        const needsSearch = () => dirty || observer.takeRecords().length > 0
            // Attaching an open root to an existing host emits no mutation record.
            || potentialHosts.some(host => host.shadowRoot)
            // In-place CSSOM changes can affect visibility without touching the DOM.
            || hiddenOverflow || hiddenRanges.some(visible) || ranges.some(range => !visible(range));
        const clear = selectCurrent => {
            const current = ranges[index];
            unpaint();
            observe(new Set());
            if (selectCurrent && current && visible(current)) {
                const text = current.toString();
                const match = pattern(query)?.exec(text);
                const selection = window.getSelection();
                if (selection && match?.index === 0 && match[0].length === text.length) {
                    selection.removeAllRanges();
                    selection.addRange(current.cloneRange());
                }
            }
            ranges = [];
            hiddenRanges = [];
            hiddenOverflow = false;
            index = -1;
            query = '';
            dirty = true;
        };
        const leave = () => clear(false);

        return {
            update(value, delta, limit) {
                query = value;
                search(limit);
                index = ranges.length ? firstInView() : -1;
                return answer();
            },
            step(value, delta, limit) {
                if (value !== query) { query = value; search(limit); index = -1; }
                else if (needsSearch()) {
                    const previous = ranges[index], ordinal = index;
                    search(limit);
                    index = positionAfterSearch(previous, ordinal, delta);
                }
                if (!ranges.length) { index = -1; return answer(); }
                if (index < 0 && delta < 0) index = ranges.length;
                index = ((index + delta) % ranges.length + ranges.length) % ranges.length;
                return answer();
            },
            clear
        };
    })();
    """#
}
