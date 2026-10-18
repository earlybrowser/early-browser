import Foundation

public struct ClosedTab: Codable, Equatable, Sendable {
    public var tab: BrowserTab
    public var position: Int
}

public struct BrowserSession: Codable, Equatable, Sendable {
    public var version = 2
    public var profileID: UUID
    public var activeSpaceID: UUID
    public var tabs: [BrowserTab]
    public var selectionBySpace: [UUID: UUID]
    public var recentlyClosed: [ClosedTab]
    public var folders: [BrowserFolder]
    public var spaces: [BrowserSpace]
    /// Only the root snapshot contains additional windows. Each window owns its
    /// Today tabs and selection; saved items are synchronized before persistence.
    public var additionalWindows: [BrowserSession] = []

    public init(profileID: UUID = UUID(), activeSpaceID: UUID = UUID(),
                tabs: [BrowserTab] = [], selectionBySpace: [UUID: UUID] = [:],
                recentlyClosed: [ClosedTab] = [], folders: [BrowserFolder] = [], spaces: [BrowserSpace]? = nil) {
        self.profileID = profileID
        self.activeSpaceID = activeSpaceID
        self.tabs = tabs
        self.selectionBySpace = selectionBySpace
        self.recentlyClosed = recentlyClosed
        self.folders = folders
        self.spaces = spaces ?? BrowserSpace.migrated(profileID: profileID, activeID: activeSpaceID,
            tabs: tabs, folders: folders, selection: selectionBySpace, closed: recentlyClosed)
    }

    private enum CodingKeys: String, CodingKey {
        case version, profileID, activeSpaceID, tabs, selectionBySpace, recentlyClosed, folders, spaces, additionalWindows
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard storedVersion == 1 || storedVersion == 2 else { throw SessionError.invalidData }
        profileID = try values.decode(UUID.self, forKey: .profileID)
        activeSpaceID = try values.decode(UUID.self, forKey: .activeSpaceID)
        tabs = try values.decode([BrowserTab].self, forKey: .tabs)
        selectionBySpace = try values.decode([UUID: UUID].self, forKey: .selectionBySpace)
        recentlyClosed = try values.decode([ClosedTab].self, forKey: .recentlyClosed)
        folders = try values.decodeIfPresent([BrowserFolder].self, forKey: .folders) ?? []
        additionalWindows = try values.decodeIfPresent([BrowserSession].self, forKey: .additionalWindows) ?? []
        if storedVersion == 1 {
            spaces = BrowserSpace.migrated(profileID: profileID, activeID: activeSpaceID,
                tabs: tabs, folders: folders, selection: selectionBySpace, closed: recentlyClosed)
            // Include Spaces referenced only by a sibling window. All windows
            // share the same catalog, while their selections/Today tabs stay local.
            var seen = Set(spaces.map(\.id))
            for window in additionalWindows {
                for space in window.spaces where seen.insert(space.id).inserted {
                    spaces.append(BrowserSpace(id: space.id, profileID: profileID, name: "Space \(spaces.count + 1)"))
                }
            }
            for index in additionalWindows.indices { additionalWindows[index].spaces = spaces }
            // Old snapshots could contain stale selections; migrate those to an
            // empty state rather than selecting an unrelated page on relaunch.
            pruneSelections()
            for index in additionalWindows.indices { additionalWindows[index].pruneSelections() }
        } else {
            spaces = try values.decode([BrowserSpace].self, forKey: .spaces)
        }
    }

    public func validate(using input: NavigationInput = NavigationInput()) throws {
        for window in additionalWindows {
            guard window.additionalWindows.isEmpty, window.profileID == profileID,
                  window.spaces == spaces else { throw SessionError.invalidData }
            try window.validate(using: input)
        }
        try BrowserFolder.validate(folders)
        try BrowserSpace.validate(spaces, profileID: profileID)
        let spaceIDs = Set(spaces.map(\.id))
        guard spaceIDs.contains(activeSpaceID), folders.allSatisfy({ spaceIDs.contains($0.spaceID) }),
              selectionBySpace.allSatisfy({ space, id in
                  spaceIDs.contains(space) && tabs.contains { $0.id == id && $0.isOpen && $0.isVisible(in: space) }
              }) else { throw SessionError.invalidData }
        guard Set(tabs.map(\.id) + folders.map(\.id)).count == tabs.count + folders.count else { throw SessionError.invalidData }
        guard version == 2, Set(tabs.map(\.id)).count == tabs.count,
              recentlyClosed.count <= 20 else { throw SessionError.invalidData }
        for tab in tabs + recentlyClosed.map(\.tab) {
            guard spaceIDs.contains(tab.spaceID) else { throw SessionError.invalidData }
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

    private mutating func pruneSelections() {
        selectionBySpace = selectionBySpace.filter { space, id in
            spaces.contains { $0.id == space } && tabs.contains { $0.id == id && $0.isOpen && $0.isVisible(in: space) }
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
                              tabs: saved + [page], selectionBySpace: [activeSpaceID: page.id], folders: folders, spaces: spaces)
    }
}
