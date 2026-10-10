import Foundation

/// Ordered metadata, independent of both window presentation and live web views.
public struct TabStore: Equatable, Sendable {
    public private(set) var tabs: [BrowserTab]

    public init(tabs: [BrowserTab] = []) {
        self.tabs = tabs
    }

    public func tab(id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    public func openTabs(in spaceID: UUID) -> [BrowserTab] {
        tabs.filter { $0.spaceID == spaceID && $0.isOpen }
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
        return before != tabs[index]
    }

    /// Closing a pin changes its open state, never its persistent identity.
    /// Prefer the next open neighbor, then the previous one, in this space only.
    @discardableResult
    public mutating func close(id: UUID) -> UUID? {
        guard let index = tabs.firstIndex(where: { $0.id == id && $0.isOpen }) else {
            return nil
        }
        let tab = tabs[index]
        let candidates = openTabs(in: tab.spaceID)
        let openIndex = candidates.firstIndex { $0.id == id }!
        let nextID = candidates.dropFirst(openIndex + 1).first?.id
            ?? candidates.prefix(openIndex).last?.id
        if tab.pinnedURL != nil {
            tabs[index].isOpen = false
        } else {
            tabs.remove(at: index)
        }
        return nextID
    }
}
