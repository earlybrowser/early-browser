// SPDX-License-Identifier: MPL-2.0

import Foundation
import Observation

/// How far the current page's connection can be trusted, from WebKit's
/// public trust and secure-content state.
public enum PageSecurity: Equatable, Sendable {
    /// No website: an empty tab or one of Early's own pages.
    case none
    case secure
    /// HTTPS, but some of the page's content arrived unencrypted.
    case mixedContent
    case notSecure
    /// The certificate could not be verified, so Early did not open the page.
    case certificateProblem
    case localFile

    public static func classify(url: URL?, hasOnlySecureContent: Bool, certificateFailed: Bool) -> PageSecurity {
        if certificateFailed { return .certificateProblem }
        switch url?.scheme?.lowercased() {
        case "https": return hasOnlySecureContent ? .secure : .mixedContent
        case "http": return .notSecure
        case "file": return .localFile
        default: return .none
        }
    }

    /// HTTP pages, mixed content and certificate problems.
    public var isInsecure: Bool { self == .notSecure || self == .mixedContent || self == .certificateProblem }
}

/// What a website can ask to use. Notifications have no public WebKit API.
public enum SitePermission: String, Codable, CaseIterable, Sendable {
    case camera, microphone, location

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        }
    }
}

public enum SitePermissionDecision: String, Codable, CaseIterable, Sendable {
    case ask, allow, block

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .block: "Block"
        }
    }
}

/// A profile's per-site permission choices, keyed by origin. Saved beside the
/// session; a private profile keeps them in memory only.
@MainActor @Observable
public final class SitePermissions {
    public private(set) var decisions: [String: [SitePermission: SitePermissionDecision]] = [:]
    /// Why the latest choices couldn't be saved; nil once a save succeeds.
    /// They still apply until Early quits, and ``retrySaving()`` tries again.
    public private(set) var saveError: String?
    @ObservationIgnored public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return }
        for (origin, choices) in saved {
            let parsed = choices.reduce(into: [SitePermission: SitePermissionDecision]()) { result, choice in
                if let permission = SitePermission(rawValue: choice.key),
                   let decision = SitePermissionDecision(rawValue: choice.value), decision != .ask {
                    result[permission] = decision
                }
            }
            if !parsed.isEmpty { decisions[origin] = parsed }
        }
    }

    /// `scheme://host[:port]` for web pages; nil for anything else.
    public nonisolated static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : $0 }
        return origin(scheme: scheme, host: host, port: port ?? 0)
    }

    /// WebKit's security origins report port 0 for a scheme's default port.
    public nonisolated static func origin(scheme: String, host: String, port: Int) -> String? {
        let scheme = scheme.lowercased(), host = host.lowercased()
        guard ["http", "https"].contains(scheme), !host.isEmpty else { return nil }
        let explicit = port != 0 && port != (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host)" + (explicit ? ":\(port)" : "")
    }

    public func decision(for origin: String, _ permission: SitePermission) -> SitePermissionDecision {
        decisions[origin]?[permission] ?? .ask
    }

    /// Allowed only when every requested permission is; blocked when any is.
    public func decision(for origin: String, _ permissions: [SitePermission]) -> SitePermissionDecision {
        let choices = permissions.map { decision(for: origin, $0) }
        if choices.contains(.block) { return .block }
        return !choices.isEmpty && choices.allSatisfy { $0 == .allow } ? .allow : .ask
    }

    public func set(_ decision: SitePermissionDecision, for permissions: [SitePermission], origin: String) {
        var choices = decisions[origin] ?? [:]
        for permission in permissions { choices[permission] = decision == .ask ? nil : decision }
        guard decisions[origin] ?? [:] != choices else { return }
        decisions[origin] = choices.isEmpty ? nil : choices
        save()
    }

    /// Every site back to asking.
    public func removeAll() {
        guard !decisions.isEmpty else { return }
        decisions.removeAll()
        save()
    }

    public func removeFile() {
        decisions.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    public func retrySaving() { save() }

    private func save() {
        guard let fileURL else { return }
        let saved = decisions.mapValues { choices in
            Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value.rawValue) })
        }
        do {
            let data = try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            if saveError != nil { saveError = nil }
        } catch {
            saveError = "Your website permission choices couldn’t be saved, so they last only until you quit Early. \(error.localizedDescription)"
        }
    }
}
