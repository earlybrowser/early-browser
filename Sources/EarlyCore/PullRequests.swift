// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The Pull Requests live folder's groups, each one of GitHub's own pull
/// request searches. `@me` is whoever is signed in to GitHub in the profile.
public enum PullRequestGroup: String, CaseIterable, Sendable {
    case opened, assigned, reviewRequested

    public var title: String {
        switch self {
        case .opened: "Opened"
        case .assigned: "Assigned"
        case .reviewRequested: "Review Requested"
        }
    }

    /// Review requests include those made to the person's teams.
    public var query: String {
        switch self {
        case .opened: "is:pr is:open author:@me"
        case .assigned: "is:pr is:open assignee:@me"
        case .reviewRequested: "is:pr is:open review-requested:@me"
        }
    }

    public func url(base: URL = PullRequest.github) -> URL {
        var parts = URLComponents(url: base.appending(path: "pulls"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts.url!
    }
}

/// One pull request, known by its repository and number, GitHub's stable
/// identifiers; the title is only for showing.
public struct PullRequest: Identifiable, Equatable, Sendable {
    public static let github = URL(string: "https://github.com")!
    public static let titleLimit = 300

    public let owner: String
    public let repository: String
    public let number: Int
    public let title: String

    /// GitHub names are case-insensitive.
    public var id: String { "\(owner)/\(repository)#\(number)".lowercased() }
    public var repositoryName: String { "\(owner)/\(repository)" }

    public func url(base: URL = github) -> URL { base.appending(path: "\(owner)/\(repository)/pull/\(number)") }

    public init?(owner: String, repository: String, number: Int, title: String) {
        guard Self.isName(owner), Self.isName(repository), (1...999_999_999).contains(number) else { return nil }
        self.owner = owner
        self.repository = repository
        self.number = number
        let line = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.title = line.isEmpty ? "Pull request #\(number)" : String(line.prefix(Self.titleLimit))
    }

    private static func isName(_ name: String) -> Bool {
        (1...100).contains(name.count) && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.".unicodeScalars.contains($0) }
    }

    /// The same pull request, or one of its own pages (files, commits).
    public func isShown(at url: URL, base: URL = github) -> Bool {
        guard url.host?.lowercased() == base.host?.lowercased() else { return false }
        let own = "/\(owner)/\(repository)/pull/\(number)".lowercased()
        let path = url.path.lowercased()
        return path == own || path == own + "/" || path.hasPrefix(own + "/")
    }
}

/// What one of GitHub's pages gave.
public enum PullRequestReading: Equatable, Sendable {
    case found([PullRequest])
    /// GitHub sent the reader to its sign-in page.
    case signedOut
    /// The page loaded but its pull requests couldn't be found, as after a
    /// GitHub redesign.
    case unreadable
    case offline
    /// GitHub asked to slow down.
    case throttled
}

/// One group's pull requests in the folder.
public struct PullRequestSection: Identifiable, Equatable, Sendable {
    public let group: PullRequestGroup
    public let items: [PullRequest]
    public var id: PullRequestGroup { group }

    public init(group: PullRequestGroup, items: [PullRequest]) {
        self.group = group
        self.items = items
    }
}

/// What the folder shows.
public enum PullRequestFolderStatus: Equatable, Sendable {
    case idle, loading, ready, signedOut, unreadable, offline, throttled
}

public enum PullRequests {
    /// At most this many per group: the first page of GitHub's results.
    public static let limit = 25
    /// How often a shown folder is read again.
    public static let interval: TimeInterval = 600

    /// The reader script's answer for one page, given where it ended up.
    public static func reading(from result: Any?, finalURL: URL?, statusCode: Int?, base: URL = PullRequest.github) -> PullRequestReading {
        if statusCode == 429 { return .throttled }
        guard let finalURL, finalURL.host?.lowercased() == base.host?.lowercased() else { return .unreadable }
        let path = finalURL.path.lowercased()
        if path.hasPrefix("/login") || path.hasPrefix("/session") { return .signedOut }
        guard let page = result as? [String: Any] else { return .unreadable }
        if page["limited"] as? Bool == true { return .throttled }
        if let statusCode, !(200..<300).contains(statusCode) { return .unreadable }
        let entries = (page["entries"] as? [[String: Any]] ?? []).compactMap { entry -> PullRequest? in
            guard let owner = entry["owner"] as? String, let repository = entry["repo"] as? String,
                  let number = (entry["number"] as? NSNumber)?.intValue else { return nil }
            return PullRequest(owner: owner, repository: repository, number: number, title: entry["title"] as? String ?? "")
        }
        if !entries.isEmpty { return .found(Array(unique(entries).prefix(limit))) }
        // An empty search still shows GitHub's search box or its "No results".
        return page["recognized"] as? Bool == true ? .found([]) : .unreadable
    }

    public enum Contents: Equatable, Sendable {
        case sections([PullRequestSection])
        case failed(PullRequestFolderStatus)
    }

    /// The folder from every group's page. One failure fails the folder, so
    /// it never shows a partial or out-of-date list; each pull request is
    /// listed once, in the first group it's in.
    public static func combine(_ readings: [PullRequestGroup: PullRequestReading]) -> Contents {
        let all = PullRequestGroup.allCases.map { readings[$0] ?? .unreadable }
        for failure in [PullRequestReading.signedOut, .throttled, .offline, .unreadable] where all.contains(failure) {
            switch failure {
            case .signedOut: return .failed(.signedOut)
            case .throttled: return .failed(.throttled)
            case .offline: return .failed(.offline)
            default: return .failed(.unreadable)
            }
        }
        var seen = Set<String>()
        var sections: [PullRequestSection] = []
        for (group, reading) in zip(PullRequestGroup.allCases, all) {
            guard case .found(let items) = reading else { continue }
            sections.append(PullRequestSection(group: group, items: items.filter { seen.insert($0.id).inserted }))
        }
        return .sections(sections)
    }

    /// When to try again after a failure, backing off as it repeats.
    public static func retryDelay(after status: PullRequestFolderStatus, failures: Int) -> TimeInterval {
        let repeats = Double(max(failures - 1, 0))
        switch status {
        case .throttled: return min(1200 * pow(2, repeats), 3600)
        case .offline: return min(60 * pow(2, repeats), 600)
        case .unreadable: return 1800
        default: return interval
        }
    }

    private static func unique(_ items: [PullRequest]) -> [PullRequest] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
