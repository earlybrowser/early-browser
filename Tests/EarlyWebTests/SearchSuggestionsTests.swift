// SPDX-License-Identifier: MPL-2.0

import Foundation
import EarlyCore
@testable import EarlyWeb
import Testing

struct SearchSuggestionPolicyTests {
    @Test(arguments: ["", "a", "https://example.com/private", "user@example.com", "localhost",
                      "127.0.0.1", "example.com", "find https://example.com", "token=abc#secret",
                      "file:///secret", "hello\nworld", String(repeating: "a", count: 201)])
    func rejectsAddressesAndIneligibleInput(query: String) {
        #expect(SearchSuggestionPolicy.query(query) == nil)
        #expect(OnlineSearchSuggestions.request(for: query) == nil)
    }

    @Test func encodesSearchPhrasesWithoutCookiesOrPersistentCache() throws {
        #expect(SearchSuggestionPolicy.query("  café ideas  ") == "café ideas")
        let request = try #require(OnlineSearchSuggestions.request(for: "café & tea"))
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "www.google.com")
        #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "café & tea")
        #expect(components.queryItems?.first(where: { $0.name == "oe" })?.value == "utf-8")
        let configuration = OnlineSearchSuggestions.configuration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(!configuration.httpShouldSetCookies)
    }

    @Test func parserValidatesQueryDeduplicatesAndBoundsResults() throws {
        let values = ["swift", "Swift guide", "swift GUIDE", "https://example.com", "", "swift\ncode"]
            + (1...12).map { "swift example \($0)" }
        let data = try JSONSerialization.data(withJSONObject: ["swift", values])
        let result = try SearchSuggestionPolicy.parse(data, query: "swift")
        #expect(result.count == 6)
        #expect(result.first == "Swift guide")
        #expect(try SearchSuggestionPolicy.parse(data, query: "different").isEmpty)
        #expect(try SearchSuggestionPolicy.parse(Data("{}".utf8), query: "swift").isEmpty)
        #expect(throws: (any Error).self) { try SearchSuggestionPolicy.parse(Data("not JSON".utf8), query: "swift") }
        #expect(try SearchSuggestionPolicy.parse(Data(repeating: 0, count: 65_537), query: "swift").isEmpty)
    }

    @Test func suggestionAlwaysSearchesInsteadOfNavigating() throws {
        let url = try NavigationInput().searchURL(for: "https://example.com/?secret=yes")
        #expect(url.host == "www.google.com")
        #expect(url.path == "/search")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "https://example.com/?secret=yes")
    }

    @Test func gitResponseWithLatin1DescriptionStillReturnsSuggestions() throws {
        // The real provider puts a Latin-1 middle dot in unused description
        // metadata. Even ASCII candidates previously failed JSON decoding.
        let response = #"["git",["github","https://github.com/","git café"],["","How people build software · GitHub",""]]"#
        let latin1 = try #require(response.data(using: .isoLatin1))
        #expect(throws: (any Error).self) { try SearchSuggestionPolicy.parse(latin1, query: "git") }
        #expect(try SearchSuggestionPolicy.parse(latin1, query: "git", textEncodingName: "ISO-8859-1") == ["github", "git café"])
        #expect(try SearchSuggestionPolicy.parse(Data(response.utf8), query: "git", textEncodingName: "UTF-8") == ["github", "git café"])
        #expect(try SearchSuggestionPolicy.parse(latin1, query: "github", textEncodingName: "ISO-8859-1").isEmpty)
        #expect(throws: (any Error).self) {
            try SearchSuggestionPolicy.parse(latin1, query: "git", textEncodingName: "unsupported")
        }
    }
}

