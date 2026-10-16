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
