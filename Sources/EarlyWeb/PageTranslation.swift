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

/// Translation replaces the text of the page's own text nodes from an isolated
/// world, keeping each node's surrounding whitespace, and can restore it.
@MainActor
extension WebViewManager {
    static let translationWorld = WKContentWorld.world(name: "Early.Translate")
    static let translationBatchSize = 40
    static let translationLimits = (nodes: 3000, characters: 100_000)

    public func canTranslate(_ id: UUID) -> Bool {
        guard let page = pages[id], page.view.url != nil, !page.isReaderShown else { return false }
        return page.language != nil
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
        guard canTranslate(id), let page = pages[id], !page.translation.isActive else { return false }
        let generation = page.navigationGeneration
        // Translate, Show Original, Translate again: the first run's batches
        // and errors must never reach the second's text.
        let run = UUID()
        page.translationRun = run
        page.translation = .translating(completed: 0, total: 0)
        func current() -> Bool {
            pages[id] === page && page.navigationGeneration == generation && page.translationRun == run && page.translation.isActive
        }
        let collected = try? await page.view.callAsyncJavaScript(Self.translationCollect,
            arguments: ["maxNodes": Self.translationLimits.nodes, "maxCharacters": Self.translationLimits.characters],
            in: nil, contentWorld: Self.translationWorld)
        guard current() else { return false }
        guard let texts = collected as? [String], !texts.isEmpty else {
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
                    arguments: ["start": start, "texts": translated], in: nil, contentWorld: Self.translationWorld)
                guard current() else { return false }
                start += batch.count
                page.translation = .translating(completed: start, total: texts.count)
            }
        } catch {
            guard current() else { return false }
            restoreOriginalText(page)
            page.translation = .failed(error is TranslationMismatch ? "The translation was incomplete." : error.localizedDescription)
            return false
        }
        page.translationRun = nil
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
        page.view.callAsyncJavaScript(Self.translationRestore, arguments: [:], in: nil, in: Self.translationWorld) { _ in }
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
    const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION',
        'CODE', 'PRE', 'KBD', 'SAMP', 'VAR', 'SVG', 'MATH', 'IFRAME', 'OBJECT', 'EMBED', 'CANVAS', 'AUDIO', 'VIDEO']);
    const state = window.__earlyTranslation || (window.__earlyTranslation = { nodes: [], originals: [] });
    // Always start from the original text.
    state.nodes.forEach((node, index) => { if (node.isConnected) node.data = state.originals[index]; });
    state.nodes = [];
    state.originals = [];
    let characters = 0, full = false;
    const visit = root => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
                if (node.nodeType !== Node.ELEMENT_NODE) return NodeFilter.FILTER_ACCEPT;
                if (skipped.has(node.tagName) || node.getAttribute('translate') === 'no'
                    || node.classList.contains('notranslate') || node.isContentEditable) return NodeFilter.FILTER_REJECT;
                return node.shadowRoot ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
            }
        });
        for (let node = walker.nextNode(); node && !full; node = walker.nextNode()) {
            if (node.nodeType === Node.ELEMENT_NODE) { visit(node.shadowRoot); continue; }
            const text = node.data.trim();
            if (!text || !/\p{L}/u.test(text)) continue;
            if (state.nodes.length >= maxNodes || characters + text.length > maxCharacters) { full = true; break; }
            state.nodes.push(node);
            state.originals.push(node.data);
            characters += text.length;
        }
    };
    if (document.body) visit(document.body);
    return state.nodes.map(node => node.data.trim());
    """#

    static let translationApply = #"""
    const state = window.__earlyTranslation;
    if (!state) return 0;
    texts.forEach((text, offset) => {
        const node = state.nodes[start + offset], original = state.originals[start + offset];
        if (!node || !node.isConnected || typeof text !== 'string') return;
        node.data = original.match(/^\s*/)[0] + text + original.match(/\s*$/)[0];
    });
    return texts.length;
    """#

    static let translationRestore = #"""
    const state = window.__earlyTranslation;
    if (state) {
        state.nodes.forEach((node, index) => { if (node.isConnected) node.data = state.originals[index]; });
        state.nodes = [];
        state.originals = [];
    }
    return true;
    """#
}
