import Foundation

/// Durable metadata. A tab never owns a web view or a navigation delegate.
public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var spaceID: UUID
    public let profileID: UUID
    public var title: String
    public var currentURL: URL
    public var pinnedURL: URL?
    /// The original page name, independent of the title of a page visited later.
    public var pinnedTitle: String?
    public var isFavorite: Bool
    public var isOpen: Bool

    public init(
        id: UUID = UUID(), spaceID: UUID, profileID: UUID,
        title: String, currentURL: URL, pinnedURL: URL? = nil, isOpen: Bool = true,
        pinnedTitle: String? = nil, isFavorite: Bool = false
    ) {
        self.id = id
        self.spaceID = spaceID
        self.profileID = profileID
        self.title = title
        self.currentURL = currentURL
        self.pinnedURL = pinnedURL
        self.pinnedTitle = pinnedURL == nil ? nil : (pinnedTitle ?? (currentURL == pinnedURL ? title : nil))
        self.isFavorite = isFavorite
        self.isOpen = isOpen
    }

    private enum CodingKeys: String, CodingKey {
        case id, spaceID, profileID, title, currentURL, pinnedURL, pinnedTitle, isOpen, isFavorite
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        spaceID = try values.decode(UUID.self, forKey: .spaceID)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        title = try values.decode(String.self, forKey: .title)
        currentURL = try values.decode(URL.self, forKey: .currentURL)
        pinnedURL = try values.decodeIfPresent(URL.self, forKey: .pinnedURL)
        pinnedTitle = try values.decodeIfPresent(String.self, forKey: .pinnedTitle)
        isOpen = try values.decode(Bool.self, forKey: .isOpen)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    public func isVisible(in spaceID: UUID) -> Bool {
        isFavorite || self.spaceID == spaceID
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
