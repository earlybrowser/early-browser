// SPDX-License-Identifier: MPL-2.0

import Foundation

public enum NavigationInputError: String, LocalizedError, Sendable {
    case empty = "Enter a URL or search term."
    case unsupportedScheme = "This address type is not supported. Use an HTTP or HTTPS address."
    case invalidAddress = "That address is not valid. Check the hostname and port."
    case credentials = "Addresses containing a username or password are not supported."
    public var errorDescription: String? { rawValue }
}

public struct NavigationInput: Sendable {
    public let allowedSchemes: Set<String>
    public init(allowedSchemes: Set<String> = ["http", "https"]) {
        self.allowedSchemes = allowedSchemes
    }

    public func resolve(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NavigationInputError.empty }
        let authority = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        let local = authority == "localhost" || authority.hasPrefix("localhost:")
            || authority.hasPrefix("127.") || authority.hasPrefix("[::1]")
        let hostWithPort = authority.range(of: #"^(localhost|[\w.-]+\.[\w.-]+|\[[0-9a-fA-F:]+\]):[0-9]+$"#,
                                         options: .regularExpression) != nil
        let explicitScheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
        if explicitScheme && !hostWithPort {
            guard let url = URL(string: text) else { throw NavigationInputError.invalidAddress }
            return try validate(url)
        }
        if !text.contains(where: { $0.isWhitespace }),
           local || authority.contains(".") || hostWithPort || authority.hasPrefix("[") {
            guard let url = URL(string: (local ? "http://" : "https://") + text) else {
                throw NavigationInputError.invalidAddress
            }
            return try validate(url)
        }
        return try searchURL(for: text)
    }

    /// A provider suggestion is always a search, never permission to visit a URL.
    /// Clipboard text as a one-line query for Paste and Go. An address copied
    /// with line breaks (wrapped in an email or document) is joined again;
    /// other text has every run of whitespace reduced to one space.
    public static func pastedQuery(_ text: String, limit: Int = 2048) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let wrappedAddress = !trimmed.contains { $0 == " " || $0 == "\t" }
        let query = wrappedAddress ? trimmed.filter { !$0.isNewline }
            : trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(query.prefix(limit))
    }

    /// View Page Source shows `view-source:` plus the page's address.
    public static let pageSourceScheme = "view-source"
    /// Extensions' own pages: Safari Web Extensions from Mac apps, and folder
    /// or ZIP installs. They open in tabs but are not websites.
    public static let extensionSchemes: Set<String> = ["safari-web-extension", "webkit-extension"]

    public static func sourceURL(of page: URL) -> URL? { URL(string: pageSourceScheme + ":" + page.absoluteString) }

    public static func page(ofSource url: URL) -> URL? {
        guard url.scheme?.lowercased() == pageSourceScheme else { return nil }
        return URL(string: String(url.absoluteString.dropFirst(pageSourceScheme.count + 1)))
    }

    public func searchURL(for query: String) throws -> URL {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NavigationInputError.empty }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url!
    }

    public func validate(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            throw NavigationInputError.unsupportedScheme
        }
        if scheme == Self.pageSourceScheme {
            // A page's source: valid when the page's own address is.
            guard let page = Self.page(ofSource: url), page.scheme?.lowercased() != Self.pageSourceScheme else {
                throw NavigationInputError.invalidAddress
            }
            _ = try validate(page)
            return url
        }
        if scheme == "file" {
            // Local documents chosen by the user: a path, and no remote host.
            guard url.isFileURL, url.path.hasPrefix("/"), url.path.count > 1,
                  (url.host ?? "").isEmpty || url.host == "localhost" else { throw NavigationInputError.invalidAddress }
            return url
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw NavigationInputError.invalidAddress
        }
        guard parts.user == nil, parts.password == nil else { throw NavigationInputError.credentials }
        return url
    }
}
