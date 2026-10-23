// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Foundation
import Testing
import WebKit

/// The Pull Requests folder's reader, against pages shaped like GitHub's own
/// pull-request search (saved markup, served on loopback; nothing reaches
/// GitHub), and the feed's refresh rules with stand-in pages.
@Suite(.serialized) @MainActor
struct PullRequestFeedTests {
    /// GitHub's /pulls results: a header with its own pull request link that
    /// must be ignored, each row's repository, title and comment-count links.
    nonisolated static func resultsPage(query: String, rows: [(owner: String, repo: String, number: Int, title: String)]) -> String {
        let items = rows.map { row in
            """
            <div id="issue_\(row.number)" class="Box-row Box-row--focus-gray js-navigation-item js-issue-row">
              <a class="Link--muted h4" data-hovercard-type="repository" href="/\(row.owner)/\(row.repo)">\(row.owner)/\(row.repo)</a>
              <a id="issue_\(row.number)_link" class="Link--primary h4 js-navigation-open markdown-title"
                 data-hovercard-type="pull_request" href="/\(row.owner)/\(row.repo)/pull/\(row.number)">\(row.title)</a>
              <span class="opened-by">#\(row.number) opened 2 days ago by ada</span>
              <a href="/\(row.owner)/\(row.repo)/pull/\(row.number)" class="Link--muted" aria-label="3 comments"><span>3</span></a>
            </div>
            """
        }.joined(separator: "\n")
        return """
            <!DOCTYPE html><html><head><title>Pull Requests</title></head><body>
            <header class="AppHeader"><a href="/pulls">Pull requests</a><a href="/someone/else/pull/9">Recent: Not mine</a></header>
            <main><div class="subnav"><input id="js-issues-search" name="q" value="\(query) archived:false"></div>
            <div class="js-navigation-container">\(items.isEmpty ? "<div class=\"blankslate\"><h3>No results matched your search.</h3></div>" : items)</div>
            </main></body></html>
            """
    }

    nonisolated static let loginPage = "<!DOCTYPE html><title>Sign in to GitHub</title><main><form action=\"/session\"><input name=\"login\"></form></main>"

    /// Which search a request is: the query as sent.
    nonisolated static func group(of query: String) -> PullRequestGroup? {
        let text = query.removingPercentEncoding ?? query
        return PullRequestGroup.allCases.first { text.contains($0.query.replacingOccurrences(of: " ", with: "+"))
            || text.contains($0.query) }
    }

    @Test func readsEachSearchFromTheProfilesStore() async throws {
        _ = NSApplication.shared
        let server = try HTMLServer { path, query in
            guard path == "/pulls", let group = Self.group(of: query) else { return nil }
            switch group {
            case .opened:
                return .init(body: Self.resultsPage(query: group.query, rows: [("octo", "early", 12, "Add the Pull Requests folder"),
                                                                              ("Octo", "Early", 12, "Duplicate row"),
                                                                              ("octo", "web", 3, "Site <b>copy</b>")]))
            case .assigned:
                return .init(body: Self.resultsPage(query: group.query, rows: [("octo", "early", 12, "Add the Pull Requests folder"),
                                                                              ("team", "tools", 40, "Fix the build")]))
            case .reviewRequested:
                return .init(body: Self.resultsPage(query: group.query, rows: []))
            }
        }
        defer { server.stop() }
        let readings = await GitHubPullRequestReader(base: server.url("")).read(PullRequestGroup.allCases, store: .nonPersistent())
        guard case .found(let opened) = readings[.opened] else { Issue.record("\(String(describing: readings[.opened]))"); return }
        #expect(opened.map(\.id) == ["octo/early#12", "octo/web#3"], "One per pull request, never the header's")
        #expect(opened.first?.title == "Add the Pull Requests folder" && opened.last?.title == "Site copy")
        #expect(readings[.reviewRequested] == .found([]), "An empty search is an empty group, not a failure")
        guard case .sections(let sections) = PullRequests.combine(readings) else { Issue.record("Not combined"); return }
        #expect(sections.map(\.group) == PullRequestGroup.allCases)
        #expect(sections[1].items.map(\.id) == ["team/tools#40"], "Listed once, in the first group")
    }

    @Test func signedOutThrottledAndUnreadablePagesSaySo() async throws {
        _ = NSApplication.shared
        let mode = Mode()
        let server = try HTMLServer { path, _ in
            switch (mode.value, path) {
            case ("signedOut", "/pulls"): return .init(status: "302 Found", headers: ["Location": "/login?return_to=%2Fpulls"], body: "")
            case ("signedOut", "/login"): return .init(body: Self.loginPage)
            case ("throttled", "/pulls"): return .init(status: "429 Too Many Requests", body: "<title>Too many requests</title>")
            case ("limited", "/pulls"):
                return .init(status: "403 Forbidden", body: "<main><h1>Whoa there!</h1><p>You have exceeded a secondary rate limit.</p></main>")
            case ("redesigned", "/pulls"): return .init(body: "<!DOCTYPE html><main><div class=\"new-thing\">Something else</div></main>")
            case ("elsewhere", "/pulls"): return .init(status: "302 Found", headers: ["Location": "https://example.com/"], body: "")
            default: return nil
            }
        }
        defer { server.stop() }
        func read(_ value: String) async -> [PullRequestGroup: PullRequestReading] {
            mode.value = value
            return await GitHubPullRequestReader(base: server.url("")).read(PullRequestGroup.allCases, store: .nonPersistent())
        }
        let signedOut = await read("signedOut")
        #expect(signedOut == [.opened: .signedOut], "Stops at the first page: the others would say the same")
        #expect(PullRequests.combine(signedOut) == .failed(.signedOut))
        #expect(await read("throttled") == [.opened: .throttled])
        #expect(await read("limited") == [.opened: .throttled])
        #expect(PullRequests.combine(await read("redesigned")) == .failed(.unreadable), "A changed page is never an empty list")
        #expect(PullRequests.combine(await read("elsewhere")) == .failed(.unreadable), "The reader never leaves GitHub")
    }

