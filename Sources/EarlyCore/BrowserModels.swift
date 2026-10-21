// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Durable metadata. A tab never owns a web view or a navigation delegate.
public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var spaceID: UUID
    public let profileID: UUID
    public var title: String
    public var customTitle: String?
    public var folderID: UUID?
    public var sidebarPosition: Int?
    public var displayTitle: String { customTitle ?? title }
    public var currentURL: URL
    public var pinnedURL: URL?
    /// The original page name, independent of the title of a page visited later.
    public var pinnedTitle: String?
    public var isFavorite: Bool
    public var isOpen: Bool
    /// Local command-bar ranking signals for this existing record only. This
    /// is not browsing history and is removed with the tab.
    public var lastActivatedAt: Date?
    public var activationCount: Int
    public static let maximumActivationCount = 10_000

    /// Compare the complete address: a different path, query or fragment is a detour.
    public var hasNavigatedFromPin: Bool {
        isOpen && pinnedURL.map { $0 != currentURL } == true
    }

    public init(
        id: UUID = UUID(), spaceID: UUID, profileID: UUID,
        title: String, currentURL: URL, pinnedURL: URL? = nil, isOpen: Bool = true,
        pinnedTitle: String? = nil, isFavorite: Bool = false, customTitle: String? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.profileID = profileID
        self.title = title
        self.customTitle = customTitle
        self.currentURL = currentURL
        self.pinnedURL = pinnedURL
        self.pinnedTitle = pinnedURL == nil ? nil : (pinnedTitle ?? (currentURL == pinnedURL ? title : nil))
        self.isFavorite = isFavorite
        self.isOpen = isOpen
        lastActivatedAt = nil
        activationCount = 0
    }

    /// Record a user-visible switch to this tab, bounded for persistence.
    public mutating func recordActivation(at date: Date) {
        lastActivatedAt = date
        activationCount = min(Self.maximumActivationCount, activationCount + 1)
    }

    /// Windows sharing a saved item keep its most recent, most frequent use.
    public mutating func mergeUsage(from other: BrowserTab) {
        if let date = other.lastActivatedAt, lastActivatedAt.map({ date > $0 }) ?? true { lastActivatedAt = date }
        activationCount = max(activationCount, other.activationCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id, spaceID, profileID, title, customTitle, folderID, sidebarPosition, currentURL, pinnedURL, pinnedTitle, isOpen, isFavorite
        case lastActivatedAt, activationCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        spaceID = try values.decode(UUID.self, forKey: .spaceID)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        title = try values.decode(String.self, forKey: .title)
        customTitle = try values.decodeIfPresent(String.self, forKey: .customTitle)
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
        sidebarPosition = try values.decodeIfPresent(Int.self, forKey: .sidebarPosition)
        currentURL = try values.decode(URL.self, forKey: .currentURL)
        pinnedURL = try values.decodeIfPresent(URL.self, forKey: .pinnedURL)
        pinnedTitle = try values.decodeIfPresent(String.self, forKey: .pinnedTitle)
        isOpen = try values.decode(Bool.self, forKey: .isOpen)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        // Ranking signals are optional and advisory: older sessions lack them,
        // and an unusable value must not prevent restoring the tab.
        lastActivatedAt = (try? values.decodeIfPresent(Date.self, forKey: .lastActivatedAt))
            .flatMap { $0 }.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
        let count = (try? values.decodeIfPresent(Int.self, forKey: .activationCount)).flatMap { $0 } ?? 0
        activationCount = min(Self.maximumActivationCount, max(0, count))
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
    /// Distinguish an untouched location prefill from deliberately searching
    /// for the same address. Transient UI state, never session metadata.
    public internal(set) var hasEditedQuery = false

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
