import Foundation

/// Ordered metadata for one profile, independent of presentation and live views.
public struct TabStore: Equatable, Sendable {
    public private(set) var tabs: [BrowserTab]

    public init(tabs: [BrowserTab] = []) {
        self.tabs = tabs
    }

    public func tab(id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    public func openTabs(in spaceID: UUID) -> [BrowserTab] {
        // Keyboard selection and close-neighbour selection follow sidebar order.
        favorites.filter(\.isOpen) + pinnedTabs(in: spaceID).filter(\.isOpen) + todayTabs(in: spaceID)
    }

    public var favorites: [BrowserTab] { tabs.filter(\.isFavorite) }

    public func pinnedTabs(in spaceID: UUID) -> [BrowserTab] {
        tabs.filter { $0.spaceID == spaceID && $0.pinnedURL != nil && !$0.isFavorite }
    }

    public func todayTabs(in spaceID: UUID) -> [BrowserTab] {
        tabs.filter { $0.spaceID == spaceID && $0.pinnedURL == nil && !$0.isFavorite && $0.isOpen }
    }

    @discardableResult
    public mutating func setPinned(_ id: UUID, pinned: Bool) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              !tabs[index].isFavorite,
              (tabs[index].pinnedURL != nil) != pinned else { return false }
        if pinned {
            guard tabs[index].isOpen else { return false }
            tabs[index].pinnedURL = tabs[index].currentURL
            tabs[index].pinnedTitle = savedTitle(for: tabs[index])
        } else {
            tabs[index].pinnedURL = nil
            tabs[index].pinnedTitle = nil
            // A closed pin becomes an unloaded Today tab, not orphaned metadata.
            // The runtime owner still loads only on explicit selection.
            tabs[index].isOpen = true
        }
        return true
    }

    /// Favorites reuse pin lifecycle and identity, but are visible in every space.
    /// Removing one places a regular tab in the current space, without loading it.
    @discardableResult
    public mutating func setFavorite(_ id: UUID, favorite: Bool, in spaceID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].isFavorite != favorite else { return false }
        if favorite, tabs[index].pinnedURL == nil {
            guard setPinned(id, pinned: true) else { return false }
        }
        tabs[index].isFavorite = favorite
        if !favorite {
            tabs[index].spaceID = spaceID
            tabs[index].pinnedURL = nil
            tabs[index].pinnedTitle = nil
            // A closed favorite becomes an unloaded regular tab, like unpinning.
            tabs[index].isOpen = true
        }
        return true
    }

    public mutating func insert(_ tab: BrowserTab, at position: Int? = nil) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tabs.insert(tab, at: min(max(position ?? tabs.count, 0), tabs.count))
    }

    public mutating func reopen(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isOpen = true
    }

    @discardableResult
    public mutating func update(_ id: UUID, url: URL? = nil, title: String? = nil) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let before = tabs[index]
        if let url { tabs[index].currentURL = url }
        if let title, !title.isEmpty { tabs[index].title = String(title.prefix(512)) }
        // Old sessions and pins made before a page finished loading have no
        // saved name. Learn it only from the original page, never a subpage.
        if title != nil, tabs[index].pinnedTitle == nil,
           tabs[index].currentURL == tabs[index].pinnedURL {
            tabs[index].pinnedTitle = savedTitle(for: tabs[index])
        }
        return before != tabs[index]
    }

    private func savedTitle(for tab: BrowserTab) -> String? {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != tab.currentURL.host,
              title != tab.currentURL.absoluteString else { return nil }
        return String(title.prefix(512))
    }

    @discardableResult
    public mutating func resetPinnedLocation(_ id: UUID) -> URL? {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let url = tabs[index].pinnedURL else { return nil }
        tabs[index].currentURL = url
        tabs[index].title = tabs[index].pinnedTitle ?? url.host ?? url.absoluteString
        return url
    }

    /// Closing a pin resets its address and unloads it, preserving its identity.
    /// Prefer the next open neighbor, then the previous one, in this space only.
    @discardableResult
    public mutating func close(id: UUID, in spaceID: UUID? = nil) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id && $0.isOpen }) else {
            return nil
        }
        let tab = tabs[index]
        let candidates = openTabs(in: spaceID ?? tab.spaceID)
        guard let openIndex = candidates.firstIndex(where: { $0.id == id }) else { return nil }
        let nextID = candidates.dropFirst(openIndex + 1).first?.id
            ?? candidates.prefix(openIndex).last?.id
        if tab.pinnedURL != nil {
            tabs[index].isOpen = false
            resetPinnedLocation(id)
        } else {
            tabs.remove(at: index)
        }
        return nextID
    }
}
