import Foundation

public struct ClosedTab: Codable, Equatable, Sendable {
    public var tab: BrowserTab
    public var position: Int
}

public struct BrowserSession: Codable, Equatable, Sendable {
    public var version = 1
    public var profileID: UUID
    public var activeSpaceID: UUID
    public var tabs: [BrowserTab]
    public var selectionBySpace: [UUID: UUID]
    public var recentlyClosed: [ClosedTab]
    public var folders: [BrowserFolder]

    public init(profileID: UUID = UUID(), activeSpaceID: UUID = UUID(),
                tabs: [BrowserTab] = [], selectionBySpace: [UUID: UUID] = [:],
                recentlyClosed: [ClosedTab] = [], folders: [BrowserFolder] = []) {
        self.profileID = profileID
        self.activeSpaceID = activeSpaceID
        self.tabs = tabs
        self.selectionBySpace = selectionBySpace
        self.recentlyClosed = recentlyClosed
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case version, profileID, activeSpaceID, tabs, selectionBySpace, recentlyClosed, folders
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        activeSpaceID = try values.decode(UUID.self, forKey: .activeSpaceID)
        tabs = try values.decode([BrowserTab].self, forKey: .tabs)
        selectionBySpace = try values.decode([UUID: UUID].self, forKey: .selectionBySpace)
        recentlyClosed = try values.decode([ClosedTab].self, forKey: .recentlyClosed)
        folders = try values.decodeIfPresent([BrowserFolder].self, forKey: .folders) ?? []
    }

    public func validate(using input: NavigationInput = NavigationInput()) throws {
        try BrowserFolder.validate(folders)
        guard version == 1, Set(tabs.map(\.id)).count == tabs.count,
              recentlyClosed.count <= 20 else { throw SessionError.invalidData }
        for tab in tabs + recentlyClosed.map(\.tab) {
            if let id = tab.folderID {
                guard tab.pinnedURL != nil, !tab.isFavorite,
                      folders.contains(where: { $0.id == id && $0.spaceID == tab.spaceID }) else { throw SessionError.invalidData }
            }
            guard !tab.isFavorite || tab.pinnedURL != nil else { throw SessionError.invalidData }
            _ = try input.validate(tab.currentURL)
            if let url = tab.pinnedURL { _ = try input.validate(url) }
            guard tab.profileID == profileID else { throw SessionError.invalidData }
        }
    }
}
