// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

/// Passwords use the same origin for a URL, a WebKit frame and an HTTP challenge.
public enum PasswordOrigin {
    public static func from(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return format(scheme: scheme, host: host, port: url.port)
    }

    /// WebKit reports zero for a scheme's default port.
    public static func from(scheme: String, host: String, port: Int) -> String? {
        format(scheme: scheme, host: host, port: port == 0 ? nil : port)
    }

    private static func format(scheme: String, host: String, port: Int?) -> String? {
        let scheme = scheme.lowercased()
        guard ["http", "https"].contains(scheme), !host.isEmpty else { return nil }
        let authority: String
        if host.contains(":") {
            // Serialized IPv6 hosts enclose the literal in brackets and escape
            // the zone delimiter. Foundation's URL.host has already decoded it.
            let literal = host.hasPrefix("[") && host.hasSuffix("]") ? URL(string: "\(scheme)://\(host)")?.host : host
            guard let literal, let address = ipv6(literal) else { return nil }
            authority = "[\(address)]"
        } else { authority = host.lowercased() }
        let suffix = port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(authority)" + suffix
    }

    private static func ipv6(_ host: String) -> String? {
        let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        var address = in6_addr()
        guard let literal = parts.first, inet_pton(AF_INET6, String(literal), &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let normalized = buffer.withUnsafeMutableBufferPointer { bytes in
            inet_ntop(AF_INET6, &address, bytes.baseAddress, socklen_t(bytes.count)).map { String(cString: $0) }
        }
        guard let normalized else { return nil }
        if parts.count == 1 { return normalized }
        let zone = parts[1]
        guard !zone.isEmpty, zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }) else { return nil }
        return normalized + "%25" + zone
    }

    /// Older files could store an IPv6 address without brackets. Its final
    /// decimal component can be part of the address or a nondefault port.
    static func storedIPv6Origins(_ origin: String) -> [String]? {
        guard let separator = origin.range(of: "://") else { return nil }
        let host = origin[separator.upperBound...]
        if host.first == "[" {
            guard !host.contains(where: { "/?#@".contains($0) }) else { return nil }
            return URL(string: origin).flatMap(from(_:)).map { [$0] }
        }
        guard let colon = host.lastIndex(of: ":"), host[..<colon].contains(":") else { return nil }
        let scheme = String(origin[..<separator.lowerBound])
        var candidates: [String] = []
        if let whole = format(scheme: scheme, host: String(host), port: nil) { candidates.append(whole) }
        let suffix = host[host.index(after: colon)...]
        if let port = UInt16(suffix), String(port) == suffix, port != 0, port != (scheme == "https" ? 443 : 80),
           let withPort = format(scheme: scheme, host: String(host[..<colon]), port: Int(port)) {
            candidates.append(withPort)
        }
        return candidates
    }
}
