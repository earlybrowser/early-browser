// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyBrowser
import Testing
import WebKit

/// No windows are presented and no input events are synthesized. These tests
/// exercise the real application controller, writer, and ephemeral WebKit stores.
@Suite(.serialized) @MainActor
struct ProfileApplicationTests {
    private let url = URL(string: "early-test://fixture/one")!
    private let input = NavigationInput(allowedSchemes: ["http", "https", "early-test"])

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyRuntime-\(UUID())", isDirectory: true)
        let suite = "local.early.tests.runtime.\(UUID())"
        let defaults: UserDefaults
        let preferences: BrowserPreferences
        let application = EarlyAppDelegate()
        var opened: [UUID] = []

        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            application.presentWindow = { [weak self] in self?.opened.append($0) }
        }

        func start() async -> [UUID] {
            await application.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
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

    @Test func profilesSpaceEditSelectsOnlyAfterSuccessfulSaveAndPreservesLivePages() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let personal = model.coordinator.activeSpaceID
        let personalTab = try #require(model.coordinator.navigate(to: url, target: .newTab(spaceID: personal)))
        model.activateSelection()
        let personalView = try #require(model.webViews.existingView(for: personalTab))
        let work = try #require(model.createSpace(name: "Work"))
        model.switchSpace(to: work)
        let workTab = try #require(model.coordinator.navigate(to: url, target: .newTab(spaceID: work)))
        model.activateSelection()
        let workView = try #require(model.webViews.existingView(for: workTab))
        model.switchSpace(to: personal)
        model.onOpenWindow?(url, "Sibling")
        let siblingID = try #require(fixture.opened.last)
        let sibling = try #require(app.windowModel(siblingID))
        let siblingSelection = sibling.coordinator.activeTabID

        app.showSpaceEditor(profileID: model.coordinator.profileID, spaceID: work)
        #expect(model.coordinator.activeSpaceID == personal && model.coordinator.activeTabID == personalTab)
        model.spaceEditor = nil // Cancel must not follow the edited Space.
        #expect(model.coordinator.activeSpaceID == personal && model.webViews.creationCount == 2)
        app.showSpaceEditor(profileID: model.coordinator.profileID, spaceID: work)
        let request = try #require(model.spaceEditor)
        guard case .edit(let id, let selectOnSave) = request else {
            Issue.record("Profiles should open an edit request")
            await fixture.cleanup()
            return
        }
        #expect(id == work && selectOnSave)
        #expect(!model.editSpace(id, name: " ", color: .green, icon: nil, selectOnSave: selectOnSave))
        #expect(model.coordinator.activeSpaceID == personal)
        #expect(model.editSpace(id, name: "Research", color: .green, icon: nil, selectOnSave: selectOnSave))
        model.spaceEditor = nil
        #expect(model.coordinator.activeSpaceID == work && model.coordinator.activeTabID == workTab)
        #expect(model.coordinator.activeSpace?.name == "Research" && model.coordinator.activeSpace?.color == .green)
        #expect(model.webViews.existingView(for: workTab) === workView)
        #expect(model.webViews.existingView(for: personalTab) === personalView)
        #expect(model.webViews.creationCount == 2)
        #expect(sibling.coordinator.activeSpaceID == personal && sibling.coordinator.activeTabID == siblingSelection)
        #expect(sibling.coordinator.spaces.first { $0.id == work }?.name == "Research")
        #expect(await app.persistence?.flush() == true)
        let repository = SessionRepository(fileURL: fixture.directory.appendingPathComponent("session.sqlite"), input: input)
        let workspace = try #require(try await repository.loadWorkspace())
        #expect(workspace.session(for: model.coordinator.profileID)?.activeSpaceID == work)
        await fixture.cleanup()
    }

    @Test func sidebarEditsKeepSelectionAndProfilesCanFollowAnEmptySpaceWithoutCreatingPages() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let model = try #require(app.model)
        let personal = model.coordinator.activeSpaceID
        let work = try #require(model.createSpace(name: "Work"))
        model.requestEditSpace(work)
        if case .edit(let id, let selectOnSave) = model.spaceEditor {
            #expect(id == work && !selectOnSave)
            #expect(model.editSpace(id, name: "Work 2", color: .blue, icon: nil, selectOnSave: selectOnSave))
        } else { Issue.record("Sidebar should open an edit request") }
        model.spaceEditor = nil
        #expect(model.coordinator.activeSpaceID == personal)
        app.showSpaceEditor(profileID: model.coordinator.profileID, spaceID: work)
        #expect(model.editSpace(work, name: "Work 3", color: .purple, icon: nil, selectOnSave: true))
        model.spaceEditor = nil
        #expect(model.coordinator.activeSpaceID == work && model.coordinator.content == .empty)
        #expect(model.coordinator.activeTabID == nil && model.coordinator.commandBar == nil)
        #expect(model.webViews.creationCount == 0)
        await fixture.cleanup()
    }

    @Test func spaceReorderingPersistsAcrossProfileWindowsWithoutSwitchingOrReloadingPages() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let primary = try #require(app.model)
        let personal = primary.coordinator.activeSpaceID
        let page = try #require(primary.coordinator.navigate(to: url, target: .newTab(spaceID: personal)))
        primary.activateSelection()
        let primaryView = try #require(primary.webViews.existingView(for: page))
        let work = try #require(primary.createSpace(name: "Work"))
        let research = try #require(primary.createSpace(name: "Research"))
        primary.onOpenWindow?(url, "Sibling")
        let siblingID = try #require(fixture.opened.last)
        let sibling = try #require(app.windowModel(siblingID))
        sibling.switchSpace(to: work)
        let siblingPage = try #require(sibling.coordinator.navigate(to: url, target: .newTab(spaceID: work)))
        sibling.activateSelection()
        sibling.save()
        let siblingView = try #require(sibling.webViews.existingView(for: siblingPage))
        let creations = [primary.webViews.creationCount, sibling.webViews.creationCount]
        let otherProfile = try #require(app.createProfile(name: "Other", color: .purple))
        app.openProfile(otherProfile)
        let otherWindow = try #require(fixture.opened.last)
        let other = try #require(app.windowModel(otherWindow))
        let otherSession = other.coordinator.session

        #expect(primary.reorderSpace(personal, before: nil))
        let expected = [work, research, personal]
        #expect(primary.coordinator.spaces.map(\.id) == expected)
        #expect(sibling.coordinator.spaces.map(\.id) == expected)
        #expect(primary.coordinator.activeSpaceID == personal && primary.coordinator.activeTabID == page)
        #expect(sibling.coordinator.activeSpaceID == work && sibling.coordinator.activeTabID == siblingPage)
        #expect(primary.webViews.existingView(for: page) === primaryView)
        #expect(sibling.webViews.existingView(for: siblingPage) === siblingView)
        #expect([primary.webViews.creationCount, sibling.webViews.creationCount] == creations)
        #expect(other.coordinator.session == otherSession)
        #expect(await app.persistence?.flush() == true)
        let repository = SessionRepository(fileURL: fixture.directory.appendingPathComponent("session.sqlite"), input: input)
        let workspace = try #require(try await repository.loadWorkspace())
        let session = try #require(workspace.session(for: primary.coordinator.profileID))
        #expect(session.spaces.map(\.id) == expected)
        #expect(session.additionalWindows.count == 1)
        #expect(session.additionalWindows.first?.spaces.map(\.id) == expected)
        try workspace.validate(using: input)
        await fixture.cleanup()
    }

    @Test func accessibleSpaceMovesRespectBoundsAndInteractionLocksWithoutChangingSelection() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let model = try #require(fixture.application.model)
        let personal = model.coordinator.activeSpaceID
        let work = try #require(model.createSpace(name: "Work"))
        let research = try #require(model.createSpace(name: "Research"))
        let original = model.coordinator.session
        model.sidebarInteractionInProgress = true
        #expect(!model.reorderSpace(personal, before: nil))
        #expect(!model.shiftSpace(personal, by: 1))
        #expect(!model.switchSpace(to: work))
        model.updateSpaceSwipe(translation: -100)
        #expect(model.spaceSwipeProgress == 0 && !model.spaceSwipeIsSettling)
        #expect(model.coordinator.session == original)
        model.sidebarInteractionInProgress = false
        model.updateSpaceSwipe(translation: -100)
        #expect(model.spaceSwipeProgress < 0)
        model.cancelSpaceSwipePresentation()
        model.spaceSwipeIsSettling = true
        #expect(!model.reorderSpace(personal, before: nil))
        model.spaceSwipeIsSettling = false
        #expect(!model.shiftSpace(personal, by: -1))
        #expect(!model.shiftSpace(research, by: 1))
        #expect(!model.shiftSpace(personal, by: 0))
        #expect(!model.shiftSpace(personal, by: 2))
        #expect(!model.shiftSpace(UUID(), by: 1))
        #expect(model.shiftSpace(personal, by: 1))
        #expect(model.coordinator.spaces.map(\.id) == [work, personal, research])
        #expect(model.shiftSpace(research, by: -1))
        #expect(model.coordinator.spaces.map(\.id) == [work, research, personal])
        #expect(model.coordinator.activeSpaceID == personal)
        #expect(model.coordinator.content == .empty && model.webViews.creationCount == 0)
        await fixture.cleanup()
    }

    @Test func defaultMigrationAndSharedWriterKeepProfileWindowsAndWebsiteStoresSeparate() async throws {
        let fixture = Fixture()
        let legacy = BrowserSession()
        let repository = SessionRepository(fileURL: fixture.directory.appendingPathComponent("session.sqlite"), input: input)
        try await repository.save(legacy, revision: 0)
        _ = await fixture.start()
        let app = fixture.application
        let personal = try #require(app.windowModel(nil))
        #expect(personal.coordinator.profileID == legacy.profileID)
        let workID = try #require(app.createProfile(name: "Work", color: .purple))
        app.openProfile(workID)
        let workWindow = try #require(fixture.opened.last)
        let work = try #require(app.windowModel(workWindow))
        #expect(work.persistence === personal.persistence)
        #expect(work.preferences === personal.preferences)
        #expect(work.webViews.websiteDataStore !== personal.webViews.websiteDataStore)
        #expect(work.webViews.liveViewCount == 0 && work.coordinator.tabStore.tabs.isEmpty)
        let cookie = try #require(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "login", .value: "personal"]))
        await personal.webViews.websiteDataStore.httpCookieStore.setCookie(cookie)
        #expect(await work.webViews.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        personal.onOpenWindow?(url, "New window")
        let siblingID = try #require(fixture.opened.last)
        let sibling = try #require(app.windowModel(siblingID))
        #expect(sibling.coordinator.profileID == personal.coordinator.profileID)
        #expect(sibling.webViews.websiteDataStore === personal.webViews.websiteDataStore)
        app.openProfile(workID)
        #expect(fixture.opened.count == 2) // Opening an existing profile only focuses it.
        #expect(await app.persistence?.flush() == true)
        let snapshot = try #require(try await repository.loadWorkspace())
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.session(for: legacy.profileID)?.additionalWindows.count == 1)
        #expect(snapshot.session(for: workID)?.additionalWindows.isEmpty == true)
        await fixture.cleanup()
    }

    @Test func spaceReassignmentReloadsOnlyMovedPagesAndLeavesFavoritesAndClosedPinsBehind() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let personal = try #require(app.windowModel(nil))
        let sourceSpace = personal.coordinator.activeSpaceID
        let unrelatedSpace = try #require(personal.createSpace(name: "Stay"))
        let live = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: sourceSpace)))
        personal.activateSelection()
        let oldView = personal.webViews.existingView(for: live)
        let folder = try #require(personal.coordinator.createFolder(name: "Folder"))
        personal.coordinator.moveTab(live, toFolder: folder)
        let pin = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: sourceSpace)))
        personal.coordinator.setPinned(pin, pinned: true)
        personal.closeTab(pin)
        let favorite = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: sourceSpace)))
        personal.setFavorite(favorite, favorite: true)
        personal.switchSpace(to: unrelatedSpace)
        let stays = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: unrelatedSpace)))
        personal.activateSelection()
        let staysView = personal.webViews.existingView(for: stays)
        personal.save()
        let workID = try #require(app.createProfile(name: "Work", color: .orange))
        #expect(app.moveSpace(sourceSpace, from: personal, to: workID, name: "Moved", color: .green, icon: nil))
        let workWindow = try #require(fixture.opened.last)
        let work = try #require(app.windowModel(workWindow))
        #expect(work.coordinator.spaces.last?.name == "Moved")
        #expect(work.coordinator.tabStore.tab(id: live)?.profileID == workID)
        #expect(work.coordinator.tabStore.tab(id: pin)?.isOpen == false)
        #expect(work.webViews.existingView(for: pin) == nil)
        #expect(personal.webViews.existingView(for: live) == nil)
        #expect(work.webViews.existingView(for: live) !== oldView)
        #expect(personal.webViews.existingView(for: stays) === staysView)
        #expect(personal.coordinator.tabStore.tab(id: favorite)?.isFavorite == true)
        #expect(work.favorites.isEmpty)
        #expect(await app.persistence?.flush() == true)
        try app.workspace?.validate(using: input)
        await fixture.cleanup()
    }

    @Test func closingAProfileWindowDoesNotRestoreItsTodayTabsOrDiscardAnotherProfilesPages() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let personal = try #require(app.windowModel(nil))
        let personalID = personal.coordinator.profileID
        let pin = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: personal.coordinator.activeSpaceID)))
        personal.setPinned(pin, pinned: true)
        _ = personal.coordinator.navigate(to: url, target: .newTab(spaceID: personal.coordinator.activeSpaceID))
        personal.save()
        let workID = try #require(app.createProfile(name: "Work", color: .blue))
        app.openProfile(workID)
        let workWindow = try #require(fixture.opened.last)
        let work = try #require(app.windowModel(workWindow))
        let workTab = try #require(work.coordinator.navigate(to: url, target: .newTab(spaceID: work.coordinator.activeSpaceID)))
        work.activateSelection()
        let view = work.webViews.existingView(for: workTab)
        app.closeWindow(nil)
        #expect(app.workspace?.session(for: personalID)?.tabs.map(\.id) == [pin])
        #expect(app.workspace?.session(for: personalID)?.tabs.first?.isOpen == false)
        #expect(work.webViews.existingView(for: workTab) === view)
        #expect(app.workspace?.openProfileIDs == [workID])
        #expect(app.workspace?.activeProfileID == workID)
        #expect(await app.persistence?.flush() == true)
        let restored = EarlyAppDelegate()
        let windows = await restored.bootstrap(launchStore: FirstLaunchStore(defaults: fixture.defaults), preferences: fixture.preferences,
            defaults: fixture.defaults, storageDirectory: fixture.directory, isTesting: true)
        #expect(windows.isEmpty)
        #expect(restored.model?.coordinator.profileID == workID)
        #expect(restored.model?.coordinator.activeTabID == workTab)
        restored.closeWindow(nil)
        _ = await restored.persistence?.flush()
        await fixture.cleanup()
    }

    @Test func profileDeletionProtectsDefaultAndOtherProfilesAndPreventsStaleCallbacks() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let personal = try #require(app.windowModel(nil))
        let workID = try #require(app.createProfile(name: "Work", color: .green))
        app.openProfile(workID)
        let id = try #require(fixture.opened.last)
        let work = try #require(app.windowModel(id))
        await app.deleteProfile(workID)
        #expect(app.windowModel(id) == nil)
        #expect(app.profiles.count == 1)
        #expect(work.onSave == nil && work.onOpenWindow == nil)
        #expect(work.webViews.liveViewCount == 0)
        #expect(app.model === personal)
        await app.deleteProfile(personal.coordinator.profileID)
        #expect(app.profiles.count == 1)
        #expect(app.workspace?.defaultProfileID == personal.coordinator.profileID)
        await fixture.cleanup()
    }

    @Test func startupPreferenceKeepsAllSavedOrganizationWithoutAllocatingPages() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let personal = try #require(app.windowModel(nil))
        let pin = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: personal.coordinator.activeSpaceID)))
        personal.setPinned(pin, pinned: true)
        _ = personal.coordinator.navigate(to: url, target: .newTab(spaceID: personal.coordinator.activeSpaceID))
        let workID = try #require(app.createProfile(name: "Work", color: .green))
        personal.save()
        fixture.preferences.restoreSession = false
        #expect(await app.persistence?.flush() == true)
        let restored = EarlyAppDelegate()
        _ = await restored.bootstrap(launchStore: FirstLaunchStore(defaults: fixture.defaults), preferences: fixture.preferences,
            defaults: fixture.defaults, storageDirectory: fixture.directory, isTesting: true)
        #expect(restored.profiles.contains { $0.id == workID })
        #expect(restored.model?.coordinator.tabStore.tabs.map(\.id) == [pin])
        #expect(restored.model?.webViews.liveViewCount == 0)
        #expect(restored.model?.coordinator.commandBar != nil)
        restored.closeWindow(nil)
        _ = await restored.persistence?.flush()
        await fixture.cleanup()
    }

    @Test func corruptStorageIsNotOverwrittenAndDisablesProfileMutations() async throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let file = fixture.directory.appendingPathComponent("session.sqlite")
        let damaged = Data("not a sqlite database".utf8)
        try damaged.write(to: file)
        _ = await fixture.start()
        #expect(!fixture.application.canEditProfiles)
        #expect(fixture.application.persistence?.error != nil)
        #expect(fixture.application.createProfile(name: "Work", color: .blue) == nil)
        fixture.application.saveAll()
        #expect(await fixture.application.persistence?.flush() == false)
        #expect(try Data(contentsOf: file) == damaged)
        await fixture.cleanup()
    }

    @Test func movingFromASiblingWindowUsesItsSelectionAndKeepsTheDestinationsExistingViews() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let primary = try #require(app.model)
        let space = primary.coordinator.activeSpaceID
        primary.onOpenWindow?(url, "Source sibling")
        let sourceID = try #require(fixture.opened.last)
        let source = try #require(app.windowModel(sourceID))
        let selected = try #require(source.coordinator.activeTabID)
        let workID = try #require(app.createProfile(name: "Work", color: .green))
        app.openProfile(workID)
        let destinationID = try #require(fixture.opened.last)
        let destination = try #require(app.windowModel(destinationID))
        let stay = try #require(destination.coordinator.navigate(to: url, target: .newTab(spaceID: destination.coordinator.activeSpaceID)))
        destination.activateSelection()
        let view = destination.webViews.existingView(for: stay)
        destination.onOpenWindow?(url, "Destination sibling")
        let otherID = try #require(fixture.opened.last)
        let other = try #require(app.windowModel(otherID))
        #expect(app.moveSpace(space, from: source, to: workID, name: "Moved", color: .purple, icon: nil))
        #expect(destination.coordinator.activeTabID == selected)
        #expect(destination.webViews.existingView(for: stay) === view)
        #expect(other.webViews.liveViewCount == 1)
        #expect(other.coordinator.tabStore.tab(id: selected) == nil) // Today stays in one window.
        #expect(primary.coordinator.activeSpaceID == source.coordinator.activeSpaceID)
        #expect(primary.webViews.liveViewCount == 0 && source.webViews.liveViewCount == 0)
        #expect(await app.persistence?.flush() == true)
        try app.workspace?.validate(using: input)
        await fixture.cleanup()
    }

    @Test func liveSettingsAreSharedByAllProfilesWithoutReplacingViewsAndCancelSuggestionsImmediately() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let primary = try #require(app.model)
        let page = try #require(primary.coordinator.navigate(to: url, target: .newTab(spaceID: primary.coordinator.activeSpaceID)))
        primary.activateSelection()
        let view = primary.webViews.existingView(for: page)
        let workID = try #require(app.createProfile(name: "Work", color: .green))
        app.openProfile(workID)
        let workWindow = try #require(fixture.opened.last)
        let work = try #require(app.windowModel(workWindow))
        primary.presentCommandBar(.newTab)
        primary.updateQuery("swift")
        work.updateQuery("swift")
        #expect(primary.suggestions.isRefreshing && work.suggestions.isRefreshing)
        fixture.preferences.onlineSuggestions = false
        #expect(!primary.suggestions.isRefreshing && !work.suggestions.isRefreshing)
        #expect(!primary.suggestions.isLoading && !work.suggestions.isLoading)
        fixture.preferences.appearance = .dark
        fixture.preferences.spaceThemes = false
        fixture.preferences.translucentChrome = false
        fixture.preferences.sidebarAutoHides = true
        fixture.preferences.sidebarWidth = 300
        fixture.preferences.spaceSwipes = false
        fixture.preferences.haptics = false
        #expect(work.sidebarWidth == 300 && !work.onlineSuggestionsEnabled)
        #expect(primary.webViews.existingView(for: page) === view && primary.webViews.creationCount == 1)
        #expect(work.webViews.creationCount == 0)
        let restored = BrowserPreferences(defaults: fixture.defaults)
        #expect(restored.sidebarAutoHides && restored.appearance == .dark)
        #expect(!restored.spaceThemes && !restored.translucentChrome && !restored.haptics && !restored.spaceSwipes)
        await fixture.cleanup()
    }

    @Test func autosaverCoalescesWholeWorkspacesAndKeepsThePreviousSnapshotOnFailure() async throws {
        let fixture = Fixture()
        let repository = SessionRepository(fileURL: fixture.directory.appendingPathComponent("writer.sqlite"))
        let writer = SessionAutosaver(repository: repository, disabledReason: nil)
        var workspace = BrowserWorkspace()
        for index in 0..<100 {
            workspace.profiles[0].name = "Default \(index)"
            writer.enqueue(workspace)
        }
        #expect(await writer.flush())
        #expect(!writer.isSaving && writer.lastSavedAt != nil)
        #expect(try await repository.loadWorkspace() == workspace)
        var invalid = workspace
        invalid.sessions = []
        writer.enqueue(invalid)
        #expect(await writer.flush() == false)
        #expect(writer.error != nil)
        #expect(try await repository.loadWorkspace() == workspace)
        workspace.profiles[0].name = "Recovered"
        writer.enqueue(workspace)
        #expect(await writer.flush())
        #expect(writer.error == nil)
        #expect(try await repository.loadWorkspace() == workspace)
        await fixture.cleanup()
    }

    @Test func settingsNavigationStartsWithGeneralAndKeepsTheRequestedOrder() {
        #expect(BrowserSettingsSection.allCases.map(\.rawValue) == ["General", "Profiles", "Passwords", "Sidebar", "Search", "Sessions"])
        #expect(EarlyAppDelegate().settingsSection == .appearance)
    }

    @Test func newWindowSharesSavedItemsAndStoreButStartsWithNoPagesOrSplit() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let source = try #require(app.model)
        let first = try #require(source.coordinator.navigate(to: url, target: .newTab(spaceID: source.coordinator.activeSpaceID)))
        let second = try #require(source.coordinator.navigate(to: url, target: .newTab(spaceID: source.coordinator.activeSpaceID)))
        source.activateSelection()
        #expect(source.perform(.setPinned(first, true)))
        #expect(source.perform(.splitTab(first, .leading)))
        let original = source.coordinator.session
        let firstPage = try #require(source.webViews.pages[first])
        #expect(source.perform(.newWindow))
        let id = try #require(fixture.opened.last), created = try #require(app.windowModel(id))
        #expect(created.coordinator.profileID == source.coordinator.profileID)
        #expect(created.webViews.websiteDataStore === source.webViews.websiteDataStore)
        #expect(created.webViews.liveViewCount == 0 && created.webViews.creationCount == 0)
        #expect(created.coordinator.splitGroups.isEmpty && created.coordinator.focusedTabID == nil)
        #expect(created.coordinator.commandBar?.intent == .newTab)
        #expect(created.coordinator.tabStore.tab(id: first)?.isOpen == false)
        #expect(created.coordinator.tabStore.tab(id: second) == nil)
        #expect(source.coordinator.session == original && source.webViews.pages[first] === firstPage)
        #expect(await app.persistence?.flush() == true)
        await fixture.cleanup()
    }

    @Test func choosingDefaultPersistsWithoutSwitchingProfilesOrReplacingLiveViews() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let personal = try #require(app.model)
        let tab = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: personal.coordinator.activeSpaceID)))
        personal.activateSelection()
        let view = personal.webViews.existingView(for: tab)
        let store = personal.webViews.websiteDataStore
        let work = try #require(app.createProfile(name: "Work", color: .purple))
        #expect(app.setDefaultProfile(work))
        #expect(app.workspace?.activeProfileID == personal.coordinator.profileID)
        #expect(personal.webViews.existingView(for: tab) === view)
        #expect(personal.webViews.websiteDataStore === store)
        #expect(fixture.opened.isEmpty)
        #expect(!app.setDefaultProfile(UUID()))
        #expect(await app.persistence?.flush() == true)
        let repository = SessionRepository(fileURL: fixture.directory.appendingPathComponent("session.sqlite"), input: input)
        #expect(try await repository.loadWorkspace()?.defaultProfileID == work)
        await app.deleteProfile(work)
        #expect(app.profiles.contains { $0.id == work })
        await fixture.cleanup()
    }

    @Test(arguments: [true, false]) func defaultIsUsedForFreshStartupButNotInsteadOfARestoredSession(restoreSession: Bool) async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let personal = try #require(app.model)
        let tab = try #require(personal.coordinator.navigate(to: url, target: .newTab(spaceID: personal.coordinator.activeSpaceID)))
        let work = try #require(app.createProfile(name: "Work", color: .green))
        #expect(app.setDefaultProfile(work))
        fixture.preferences.restoreSession = restoreSession
        #expect(await app.persistence?.flush() == true)
        let restored = EarlyAppDelegate()
        _ = await restored.bootstrap(launchStore: FirstLaunchStore(defaults: fixture.defaults), preferences: fixture.preferences,
            defaults: fixture.defaults, storageDirectory: fixture.directory, isTesting: true)
        #expect(restored.model?.coordinator.profileID == (restoreSession ? personal.coordinator.profileID : work))
        #expect(restored.model?.coordinator.activeTabID == (restoreSession ? tab : nil))
        #expect(restored.model?.webViews.liveViewCount == (restoreSession ? 1 : 0))
        restored.closeWindow(nil)
        _ = await restored.persistence?.flush()
        await fixture.cleanup()
    }

    @Test func reopeningOrLaunchingAfterAllWindowsCloseUsesChosenDefault() async throws {
        let fixture = Fixture()
        _ = await fixture.start()
        let app = fixture.application
        let work = try #require(app.createProfile(name: "Work", color: .green))
        #expect(app.setDefaultProfile(work))
        app.closeWindow(nil)
        #expect(app.workspace?.openProfileIDs.isEmpty == true)
        #expect(await app.persistence?.flush() == true)
        let restored = EarlyAppDelegate()
        _ = await restored.bootstrap(launchStore: FirstLaunchStore(defaults: fixture.defaults), preferences: fixture.preferences,
            defaults: fixture.defaults, storageDirectory: fixture.directory, isTesting: true)
        #expect(restored.model?.coordinator.profileID == work)
        #expect(restored.model?.webViews.creationCount == 0)
        restored.closeWindow(nil)
        _ = await restored.persistence?.flush()
        app.ensurePrimaryWindow()
        #expect(app.model?.coordinator.profileID == work)
        #expect(app.workspace?.activeProfileID == work)
        #expect(app.model?.webViews.creationCount == 0)
        await fixture.cleanup()
    }
}
