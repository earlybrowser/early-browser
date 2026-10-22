// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One searchable command-bar entry. Candidates are value snapshots: selecting
/// one is dispatched by the window, which revalidates its target first.
public struct CommandSearchCandidate: Identifiable, Equatable, Sendable {
    public enum Kind: Int, Comparable, Sendable {
        // Raw values are the deterministic tie-break order.
        case favorite, pinnedTab, openTab, space, profile, action, history

        public var isTab: Bool { self == .favorite || self == .pinnedTab || self == .openTab }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Target: Equatable, Sendable {
        /// An existing record. Selection switches to or reopens this identity.
        case tab(UUID)
        case space(UUID)
        case profile(UUID)
        case action(BrowserAction)
        /// A page from history, opened like a typed address.
        case page(URL)
    }

    public let id: String
    public let kind: Kind
    public let target: Target
    public let title: String
    /// Display-only secondary text, usually a URL.
    public let detail: String?
    /// Additional searchable fields, e.g. saved/current URLs or alternate names.
    public let terms: [String]
    public let isOpen: Bool
    public let lastUsed: Date?
    public let useCount: Int

    public init(id: String, kind: Kind, target: Target, title: String, detail: String? = nil,
                terms: [String] = [], isOpen: Bool = false, lastUsed: Date? = nil, useCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.detail = detail
        self.terms = terms
        self.isOpen = isOpen
        self.lastUsed = lastUsed
        self.useCount = max(0, useCount)
    }
}

public struct CommandSearchResult: Identifiable, Equatable, Sendable {
    public enum Match: Int, Comparable, Sendable {
        case fuzzy, tokens, substring, wordPrefix, prefix, exact
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let candidate: CommandSearchCandidate
    public let match: Match
    public let score: Int
    public var id: String { candidate.id }
}

/// Asynchronous source for data owned outside the window, such as history.
/// Providers return candidates; Early's ranker decides which match.
public protocol CommandSearchProvider: Sendable {
    func candidates(matching query: String, limit: Int) async throws -> [CommandSearchCandidate]
}

public struct CommandSearchLimits: Equatable, Sendable {
    public var total: Int
    public var tabs: Int
    public var spaces: Int
    public var profiles: Int
    public var actions: Int
    public var pages: Int
    public var maximumCandidates: Int
    public var maximumQueryLength: Int
    public var providerResults: Int

    public init(total: Int = 8, tabs: Int = 5, spaces: Int = 3, profiles: Int = 3, actions: Int = 4, pages: Int = 6,
                maximumCandidates: Int = 5_000, maximumQueryLength: Int = 200, providerResults: Int = 50) {
        self.total = max(0, total)
        self.tabs = max(0, tabs)
        self.spaces = max(0, spaces)
        self.profiles = max(0, profiles)
        self.actions = max(0, actions)
        self.pages = max(0, pages)
        self.maximumCandidates = max(0, maximumCandidates)
        self.maximumQueryLength = max(1, maximumQueryLength)
        self.providerResults = max(0, providerResults)
    }

    func limit(for kind: CommandSearchCandidate.Kind) -> Int {
        switch kind {
        case .favorite, .pinnedTab, .openTab: tabs
        case .space: spaces
        case .profile: profiles
        case .action: actions
        case .history: pages
        }
    }
}

/// Case-, diacritic- and URL-scheme-insensitive text used only for matching.
public enum CommandSearchText {
    public static let maximumFieldLength = 512

    public static func normalize(_ text: String, limit: Int = maximumFieldLength) -> String {
        let folded = String(text.prefix(limit * 2))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(limit))
    }

    /// `https://www.example.com/` and `example.com` describe the same address
    /// to a person typing; strip only presentation prefixes and the root slash.
    public static func address(_ text: String) -> String {
        var value = normalize(text, limit: maximumFieldLength * 2)
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if value.hasSuffix("/"), value.filter({ $0 == "/" }).count == 1 { value.removeLast() }
        return String(value.prefix(maximumFieldLength))
    }

    public static func address(_ url: URL) -> String { address(url.absoluteString) }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

/// Pure, deterministic matching and ranking. The same query, candidates and
/// clock always produce the same order, independent of input order.
public enum CommandSearchRanker {
    public static func rank(_ query: String, candidates: [CommandSearchCandidate], now: Date,
                            limits: CommandSearchLimits = CommandSearchLimits()) throws -> [CommandSearchResult] {
        guard let query = Query(query, limit: limits.maximumQueryLength) else { return [] }
        var matches: [CommandSearchResult] = []
        var seen = Set<String>()
        for (index, candidate) in candidates.prefix(limits.maximumCandidates).enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard seen.insert(candidate.id).inserted,
                  let (match, base) = bestMatch(query, candidate) else { continue }
            matches.append(CommandSearchResult(candidate: candidate, match: match,
                score: base + bonus(for: candidate, now: now)))
        }
        try Task.checkCancellation()
        matches.sort(by: ordered)
        var counts: [CommandSearchCandidate.Kind: Int] = [:]
        var tabCount = 0
        var pageCount = 0
        var results: [CommandSearchResult] = []
        for result in matches where results.count < limits.total {
            let kind = result.candidate.kind
            if kind.isTab {
                guard tabCount < limits.tabs else { continue }
                tabCount += 1
            } else if kind == .history {
                guard pageCount < limits.pages else { continue }
                pageCount += 1
            } else {
                guard counts[kind, default: 0] < limits.limit(for: kind) else { continue }
                counts[kind, default: 0] += 1
            }
            results.append(result)
        }
        return results
    }

