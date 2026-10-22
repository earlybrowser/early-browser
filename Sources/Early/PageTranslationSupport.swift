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
            if translationRequest?.offer.tabID == id { translationRequest = nil }
            webViews.showOriginal(id)
            return
        }
        guard let offer = translationOffers[id], webViews.canTranslate(id) else { return }
        webViews.showOriginal(id) // Clears an earlier failure.
        translationRequest = TranslationRequest(offer: offer)
    }

    @available(macOS 15.0, *)
    func runTranslation(_ request: TranslationRequest, session: TranslationSession) async {
        defer { if translationRequest?.id == request.id { translationRequest = nil } }
        let translator = SessionTranslator(session: session)
        await webViews.translatePage(request.offer.tabID) { texts in try await translator.translate(texts) }
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
    @State private var configuration: TranslationSession.Configuration?
    @State private var running: TranslationRequest?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: model.translationRequest) { _, request in start(request) }
            .translationTask(configuration) { session in
                guard let running else { return }
                await model.runTranslation(running, session: session)
            }
    }

    private func start(_ request: TranslationRequest?) {
        guard let request else { return }
        running = request
        let source = Locale.Language(identifier: request.offer.source)
        let target = Locale.Language(identifier: request.offer.target)
        if configuration?.source == source && configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
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
        let tint = model.splitTheme.focusBorder(isDark: colorScheme == .dark, increasedContrast: contrast == .increased).color
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
            .modifier(PageToolSurface(theme: model.splitTheme, allowsTransparency: model.preferences.translucentChrome))
            .help({ if case .failed(let reason) = phase { return reason } else { return message } }())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message)
            .accessibilityIdentifier("translation.badge")
        }
    }
}
