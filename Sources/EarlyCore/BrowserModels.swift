import Foundation

/// Durable metadata. A tab never owns a web view or a navigation delegate.
public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let spaceID: UUID
    public let profileID: UUID
    public var title: String
    public var currentURL: URL
    public var pinnedURL: URL?
    public var isOpen: Bool

    public init(
        id: UUID = UUID(), spaceID: UUID, profileID: UUID,
        title: String, currentURL: URL, pinnedURL: URL? = nil, isOpen: Bool = true
    ) {
        self.id = id
        self.spaceID = spaceID
        self.profileID = profileID
        self.title = title
        self.currentURL = currentURL
        self.pinnedURL = pinnedURL
        self.isOpen = isOpen
    }
}

public enum CommandBarIntent: Equatable, Sendable {
    case newTab
    case navigateCurrentTab
    case commandSearch
}

public enum BrowserContentPresentation: Equatable, Sendable {
    case empty
    case web(tabID: UUID)
}

public struct CommandBarPresentation: Equatable, Sendable {
    public var intent: CommandBarIntent
    public var query: String

    public init(intent: CommandBarIntent, query: String = "") {
        self.intent = intent
        self.query = query
    }
}

public enum StartupContext: Sendable {
    case firstLaunch
    case returningSession
}

/// An unvalidated request, not permission to load a URL. NavigationInput must
/// validate it before the window model creates a tab or web view.
public struct NavigationRequest: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case newTab(spaceID: UUID)
        case currentTab(UUID)
    }

    public let query: String
    public let target: Target
}
