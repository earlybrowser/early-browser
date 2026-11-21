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
    /// Opening files on this Mac in tabs, and reading local pages: off by
    /// default, as in Chrome.
    public var allowsLocalFiles: Bool
    public var added: Date

    public init(id: UUID = UUID(), source: ExtensionSource, name: String, version: String, isEnabled: Bool = true,
                siteAccess: ExtensionSiteAccess = .allSites, allowedSites: [String] = [], grantedPermissions: [String] = [],
                allowsPrivateWindows: Bool = false, allowsLocalFiles: Bool = false, added: Date = Date()) {
        self.id = id
        self.source = source
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.siteAccess = siteAccess
        self.allowedSites = allowedSites
        self.grantedPermissions = grantedPermissions
        self.allowsPrivateWindows = allowsPrivateWindows
        self.allowsLocalFiles = allowsLocalFiles
        self.added = added
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, name, version, isEnabled, siteAccess, allowedSites, grantedPermissions, allowsPrivateWindows,
             allowsLocalFiles, added
    }

    /// Catalogs saved before local files had a switch read as not allowed.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(ExtensionSource.self, forKey: .source)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        siteAccess = try values.decode(ExtensionSiteAccess.self, forKey: .siteAccess)
        allowedSites = try values.decode([String].self, forKey: .allowedSites)
        grantedPermissions = try values.decode([String].self, forKey: .grantedPermissions)
        allowsPrivateWindows = try values.decode(Bool.self, forKey: .allowsPrivateWindows)
        allowsLocalFiles = try values.decodeIfPresent(Bool.self, forKey: .allowsLocalFiles) ?? false
        added = try values.decode(Date.self, forKey: .added)
    }
}

/// A profile's extensions, saved beside the session. Their files and data
/// stay in the profile; extensions never cross profiles.
@MainActor @Observable
public final class ExtensionCatalog: SettingsStore {
    public var extensions: [InstalledExtension] { persistence.value }
    public var isReady: Bool { persistence.isLoaded && !persistence.isRemoved }
    public var isLoading: Bool { persistence.isLoading }
    public var isSaving: Bool { persistence.isSaving }
    public var isRemoved: Bool { persistence.isRemoved }
    public var acceptsChanges: Bool {
        get { persistence.acceptsChanges }
        set { persistence.acceptsChanges = newValue }
    }
    public var loadError: String? {
        persistence.loadError.map { "Your extensions couldn’t be loaded. Try again before changing them. \($0)" }
    }
    public var saveError: String? {
        persistence.saveError.map { "Your extension changes couldn’t be saved, so they last only until you quit Early. \($0)" }
    }
    @ObservationIgnored public let fileURL: URL?
    @ObservationIgnored public var onLoad: ((ExtensionCatalog) -> Void)?
    @ObservationIgnored let persistence: SettingsPersistence<[InstalledExtension]>
    @ObservationIgnored private var loadVersions: [UUID: UUID] = [:]
    @ObservationIgnored private var permissionVersions: [UUID: UUID] = [:]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        persistence = SettingsPersistence(fileURL: fileURL, empty: [], decode: {
            try JSONDecoder().decode([InstalledExtension].self, from: $0)
        }, encode: {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode($0)
        })
        persistence.onAvailabilityChange = { [weak self] in
            guard let self, self.isReady else { return }
            self.onLoad?(self)
        }
    }

    @discardableResult public func load(retry: Bool = false) async -> Bool { await persistence.load(retry: retry) }
    public func flush(timeout: Duration = .seconds(10)) async -> Bool { await persistence.flush(timeout: timeout) }
    public func retrySaving() { persistence.retrySaving() }

    /// Unloading/re-enabling or replacing an installation invalidates an
    /// initializer already in flight, even when its ID or choices later match.
    public func loadVersion(_ id: UUID) -> UUID? {
        guard installed(id) != nil, isReady else { return nil }
        if loadVersions[id] == nil { loadVersions[id] = UUID() }
        return loadVersions[id]
    }

    public func installed(_ id: UUID) -> InstalledExtension? { extensions.first { $0.id == id } }

    /// A permission decision can change and change back while its sheet is open.
    public func permissionVersion(_ id: UUID) -> UUID? {
        permissionVersions[id] ?? loadVersion(id)
    }

    /// The extension from this source, if it's already added.
    public func installed(source: ExtensionSource) -> InstalledExtension? { extensions.first { $0.source == source } }

    public func add(_ item: InstalledExtension) {
        guard persistence.canChange, installed(item.id) == nil, installed(source: item.source) == nil else { return }
        loadVersions[item.id] = UUID()
        persistence.mutate { $0.append(item) }
    }

    public func update(_ item: InstalledExtension) {
        guard persistence.canChange, let index = extensions.firstIndex(where: { $0.id == item.id }),
              extensions[index] != item else { return }
        let previous = extensions[index]
        if previous.source != item.source || previous.isEnabled != item.isEnabled
            || previous.allowsPrivateWindows != item.allowsPrivateWindows {
            loadVersions[item.id] = UUID()
            permissionVersions[item.id] = nil
        } else if previous.siteAccess != item.siteAccess || previous.allowedSites != item.allowedSites
                    || previous.grantedPermissions != item.grantedPermissions || previous.allowsLocalFiles != item.allowsLocalFiles {
            permissionVersions[item.id] = UUID()
        }
        persistence.mutate { $0[index] = item }
    }

    /// Changes one extension in place.
    public func change(_ id: UUID, _ body: (inout InstalledExtension) -> Void) {
        guard var item = installed(id) else { return }
        body(&item)
        update(item)
    }

    public func remove(_ id: UUID) {
        guard persistence.canChange, extensions.contains(where: { $0.id == id }) else { return }
        loadVersions[id] = nil
        permissionVersions[id] = nil
        persistence.mutate { $0.removeAll { $0.id == id } }
    }

    /// Deleting a profile drains writes before erasing the catalog.
    public func removeFile() async throws {
        loadVersions.removeAll()
        permissionVersions.removeAll()
        try await persistence.removeFile()
    }

    /// `example.com` from an address, for allowing one site.
    public nonisolated static func site(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
}
