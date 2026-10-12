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

    public init(profileID: UUID = UUID(), activeSpaceID: UUID = UUID(),
                tabs: [BrowserTab] = [], selectionBySpace: [UUID: UUID] = [:],
                recentlyClosed: [ClosedTab] = []) {
        self.profileID = profileID
        self.activeSpaceID = activeSpaceID
        self.tabs = tabs
        self.selectionBySpace = selectionBySpace
        self.recentlyClosed = recentlyClosed
    }

    public func validate(using input: NavigationInput = NavigationInput()) throws {
        guard version == 1, Set(tabs.map(\.id)).count == tabs.count,
              recentlyClosed.count <= 20 else { throw SessionError.invalidData }
        for tab in tabs + recentlyClosed.map(\.tab) {
            guard !tab.isFavorite || tab.pinnedURL != nil else { throw SessionError.invalidData }
            _ = try input.validate(tab.currentURL)
            if let url = tab.pinnedURL { _ = try input.validate(url) }
            guard tab.profileID == profileID else { throw SessionError.invalidData }
        }
    }
}
