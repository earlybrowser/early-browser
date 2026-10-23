// SPDX-License-Identifier: MPL-2.0

import AppKit
@testable import EarlyBrowser
import EarlyCore
import EarlyWeb
import Testing

/// The Pull Requests live folder in the application: added per Space, shared
/// by the profile's windows, read only while shown, never in private windows.
/// GitHub is replaced by stand-in pages; nothing leaves the Mac.
@Suite(.serialized) @MainActor
struct PullRequestsApplicationTests {
    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPullRequests-\(UUID())", isDirectory: true)
        let suite = "local.early.tests.pullrequests.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let application = EarlyAppDelegate()
        var opened: [UUID] = []
        var answer: [PullRequestGroup: PullRequestReading]
        var reads = 0

        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            answer = [.opened: .found([PullRequestsApplicationTests.item]), .assigned: .found([]), .reviewRequested: .found([])]
            application.presentWindow = { [weak self] in self?.opened.append($0) }
            application.presentSettingsWindow = {}
            application.pullRequestReader = { [weak self] _ in
                self?.reads += 1
                return self?.answer ?? [:]
            }
        }

        func start() async {
            _ = await application.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                defaults: defaults, storageDirectory: directory, isTesting: true)
        }

        func cleanup() async {
            _ = await application.persistence?.flush()
            for id in opened { application.closeWindow(id) }
            application.closeWindow(nil)
            _ = await application.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static let item = PullRequest(owner: "octo", repository: "early", number: 12, title: "Add the Pull Requests folder")!

    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static let other = PullRequest(owner: "team", repository: "tools", number: 40, title: "Fix the build")!
    static func found(_ items: [PullRequest]) -> [PullRequestGroup: PullRequestReading] {
        [.opened: .found(items), .assigned: .found([]), .reviewRequested: .found([])]
    }

    private func pins(_ model: BrowserWindowModel, in folder: UUID) -> [BrowserTab] {
        model.coordinator.tabStore.tabs.filter { $0.folderID == folder }
    }

    @Test func aGitHubLiveFolderFillsWithPinsSharedByTheProfilesWindows() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let personal = try #require(app.model)
        let feed = try #require(personal.pullRequests)
        #expect(!feed.isActive && fixture.reads == 0, "Nothing is read before a live folder is added")

        let folder = try #require(personal.addGitHubLiveFolder())
        #expect(personal.coordinator.folders.first { $0.id == folder }?.live?.source == .githubPullRequests)
        try await Self.waitUntil { self.pins(personal, in: folder).count == 1 }
        let pin = try #require(pins(personal, in: folder).first)
        #expect(pin.liveItemID == Self.item.id && pin.pinnedURL == Self.item.url() && pin.displayTitle == Self.item.title)
        #expect(!pin.isOpen, "Nothing loads until it's chosen")
        let fetched = try #require(feed.lastRefreshed)
        #expect(BrowserWindowView.lastFetch(feed, now: fetched.addingTimeInterval(30)) == "Last fetch: 30 seconds ago")
        #expect(BrowserWindowView.lastFetch(feed, now: fetched.addingTimeInterval(7200)).hasPrefix("Last fetch: 2 hours"))

        // Another window of the profile shares the folder and its pins.
        #expect(personal.perform(.newWindow))
        let second = try #require(app.windowModel(fixture.opened.last))
        #expect(pins(second, in: folder).map(\.id) == [pin.id] && second.pullRequests === feed)

        // Never in private windows, and never another profile's.
        #expect(personal.perform(.newPrivateWindow))
        let privateWindow = try #require(app.windowModel(fixture.opened.last))
        #expect(privateWindow.pullRequests == nil && privateWindow.coordinator.folders.isEmpty)
        let workID = try #require(app.createProfile(name: "Work", color: .purple))
        app.openProfile(workID)
        let work = try #require(app.windowModel(fixture.opened.last))
        let workFeed = try #require(work.pullRequests)
        #expect(workFeed !== feed && !workFeed.isActive && work.coordinator.folders.isEmpty)

        // One being read when its pull request merges stays open, as a Today tab.
        #expect(personal.coordinator.openTab(pin.id))
        fixture.answer = Self.found([Self.other])
        feed.refresh()
        try await Self.waitUntil { self.pins(personal, in: folder).map(\.liveItemID) == [Self.other.id] }
        #expect(personal.coordinator.tabStore.tab(id: pin.id).map { $0.isOpen && $0.pinnedURL == nil } == true)
        #expect(pins(second, in: folder).map(\.liveItemID) == [Self.other.id], "Every window follows")

        // Deleting the folder stops reading.
        #expect(personal.perform(.deleteFolder(folder)))
        #expect(!feed.isActive && feed.sections.isEmpty)
        await fixture.cleanup()
    }

    @Test func removedPinsStayRemovedAndASignedOutFolderEmpties() async throws {
        let fixture = Fixture()
        fixture.answer = Self.found([Self.item, Self.other])
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let profile = model.coordinator.profileID
        let folder = try #require(model.addGitHubLiveFolder())
        let feed = try #require(model.pullRequests)
        try await Self.waitUntil { self.pins(model, in: folder).count == 2 }

        let first = try #require(pins(model, in: folder).first { $0.liveItemID == Self.item.id })
        model.removeLiveItem(first.id)
        #expect(pins(model, in: folder).map(\.liveItemID) == [Self.other.id])
        feed.refresh()
        try await Self.waitUntil { fixture.reads == 2 && !feed.isRefreshing }
        #expect(pins(model, in: folder).map(\.liveItemID) == [Self.other.id], "Not added back while it's open")

        // Signed out: the folder empties instead of showing an old list.
        fixture.answer = [.opened: .signedOut]
        feed.refresh()
        try await Self.waitUntil { feed.status == .signedOut }
        #expect(pins(model, in: folder).isEmpty)
        #expect(LiveFolderStatusRow.message(for: .signedOut, hasPins: false)?.text == "Sign in to GitHub")

        // Signing in on GitHub in a tab reads it again; the removed one stays out.
        app.noteVisit(URL(string: "https://github.com/login?return_to=%2Fpulls")!, profile: profile)
        app.noteVisit(URL(string: "https://example.com/")!, profile: profile)
        await Task.yield()
        #expect(fixture.reads == 3, "Still signing in, or not GitHub")
        fixture.answer = Self.found([Self.item, Self.other])
        app.noteVisit(URL(string: "https://github.com/")!, profile: profile)
        try await Self.waitUntil { feed.status == .ready && !self.pins(model, in: folder).isEmpty }
        #expect(pins(model, in: folder).map(\.liveItemID) == [Self.other.id])

        // With no window of the profile open, it stops reading; the pins stay saved.
        app.closeWindow(nil)
        #expect(!feed.isActive)
        #expect(app.workspace?.session(for: profile)?.tabs.contains { $0.liveItemID == Self.other.id } == true)
        await fixture.cleanup()
    }

    @Test func theMostFrequentFetchIntervalWinsAndFoldersShowTheirIcon() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let first = try #require(model.addGitHubLiveFolder())
        let feed = try #require(model.pullRequests)
        #expect(feed.interval == LiveFolder.Interval.fifteenMinutes.seconds)
        #expect(model.coordinator.setLiveFolderInterval(first, .fourHours))
        model.save()
        #expect(feed.interval == LiveFolder.Interval.fourHours.seconds)
        // One per Space; another Space can have its own.
        #expect(model.addGitHubLiveFolder() == nil)
        let space = model.coordinator.activeSpaceID
        let otherSpace = try #require(model.coordinator.createSpace(name: "Other"))
        #expect(model.switchSpace(to: otherSpace))
        let second = try #require(model.addGitHubLiveFolder())
        #expect(model.coordinator.moveFolder(second, toSpace: space) == false, "Moving it would make two")
        #expect(model.coordinator.setLiveFolderInterval(second, .oneHour))
        model.save()
        #expect(feed.interval == LiveFolder.Interval.oneHour.seconds, "One read serves both")

        let live = try #require(model.coordinator.tabStore.folders.first { $0.id == first })
        #expect(FolderEmblem(live) == .github)
        let own = try #require(model.coordinator.createFolder(name: "Work", icon: .symbol(.briefcase)))
        let folder = try #require(model.coordinator.folders.first { $0.id == own })
        #expect(FolderEmblem(folder) == .symbol("briefcase.fill"))
        #expect(FolderEmblem(BrowserFolder(spaceID: folder.spaceID, name: "Plain")) == nil)
        await fixture.cleanup()
    }

    @Test func newTabWithNoWindowOpensOneWithTheCommandBar() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        // ⌘W closed the last window; Early keeps running.
        app.closeWindow(nil)
        #expect(app.model == nil && fixture.opened.isEmpty)
        #expect(app.presentCommandBar(.newTab))
        let opened = try #require(app.windowModel(fixture.opened.last))
        #expect(opened.coordinator.commandBar?.intent == .newTab && opened.coordinator.activeTabID == nil)
        #expect(fixture.opened.count == 1)

        // The Dock icon with no window showing opens one; with one showing, AppKit does the usual.
        #expect(!app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(fixture.opened.count == 2)
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) && fixture.opened.count == 2)
        await fixture.cleanup()
    }

    @Test func liveFolderNotesSayWhatsHappening() {
        #expect(LiveFolderStatusRow.message(for: .loading, hasPins: false)?.text == "Reading GitHub…")
        #expect(LiveFolderStatusRow.message(for: .loading, hasPins: true) == nil)
        #expect(LiveFolderStatusRow.message(for: .ready, hasPins: false)?.text == "No open pull requests")
        #expect(LiveFolderStatusRow.message(for: .ready, hasPins: true) == nil)
        #expect(LiveFolderStatusRow.message(for: .offline, hasPins: true)?.text == "Can’t reach GitHub", "Kept pins get the note too")
        #expect(LiveFolderStatusRow.message(for: .unreadable, hasPins: false) != nil)
    }

    @Test func pictureInPicturesReturnButtonShowsTheVideosTabInItsSpace() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let first = model.coordinator.activeSpaceID
        let video = try #require(model.coordinator.navigate(to: URL(string: "early-test://fixture/one")!, target: .newTab(spaceID: first)))
        let second = try #require(model.coordinator.createSpace(name: "Second"))
        #expect(model.switchSpace(to: second))
        #expect(model.coordinator.activeSpaceID == second)

        model.showTabFromPictureInPicture(video)
        #expect(model.coordinator.activeSpaceID == first && model.coordinator.focusedTabID == video)
        model.showTabFromPictureInPicture(UUID())
        #expect(model.coordinator.focusedTabID == video, "Unknown tabs change nothing")
        await fixture.cleanup()
    }
}
