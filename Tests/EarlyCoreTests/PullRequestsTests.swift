// SPDX-License-Identifier: MPL-2.0

@testable import EarlyCore
import Foundation
import Testing

struct PullRequestsTests {
    private let github = PullRequest.github
    private func page(_ path: String) -> URL { github.appending(path: path) }
    private func entry(_ owner: String, _ repo: String, _ number: Int, _ title: String = "Title") -> [String: Any] {
        ["owner": owner, "repo": repo, "number": NSNumber(value: number), "title": title]
    }

    @Test func eachGroupIsOneOfGitHubsSearches() throws {
        let opened = PullRequestGroup.opened.url()
        let parts = try #require(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        #expect(parts.host == "github.com" && parts.path == "/pulls")
        #expect(parts.queryItems == [URLQueryItem(name: "q", value: "is:pr is:open author:@me")])
        #expect(PullRequestGroup.assigned.query.contains("assignee:@me"))
        #expect(PullRequestGroup.reviewRequested.query.contains("review-requested:@me"), "Includes the person's teams")
        #expect(PullRequestGroup.allCases.map(\.title) == ["Opened", "Assigned", "Review Requested"])
    }

    @Test func pullRequestsAreKnownByRepositoryAndNumber() throws {
        let item = try #require(PullRequest(owner: "Octo", repository: "Early.app", number: 12, title: "  Add\n the   folder "))
        #expect(item.id == "octo/early.app#12" && item.title == "Add the folder")
        #expect(item.url().absoluteString == "https://github.com/Octo/Early.app/pull/12")
        #expect(PullRequest(owner: "octo", repository: "early", number: 3, title: "")?.title == "Pull request #3")
        #expect(PullRequest(owner: "../x", repository: "early", number: 1, title: "") == nil)
        #expect(PullRequest(owner: "octo", repository: "..", number: 1, title: "") == nil)
        #expect(PullRequest(owner: "octo", repository: "early", number: 0, title: "") == nil)
        #expect(PullRequest(owner: "o c", repository: "early", number: 1, title: "") == nil)
        #expect(PullRequest(owner: "octo", repository: "early", number: 1, title: String(repeating: "a", count: 400))?.title.count
                == PullRequest.titleLimit)
        // Its tab: the pull request or one of its pages, never another one.
        #expect(item.isShown(at: page("octo/early.app/pull/12")))
        #expect(item.isShown(at: page("Octo/Early.app/pull/12/files")))
        #expect(!item.isShown(at: page("octo/early.app/pull/120")))
        #expect(!item.isShown(at: URL(string: "https://example.com/Octo/Early.app/pull/12")!))
    }

    @Test func aPageSaysWhatItShows() {
        let list: [String: Any] = ["entries": [entry("octo", "early", 1, "One"), entry("OCTO", "Early", 1, "Again"),
                                               entry("bad name", "x", 2), ["owner": "octo"]], "recognized": true]
        #expect(PullRequests.reading(from: list, finalURL: page("pulls"), statusCode: 200)
                == .found([PullRequest(owner: "octo", repository: "early", number: 1, title: "One")!]))
        let many: [String: Any] = ["entries": (1...40).map { entry("octo", "early", $0) }]
        if case .found(let items) = PullRequests.reading(from: many, finalURL: page("pulls"), statusCode: 200) {
            #expect(items.count == PullRequests.limit)
        } else { Issue.record("Not found") }

        let empty: [String: Any] = ["entries": [], "recognized": true]
        #expect(PullRequests.reading(from: empty, finalURL: page("pulls"), statusCode: 200) == .found([]))
        let unknown: [String: Any] = ["entries": [], "recognized": false]
        #expect(PullRequests.reading(from: unknown, finalURL: page("pulls"), statusCode: 200) == .unreadable)
        #expect(PullRequests.reading(from: nil, finalURL: page("pulls"), statusCode: 200) == .unreadable)
        #expect(PullRequests.reading(from: empty, finalURL: page("login"), statusCode: 200) == .signedOut)
        #expect(PullRequests.reading(from: empty, finalURL: page("session"), statusCode: 200) == .signedOut)
        #expect(PullRequests.reading(from: nil, finalURL: page("pulls"), statusCode: 429) == .throttled)
        #expect(PullRequests.reading(from: ["limited": true], finalURL: page("pulls"), statusCode: 403) == .throttled)
        #expect(PullRequests.reading(from: empty, finalURL: page("pulls"), statusCode: 500) == .unreadable)
        #expect(PullRequests.reading(from: list, finalURL: URL(string: "https://example.com/pulls"), statusCode: 200) == .unreadable)
    }

    @Test func oneFailureFailsTheFolderAndEachPullRequestIsListedOnce() {
        let one = PullRequest(owner: "octo", repository: "early", number: 1, title: "One")!
        let two = PullRequest(owner: "octo", repository: "early", number: 2, title: "Two")!
        let found: [PullRequestGroup: PullRequestReading] = [.opened: .found([one]), .assigned: .found([one, two]),
                                                            .reviewRequested: .found([])]
        #expect(PullRequests.combine(found) == .sections([PullRequestSection(group: .opened, items: [one]),
                                                          PullRequestSection(group: .assigned, items: [two]),
                                                          PullRequestSection(group: .reviewRequested, items: [])]))
        var partial = found
        partial[.reviewRequested] = .unreadable
        #expect(PullRequests.combine(partial) == .failed(.unreadable), "Never a partial list")
        #expect(PullRequests.combine([.opened: .found([one])]) == .failed(.unreadable), "A missing page is a failure")
        #expect(PullRequests.combine([.opened: .offline, .assigned: .signedOut]) == .failed(.signedOut))
        #expect(PullRequests.combine([.opened: .offline, .assigned: .throttled]) == .failed(.throttled))
        #expect(PullRequests.retryDelay(after: .unreadable, failures: 4) == 1800)
        #expect(PullRequests.retryDelay(after: .signedOut, failures: 4) == PullRequests.interval)
    }

    @Test @MainActor func aSpaceKeepsItsFolderAndOlderSpacesHaveNone() throws {
        let profile = UUID()
        var space = BrowserSpace(profileID: profile, name: "Work")
        #expect(!space.showsPullRequests)
        space.showsPullRequests = true
        let data = try JSONEncoder().encode(space)
        #expect(try JSONDecoder().decode(BrowserSpace.self, from: data).showsPullRequests)
        let old = Data(#"{"id":"\#(UUID().uuidString)","profileID":"\#(profile.uuidString)","name":"Old","color":"blue"}"#.utf8)
        #expect(try !JSONDecoder().decode(BrowserSpace.self, from: old).showsPullRequests)

        let one = BrowserSpace(profileID: profile, name: "One")
        let coordinator = BrowserCoordinator(startup: .returningSession, activeSpaceID: one.id, profileID: profile, spaces: [one])
        let id = one.id
        #expect(coordinator.setShowsPullRequests(true, in: id) && coordinator.spaces[0].showsPullRequests)
        #expect(!coordinator.setShowsPullRequests(true, in: id), "Already there")
        #expect(!coordinator.setShowsPullRequests(true, in: UUID()))
        #expect(coordinator.setShowsPullRequests(false, in: id) && !coordinator.spaces[0].showsPullRequests)
    }
}