    static func ordered(_ lhs: CommandSearchResult, _ rhs: CommandSearchResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.candidate.kind != rhs.candidate.kind { return lhs.candidate.kind < rhs.candidate.kind }
        let left = CommandSearchText.normalize(lhs.candidate.title)
        let right = CommandSearchText.normalize(rhs.candidate.title)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    struct Query {
        let text: String
        let address: String
        let tokens: [String]

        init?(_ raw: String, limit: Int) {
            let text = CommandSearchText.normalize(raw, limit: limit)
            guard !text.isEmpty else { return nil }
            self.text = text
            address = CommandSearchText.address(text)
            tokens = text.split(separator: " ").map(String.init)
        }
    }

    // Match tiers are separated widely enough that usage only reorders
    // results of similar quality; it cannot lift a weak fuzzy match over a
    // fresh exact or prefix match.
    static func base(_ match: CommandSearchResult.Match) -> Int {
        switch match {
        case .exact: 1_000
        case .prefix: 800
        case .wordPrefix: 650
        case .substring: 500
        case .tokens: 450
        case .fuzzy: 300
        }
    }

    static func bestMatch(_ query: Query, _ candidate: CommandSearchCandidate) -> (CommandSearchResult.Match, Int)? {
        var best: (CommandSearchResult.Match, Int)?
        func consider(_ found: (CommandSearchResult.Match, Int)?) {
            guard let found, best.map({ found.1 > $0.1 }) ?? true else { return }
            best = found
        }
        let title = CommandSearchText.normalize(candidate.title)
        consider(match(query.text, in: title))
        var words = Self.words(title)
        let texts = query.address == query.text || query.address.isEmpty ? [query.text] : [query.text, query.address]
        for term in candidate.terms.prefix(8) {
            let field = CommandSearchText.address(term)
            words += Self.words(field)
            for text in texts {
                // Secondary fields count slightly less than the visible name
                // and do not allow subsequence fuzzy leaps across URLs/keywords.
                consider(match(text, in: field, allowFuzzy: false).map { ($0.0, $0.1 - $0.1 / 10) })
            }
        }
        if query.tokens.count > 1, query.tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) {
            consider((.tokens, base(.tokens)))
        }
        return best
    }

    static func match(_ query: String, in field: String, allowFuzzy: Bool = true) -> (CommandSearchResult.Match, Int)? {
        guard !query.isEmpty, !field.isEmpty else { return nil }
        if field == query { return (.exact, base(.exact)) }
        if field.hasPrefix(query) { return (.prefix, base(.prefix)) }
        var search = field.startIndex..<field.endIndex
        var foundSubstring = false
        while let range = field.range(of: query, options: .literal, range: search) {
            if range.lowerBound == field.startIndex
                || !CommandSearchText.isWordCharacter(field[field.index(before: range.lowerBound)]) {
                return (.wordPrefix, base(.wordPrefix))
            }
            foundSubstring = true
            search = field.index(after: range.lowerBound)..<field.endIndex
        }
        let length = query.count
        if foundSubstring, length >= 2 { return (.substring, base(.substring)) }
        guard allowFuzzy, length >= 3, !query.contains(" "), let penalty = fuzzyPenalty(query, in: field) else { return nil }
        return (.fuzzy, max(150, base(.fuzzy) - penalty))
    }

    /// An in-order subsequence that starts at a word boundary and stays
    /// compact. Only the first few boundaries are tried, keeping it linear.
    static func fuzzyPenalty(_ query: String, in field: String) -> Int? {
        let needle = Array(query)
        let haystack = Array(field)
        guard let first = needle.first else { return nil }
        let maximumSpan = max(needle.count * 3, needle.count + 8)
        var best: Int?
        var attempts = 0
        for start in haystack.indices where haystack[start] == first
            && (start == 0 || !CommandSearchText.isWordCharacter(haystack[start - 1])) {
            attempts += 1
            guard attempts <= 8 else { break }
            var position = start + 1
            var matched = 1
            while matched < needle.count, position < haystack.count, position - start <= maximumSpan {
                if haystack[position] == needle[matched] { matched += 1 }
                position += 1
            }
            guard matched == needle.count else { continue }
            let penalty = (position - start - needle.count) * 12 + min(start, 40)
            best = min(best ?? penalty, penalty)
        }
        return best
    }

    static func words(_ field: String) -> [String] {
        field.split(whereSeparator: { !CommandSearchText.isWordCharacter($0) }).map(String.init)
    }

    /// Bounded recency/frequency and saved-item bonuses.
    static func bonus(for candidate: CommandSearchCandidate, now: Date) -> Int {
        var bonus = 0
        if candidate.kind == .favorite || candidate.kind == .pinnedTab { bonus += 40 }
        if candidate.kind.isTab, candidate.isOpen { bonus += 20 }
        if let used = candidate.lastUsed {
            let hours = max(0, now.timeIntervalSince(used)) / 3_600
            bonus += Int((120 * pow(0.5, hours / 72)).rounded())
        }
        if candidate.useCount > 0 {
            bonus += min(60, Int((15 * log2(1 + Double(min(candidate.useCount, BrowserTab.maximumActivationCount)))).rounded()))
        }
        return bonus
    }
}
