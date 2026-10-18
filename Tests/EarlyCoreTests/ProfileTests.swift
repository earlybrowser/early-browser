// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct ProfileTests {
    private let url = URL(string: "https://example.com/")!

    @Test func legacyMigrationKeepsTheExactStorageIDWindowsAndSavedOrganization() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let tab = try #require(browser.navigate(to: url, target: .newTab(spaceID: browser.activeSpaceID)))
        browser.setFavorite(tab, favorite: true)
        var session = browser.session
        session.additionalWindows = [session.openingWindow(at: url)]
        let workspace = try BrowserWorkspace.decodeMigrating(JSONEncoder().encode(session))
        #expect(workspace.defaultProfileID == session.profileID)
        #expect(workspace.activeProfileID == session.profileID)
        #expect(workspace.profiles == [BrowserProfile(id: session.profileID, name: "Default", color: .gray)])
        #expect(workspace.sessions == [session])
        #expect(try BrowserWorkspace.decodeMigrating(JSONEncoder().encode(workspace)) == workspace)
    }

    @Test func profileCreationRenameDeletionAreValidatedAndKeepStorageIdentity() throws {
        var workspace = BrowserWorkspace()
        let original = workspace
        for name in ["", "  ", "bad\nname", "DEFAULT", String(repeating: "a", count: 65)] {
            let created = workspace.createProfile(name: name)
            #expect(created == nil)
        }
        #expect(workspace == original)
        let created = workspace.createProfile(name: " Work ", color: .purple)
        let work = try #require(created)
        #expect(workspace.profiles.last?.name == "Work")
        #expect(workspace.session(for: work)?.spaces.first?.profileID == work)
        #expect(workspace.session(for: work)?.tabs.isEmpty == true)
        let renamed = workspace.editProfile(work, name: "Research", color: .green)
        #expect(renamed)
        #expect(workspace.profiles.last?.id == work && workspace.profiles.last?.color == .green)
        let duplicateRename = workspace.editProfile(work, name: "default", color: .blue)
        let deleteDefault = workspace.deleteProfile(workspace.defaultProfileID)
        #expect(!duplicateRename)
        #expect(!deleteDefault)
        workspace.activeProfileID = work
        workspace.openProfileIDs.append(work)
        let deleted = workspace.deleteProfile(work)
        #expect(deleted)
        #expect(workspace.activeProfileID == workspace.defaultProfileID)
        #expect(workspace.sessions == original.sessions)
        try workspace.validate()
    }

    @Test func crossProfileMovePreservesIDsAndClosedPinsButNotFavoritesOrForeignSelections() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let movedSpace = browser.activeSpaceID
        let folder = try #require(browser.createFolder(name: "Work"))
        let live = try #require(browser.navigate(to: url, target: .newTab(spaceID: movedSpace)))
        browser.moveTab(live, toFolder: folder)
        browser.renameTab(live, to: "My work")
        let closed = try #require(browser.navigate(to: url.appendingPathComponent("closed"), target: .newTab(spaceID: movedSpace)))
        browser.setPinned(closed, pinned: true)
        browser.closeTab(closed)
        let favorite = try #require(browser.navigate(to: url.appendingPathComponent("favorite"), target: .newTab(spaceID: movedSpace)))
        browser.setFavorite(favorite, favorite: true)
        browser.selectOpenTab(live)
        var source = browser.session
        source.additionalWindows = [source.openingWindow(at: url.appendingPathComponent("other-window"))]
        var workspace = BrowserWorkspace(session: source)
        let created = workspace.createProfile(name: "Work")
        let work = try #require(created)
        let destination = try #require(workspace.sessions.firstIndex { $0.profileID == work })
        workspace.sessions[destination].additionalWindows = [workspace.sessions[destination].openingWindow(at: url)]
        let moved = workspace.moveSpace(movedSpace, from: browser.profileID, to: work)
        #expect(moved)
        let old = try #require(workspace.session(for: browser.profileID))
        let new = try #require(workspace.session(for: work))
        #expect(old.spaces.count == 1 && old.activeSpaceID != movedSpace)
        #expect(old.tabs.map(\.id) == [favorite])
        #expect(old.tabs.first?.spaceID == old.activeSpaceID)
        #expect(old.additionalWindows.first?.spaces == old.spaces)
        #expect(old.additionalWindows.first?.tabs.map(\.id) == [favorite])
        #expect(new.spaces.last?.id == movedSpace && new.spaces.last?.profileID == work)
        #expect(new.folders.map(\.id) == [folder])
        #expect(new.tabs.first { $0.id == live }?.profileID == work)
        #expect(new.tabs.first { $0.id == live }?.customTitle == "My work")
        #expect(new.tabs.first { $0.id == closed }?.isOpen == false)
        #expect(new.selectionBySpace[movedSpace] == live)
        #expect(new.tabs.allSatisfy { !$0.isFavorite })
        #expect(new.additionalWindows.first?.tabs.filter { $0.spaceID == movedSpace }.allSatisfy { !$0.isOpen } == true)
        try workspace.validate()
    }

    @Test func changingDefaultKeepsStorageIdentitiesAndProtectsTheNewDefault() throws {
        var workspace = BrowserWorkspace()
        let previousDefault = workspace.defaultProfileID
        let created = workspace.createProfile(name: "Work", color: .purple)
        let work = try #require(created)
        let original = workspace
        let invalid = workspace.setDefaultProfile(UUID())
        #expect(!invalid && workspace == original)
        let changed = workspace.setDefaultProfile(work)
        #expect(changed)
        var expected = original
        expected.defaultProfileID = work
        #expect(workspace == expected)
        let protected = workspace.deleteProfile(work)
        #expect(!protected && workspace == expected)
        let removed = workspace.deleteProfile(previousDefault)
        #expect(removed && workspace.activeProfileID == work)
        #expect(workspace.sessions.map(\.profileID) == [work])
        try workspace.validate()
    }

    @Test func freshSessionsUseChosenDefaultInsteadOfLastActiveProfile() throws {
        var workspace = BrowserWorkspace()
        let created = workspace.createProfile(name: "Work")
        let work = try #require(created)
        let changed = workspace.setDefaultProfile(work)
        #expect(changed && workspace.activeProfileID != work)
        let startup = workspace.startingWithSavedItemsOnly()
        #expect(startup.defaultProfileID == work && startup.activeProfileID == work)
        #expect(startup.openProfileIDs == [work])
        #expect(startup.profiles == workspace.profiles && startup.sessions == workspace.sessions)
        try startup.validate()
    }

    @Test func rejectedSpaceTransfersAreAtomicAndProfilesStayIsolated() throws {
        var workspace = BrowserWorkspace()
        let source = workspace.defaultProfileID
        let created = workspace.createProfile(name: "Work")
        let destination = try #require(created)
        let original = workspace
        let missingSpace = workspace.moveSpace(UUID(), from: source, to: destination)
        let sameProfile = workspace.moveSpace(workspace.sessions[0].activeSpaceID, from: source, to: source)
        let missingProfile = workspace.moveSpace(workspace.sessions[0].activeSpaceID, from: source, to: UUID())
        #expect(!missingSpace)
        #expect(!sameProfile)
        #expect(!missingProfile)
        #expect(workspace == original)
        var malformed = workspace
        malformed.sessions[1].spaces = malformed.sessions[0].spaces
        #expect(throws: SessionError.self) { try malformed.validate() }
        malformed = workspace
        malformed.profiles[1].name = "DEFAULT"
        #expect(throws: SessionError.self) { try malformed.validate() }
        malformed = workspace
        malformed.activeProfileID = UUID()
        #expect(throws: SessionError.self) { try malformed.validate() }
    }

    @Test func savedItemsStartupKeepsProfilesAndSpacesWithoutLoadingOldTodayTabs() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let pin = try #require(browser.navigate(to: url, target: .newTab(spaceID: browser.activeSpaceID)))
        browser.setPinned(pin, pinned: true)
        _ = browser.navigate(to: url.appendingPathComponent("today"), target: .newTab(spaceID: browser.activeSpaceID))
        var workspace = BrowserWorkspace(session: browser.session)
        _ = workspace.createProfile(name: "Work")
        let startup = workspace.startingWithSavedItemsOnly()
        #expect(startup.profiles == workspace.profiles)
        #expect(startup.sessions[0].tabs.map(\.id) == [pin])
        #expect(startup.sessions[0].tabs.first?.isOpen == false)
        #expect(startup.sessions[0].selectionBySpace.isEmpty)
        #expect(startup.sessions[0].spaces == workspace.sessions[0].spaces)
        try startup.validate()
    }

    @Test func applyingProfileMetadataRejectsForeignStorageAndPreservesFolderExpansion() throws {
        let browser = BrowserCoordinator(startup: .returningSession)
        let folder = try #require(browser.createFolder(name: "Work"))
        browser.setFolderExpanded(folder, expanded: true)
        let id = try #require(browser.navigate(to: url, target: .newTab(spaceID: browser.activeSpaceID)))
        let snapshot = browser.session
        #expect(!browser.applySession(BrowserSession()))
        #expect(browser.session == snapshot)
        browser.closeTab(id)
        #expect(browser.applySession(snapshot))
        #expect(browser.activeTabID == id)
        #expect(browser.tabStore.folders.first?.isExpanded == true)
    }

    @Test func workspaceWriterMigratesTheExistingDatabaseAndRejectsInvalidOrStaleWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyProfiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.sqlite")
        let repository = SessionRepository(fileURL: file)
        let legacy = BrowserSession()
        try await repository.save(legacy, revision: 1)
        var workspace = try #require(try await repository.loadWorkspace())
        #expect(workspace.sessions == [legacy])
        _ = workspace.createProfile(name: "Work")
        try await repository.saveWorkspace(workspace, revision: 2)
        #expect(try await SessionRepository(fileURL: file).loadWorkspace() == workspace)
        var invalid = workspace
        invalid.sessions.removeLast()
        await #expect(throws: SessionError.self) { try await repository.saveWorkspace(invalid, revision: 3) }
        try await repository.saveWorkspace(BrowserWorkspace(session: legacy), revision: 1)
        #expect(try await repository.loadWorkspace() == workspace)
        var future = workspace
        future.workspaceVersion = 99
        #expect(throws: SessionError.self) { try BrowserWorkspace.decodeMigrating(JSONEncoder().encode(future)) }
    }
}
