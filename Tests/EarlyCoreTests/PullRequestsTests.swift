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

    private func item(_ number: Int, _ title: String = "Title") -> LiveFolderItem {
        LiveFolderItem(id: "octo/early#\(number)", url: page("octo/early/pull/\(number)"), title: title)
    }

    @Test func aLiveFolderFollowsItsSourceAndKeepsOpenPages() throws {
        let profile = UUID(), space = UUID()
        var store = TabStore()
        let created = store.createLiveFolder(name: "Pull Requests", source: .githubPullRequests, spaceID: space)
        let folder = try #require(created)
        #expect(store.folders.first?.isExpanded == true && store.isLiveFolder(folder))
        let filled = store.syncLiveFolder(folder, items: [item(1, "One"), item(2, "Two"), item(1, "Again")], profileID: profile)
        #expect(filled)
        func pins() -> [BrowserTab] {
            store.pinnedItems(in: space, parentID: folder).compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
        }
        #expect(pins().map(\.liveItemID) == ["octo/early#1", "octo/early#2"], "Each once, in the source's order")
        #expect(pins().allSatisfy { !$0.isOpen && $0.pinnedURL == $0.currentURL && $0.folderID == folder && $0.profileID == profile })
        #expect(pins().first?.displayTitle == "One")
        let unchanged = store.syncLiveFolder(folder, items: [item(1, "One"), item(2, "Two")], profileID: profile)
        #expect(!unchanged, "Nothing changed")

        // Reading one: it's opened like any pin. Then its pull request merges.
        let reading = pins()[1].id
        store.reopen(reading)
        let merged = store.syncLiveFolder(folder, items: [item(3, "Three"), item(1, "Renamed")], profileID: profile)
        #expect(merged)
        #expect(pins().map(\.liveItemID) == ["octo/early#3", "octo/early#1"] && pins().last?.displayTitle == "Renamed")
        let kept = try #require(store.tab(id: reading))
        #expect(kept.isOpen && kept.pinnedURL == nil && kept.folderID == nil && kept.liveItemID == nil,
                "The page being read stays open, as a Today tab")
        #expect(store.todayTabs(in: space).map(\.id) == [reading])

        // Removed by hand: gone, and not added back while it's listed.
        let removed = store.dismissLiveItem(pins()[0].id)
        store.syncLiveFolder(folder, items: [item(3), item(1, "Renamed")], profileID: profile)
        #expect(removed)
        #expect(store.tabs.compactMap(\.liveItemID) == ["octo/early#1"])
        // Once it's no longer listed it's forgotten, so a reopened one comes back.
        let forgotten = store.syncLiveFolder(folder, items: [item(1, "Renamed")], profileID: profile)
        #expect(forgotten && store.folders.first?.live?.dismissed.isEmpty == true)
        // A list that couldn't be read empties the folder but keeps removals.
        let last = try #require(store.tabs.first { $0.liveItemID == "octo/early#1" })
        let dismissed = store.dismissLiveItem(last.id)
        let cleared = store.syncLiveFolder(folder, items: [], profileID: profile, forgetsRemoved: false)
        #expect(dismissed && !cleared && store.folders.first?.live?.dismissed == ["octo/early#1"])
    }

    @Test func liveFoldersTakeNothingInAndTheirPinsStayPut() throws {
        let profile = UUID(), space = UUID(), other = UUID()
        var store = TabStore()
        let created = store.createLiveFolder(name: "Pull Requests", source: .githubPullRequests, spaceID: space)
        let live = try #require(created)
        let mine = store.createFolder(name: "Mine", parentID: nil, spaceID: space)
        let own = try #require(mine)
        store.syncLiveFolder(live, items: [item(1), item(2)], profileID: profile)
        let tab = BrowserTab(spaceID: space, profileID: profile, title: "Page", currentURL: page("x"))
        store.insert(tab)
        let pin = try #require(store.tabs.first { $0.liveItemID == "octo/early#1" })
        let movedIn = store.moveTab(tab.id, toFolder: live)
        let placedIn = store.place(tab.id, in: .pinned, folderID: live, spaceID: space)
        #expect(!movedIn && !placedIn, "Only GitHub fills it")
        #expect(!store.canCreateFolder(in: live, spaceID: space) && !store.canMoveFolder(own, to: live))
        let movedOut = store.moveTab(pin.id, toFolder: own)
        let toTop = store.moveTab(pin.id, toFolder: nil)
        let unpinned = store.setPinned(pin.id, pinned: false)
        let favorite = store.setFavorite(pin.id, favorite: true, in: space)
        let reordered = store.placePin(pin.id, before: nil)
        let toToday = store.move(pin.id, to: .regular, in: space)
        #expect(!movedOut && !toTop && !unpinned && !favorite && !reordered && !toToday)
        #expect(store.canMoveFolder(live, to: own), "The folder itself can go anywhere")

        // Moving its Space keeps it live; a copied Space gets an empty live folder.
        let moved = store.moveFolder(live, toSpace: other)
        #expect(moved != nil && store.folders.first { $0.id == live }?.live?.source == .githubPullRequests)
        #expect(store.tabs.filter { $0.liveItemID != nil }.allSatisfy { $0.spaceID == other })
        store.duplicateSavedItems(in: other, to: space)
        let copy = try #require(store.folders.first { $0.spaceID == space && $0.live != nil })
        #expect(store.pinnedItems(in: space, parentID: copy.id).isEmpty)
    }

    @Test func liveFoldersAndPinsAreSavedAndOldSessionsHaveNone() throws {
        var folder = BrowserFolder(spaceID: UUID(), name: "Pull Requests", live: LiveFolder(source: .githubPullRequests, dismissed: ["a/b#1"]))
        folder.sidebarPosition = 2
        #expect(try JSONDecoder().decode(BrowserFolder.self, from: JSONEncoder().encode(folder)) == folder)
        var pin = BrowserTab(spaceID: UUID(), profileID: UUID(), title: "One", currentURL: page("a/b/pull/1"),
                             pinnedURL: page("a/b/pull/1"), isOpen: false)
        pin.liveItemID = "a/b#1"
        #expect(try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(pin)).liveItemID == "a/b#1")
        let old = Data(#"{"id":"\#(UUID().uuidString)","spaceID":"\#(UUID().uuidString)","name":"Old","isExpanded":false}"#.utf8)
        #expect(try JSONDecoder().decode(BrowserFolder.self, from: old).live == nil)
    }

    @Test func foldersKeepTheirIconAndLiveFoldersTheirInterval() throws {
        let space = UUID(), other = UUID()
        var store = TabStore()
        let made = store.createFolder(name: "Work", parentID: nil, spaceID: space, icon: .symbol(.briefcase))
        let folder = try #require(made)
        #expect(store.folders.first?.icon == .symbol(.briefcase))
        let changed = store.setFolderIcon(folder, icon: .symbol(.star))
        let same = store.setFolderIcon(folder, icon: .symbol(.star))
        #expect(changed && !same && store.folders.first?.icon == .symbol(.star))
        let liveMade = store.createLiveFolder(name: "Pull Requests", source: .githubPullRequests, spaceID: space)
        let live = try #require(liveMade)
        let second = store.createLiveFolder(name: "Again", source: .githubPullRequests, spaceID: space)
        #expect(second == nil && store.hasLiveFolder(.githubPullRequests, in: space) && !store.hasLiveFolder(.githubPullRequests, in: other))
        let liveIcon = store.setFolderIcon(live, icon: .symbol(.star))
        #expect(!liveIcon, "A live folder shows its source's mark")
        #expect(store.folders.first { $0.id == live }?.live?.interval == .fifteenMinutes)
        let interval = store.setLiveFolderInterval(live, .twoHours)
        let notLive = store.setLiveFolderInterval(folder, .twoHours)
        #expect(interval && !notLive && store.folders.first { $0.id == live }?.live?.interval == .twoHours)
        #expect(LiveFolder.Interval.allCases.map(\.title) == ["15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours", "8 hours"])

        // Moving or copying a Space keeps both.
        _ = store.moveFolder(folder, toSpace: other)
        _ = store.moveFolder(live, toSpace: other)
        #expect(store.folders.first { $0.id == folder }?.icon == .symbol(.star))
        store.duplicateSavedItems(in: other, to: space)
        #expect(store.folders.contains { $0.spaceID == space && $0.icon == .symbol(.star) })
        #expect(store.folders.contains { $0.spaceID == space && $0.live?.interval == .twoHours })

        // Saved; older or unknown values never stop a session restoring.
        let saved = try #require(store.folders.first { $0.id == live })
        #expect(try JSONDecoder().decode(BrowserFolder.self, from: JSONEncoder().encode(saved)) == saved)
        let id = UUID().uuidString, spaceID = UUID().uuidString
        let older = Data(#"{"id":"\#(id)","spaceID":"\#(spaceID)","name":"PRs","isExpanded":true,"live":{"source":"githubPullRequests","dismissed":["a/b#1"]}}"#.utf8)
        let decoded = try JSONDecoder().decode(BrowserFolder.self, from: older)
        #expect(decoded.live == LiveFolder(source: .githubPullRequests, interval: .fifteenMinutes, dismissed: ["a/b#1"]))
        let unknown = Data(#"{"id":"\#(id)","spaceID":"\#(spaceID)","name":"X","isExpanded":false,"icon":{"symbol":{"_0":"no.such"}},"live":{"source":"elsewhere"}}"#.utf8)
        let tolerant = try JSONDecoder().decode(BrowserFolder.self, from: unknown)
        #expect(tolerant.icon == nil && tolerant.live == nil && tolerant.name == "X")
    }
}
