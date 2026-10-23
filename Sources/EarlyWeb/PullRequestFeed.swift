// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Foundation
import Observation
import WebKit

/// A profile's Pull Requests folder, shared by its windows. While a Space
/// shows the folder it's read from GitHub on start, every ten minutes and
/// when asked, with the GitHub sign-in the profile already has. Entries are
/// kept only in memory and cleared when the folder goes.
@MainActor @Observable
public final class PullRequestFeed {
    public typealias Read = @MainActor ([PullRequestGroup]) async -> [PullRequestGroup: PullRequestReading]

    public private(set) var status: PullRequestFolderStatus = .idle
    public private(set) var sections: [PullRequestSection] = []
    public private(set) var lastRefreshed: Date?
    public private(set) var isRefreshing = false
    public private(set) var isActive = false
    public var count: Int { sections.reduce(0) { $0 + $1.items.count } }

    @ObservationIgnored private let read: Read
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var generation = 0

    /// Tests read stand-in pages.
    public init(read: @escaping Read, now: @escaping () -> Date = { Date() }) {
        self.read = read
        self.now = now
    }

    /// GitHub itself, read in a web view on the profile's website data store.
    public convenience init(dataStore: @escaping @MainActor () -> WKWebsiteDataStore?, base: URL = PullRequest.github) {
        self.init(read: { groups in
            guard let store = dataStore() else { return [:] }
            // A new reader each time: nothing outlives a refresh.
            return await GitHubPullRequestReader(base: base).read(groups, store: store)
        })
    }

    public func start() {
        guard !isActive else { return }
        isActive = true
        status = .loading
        schedule(after: 0)
    }

    /// The folder was removed, or none of the profile's windows is open.
    public func stop() {
        guard isActive else { return }
        isActive = false
        loop?.cancel()
        loop = nil
        generation += 1
        sections = []
        status = .idle
        lastRefreshed = nil
        isRefreshing = false
        failures = 0
    }

    /// Now, as when the person asks.
    public func refresh() {
        guard isActive, !isRefreshing else { return }
        schedule(after: 0)
    }

    /// A window came forward or the folder opened: read again if it's been a
    /// while (soon after a failure), but never while GitHub asked to wait.
    public func refreshIfStale(olderThan age: TimeInterval = 300) {
        guard isActive, !isRefreshing, status != .throttled else { return }
        let limit = status == .ready ? age : min(age, 30)
        if let lastRefreshed, now().timeIntervalSince(lastRefreshed) < limit { return }
        refresh()
    }

    private func schedule(after delay: TimeInterval) {
        loop?.cancel()
        loop = Task { [weak self] in
            var wait = delay
            while true {
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                guard let feed = self, !Task.isCancelled else { return }
                wait = await feed.load()
            }
        }
    }

    /// One refresh; returns when to read again.
    private func load() async -> TimeInterval {
        let current = generation
        isRefreshing = true
        let readings = await read(PullRequestGroup.allCases)
        guard current == generation, isActive else { return PullRequests.interval }
        isRefreshing = false
        lastRefreshed = now()
        switch PullRequests.combine(readings) {
        case .sections(let found):
            sections = found
            status = .ready
            failures = 0
            return PullRequests.interval
        case .failed(let failure):
            // Say so instead of showing what may be out of date.
            sections = []
            status = failure
            failures += 1
            return PullRequests.retryDelay(after: failure, failures: failures)
        }
    }
}

/// Reads GitHub's pull-request search pages in a web view that's never shown
/// or made a tab, on the profile's website data store, so the GitHub sign-in
/// it already has is used and Early stores nothing. It never acts on GitHub:
/// it only reads links from the page, in a content world of its own.
@MainActor
final class GitHubPullRequestReader: NSObject, WKNavigationDelegate {
    static let world = WKContentWorld.world(name: "EarlyPullRequests")
    private enum Outcome { case loaded, failed(PullRequestReading) }

    private let base: URL
    private var pending: (id: UUID, continuation: CheckedContinuation<Outcome, Never>)?
    private var statusCode: Int?

    init(base: URL) { self.base = base }

