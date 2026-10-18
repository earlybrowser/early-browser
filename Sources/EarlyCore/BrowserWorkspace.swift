// SPDX-License-Identifier: MPL-2.0

import Foundation

public struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var color: BrowserSpace.Color

    public init(id: UUID = UUID(), name: String, color: BrowserSpace.Color = .blue) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// One atomic snapshot owns all profiles. Each profile keeps its existing
/// window-local Today tabs and profile-wide saved organization. No website
/// storage, cookies, or credentials are serialized here.
public struct BrowserWorkspace: Codable, Equatable, Sendable {
    public var workspaceVersion = 1
    public var profiles: [BrowserProfile]
    public var sessions: [BrowserSession]
    public var defaultProfileID: UUID
    public var activeProfileID: UUID
    public var openProfileIDs: [UUID]

    public init(session: BrowserSession = BrowserSession()) {
        profiles = [BrowserProfile(id: session.profileID, name: "Default", color: .gray)]
        sessions = [session]
        defaultProfileID = session.profileID
        activeProfileID = session.profileID
        openProfileIDs = [session.profileID]
    }

    public func session(for profileID: UUID) -> BrowserSession? { sessions.first { $0.profileID == profileID } }

    public func validate(using input: NavigationInput = NavigationInput()) throws {
        let profileIDs = Set(profiles.map(\.id))
        guard workspaceVersion == 1, !profiles.isEmpty, profileIDs.count == profiles.count,
              !profileIDs.contains(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))),
              Set(sessions.map(\.profileID)) == profileIDs, sessions.count == profiles.count,
              profileIDs.contains(defaultProfileID), profileIDs.contains(activeProfileID),
              Set(openProfileIDs).count == openProfileIDs.count, Set(openProfileIDs).isSubset(of: profileIDs),
              profiles.allSatisfy({ BrowserSpace.normalizedName($0.name) == $0.name }),
              Set(profiles.map { $0.name.lowercased() }).count == profiles.count else { throw SessionError.invalidData }
        var spaceIDs = Set<UUID>()
        var itemIDs = Set<UUID>()
        for session in sessions {
            try session.validate(using: input)
            let spaces = Set(session.spaces.map(\.id))
            let items = Set(([session] + session.additionalWindows).flatMap { $0.tabs.map(\.id) + $0.folders.map(\.id) })
            guard spaces.isDisjoint(with: spaceIDs), items.isDisjoint(with: itemIDs) else { throw SessionError.invalidData }
            spaceIDs.formUnion(spaces)
            itemIDs.formUnion(items)
        }
    }

    public static func decodeMigrating(_ data: Data, using input: NavigationInput = NavigationInput()) throws -> Self {
        struct Header: Decodable { let workspaceVersion: Int? }
        let decoder = JSONDecoder()
        let result: Self
        if try decoder.decode(Header.self, from: data).workspaceVersion != nil {
            result = try decoder.decode(Self.self, from: data)
        } else {
            // The original UUID remains the WebKit storage identifier. Merely
            // introducing named profiles must never sign existing users out.
            result = Self(session: try decoder.decode(BrowserSession.self, from: data))
        }
        try result.validate(using: input)
        return result
    }

    @discardableResult
    public mutating func createProfile(name: String, color: BrowserSpace.Color = .blue) -> UUID? {
        guard let name = BrowserSpace.normalizedName(name),
              !profiles.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
        let profile = BrowserProfile(name: name, color: color)
        let space = BrowserSpace(profileID: profile.id, name: name, color: color)
        profiles.append(profile)
        sessions.append(BrowserSession(profileID: profile.id, activeSpaceID: space.id, spaces: [space]))
        return profile.id
    }

    @discardableResult
    public mutating func editProfile(_ id: UUID, name: String, color: BrowserSpace.Color) -> Bool {
        guard let name = BrowserSpace.normalizedName(name), let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) else { return false }
        profiles[index].name = name
        profiles[index].color = color
        return true
    }

    @discardableResult
    public mutating func setDefaultProfile(_ id: UUID) -> Bool {
        guard profiles.contains(where: { $0.id == id }), session(for: id) != nil else { return false }
        defaultProfileID = id
        return true
    }

    @discardableResult
    public mutating func deleteProfile(_ id: UUID) -> Bool {
        guard id != defaultProfileID, profiles.contains(where: { $0.id == id }) else { return false }
        profiles.removeAll { $0.id == id }
        sessions.removeAll { $0.profileID == id }
        openProfileIDs.removeAll { $0 == id }
        if activeProfileID == id { activeProfileID = defaultProfileID }
        return true
    }

    /// Called only after the UI confirms that pages will reload. The operation
    /// reassigns metadata, not WebKit configurations or authentication state.
    /// Favorites stay with their original profile; folder/tab identities stay.
    @discardableResult
    public mutating func moveSpace(_ id: UUID, from sourceID: UUID, to destinationID: UUID,
                                   using input: NavigationInput = NavigationInput()) -> Bool {
        guard sourceID != destinationID,
              let sourceIndex = sessions.firstIndex(where: { $0.profileID == sourceID }),
              let destinationIndex = sessions.firstIndex(where: { $0.profileID == destinationID }),
              let space = sessions[sourceIndex].spaces.first(where: { $0.id == id }),
              (try? validate(using: input)) != nil else { return false }
        var draft = self
        var source = draft.sessions[sourceIndex]
        var destination = draft.sessions[destinationIndex]
        let sourceWindows = [source] + source.additionalWindows
        var movedTabs: [BrowserTab] = []
        for window in sourceWindows {
            for tab in window.tabs where tab.spaceID == id && !tab.isFavorite {
                if let index = movedTabs.firstIndex(where: { $0.id == tab.id }) {
                    if !movedTabs[index].isOpen && tab.isOpen { movedTabs[index] = tab }
                } else { movedTabs.append(tab) }
            }
        }
        movedTabs = movedTabs.map { $0.reassigned(to: destinationID) }
        let movedFolders = source.folders.filter { $0.spaceID == id }
        var remainingSpaces = source.spaces.filter { $0.id != id }
        if remainingSpaces.isEmpty { remainingSpaces = [BrowserSpace(profileID: sourceID, name: "Personal")] }
        func removeSpace(from window: inout BrowserSession) {
            window.spaces = remainingSpaces
            window.tabs.removeAll { $0.spaceID == id && !$0.isFavorite }
            window.folders.removeAll { $0.spaceID == id }
            window.recentlyClosed.removeAll { $0.tab.spaceID == id && !$0.tab.isFavorite }
            for index in window.tabs.indices where window.tabs[index].spaceID == id {
                window.tabs[index].spaceID = remainingSpaces[0].id
            }
            for index in window.recentlyClosed.indices where window.recentlyClosed[index].tab.spaceID == id {
                window.recentlyClosed[index].tab.spaceID = remainingSpaces[0].id
            }
            window.selectionBySpace.removeValue(forKey: id)
            if window.activeSpaceID == id { window.activeSpaceID = remainingSpaces[0].id }
        }
        removeSpace(from: &source)
        for index in source.additionalWindows.indices { removeSpace(from: &source.additionalWindows[index]) }
        let newSpace = BrowserSpace(id: id, profileID: destinationID, name: space.name, color: space.color, icon: space.icon)
        destination.spaces.append(newSpace)
        destination.tabs.append(contentsOf: movedTabs)
        destination.folders.append(contentsOf: movedFolders)
        destination.activeSpaceID = id
        let selected = sourceWindows.first?.selectionBySpace[id]
        destination.selectionBySpace[id] = movedTabs.first { $0.id == selected && $0.isOpen }?.id
            ?? movedTabs.first { $0.isOpen }?.id
        for index in destination.additionalWindows.indices {
            destination.additionalWindows[index].spaces = destination.spaces
            destination.additionalWindows[index].folders.append(contentsOf: movedFolders)
            destination.additionalWindows[index].tabs.append(contentsOf: movedTabs.filter { $0.pinnedURL != nil }.map { $0.closedSavedCopy })
        }
        draft.sessions[sourceIndex] = source
        draft.sessions[destinationIndex] = destination
        guard (try? draft.validate(using: input)) != nil else { return false }
        self = draft
        return true
    }

    public func startingWithSavedItemsOnly() -> Self {
        var copy = self
        copy.sessions = sessions.map { $0.savedItemsOnly }
        copy.activeProfileID = defaultProfileID
        copy.openProfileIDs = [defaultProfileID]
        return copy
    }
}

public extension BrowserSession {
    var savedItemsOnly: Self {
        BrowserSession(profileID: profileID, activeSpaceID: activeSpaceID,
            tabs: tabs.filter { $0.pinnedURL != nil }.map(\.closedSavedCopy), folders: folders, spaces: spaces)
    }
}

private extension BrowserTab {
    var closedSavedCopy: Self {
        var copy = self
        copy.isOpen = false
        copy.currentURL = pinnedURL ?? currentURL
        copy.title = pinnedTitle ?? title
        return copy
    }

    func reassigned(to profileID: UUID) -> Self {
        var copy = Self(id: id, spaceID: spaceID, profileID: profileID, title: title, currentURL: currentURL,
            pinnedURL: pinnedURL, isOpen: isOpen, pinnedTitle: pinnedTitle, isFavorite: isFavorite, customTitle: customTitle)
        copy.folderID = folderID
        copy.sidebarPosition = sidebarPosition
        return copy
    }
}