    final class Mode: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ""
        var value: String {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    @MainActor final class Pages {
        var answer: [PullRequestGroup: PullRequestReading] = [:]
        var reads = 0
        var gate: CheckedContinuation<Void, Never>?
        var holds = false
    }

    static let item = PullRequest(owner: "octo", repository: "early", number: 1, title: "One")!

    @Test func theFeedReadsWhileShownAndForgetsWhenStopped() async throws {
        let pages = Pages()
        var clock = Date(timeIntervalSince1970: 1_000)
        let feed = PullRequestFeed(read: { _ in
            pages.reads += 1
            if pages.holds { await withCheckedContinuation { pages.gate = $0 } }
            return pages.answer
        }, now: { clock })
        pages.answer = [.opened: .found([Self.item]), .assigned: .found([]), .reviewRequested: .found([])]
        #expect(feed.status == .idle && !feed.isActive)
        feed.refresh()
        #expect(pages.reads == 0, "Nothing is read until a Space shows the folder")

        feed.start()
        #expect(feed.status == .loading)
        try await Self.waitUntil { feed.status == .ready }
        #expect(feed.sections.first?.items == [Self.item] && feed.count == 1 && pages.reads == 1)

        // Fresh: coming back to a window doesn't read again; overdue does.
        feed.refreshIfStale()
        await Task.yield()
        #expect(pages.reads == 1)
        clock += 901
        feed.refreshIfStale()
        try await Self.waitUntil { pages.reads == 2 && !feed.isRefreshing }

        // A failure replaces the list instead of leaving it out of date.
        pages.answer = [.opened: .unreadable]
        feed.refresh()
        try await Self.waitUntil { feed.status == .unreadable }
        #expect(feed.sections.isEmpty && feed.count == 0)

        // Stopping during a read: its answer is dropped, and everything is forgotten.
        pages.answer = [.opened: .found([Self.item]), .assigned: .found([]), .reviewRequested: .found([])]
        pages.holds = true
        feed.refresh()
        try await Self.waitUntil { pages.gate != nil }
        feed.stop()
        pages.gate?.resume()
        pages.gate = nil
        await Task.yield()
        #expect(feed.status == .idle && feed.sections.isEmpty && feed.lastRefreshed == nil && !feed.isActive)
    }

    @Test func theChosenIntervalDecidesWhenItsOverdue() async throws {
        let pages = Pages()
        var clock = Date(timeIntervalSince1970: 1_000)
        let feed = PullRequestFeed(read: { _ in
            pages.reads += 1
            return pages.answer
        }, now: { clock })
        pages.answer = [.opened: .found([Self.item]), .assigned: .found([]), .reviewRequested: .found([])]
        #expect(feed.interval == 900, "Fifteen minutes unless chosen")
        feed.interval = 7200
        feed.start()
        try await Self.waitUntil { feed.status == .ready }
        clock += 1800
        feed.refreshIfStale()
        await Task.yield()
        #expect(pages.reads == 1, "Coming back after half an hour doesn't read a two-hour folder")
        clock += 5401
        feed.refreshIfStale()
        try await Self.waitUntil { pages.reads == 2 }
        feed.stop()
    }

    @Test func throttlingWaitsAndBacksOff() async throws {
        let pages = Pages()
        let clock = Date(timeIntervalSince1970: 1_000)
        let feed = PullRequestFeed(read: { _ in
            pages.reads += 1
            return pages.answer
        }, now: { clock })
        pages.answer = [.opened: .throttled]
        feed.start()
        try await Self.waitUntil { feed.status == .throttled }
        feed.refreshIfStale(olderThan: 0)
        await Task.yield()
        #expect(pages.reads == 1, "Never reads early while GitHub asked to wait")
        #expect(PullRequests.retryDelay(after: .throttled, failures: 1) == 1200)
        #expect(PullRequests.retryDelay(after: .throttled, failures: 3) == 3600)
        #expect(PullRequests.retryDelay(after: .offline, failures: 1) == 60)
        #expect(PullRequests.retryDelay(after: .offline, failures: 9) == 600)
        feed.refresh()
        try await Self.waitUntil { pages.reads == 2 }
        feed.stop()
    }

    static func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw PageToolFixture.Failure.timeout("feed") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
