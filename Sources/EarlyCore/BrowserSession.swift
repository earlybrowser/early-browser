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
    /// Only the root snapshot contains additional windows. Each window owns its
    /// Today tabs and selection; saved items are synchronized before persistence.
    public var additionalWindows: [BrowserSession] = []

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
        case version, profileID, activeSpaceID, tabs, selectionBySpace, recentlyClosed, folders, additionalWindows
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
        additionalWindows = try values.decodeIfPresent([BrowserSession].self, forKey: .additionalWindows) ?? []
    }

    public func validate(using input: NavigationInput = NavigationInput()) throws {
        for window in additionalWindows {
            guard window.additionalWindows.isEmpty, window.profileID == profileID else { throw SessionError.invalidData }
            try window.validate(using: input)
        }
        try BrowserFolder.validate(folders)
        guard Set(tabs.map(\.id) + folders.map(\.id)).count == tabs.count + folders.count else { throw SessionError.invalidData }
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

    /// A copied page is a new Today tab, even when opened from a saved pin.
    /// Saved tabs start unloaded; no other window's live navigation is copied.
    public func openingWindow(at url: URL, title: String? = nil) -> BrowserSession {
        let saved = tabs.filter { $0.pinnedURL != nil }.map { tab in
            var copy = tab
            copy.currentURL = tab.pinnedURL!
            copy.title = tab.pinnedTitle ?? tab.title
            copy.isOpen = false
            return copy
        }
        let page = BrowserTab(spaceID: activeSpaceID, profileID: profileID,
                              title: title ?? url.host ?? url.absoluteString, currentURL: url)
        return BrowserSession(profileID: profileID, activeSpaceID: activeSpaceID,
                              tabs: saved + [page], selectionBySpace: [activeSpaceID: page.id], folders: folders)
    }
}
