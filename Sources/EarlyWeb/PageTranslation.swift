// SPDX-License-Identifier: MPL-2.0

import NaturalLanguage
import WebKit

public enum PageTranslationPhase: Equatable, Sendable {
    case original
    case translating(completed: Int, total: Int)
    case translated
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .translating, .translated: true
        case .original, .failed: false
        }
    }
}

/// Translates a batch of texts in order. The app supplies Apple's on-device
/// Translation; tests supply a stand-in. Page text goes nowhere else.
public typealias PageTextTranslator = @MainActor ([String]) async throws -> [String]

/// The live page and navigation that requested an on-device translation session.
public struct PageTranslationTarget: Equatable, Sendable {
    fileprivate let page: UUID
    fileprivate let document: UUID
    fileprivate let navigation: UUID
}

/// Translation replaces the text of the page's own text nodes from an isolated
/// world, keeping each node's surrounding whitespace, and can restore it.
@MainActor
extension WebViewManager {
    static let translationWorld = WKContentWorld.world(name: "Early.Translate")
    static let translationBatchSize = 40
    static let translationLimits = (nodes: 3000, characters: 100_000, visited: 30_000)

    public func canTranslate(_ id: UUID) -> Bool {
        translationTarget(for: id) != nil
    }

    public func translationTarget(for id: UUID) -> PageTranslationTarget? {
        guard let page = pages[id], let document = page.currentDocumentID, page.view.url != nil,
              page.language != nil, !page.isReaderShown else { return nil }
        return PageTranslationTarget(page: page.instanceID, document: document, navigation: page.navigationGeneration)
    }

    /// The page's language from its own visible text, with its `lang`
    /// attribute only as a fallback for pages with too little text.
    func detectPageLanguage(_ id: UUID) {
        guard let page = pages[id], page.view.url.flatMap({ try? input.validate($0) }) != nil else { return }
        let generation = page.navigationGeneration
        page.view.callAsyncJavaScript("""
            return { lang: document.documentElement.lang || '',
                     text: (document.body ? document.body.innerText : '').slice(0, 2000) };
            """, arguments: [:], in: nil, in: Self.translationWorld) { [weak self, weak page] result in
                guard let self, let page, self.pages[id] === page, page.navigationGeneration == generation,
                      let values = (try? result.get()) as? [String: Any] else { return }
                let language = Self.dominantLanguage(text: values["text"] as? String ?? "", hint: values["lang"] as? String ?? "")
                guard page.language != language else { return }
                page.language = language
                self.onPageLanguage?(id, language)
            }
    }

