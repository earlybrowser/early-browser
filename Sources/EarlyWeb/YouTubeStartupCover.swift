// SPDX-License-Identifier: MPL-2.0

import AppKit
import WebKit

/// YouTube can serve a blank white document before reloading with its chosen
/// dark theme. Cover only a new web view's first load; never change the site's
/// styles, theme preference, cookies, or an already displayed page.
@MainActor
final class YouTubeStartupCover: NSView {
    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var timeout: Task<Void, Never>?
    private var startedLoading = false
    private var finished = false
    private let initialBackground: NSColor?

    static func supports(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(url.host?.lowercased() ?? "")
    }

    init?(webView: WKWebView, destination: URL, maximumWait: Duration = .seconds(30)) {
        guard Self.supports(destination), webView.url == nil,
              webView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return nil }
        self.webView = webView
        initialBackground = webView.underPageBackgroundColor.usingColorSpace(.sRGB)
        super.init(frame: webView.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1).cgColor
        // WebKit may attach its compositing view after this cover was added.
        layer?.zPosition = 1
        webView.addSubview(self, positioned: .above, relativeTo: nil)
        observations = [
            webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.backgroundChanged() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let url = self.webView?.url else { return }
                    self.navigate(to: url)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard let loading = change.newValue else { return }
                Task { @MainActor [weak self] in self?.loadingChanged(loading) }
            }
        ]
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: maximumWait) } catch { return }
            self?.finish()
        }
    }

    required init?(coder: NSCoder) { nil }
    deinit { timeout?.cancel() }

    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func navigate(to url: URL) {
        if !Self.supports(url) { finish() }
    }

    private func loadingChanged(_ loading: Bool) {
        guard !finished else { return }
        if loading { startedLoading = true }
        else if startedLoading { finish() }
    }

    private func backgroundChanged() {
        guard !finished, startedLoading, let webView,
              let color = webView.underPageBackgroundColor.usingColorSpace(.sRGB),
              let initialBackground else { return }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        let original = [initialBackground.redComponent, initialBackground.greenComponent, initialBackground.blueComponent]
        // The default empty WebKit surface is dark too. Wait for a different
        // dark color from the document, not that initial surface or its white
        // intermediate page. Light-theme pages are revealed when loading ends.
        if color.alphaComponent == 1, components.allSatisfy({ $0 < 0.5 }),
           zip(components, original).contains(where: { abs($0 - $1) > 0.001 }) { finish() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        observations.removeAll()
        removeFromSuperview()
    }
}
