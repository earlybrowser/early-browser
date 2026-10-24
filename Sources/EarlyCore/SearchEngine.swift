// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Where command-bar searches go, chosen in Settings › Search. Google stays
/// the default, as it was before there was a choice.
public enum SearchEngine: String, CaseIterable, Codable, Sendable {
    case google, duckDuckGo, bing, ecosia, brave, kagi

    public var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        case .brave: "Brave Search"
        case .kagi: "Kagi"
        }
    }

    public func searchURL(for query: String) -> URL {
        let (address, name) = switch self {
        case .google: ("https://www.google.com/search", "q")
        case .duckDuckGo: ("https://duckduckgo.com/", "q")
        case .bing: ("https://www.bing.com/search", "q")
        case .ecosia: ("https://www.ecosia.org/search", "q")
        case .brave: ("https://search.brave.com/search", "q")
        case .kagi: ("https://kagi.com/search", "q")
        }
        var parts = URLComponents(string: address)!
        parts.queryItems = [URLQueryItem(name: name, value: query)]
        return parts.url!
    }

    /// The engine's own suggestions, in the OpenSearch form `[query, [suggestions]]`.
    /// Nil when it offers none without an account: then nothing typed leaves
    /// the Mac until a search, and nothing is sent to another engine instead.
    public func suggestionURL(for query: String) -> URL? {
        let endpoint: (address: String, items: [URLQueryItem])? = switch self {
        // Google documents this one in its Chrome search-provider policy.
        case .google: ("https://www.google.com/complete/search",
                       [URLQueryItem(name: "output", value: "chrome"), URLQueryItem(name: "oe", value: "utf-8"),
                        URLQueryItem(name: "q", value: query)])
        case .duckDuckGo: ("https://duckduckgo.com/ac/", [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "list")])
        case .bing: ("https://api.bing.com/osjson.aspx", [URLQueryItem(name: "query", value: query)])
        case .ecosia: ("https://ac.ecosia.org/autocomplete", [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "list")])
        case .brave: ("https://search.brave.com/api/suggest", [URLQueryItem(name: "q", value: query)])
        // Kagi's suggestions need its sign-in.
        case .kagi: nil
        }
        guard let endpoint, var parts = URLComponents(string: endpoint.address) else { return nil }
        parts.queryItems = endpoint.items
        return parts.url
    }

    public var offersSuggestions: Bool { suggestionURL(for: "early") != nil }
}
