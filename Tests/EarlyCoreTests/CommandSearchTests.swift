// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Foundation
import Testing

struct CommandSearchTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func exactPrefixWordSubstringTokenAndFuzzyTiersRankDeterministically() throws {
        let exact = CommandSearchCandidate(id: "tab.exact", kind: .openTab, target: .tab(UUID()), title: "git")
        let prefix = CommandSearchCandidate(id: "tab.prefix", kind: .openTab, target: .tab(UUID()), title: "github")
        let word = CommandSearchCandidate(id: "tab.word", kind: .openTab, target: .tab(UUID()), title: "learn git fast")
        let substring = CommandSearchCandidate(id: "tab.sub", kind: .openTab, target: .tab(UUID()), title: "legitimately")
        let fuzzy = CommandSearchCandidate(id: "tab.fuzzy", kind: .openTab, target: .tab(UUID()), title: "get in touch")
        let limits = CommandSearchLimits(total: 10, tabs: 10)

        let forward = try CommandSearchRanker.rank("git",
            candidates: [fuzzy, substring, word, prefix, exact], now: now, limits: limits)
        let reverse = try CommandSearchRanker.rank("git",
            candidates: [exact, prefix, word, substring, fuzzy], now: now, limits: limits)
        #expect(forward == reverse)
        #expect(forward.map(\.id) == ["tab.exact", "tab.prefix", "tab.word", "tab.sub", "tab.fuzzy"])
        #expect(forward.map(\.match) == [.exact, .prefix, .wordPrefix, .substring, .fuzzy])

        let token = CommandSearchCandidate(id: "tab.token", kind: .openTab, target: .tab(UUID()),
            title: "Swift Package Index", terms: ["https://swiftpackageindex.com/apple/swift-testing"])
        let tokenResults = try CommandSearchRanker.rank("swift test", candidates: [token], now: now)
        #expect(tokenResults.map(\.match) == [.tokens])