@MainActor
struct SearchSuggestionsTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Suggestion operation did not settle")
    }

    @Test func disabledAndAddressQueriesNeverFetchAndTypingDebounces() async throws {
        let provider = RecordingSuggestions()
        let state = SearchSuggestions(debounce: .milliseconds(80)) { await provider.fetch($0) }
        state.update(query: "swift", enabled: false)
        state.update(query: "https://example.com", enabled: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await provider.queries.isEmpty)
        state.update(query: "sw", enabled: true)
        state.update(query: "swi", enabled: true)
        state.update(query: "swift", enabled: true)
        try await waitUntil { !state.results.isEmpty }
        #expect(await provider.queries == ["swift"])
        #expect(state.selectedSuggestion == nil)
        state.moveSelection(1)
        #expect(state.selectedSuggestion == "swift guide")
        state.moveSelection(-1)
        #expect(state.selectedSuggestion == nil)
        state.moveSelection(-1)
        #expect(state.selectedSuggestion == "swift examples")
        state.cancel()
        #expect(state.results.isEmpty)
        #expect(state.selectedSuggestion == nil)
    }

    @Test func canceledAndOutOfOrderResponsesCannotReappear() async throws {
        let provider = SuspendedSuggestions()
        let state = SearchSuggestions(debounce: .zero) { await provider.fetch($0) }
        state.update(query: "old", enabled: true)
        try await waitUntil { await provider.contains("old") }
        state.update(query: "new", enabled: true)
        try await waitUntil { await provider.contains("new") }
        await provider.finish("new")
        try await waitUntil { state.results == ["new result"] }
        await provider.finish("old")
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.results == ["new result"])
        state.update(query: "pending", enabled: true)
        try await waitUntil { await provider.contains("pending") }
        state.update(query: "pending", enabled: false)
        await provider.finish("pending")
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.results.isEmpty)
        #expect(!state.isLoading)
    }

    @Test func refreshPreservesRowsButNeverSelectsStaleResults() async throws {
        let provider = SuspendedSuggestions()
        let state = SearchSuggestions(debounce: .zero) { await provider.fetch($0) }
        state.update(query: "first", enabled: true)
        try await waitUntil { await provider.contains("first") }
        await provider.finish("first")
        try await waitUntil { state.results == ["first result"] }
        state.moveSelection(1)
        #expect(state.selectedSuggestion == "first result")
        state.update(query: "second", enabled: true)
        #expect(state.isRefreshing)
        #expect(state.results == ["first result"])
        #expect(state.selectedSuggestion == nil)
        state.moveSelection(1)
        #expect(state.selectedIndex == nil)
        try await waitUntil { await provider.contains("second") }
        await provider.finish("second")
        try await waitUntil { !state.isRefreshing }
        #expect(state.results == ["second result"])
        state.update(query: "https://example.com", enabled: true)
        #expect(state.results.isEmpty)
        #expect(!state.isRefreshing)
    }

    @Test func cachedQueryReturnsSynchronouslyAndDisablingClearsCache() async throws {
        let provider = RecordingSuggestions()
        let state = SearchSuggestions(debounce: .zero) { await provider.fetch($0) }
        state.update(query: "swift", enabled: true)
        try await waitUntil { !state.results.isEmpty }
        state.cancel()
        state.update(query: "swift", enabled: true)
        // No yield or network wait: cached rows must already be actionable.
        #expect(state.results == ["swift guide", "swift examples"])
        #expect(!state.isRefreshing)
        state.moveSelection(1)
        #expect(state.selectedSuggestion == "swift guide")
        #expect(await provider.queries == ["swift"])
        state.update(query: "swift", enabled: false)
        state.update(query: "swift", enabled: true)
        #expect(state.isRefreshing)
        try await waitUntil { !state.isRefreshing }
        #expect(await provider.queries == ["swift", "swift"])
    }

    @Test func repeatedQueryDoesNotRestartPendingFetch() async throws {
        let provider = SuspendedSuggestions()
        let state = SearchSuggestions(debounce: .zero) { await provider.fetch($0) }
        state.update(query: "swift", enabled: true)
        try await waitUntil { await provider.contains("swift") }
        state.update(query: "swift", enabled: true)
        await provider.finish("swift")
        try await waitUntil { state.results == ["swift result"] }
        #expect(!state.isRefreshing)
    }

    @Test func failureDoesNotPreventFallbackAndNextQueryRecovers() async throws {
        let state = SearchSuggestions(debounce: .zero) { query in
            if query == "offline" { throw URLError(.notConnectedToInternet) }
            return ["\(query) guide"]
        }
        state.update(query: "offline", enabled: true)
        try await waitUntil { state.unavailable }
        #expect(state.results.isEmpty)
        #expect(!state.isLoading)
        state.update(query: "online", enabled: true)
        try await waitUntil { !state.results.isEmpty }
        #expect(!state.unavailable)
    }
}

