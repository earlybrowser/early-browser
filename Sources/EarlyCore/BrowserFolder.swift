// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A folder whose pins come from somewhere else and keep up with it, like
/// Arc's live folders. Its pins are added and removed for the person.
public struct LiveFolder: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The profile's open pull requests on GitHub.
        case githubPullRequests
    }

    /// How often its source is read again, as chosen in the folder's menu.
    public enum Interval: Int, Codable, CaseIterable, Sendable {
        case fifteenMinutes = 900, thirtyMinutes = 1800, oneHour = 3600, twoHours = 7200
        case fourHours = 14400, eightHours = 28800

        public var seconds: TimeInterval { TimeInterval(rawValue) }

        public var title: String {
            switch self {
            case .fifteenMinutes: "15 minutes"
            case .thirtyMinutes: "30 minutes"
            case .oneHour: "1 hour"
            case .twoHours: "2 hours"
            case .fourHours: "4 hours"
            case .eightHours: "8 hours"
            }
        }
    }

    public var source: Source
    public var interval: Interval
    /// Items removed by hand: not added again while the source still lists them.
    public var dismissed: [String]

    public init(source: Source, interval: Interval = .fifteenMinutes, dismissed: [String] = []) {
        self.source = source
        self.interval = interval
        self.dismissed = dismissed
    }

    private enum CodingKeys: String, CodingKey { case source, interval, dismissed }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(Source.self, forKey: .source)
        interval = (try? values.decodeIfPresent(Interval.self, forKey: .interval)) ?? .fifteenMinutes
        dismissed = (try? values.decodeIfPresent([String].self, forKey: .dismissed)) ?? []
    }

    /// The most items remembered as removed.
    public static let dismissedLimit = 200
}

/// One item a live folder's source lists: a pin, known by `id`.
public struct LiveFolderItem: Equatable, Sendable {
    public let id: String
    public let url: URL
    public let title: String

    public init(id: String, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

public struct BrowserFolder: Identifiable, Codable, Equatable, Sendable {
    /// Root = 0, with eight nested levels beneath it. Sibling count is unrestricted.
    public static let maximumNestingDepth = 8

    public let id: UUID
    public let spaceID: UUID
    public var parentID: UUID?
    public var name: String
    public var isExpanded: Bool
    public var sidebarPosition: Int?
    /// Set for a live folder; nil for the person's own folders.
    public var live: LiveFolder?
    /// Drawn on the folder's front, from the same set as Space icons.
    public var icon: SpaceIcon?

    public init(id: UUID = UUID(), spaceID: UUID, parentID: UUID? = nil, name: String, isExpanded: Bool = false,
                live: LiveFolder? = nil, icon: SpaceIcon? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.parentID = parentID
        self.name = name
        self.isExpanded = isExpanded
        self.live = live
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey { case id, spaceID, parentID, name, isExpanded, sidebarPosition, live, icon }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        spaceID = try values.decode(UUID.self, forKey: .spaceID)
        parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        name = try values.decode(String.self, forKey: .name)
        isExpanded = try values.decode(Bool.self, forKey: .isExpanded)
        sidebarPosition = try values.decodeIfPresent(Int.self, forKey: .sidebarPosition)
        // Like a Space's icon, decoration never stops a session restoring; an
        // unknown live source restores as an ordinary folder.
        live = (try? values.decodeIfPresent(LiveFolder.self, forKey: .live)) ?? nil
        icon = (try? values.decodeIfPresent(SpaceIcon.self, forKey: .icon)) ?? nil
    }

    public static func validate(_ folders: [BrowserFolder]) throws {
        guard Set(folders.map(\.id)).count == folders.count else { throw SessionError.invalidData }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for folder in folders {
            guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  folder.name.count <= 128 else { throw SessionError.invalidData }
            var seen: Set<UUID> = [folder.id]
            var parent = folder.parentID
            while let id = parent {
                guard seen.insert(id).inserted, seen.count <= 32,
                      let ancestor = byID[id], ancestor.spaceID == folder.spaceID else { throw SessionError.invalidData }
                parent = ancestor.parentID
            }
        }
    }

    /// Structural validation retains the old storage ceiling so previously
    /// saved deep hierarchies stay readable. New creation/moves use the UI limit.
    public static func nestingDepth(of id: UUID, in folders: [BrowserFolder]) -> Int? {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let folder = byID[id] else { return nil }
        var parent = folder.parentID, seen: Set<UUID> = [id], depth = 0
        while let next = parent {
            guard seen.insert(next).inserted, seen.count <= 32,
                  let ancestor = byID[next], ancestor.spaceID == folder.spaceID else { return nil }
            depth += 1
            parent = ancestor.parentID
        }
        return depth
    }
}
