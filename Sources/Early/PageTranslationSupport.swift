// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import EarlyWeb
import SwiftUI
import Translation

/// Translate is offered only when Apple's on-device Translation (macOS 15 and
/// later) supports the page's language into the user's. Page text is
/// translated on this Mac; languages it lacks are downloaded only after the
/// system's own prompt.
struct TranslationOffer: Equatable {
    let tabID: UUID
    /// BCP 47 language codes.
    let source: String
    let target: String

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }
    var sourceName: String { Self.name(source) }
    var targetName: String { Self.name(target) }
}

struct TranslationRequest: Equatable, Identifiable {
    let id = UUID()
    let offer: TranslationOffer
    let target: PageTranslationTarget
}

@MainActor
extension BrowserWindowModel {
    /// The user's first preferred language.
    static var translationTarget: String {
        let preferred = Locale.preferredLanguages.first.map { Locale.Language(identifier: $0) }
        return preferred?.languageCode?.identifier ?? "en"
    }

    static func needsTranslation(from source: String, to target: String) -> Bool {
        let from = Locale.Language(identifier: source).languageCode
        return from != nil && from != Locale.Language(identifier: target).languageCode
    }

    func updateTranslationOffer(_ id: UUID, language: String?) {
        translationOffers[id] = nil
        if pendingTranslation?.offer.tabID == id, translationRequest == nil { pendingTranslation = nil }
        let target = Self.translationTarget
        guard let language, Self.needsTranslation(from: language, to: target) else { return }
        guard #available(macOS 15.0, *) else { return }
        Task { @MainActor [weak self] in
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: language),
                                                             to: Locale.Language(identifier: target))
            guard let self, self.webViews.pages[id]?.language == language, status != .unsupported else { return }
            self.translationOffers[id] = TranslationOffer(tabID: id, source: language, target: target)
        }
    }

    /// The host and its menus observe the same request. Closing the tab or
    /// starting a navigation withdraws it even before the system replies.
    var translationRequest: TranslationRequest? {
        guard let request = pendingTranslation,
              webViews.translationTarget(for: request.offer.tabID) == request.target else { return nil }
        return request
    }

    /// The menu title for this tab, or nil when Translate would not work.
    func translationTitle(for id: UUID) -> String? {
        guard let page = webViews.pages[id] else { return nil }
        if page.translation.isActive || translationRequest?.offer.tabID == id { return "Show Original" }
        guard let offer = translationOffers[id], webViews.canTranslate(id) else { return nil }
        return "Translate to \(offer.targetName)"
    }

    func toggleTranslation(_ id: UUID) {
        guard let page = webViews.pages[id] else { return }
        if page.translation.isActive || translationRequest?.offer.tabID == id {
            if pendingTranslation?.offer.tabID == id { pendingTranslation = nil }
            webViews.showOriginal(id)
            return
        }
        guard let offer = translationOffers[id], let target = webViews.translationTarget(for: id) else { return }
        if let previous = translationRequest { webViews.showOriginal(previous.offer.tabID) }
        webViews.showOriginal(id) // Clears an earlier failure.
        pendingTranslation = TranslationRequest(offer: offer, target: target)
    }

    func runTranslation(_ request: TranslationRequest, using translate: PageTextTranslator) async {
        guard pendingTranslation?.id == request.id, webViews.pages[request.offer.tabID]?.translation.isActive != true else { return }
        defer { finishTranslationRequest(request) }
        guard translationRequest == request, !Task.isCancelled else { return }
        await webViews.translatePage(request.offer.tabID, using: translate)
    }

    fileprivate func finishTranslationRequest(_ request: TranslationRequest) {
        if pendingTranslation?.id == request.id { pendingTranslation = nil }
    }
}

/// The session is used only by this translation's sequential batches.
@available(macOS 15.0, *)
private struct SessionTranslator: @unchecked Sendable {
    let session: TranslationSession

    func translate(_ texts: [String]) async throws -> [String] {
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        var result = texts
        for response in try await session.translations(from: requests) {
            if let index = response.clientIdentifier.flatMap(Int.init), result.indices.contains(index) {
                result[index] = response.targetText
            }
        }
        return result
    }
}

/// Apple's Translation hands out sessions only through SwiftUI; this invisible
/// view turns the window's request into one.
@available(macOS 15.0, *)
struct PageTranslationHost: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        if let request = model.translationRequest {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .translationTask(source: Locale.Language(identifier: request.offer.source),
                                 target: Locale.Language(identifier: request.offer.target)) { session in
                    let translator = SessionTranslator(session: session)
                    await model.runTranslation(request) { try await translator.translate($0) }
                }
                // Even two requests for the same language pair own separate system tasks.
                .onDisappear { model.finishTranslationRequest(request) }
                .id(request.id)
        }
    }
}

/// The pane's translation status, with a way back to the original.
struct TranslationBadge: View {
    @Bindable var model: BrowserWindowModel
    let tabID: UUID
    let phase: PageTranslationPhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    static func message(for phase: PageTranslationPhase, pending: Bool, sourceName: String?) -> String? {
        switch phase {
        case .translating: return "Translating…"
        case .translated: return sourceName.map { "Translated from \($0)" } ?? "Translated"
        case .failed: return "Couldn’t translate this page"
        case .original: return pending ? "Translating…" : nil
        }
    }

    var body: some View {
        let pending = model.translationRequest?.offer.tabID == tabID
        let tint = model.chromeTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
        if let message = Self.message(for: phase, pending: pending, sourceName: model.translationOffers[tabID]?.sourceName) {
            HStack(spacing: 8) {
                if case .translating(let completed, let total) = phase, total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.circular).controlSize(.mini).tint(tint)
                } else if phase == .original || phase == .translating(completed: 0, total: 0) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: phase == .translated ? "translate" : "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(message).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Button(phase == .translated || phase.isActive || pending ? "Show Original" : "OK") {
                    if case .failed = phase { model.webViews.showOriginal(tabID) } else { model.toggleTranslation(tabID) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .browserKeyboardFocus(cornerRadius: 5)
                .accessibilityIdentifier("translation.original")
            }
            .padding(.horizontal, 10).frame(height: 30)
            .modifier(PageToolSurface(theme: model.chromeTheme, allowsTransparency: model.preferences.translucentChrome))
            .help({ if case .failed(let reason) = phase { return reason } else { return message } }())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message)
            .accessibilityIdentifier("translation.badge")
        }
    }
}
