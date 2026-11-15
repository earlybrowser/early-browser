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
/// Downloads are those a page starts without the person's click.
public enum SitePermission: String, Codable, CaseIterable, Sendable {
    case camera, microphone, location, downloads

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .downloads: "Downloads"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        case .downloads: "arrow.down.circle.fill"
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
public final class SitePermissions: SettingsStore {
    public var decisions: [String: [SitePermission: SitePermissionDecision]] { persistence.value }
    public var isReady: Bool { persistence.isLoaded && !persistence.isRemoved }
    public var isLoading: Bool { persistence.isLoading }
    public var isSaving: Bool { persistence.isSaving }
    public var acceptsChanges: Bool {
        get { persistence.acceptsChanges }
        set { persistence.acceptsChanges = newValue }
    }
    public var loadError: String? {
        persistence.loadError.map { "Your website permission choices couldn’t be loaded. Try again before changing them. \($0)" }
    }
    public var saveError: String? {
        persistence.saveError.map { "Your website permission choices couldn’t be saved, so they last only until you quit Early. \($0)" }
    }
    @ObservationIgnored public let fileURL: URL?
    @ObservationIgnored public var onChange: ((SitePermissions) -> Void)?
    @ObservationIgnored let persistence: SettingsPersistence<[String: [SitePermission: SitePermissionDecision]]>
    @ObservationIgnored private var versions: [String: [SitePermission: UUID]] = [:]
    @ObservationIgnored private var defaultVersion = UUID()

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        persistence = SettingsPersistence(fileURL: fileURL, empty: [:], decode: { data in
            let saved = try JSONDecoder().decode([String: [String: String]].self, from: data)
            return saved.reduce(into: [:]) { result, entry in
                let choices = entry.value.reduce(into: [SitePermission: SitePermissionDecision]()) { choices, choice in
                    if let permission = SitePermission(rawValue: choice.key),
                       let decision = SitePermissionDecision(rawValue: choice.value), decision != .ask {
                        choices[permission] = decision
                    }
                }
                if !choices.isEmpty { result[entry.key] = choices }
            }
        }, encode: { decisions in
            let saved = decisions.mapValues { choices in
                Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value.rawValue) })
            }
            return try JSONEncoder().encode(saved)
        })
        persistence.onAvailabilityChange = { [weak self] in
            guard let self else { return }
            self.defaultVersion = UUID()
            self.onChange?(self)
        }
    }

    @discardableResult public func load(retry: Bool = false) async -> Bool { await persistence.load(retry: retry) }
    public func flush(timeout: Duration = .seconds(10)) async -> Bool { await persistence.flush(timeout: timeout) }
    public func retrySaving() { persistence.retrySaving() }

    /// A prompt cannot accept an older answer after Block → Ask either.
    public func version(for origin: String, _ permission: SitePermission) -> UUID {
        versions[origin]?[permission] ?? defaultVersion
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
        guard isReady else { return .block }
        return decisions[origin]?[permission] ?? .ask
    }

    /// Allowed only when every requested permission is; blocked when any is.
    public func decision(for origin: String, _ permissions: [SitePermission]) -> SitePermissionDecision {
        let choices = permissions.map { decision(for: origin, $0) }
        if choices.contains(.block) { return .block }
        return !choices.isEmpty && choices.allSatisfy { $0 == .allow } ? .allow : .ask
    }

    public func set(_ decision: SitePermissionDecision, for permissions: [SitePermission], origin: String) {
        guard persistence.canChange else { return }
        var choices = decisions[origin] ?? [:]
        for permission in permissions { choices[permission] = decision == .ask ? nil : decision }
        guard decisions[origin] ?? [:] != choices else { return }
        for permission in permissions where decisions[origin]?[permission] != choices[permission] {
            versions[origin, default: [:]][permission] = UUID()
        }
        persistence.mutate { $0[origin] = choices.isEmpty ? nil : choices }
        onChange?(self)
    }

    /// Every site back to asking.
    public func removeAll() {
        guard persistence.canChange, !decisions.isEmpty else { return }
        versions.removeAll()
        defaultVersion = UUID()
        persistence.change([:])
        onChange?(self)
    }

    public func removeFile() async throws {
        defaultVersion = UUID()
        versions.removeAll()
        // The persistence owner closes admission and clears memory before its
        // first await, then waits for old writes before deleting the file.
        try await persistence.removeFile()
    }
}
