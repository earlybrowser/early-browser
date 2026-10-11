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