struct SearchSuggestionCacheTests {
    @Test func expiresWithoutExtendingLifetimeOnReadAndEvictsLeastRecent() {
        let now = ContinuousClock.now
        var cache = SearchSuggestionCache(capacity: 2, lifetime: .seconds(120))
        cache.insert(["first result"], for: "first", now: now)
        cache.insert(["second result"], for: "second", now: now)
        #expect(cache.lookup("first", now: now.advanced(by: .seconds(10))) == ["first result"])
        cache.insert(["third result"], for: "third", now: now.advanced(by: .seconds(20)))
        #expect(cache.lookup("second", now: now.advanced(by: .seconds(20))) == nil)
        #expect(cache.lookup("first", now: now.advanced(by: .seconds(120))) == nil)
        #expect(cache.lookup("third", now: now.advanced(by: .seconds(120))) == ["third result"])
        cache.clear()
        #expect(cache.lookup("third", now: now.advanced(by: .seconds(120))) == nil)
    }

    @Test func cachesEmptyResultsAndLimitsStoredRows() {
        let now = ContinuousClock.now
        var cache = SearchSuggestionCache()
        cache.insert([], for: "empty", now: now)
        #expect(cache.lookup("empty", now: now) == [])
        cache.insert((1...20).map { "result \($0)" }, for: "many", now: now)
        #expect(cache.lookup("many", now: now)?.count == 6)
    }
}

extension SearchSuggestionsTests {
    @Test func suggestionsComeFromTheChosenEngineOnly() async throws {
        let provider = EngineSuggestions()
        let state = SearchSuggestions(debounce: .zero, fetchFrom: { query, engine in await provider.fetch(query, engine) })
        state.update(query: "swift", enabled: true, engine: .duckDuckGo)
        try await waitUntil { state.results == ["swift on duckDuckGo"] }
        // Another engine never shows this one's cached suggestions.
        state.update(query: "swift", enabled: true, engine: .bing)
        #expect(state.results.isEmpty || state.isRefreshing)
        try await waitUntil { state.results == ["swift on bing"] }
        // An engine without suggestions sends nothing, anywhere.
        state.update(query: "swiftui", enabled: true, engine: .kagi)
        #expect(state.results.isEmpty && !state.isRefreshing)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await provider.calls == ["swift duckDuckGo", "swift bing"])
    }

    @Test func eachEnginesSuggestionRequestGoesToItself() throws {
        for engine in SearchEngine.allCases {
            let request = OnlineSearchSuggestions.request(for: "swift", engine: engine)
            #expect(request?.url == engine.suggestionURL(for: "swift"))
            #expect((request == nil) == !engine.offersSuggestions)
        }
        #expect(OnlineSearchSuggestions.request(for: "example.com", engine: .bing) == nil, "Addresses are never suggested")
    }
}

private actor EngineSuggestions {
    var calls: [String] = []
    func fetch(_ query: String, _ engine: SearchEngine) -> [String] {
        calls.append("\(query) \(engine.rawValue)")
        return ["\(query) on \(engine.rawValue)"]
    }
}

private actor RecordingSuggestions {
    var queries: [String] = []
    func fetch(_ query: String) -> [String] {
        queries.append(query)
        return ["\(query) guide", "\(query) examples"]
    }
}

private actor SuspendedSuggestions {
    var pending: [String: CheckedContinuation<[String], Never>] = [:]
    func fetch(_ query: String) async -> [String] {
        await withCheckedContinuation { pending[query] = $0 }
    }
    func contains(_ query: String) -> Bool { pending[query] != nil }
    func finish(_ query: String) { pending.removeValue(forKey: query)?.resume(returning: ["\(query) result"]) }
}
