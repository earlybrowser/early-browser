import Foundation
import SQLite3
import Testing
@testable import EarlyCore

struct SessionRepositoryTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "EarlyTests-\(UUID())/session.sqlite")
    }

    @Test func missingSessionDoesNotCreateDatabase() async throws {
        let url = location()
        #expect(try await SessionRepository(fileURL: url).load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor func roundTripsOpenAndEmptySessionsAndIgnoresStaleWrites() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = SessionRepository(fileURL: url)
        let coordinator = BrowserCoordinator(startup: .firstLaunch)
        coordinator.navigate(to: URL(string: "https://example.com")!, target: .newTab(spaceID: coordinator.activeSpaceID))
        let open = coordinator.session
        try await repository.save(open, revision: 1)
        #expect(try await repository.load() == open)
        coordinator.closeActiveTab()
        let empty = coordinator.session
        try await repository.save(empty, revision: 3)
        try await repository.save(open, revision: 2)
        #expect(try await SessionRepository(fileURL: url).load() == empty)
    }

    @Test func invalidSnapshotDoesNotReplaceGoodData() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = SessionRepository(fileURL: url)
        let good = BrowserSession()
        try await repository.save(good, revision: 1)
        var invalid = good
        invalid.version = 99
        await #expect(throws: (any Error).self) { try await repository.save(invalid, revision: 2) }
        #expect(try await repository.load() == good)
    }

    @Test @MainActor func pinnedResetOnCloseSurvivesRelaunch() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = SessionRepository(fileURL: url)
        let browser = BrowserCoordinator(startup: .returningSession)
        let original = URL(string: "https://example.com")!
        let article = URL(string: "https://example.com/article")!
        let id = try #require(browser.navigate(to: original, target: .newTab(spaceID: browser.activeSpaceID)))
        browser.updateMetadata(id, url: nil, title: "Example")
        #expect(browser.setPinned(id, pinned: true))
        browser.navigate(to: article, target: .currentTab(id))
        browser.updateMetadata(id, url: nil, title: "Article")
        #expect(browser.tabStore.tab(id: id)?.currentURL == article)
        browser.closeActiveTab()
        let closed = browser.session
        try await repository.save(closed, revision: 1)
        let saved = try #require(try await SessionRepository(fileURL: url).load())
        #expect(saved == closed)
        let restored = BrowserCoordinator(startup: .returningSession, activeSpaceID: saved.activeSpaceID,
            tabStore: TabStore(tabs: saved.tabs), selectionBySpace: saved.selectionBySpace,
            profileID: saved.profileID, recentlyClosed: saved.recentlyClosed)
        #expect(restored.content == .empty)
        #expect(restored.tabStore.tab(id: id)?.pinnedURL == original)
        #expect(restored.tabStore.tab(id: id)?.currentURL == original)
        #expect(restored.tabStore.tab(id: id)?.title == "Example")
        #expect(restored.tabStore.tab(id: id)?.pinnedTitle == "Example")
        #expect(restored.recentlyClosed.last?.tab.currentURL == original)
        #expect(restored.setPinned(id, pinned: false))
        try await repository.save(restored.session, revision: 2)
        #expect(try await repository.load() == restored.session)
        #expect(restored.tabStore.todayTabs(in: saved.activeSpaceID).map(\.id) == [id])
    }

    @Test func corruptDatabaseIsReportedWithoutReplacement() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not a database".utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) { try await SessionRepository(fileURL: url).load() }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func newerSchemaIsNotOverwritten() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = SessionRepository(fileURL: url)
        try await repository.save(BrowserSession(), revision: 1)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        await #expect(throws: (any Error).self) { try await repository.load() }
        await #expect(throws: (any Error).self) { try await repository.save(BrowserSession(), revision: 2) }
    }
}
