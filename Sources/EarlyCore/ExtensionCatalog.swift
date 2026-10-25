// SPDX-License-Identifier: MPL-2.0

import Foundation
import Observation

/// Where an installed extension's files are.
public enum ExtensionSource: Codable, Equatable, Hashable, Sendable {
    /// A Safari Web Extension inside a Mac app, loaded from the app in place.
    case app(extensionPath: String, bundleIdentifier: String)
    /// A folder or ZIP the person chose, copied into Early's own storage.
    case files(folderName: String)

    public var isFromApp: Bool {
        if case .app = self { return true }
        return false
    }
}

/// Which websites an extension may read and change.
public enum ExtensionSiteAccess: String, Codable, CaseIterable, Sendable {
    /// Every website it asks for, as Chrome grants at install.
    case allSites
    /// Only a page it's used on, after it's clicked, plus sites allowed one by one.
    case whenClicked

    public var title: String {
        switch self {
        case .allSites: "On All Websites"
        case .whenClicked: "When You Click It"
        }
    }
}

/// An extension added to a profile, and the person's choices for it.
public struct InstalledExtension: Codable, Equatable, Identifiable, Sendable {
    /// Also its address's host and the identifier its storage is kept under.
    public var id: UUID
    public var source: ExtensionSource
    public var name: String
    public var version: String
    public var isEnabled: Bool
    public var siteAccess: ExtensionSiteAccess
    /// Hosts allowed besides `siteAccess`, such as "example.com".
    public var allowedSites: [String]
    /// Optional API permissions granted when it asked for them.
    public var grantedPermissions: [String]
    /// Off by default, as in Safari and Chrome.
    public var allowsPrivateWindows: Bool
    public var added: Date

    public init(id: UUID = UUID(), source: ExtensionSource, name: String, version: String, isEnabled: Bool = true,
                siteAccess: ExtensionSiteAccess = .allSites, allowedSites: [String] = [], grantedPermissions: [String] = [],
                allowsPrivateWindows: Bool = false, added: Date = Date()) {
        self.id = id
        self.source = source
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.siteAccess = siteAccess
        self.allowedSites = allowedSites
        self.grantedPermissions = grantedPermissions
        self.allowsPrivateWindows = allowsPrivateWindows
        self.added = added
    }
}

/// A profile's extensions, saved beside the session. Their files and data
/// stay in the profile; extensions never cross profiles.
@MainActor @Observable
public final class ExtensionCatalog {
    public private(set) var extensions: [InstalledExtension] = []
    /// Why the latest changes couldn't be saved; nil once a save succeeds.
    /// They still apply until Early quits, and ``retrySaving()`` tries again.
    public private(set) var saveError: String?
    @ObservationIgnored public let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        extensions = (try? JSONDecoder().decode([InstalledExtension].self, from: data)) ?? []
    }

    public func installed(_ id: UUID) -> InstalledExtension? { extensions.first { $0.id == id } }

    /// The extension from this source, if it's already added.
    public func installed(source: ExtensionSource) -> InstalledExtension? { extensions.first { $0.source == source } }

    public func add(_ item: InstalledExtension) {
        guard installed(item.id) == nil, installed(source: item.source) == nil else { return }
        extensions.append(item)
        save()
    }

    public func update(_ item: InstalledExtension) {
        guard let index = extensions.firstIndex(where: { $0.id == item.id }), extensions[index] != item else { return }
        extensions[index] = item
        save()
    }

    /// Changes one extension in place.
    public func change(_ id: UUID, _ body: (inout InstalledExtension) -> Void) {
        guard var item = installed(id) else { return }
        body(&item)
        update(item)
    }

    public func remove(_ id: UUID) {
        guard extensions.contains(where: { $0.id == id }) else { return }
        extensions.removeAll { $0.id == id }
        save()
    }

    /// Deleting a profile.
    public func removeFile() {
        extensions.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    public func retrySaving() { save() }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(extensions)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            if saveError != nil { saveError = nil }
        } catch {
            saveError = "Your extension changes couldn’t be saved, so they last only until you quit Early. \(error.localizedDescription)"
        }
    }

    /// `example.com` from an address, for allowing one site.
    public nonisolated static func site(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
}
