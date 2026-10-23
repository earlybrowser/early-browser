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

    @Test func theFolderIsPerSpaceSharedByTheProfilesWindowsAndNeverPrivate() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let personal = try #require(app.model)
        let feed = try #require(personal.pullRequests)
        let space = personal.coordinator.activeSpaceID
        #expect(!feed.isActive && fixture.reads == 0, "Nothing is read before the folder is added")

        personal.setPullRequestsFolder(true, in: space)
        #expect(personal.coordinator.activeSpace?.showsPullRequests == true && personal.openPullRequestFolders == [space])
        try await Self.waitUntil { feed.status == .ready }
        #expect(feed.sections.first?.items == [Self.item] && fixture.reads == 1)

        // Another window of the profile shares the folder and what was read.
        #expect(personal.perform(.newWindow))
        let second = try #require(app.windowModel(fixture.opened.last))
        #expect(second.coordinator.spaces.first { $0.id == space }?.showsPullRequests == true)
        #expect(second.pullRequests === feed && second.openPullRequestFolders.isEmpty, "Closed until opened, like folders")

        // Never in private windows, and never another profile's.
        #expect(personal.perform(.newPrivateWindow))
        let privateWindow = try #require(app.windowModel(fixture.opened.last))
        #expect(privateWindow.pullRequests == nil)
        #expect(!privateWindow.coordinator.spaces.contains { $0.showsPullRequests })
        let workID = try #require(app.createProfile(name: "Work", color: .purple))
        app.openProfile(workID)
        let work = try #require(app.windowModel(fixture.opened.last))
        let workFeed = try #require(work.pullRequests)
        #expect(workFeed !== feed && !workFeed.isActive)

        // Removing it from any window removes it everywhere and forgets the list.
        second.setPullRequestsFolder(false, in: space)
        #expect(personal.coordinator.spaces.first { $0.id == space }?.showsPullRequests == false)
        #expect(!feed.isActive && feed.sections.isEmpty && feed.status == .idle)
        await fixture.cleanup()
    }

    @Test func choosingAPullRequestUsesItsOpenTabAndClosedWindowsStopReading() async throws {
        let fixture = Fixture()
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let space = model.coordinator.activeSpaceID
        model.setPullRequestsFolder(true, in: space)
        let feed = try #require(model.pullRequests)
        try await Self.waitUntil { feed.status == .ready }

        // Its files page is already open: that tab is chosen, nothing new opens.
        let files = Self.item.url().appending(path: "files")
        let open = try #require(model.coordinator.navigate(to: files, target: .newTab(spaceID: space)))
        _ = try #require(model.coordinator.navigate(to: URL(string: "early-test://fixture/one")!, target: .newTab(spaceID: space)))
        let count = model.coordinator.tabStore.tabs.count
        model.openPullRequest(Self.item)
        #expect(model.coordinator.focusedTabID == open && model.coordinator.tabStore.tabs.count == count)

        // Opening and closing it only changes this window's view of it.
        model.togglePullRequestsFolder(in: space)
        #expect(!model.openPullRequestFolders.contains(space))
        model.togglePullRequestsFolder(in: space)
        #expect(model.openPullRequestFolders.contains(space) && fixture.reads == 1, "Just read: no second read")

        // With no window of the profile open, it stops reading.
        app.closeWindow(nil)
        #expect(!feed.isActive && feed.sections.isEmpty)
        await fixture.cleanup()
    }

    @Test func signingInToGitHubInATabReadsASignedOutFolderAgain() async throws {
        let fixture = Fixture()
        fixture.answer = [.opened: .signedOut]
        await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let profile = model.coordinator.profileID
        model.setPullRequestsFolder(true, in: model.coordinator.activeSpaceID)
        let feed = try #require(model.pullRequests)
        try await Self.waitUntil { feed.status == .signedOut }
        #expect(feed.sections.isEmpty)

        app.noteVisit(URL(string: "https://github.com/login?return_to=%2Fpulls")!, profile: profile)
        app.noteVisit(URL(string: "https://example.com/")!, profile: profile)
        await Task.yield()
        #expect(fixture.reads == 1, "Still signing in, or not GitHub")
        fixture.answer = [.opened: .found([Self.item]), .assigned: .found([]), .reviewRequested: .found([])]
        app.noteVisit(URL(string: "https://github.com/")!, profile: profile)
        try await Self.waitUntil { feed.status == .ready }
        #expect(fixture.reads == 2 && feed.count == 1)
        await fixture.cleanup()
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