    /// Each group's page in turn, in one view discarded afterwards.
    func read(_ groups: [PullRequestGroup], store: WKWebsiteDataStore) async -> [PullRequestGroup: PullRequestReading] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.applicationNameForUserAgent = BrowserUserAgent.applicationName
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        view.navigationDelegate = self
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
        }
        var readings: [PullRequestGroup: PullRequestReading] = [:]
        for group in groups {
            let reading = await read(group.url(base: base), in: view)
            readings[group] = reading
            // One failure fails the folder, and the other pages would mostly say the same.
            guard case .found = reading else { break }
        }
        return readings
    }

    private func read(_ url: URL, in view: WKWebView) async -> PullRequestReading {
        statusCode = nil
        let id = UUID()
        let outcome = await withCheckedContinuation { continuation in
            pending = (id, continuation)
            view.load(URLRequest(url: url, timeoutInterval: 20))
            Task { [weak self, weak view] in
                try? await Task.sleep(for: .seconds(25))
                view?.stopLoading()
                self?.finish(.failed(.offline), id: id)
            }
        }
        if case .failed(let reading) = outcome { return reading }
        // Pages that build their list after loading get a moment; an empty
        // list is believed only after that.
        var reading = PullRequestReading.unreadable
        for attempt in 0..<8 {
            let result = try? await view.callAsyncJavaScript(Self.script, arguments: [:], in: nil, contentWorld: Self.world)
            reading = PullRequests.reading(from: result, finalURL: view.url, statusCode: statusCode, base: base)
            switch reading {
            case .found(let items) where items.isEmpty && attempt < 3: break
            case .unreadable: break
            default: return reading
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return reading
    }

    private func finish(_ outcome: Outcome, id: UUID? = nil) {
        guard let pending, id == nil || pending.id == id else { return }
        self.pending = nil
        pending.continuation.resume(returning: outcome)
    }

    /// Links to pull requests on the page itself (never its header), with the
    /// longest text as the title. Whether it's GitHub's search page at all
    /// tells an empty search from a page Early can no longer read.
    static let script = #"""
        const root = document.querySelector('main') || document.body;
        if (!root) return null;
        const pattern = /^\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/pull\/(\d+)\/?$/;
        const found = new Map();
        for (const link of root.querySelectorAll('a[href]')) {
            let url;
            try { url = new URL(link.getAttribute('href'), location.href); } catch (e) { continue; }
            if (url.origin !== location.origin) continue;
            const match = url.pathname.match(pattern);
            if (!match) continue;
            const key = (match[1] + '/' + match[2] + '#' + match[3]).toLowerCase();
            const title = (link.textContent || '').replace(/\s+/g, ' ').trim();
            const named = title.length > 0 && !/^#?\d+$/.test(title);
            const prior = found.get(key);
            if (!prior || (named && title.length > prior.title.length)) {
                found.set(key, { owner: match[1], repo: match[2], number: Number(match[3]), title: named ? title : (prior ? prior.title : '') });
            }
            if (found.size >= 60) break;
        }
        const text = (root.innerText || '').slice(0, 4000);
        const searchBox = Array.from(document.querySelectorAll('input, textarea')).some(field => (field.value || '').includes('is:pr'));
        return {
            entries: Array.from(found.values()),
            recognized: searchBox || /No results matched|No pull requests/i.test(text),
            limited: /exceeded a (secondary )?rate limit/i.test(document.title + ' ' + text)
        };
        """#

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only GitHub's own pages, in the main frame; never a download.
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        guard let url = action.request.url, url.scheme == base.scheme, url.host?.lowercased() == base.host?.lowercased(),
              url.port == base.port else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame { statusCode = (response.response as? HTTPURLResponse)?.statusCode }
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.loaded) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failed(Self.reading(for: error)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failed(Self.reading(for: error)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failed(.unreadable)) }

    static func reading(for error: Error) -> PullRequestReading {
        let error = error as NSError
        let unreachable = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                           NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorDNSLookupFailed,
                           NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed]
        return error.domain == NSURLErrorDomain && unreachable.contains(error.code) ? .offline : .unreadable
    }
}