        // Secondary helper terms must not fuzzy-match across words (e.g. "pin" in "switch profile 2nd one").
        let profile = CommandSearchCandidate(id: "profile.2", kind: .profile, target: .profile(UUID()),
            title: "2nd one", terms: ["switch profile 2nd one", "profile 2nd one"])
        #expect(try CommandSearchRanker.rank("pin", candidates: [profile], now: now).isEmpty)
    }

    @Test func pinsEvaluateCustomTitlesSavedURLsAndLiveURLsWhileRecencyAndFrequencyBreakSimilarMatches() throws {
        let recentPin = CommandSearchCandidate(
            id: "tab.recent", kind: .pinnedTab, target: .tab(UUID()),
            title: "Work Mail", detail: "https://mail.example.com/inbox/42",
            terms: ["Original Inbox", "https://mail.example.com/welcome", "https://mail.example.com/inbox/42"],
            isOpen: false, lastUsed: now.addingTimeInterval(-600), useCount: 12)
        let staleOpen = CommandSearchCandidate(
            id: "tab.stale", kind: .openTab, target: .tab(UUID()),
            title: "Work Notes", detail: "https://notes.example.com",
            terms: ["https://notes.example.com"],
            isOpen: true, lastUsed: now.addingTimeInterval(-86_400 * 14), useCount: 1)
        let favorite = CommandSearchCandidate(
            id: "tab.fav", kind: .favorite, target: .tab(UUID()),
            title: "Work Docs", detail: "https://docs.example.com",
            isOpen: true, lastUsed: now.addingTimeInterval(-600), useCount: 12)

        let byPrefix = try CommandSearchRanker.rank("work", candidates: [staleOpen, recentPin, favorite], now: now)
        #expect(byPrefix.map(\.id) == ["tab.fav", "tab.recent", "tab.stale"])

        // Saved pinned URL and original title remain searchable after navigating away.
        #expect(try CommandSearchRanker.rank("welcome", candidates: [recentPin], now: now).map(\.id) == ["tab.recent"])
        #expect(try CommandSearchRanker.rank("original inbox", candidates: [recentPin], now: now).map(\.id) == ["tab.recent"])
        #expect(try CommandSearchRanker.rank("https://www.mail.example.com/", candidates: [recentPin], now: now).map(\.id) == ["tab.recent"])
    }

    @Test func perKindAndTotalLimitsStayBoundedAndDeduplicateCandidateIDs() throws {
        let candidates = (0..<20).map { index in
            CommandSearchCandidate(id: "tab.\(String(format: "%02d", index))", kind: .openTab,
                target: .tab(UUID()), title: "Swift \(index)")
        } + (0..<10).map { index in
            CommandSearchCandidate(id: "action.\(index)", kind: .action,
                target: .action(.reload), title: "Swift Action \(index)")
        } + [
            CommandSearchCandidate(id: "tab.00", kind: .openTab, target: .tab(UUID()), title: "Swift duplicate")
        ]
        let limits = CommandSearchLimits(total: 6, tabs: 4, actions: 3, maximumCandidates: 25)
        let ranked = try CommandSearchRanker.rank("swift", candidates: candidates, now: now, limits: limits)
        #expect(ranked.count == 6)
        #expect(ranked.filter { $0.candidate.kind.isTab }.count == 4)
        #expect(ranked.filter { $0.candidate.kind == .action }.count == 2)
        #expect(Set(ranked.map(\.id)).count == ranked.count)
        #expect(try CommandSearchRanker.rank("   ", candidates: candidates, now: now, limits: limits).isEmpty)
    }

    @MainActor @Test func tabUsagePersistsBackwardCompatiblyAndSynchronizesHighestValues() throws {
        let space = UUID(), profile = UUID()
        var tab = BrowserTab(spaceID: space, profileID: profile, title: "Docs",
            currentURL: URL(string: "https://example.com")!, pinnedURL: URL(string: "https://example.com")!)
        tab.recordActivation(at: now)
        tab.recordActivation(at: now.addingTimeInterval(30))
        #expect(tab.activationCount == 2 && tab.lastActivatedAt == now.addingTimeInterval(30))

        let encoded = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: encoded)
        #expect(decoded == tab)

        // Legacy snapshots without usage keys decode cleanly with zeroed signals.
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lastActivatedAt")
        object.removeValue(forKey: "activationCount")
        let legacy = try JSONDecoder().decode(BrowserTab.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.lastActivatedAt == nil && legacy.activationCount == 0)

        let first = BrowserCoordinator(startup: .returningSession, activeSpaceID: space,
            tabStore: TabStore(tabs: [legacy]), profileID: profile,
            spaces: [BrowserSpace(id: space, profileID: profile, name: "Work")])
        var updated = tab
        updated.recordActivation(at: now.addingTimeInterval(120))
        let second = BrowserSession(profileID: profile, activeSpaceID: space, tabs: [updated],
            spaces: [BrowserSpace(id: space, profileID: profile, name: "Work")])
        first.synchronizeSavedItems(from: second)
        let synced = try #require(first.tabStore.tab(id: tab.id))
        #expect(synced.activationCount == 3 && synced.lastActivatedAt == now.addingTimeInterval(120))
    }

    private struct StubProvider: CommandSearchProvider {
        let delay: Duration
        let items: [CommandSearchCandidate]
        var shouldThrow = false

        func candidates(matching query: String, limit: Int) async throws -> [CommandSearchCandidate] {
            if delay > .zero { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            if shouldThrow { throw URLError(.cannotLoadFromNetwork) }
            return items
        }
    }

    @MainActor
    @Test func controllerCancelsStaleGenerationsBoundsProviderOutputAndPreservesSelectionByID() async throws {
        let bookmarkURL = URL(string: "https://example.com/guide")!
        let slow = StubProvider(delay: .milliseconds(80), items: [
            CommandSearchCandidate(id: "page.slow", kind: .bookmark, target: .page(bookmarkURL, source: .bookmark),
                title: "Swift Guide Bookmark", detail: bookmarkURL.absoluteString)
        ])
        let failing = StubProvider(delay: .zero, items: [], shouldThrow: true)
        let overproducing = StubProvider(delay: .milliseconds(10), items: (0..<20).map {
            CommandSearchCandidate(id: "history.\($0)", kind: .history,
                target: .page(bookmarkURL, source: .history), title: "Swift History \($0)")
        })
        let search = CommandSearch(providers: [slow, failing, overproducing],
            limits: CommandSearchLimits(total: 6, tabs: 4, pages: 2, providerResults: 3),
            now: { self.now })
        let localTab = CommandSearchCandidate(id: "tab.local", kind: .openTab, target: .tab(UUID()), title: "Swift Local")

        search.update(query: "old", candidates: [
            CommandSearchCandidate(id: "tab.old", kind: .openTab, target: .tab(UUID()), title: "Old Tab")
        ])
        search.update(query: "swift", candidates: [localTab])
        for _ in 0..<50 where search.isRefreshing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(search.results.map(\.id) == ["tab.local"])
        search.select(index: 0)
        #expect(search.selectedResult?.id == "tab.local")

        for _ in 0..<50 where search.isLoadingProviders { try await Task.sleep(for: .milliseconds(10)) }
        #expect(search.results.contains { $0.id == "page.slow" })
        #expect(search.results.filter { $0.candidate.kind == .bookmark || $0.candidate.kind == .history }.count == 2)
        #expect(!search.results.contains { $0.id == "tab.old" })
        #expect(search.selectedResult?.id == "tab.local")

        search.cancel()
        #expect(search.results.isEmpty && search.selectedResult == nil && !search.isRefreshing && !search.isLoadingProviders)
    }


    @Test func tabSwitcherOrdersOpenTabsByMostRecentUseStepsCircularlyAndCommitsViaSelectTab() throws {
        let space = UUID(), profile = UUID()
        let url = URL(string: "https://example.com")!
        var first = BrowserTab(spaceID: space, profileID: profile, title: "First", currentURL: url)
        var second = BrowserTab(spaceID: space, profileID: profile, title: "Second", currentURL: url)
        var third = BrowserTab(spaceID: space, profileID: profile, title: "Third", currentURL: url)
        first.recordActivation(at: now.addingTimeInterval(-300))
        third.recordActivation(at: now.addingTimeInterval(-60))
        second.recordActivation(at: now.addingTimeInterval(-10))

        #expect(TabSwitcher(openTabs: [], activeTabID: nil) == nil)

        var switcher = try #require(TabSwitcher(openTabs: [first, second, third], activeTabID: first.id, initialDelta: 1))
        #expect(switcher.tabIDs == [first.id, second.id, third.id])
        // Starting with Control-Tab (+1) highlights the most recently used sibling.
        #expect(switcher.selectedTabID == second.id)
        #expect(switcher.commitAction == .selectTab(second.id))

        switcher.step(1)
        #expect(switcher.selectedTabID == third.id)
        switcher.step(1)
        #expect(switcher.selectedTabID == first.id)
        // Committing on the originally active tab is a no-op.
        #expect(switcher.commitAction == nil)

        switcher.step(-1)
        #expect(switcher.selectedTabID == third.id)
        let selectedValid = switcher.select(second.id)
        let selectedMissing = switcher.select(UUID())
        #expect(selectedValid && !selectedMissing)
        #expect(switcher.selectedTabID == second.id)
    }
}
