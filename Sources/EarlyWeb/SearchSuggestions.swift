import Foundation
import Observation

/// Conservative filtering: online completion is for search phrases, not addresses.
public enum SearchSuggestionPolicy {
    public static func query(_ input: String) -> String? {
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...200).contains(query.count), query.utf8.count <= 1024,
              !query.contains(where: { ".:/\\@?#".contains($0) }),
              query.lowercased() != "localhost" else { return nil }
        return query
    }

    static func parse(_ data: Data, query: String, textEncodingName: String? = nil) throws -> [String] {
        guard data.count <= 65_536 else { return [] }
        // The Chrome endpoint can return Latin-1 even when the query itself is
        // ASCII (e.g. a GitHub description containing a middle dot for "git").
        // JSONSerialization accepts Unicode, not arbitrary HTTP encodings.
        let json: Data
        switch textEncodingName?.lowercased() {
        case "iso-8859-1", "latin1", "latin-1":
            guard let decoded = String(data: data, encoding: .isoLatin1) else {
                throw URLError(.cannotDecodeContentData)
            }
            json = Data(decoded.utf8)
        case nil, "utf-8", "utf8": json = data
        default: throw URLError(.cannotDecodeContentData)
        }
        guard let response = try JSONSerialization.jsonObject(with: json) as? [Any],
              response.count >= 2, response[0] as? String == query,
              let candidates = response[1] as? [String] else { return [] }
        var seen: Set<String> = [query.lowercased()]
        return Array(candidates.compactMap { candidate in
            guard let clean = Self.query(candidate), seen.insert(clean.lowercased()).inserted else { return nil }
            return clean
        }.prefix(6))
    }
}

/// Separate from WebKit's website sessions: no cookies, credentials or disk cache.
public struct GoogleSearchSuggestions: Sendable {
    private let session: URLSession

    public init() {
        session = URLSession(configuration: Self.configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        return configuration
    }

    static func request(for query: String) -> URLRequest? {
        guard SearchSuggestionPolicy.query(query) == query else { return nil }
        // Google documents this suggest URL in its Chrome search-provider policy.
        var components = URLComponents(string: "https://www.google.com/complete/search")!
        components.queryItems = [URLQueryItem(name: "output", value: "chrome"),
                                 URLQueryItem(name: "oe", value: "utf-8"),
                                 URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetch(_ query: String) async throws -> [String] {
        guard let request = Self.request(for: query) else { return [] }
        let (bytes, response) = try await session.bytes(for: request, delegate: NoSuggestionRedirects())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= 65_536 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return try SearchSuggestionPolicy.parse(data, query: query, textEncodingName: response.textEncodingName)
    }
}

private final class NoSuggestionRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Small, short-lived completion cache, owned by one window and never persisted.
struct SearchSuggestionCache {
    private struct Entry {
        let query: String
        let values: [String]
        let expires: ContinuousClock.Instant
    }
    private var entries: [Entry] = []
    let capacity: Int
    let lifetime: Duration

    init(capacity: Int = 32, lifetime: Duration = .seconds(120)) {
        self.capacity = max(0, capacity)
        self.lifetime = lifetime
    }

    mutating func lookup(_ query: String, now: ContinuousClock.Instant = .now) -> [String]? {
        entries.removeAll { $0.expires <= now }
        guard let index = entries.firstIndex(where: { $0.query == query }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.values
    }

    mutating func insert(_ values: [String], for query: String, now: ContinuousClock.Instant = .now) {
        guard capacity > 0 else { return }
        entries.removeAll { $0.expires <= now || $0.query == query }
        entries.append(Entry(query: query, values: Array(values.prefix(6)), expires: now.advanced(by: lifetime)))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    mutating func clear() { entries.removeAll() }
}

@MainActor @Observable
public final class SearchSuggestions {
    public private(set) var results: [String] = []
    public private(set) var selectedIndex: Int?
    public private(set) var isLoading = false
    public private(set) var isRefreshing = false
    public private(set) var unavailable = false
    private var generation = 0
    private var request: Task<Void, Never>?
    private let fetch: @Sendable (String) async throws -> [String]
    private let debounce: Duration
    private var activeQuery: String?
    private var cache = SearchSuggestionCache()

    public init(debounce: Duration = .milliseconds(60),
                fetch: @escaping @Sendable (String) async throws -> [String]) {
        self.debounce = debounce
        self.fetch = fetch
    }

    public var selectedSuggestion: String? {
        guard !isRefreshing, let selectedIndex, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    public func moveSelection(_ delta: Int) {
        guard !isRefreshing, !results.isEmpty else { return }
        let next = (selectedIndex ?? (delta > 0 ? -1 : results.count)) + delta
        selectedIndex = results.indices.contains(next) ? next : nil
    }

    public func cancel() {
        generation += 1
        request?.cancel()
        request = nil
        activeQuery = nil
        results = []
        selectedIndex = nil
        isLoading = false
        isRefreshing = false
        unavailable = false
    }

    public func update(query: String, enabled: Bool) {
        if !enabled { cache.clear() }
        guard enabled, let query = SearchSuggestionPolicy.query(query) else {
            cancel()
            return
        }
        // Repeated notifications must not restart an already running request.
        if activeQuery == query && isRefreshing { return }
        let startsNewSearch = activeQuery == nil
        // Retain the previous list's footprint while fetching its replacement.
        // It is display-only until fresh results arrive, never a stale action.
        generation += 1
        request?.cancel()
        request = nil
        activeQuery = query
        selectedIndex = nil
        isLoading = false
        unavailable = false
        if let cached = cache.lookup(query) {
            results = cached
            isRefreshing = false
            return
        }
        isRefreshing = true
        let revision = generation
        let fetch = fetch
        // Start the first eligible query immediately; briefly coalesce subsequent
        // keystrokes rather than waiting for a long pause in typing.
        let debounce = startsNewSearch ? Duration.zero : debounce
        request = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                guard let self, !Task.isCancelled, self.generation == revision else { return }
                self.isLoading = true
                let values = try await fetch(query)
                guard !Task.isCancelled, self.generation == revision else { return }
                self.results = Array(values.prefix(6))
                self.cache.insert(self.results, for: query)
                self.isLoading = false
                self.isRefreshing = false
                self.request = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == revision else { return }
                self.isLoading = false
                self.isRefreshing = false
                self.results = []
                self.unavailable = true
                self.request = nil
            }
        }
    }
}