    nonisolated static func dominantLanguage(text: String, hint: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if text.count >= 40, let language = recognizer.dominantLanguage,
           (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.6 {
            return language.rawValue
        }
        let code = hint.split(separator: "-").first.map { $0.lowercased() } ?? ""
        return code.count >= 2 && code.count <= 3 && code.allSatisfy(\.isLetter) ? code : nil
    }

    /// Translates the visible text in batches. Choosing Show Original or
    /// leaving the page stops it; a failure restores the original text.
    @discardableResult
    public func translatePage(_ id: UUID, using translate: PageTextTranslator) async -> Bool {
        guard !Task.isCancelled, canTranslate(id), let page = pages[id], !page.translation.isActive else { return false }
        let generation = page.navigationGeneration
        // Translate, Show Original, Translate again: the first run's batches
        // and errors must never reach the second's text.
        let run = UUID()
        page.translationRun = run
        page.translation = .translating(completed: 0, total: 0)
        func current() -> Bool {
            !Task.isCancelled && pages[id] === page && page.navigationGeneration == generation
                && page.translationRun == run && page.translation.isActive
        }
        defer {
            if pages[id] === page, page.translationRun == run, case .translating = page.translation { showOriginal(id) }
        }
        let collected = try? await page.view.callAsyncJavaScript(Self.translationCollect,
            arguments: ["runID": run.uuidString, "maxNodes": Self.translationLimits.nodes, "maxCharacters": Self.translationLimits.characters,
                        "maxVisited": Self.translationLimits.visited],
            in: nil, contentWorld: Self.translationWorld)
        guard current() else { return false }
        guard let texts = collected as? [String], !texts.isEmpty else {
            page.translationRun = nil
            page.translation = .failed("This page has no text to translate.")
            return false
        }
        page.translation = .translating(completed: 0, total: texts.count)
        do {
            var start = 0
            while start < texts.count {
                let batch = Array(texts[start..<min(start + Self.translationBatchSize, texts.count)])
                let translated = try await translate(batch)
                guard current() else { return false }
                guard translated.count == batch.count else { throw TranslationMismatch() }
                _ = try await page.view.callAsyncJavaScript(Self.translationApply,
                    arguments: ["runID": run.uuidString, "start": start, "texts": translated], in: nil, contentWorld: Self.translationWorld)
                guard current() else { return false }
                start += batch.count
                page.translation = .translating(completed: start, total: texts.count)
            }
        } catch {
            guard current() else { return false }
            restoreOriginalText(page)
            page.translationRun = nil
            page.translation = .failed(error is TranslationMismatch ? "The translation was incomplete." : error.localizedDescription)
            return false
        }
        page.translation = .translated
        return true
    }

    /// Show Original: stops a running translation and restores the text.
    public func showOriginal(_ id: UUID) {
        guard let page = pages[id], page.translation != .original else { return }
        if page.translation.isActive { restoreOriginalText(page) }
        page.translationRun = nil
        page.translation = .original
    }

    private func restoreOriginalText(_ page: BrowserPage) {
        guard let run = page.translationRun else { return }
        page.view.callAsyncJavaScript(Self.translationRestore, arguments: ["runID": run.uuidString], in: nil, in: Self.translationWorld) { _ in }
    }

    /// A new document starts untranslated, with its language detected again.
    func resetTranslationForNewDocument(_ id: UUID) {
        guard let page = pages[id] else { return }
        page.translationRun = nil
        page.translation = .original
        if page.language != nil {
            page.language = nil
            onPageLanguage?(id, nil)
        }
    }

    private struct TranslationMismatch: Error {}

    static let translationCollect = #"""
    window.__earlyTranslation?.restore();
    const entries = [], texts = [];
    window.__earlyTranslation = { runID, entries, restore() {
        for (const entry of entries) {
            if (entry && entry.written !== null && entry.node.isConnected && entry.node.parentNode === entry.parent
                && entry.node.ownerDocument === document
                && entry.node.data === entry.written) entry.node.data = entry.original;
        }
        entries.length = 0;
    }};
    const skipped = new Set(['head', 'script', 'style', 'noscript', 'template', 'textarea', 'input', 'select', 'option',
        'code', 'pre', 'kbd', 'samp', 'var', 'svg', 'math', 'iframe', 'object', 'embed', 'canvas', 'audio', 'video']);
    let visited = 0, characters = 0;
    function* slotChildren(slot) {
        const host = slot.getRootNode().host;
        if (!host || host.childNodes.length <= maxVisited - visited) {
            const assigned = slot.assignedNodes();
            yield* (assigned.length ? assigned : slot.childNodes);
            return;
        }
        // Avoid materializing an oversized assignment list. Charge the light
        // children we inspect to the same traversal budget.
        let found = false;
        for (const child of host.childNodes) {
            if (++visited >= maxVisited) return;
            if (child.assignedSlot === slot) { found = true; yield child; }
        }
        if (!found) yield* slot.childNodes;
    }
    const stack = [{ children: document.childNodes.values(), visible: true }];
    while (stack.length && visited < maxVisited && entries.length < maxNodes && characters < maxCharacters) {
        const level = stack[stack.length - 1], next = level.children.next();
        if (next.done) { stack.pop(); continue; }
        const node = next.value;
        visited++;
        if (level.summaryOnly) {
            if (node.localName !== 'summary') continue;
            stack.pop(); // Only the first direct summary is rendered in closed details.
        }
        if (node.nodeType === Node.TEXT_NODE) {
            if (!level.visible || node.length > maxCharacters) continue;
            const original = node.data, text = original.trim();
            if (text.length <= maxCharacters - characters && /\p{L}/u.test(text)) {
                entries.push({ node, parent: node.parentNode, original, written: null });
                texts.push(text);
                characters += text.length;
            }
            continue;
        }
        if (node.nodeType !== Node.ELEMENT_NODE || skipped.has(node.localName) || node.hasAttribute('hidden')
            || node.getAttribute('translate')?.toLowerCase() === 'no' || node.classList.contains('notranslate')
            || node.isContentEditable) continue;
        const style = getComputedStyle(node);
        if (style.display === 'none' || style.contentVisibility === 'hidden' || style.opacity === '0') continue;
        // Descendants can override inherited visibility. Their own styles decide.
        const visible = style.visibility !== 'hidden' && style.visibility !== 'collapse';
        const root = node.shadowRoot || node;
        const children = node.localName === 'slot' ? slotChildren(node)
            : (visible ? root.childNodes : root.children)[Symbol.iterator]();
        stack.push({ children, visible, summaryOnly: node.localName === 'details' && !node.open });
    }
    return texts;
    """#

    static let translationApply = #"""
    const state = window.__earlyTranslation;
    if (state?.runID !== runID) return 0;
    const entries = state.entries;
    texts.forEach((text, offset) => {
        const index = start + offset, entry = entries[index];
        if (!entry || typeof text !== 'string') return;
        const { node, original } = entry;
        if (!node.isConnected || node.parentNode !== entry.parent || node.ownerDocument !== document || node.data !== original) {
            entries[index] = null;
            return;
        }
        entry.written = original.match(/^\s*/)[0] + text + original.match(/\s*$/)[0];
        node.data = entry.written;
    });
    return texts.length;
    """#

    static let translationRestore = #"""
    const state = window.__earlyTranslation;
    if (state?.runID === runID) state.restore();
    return true;
    """#
}
