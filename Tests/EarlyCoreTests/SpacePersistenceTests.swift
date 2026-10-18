import Foundation
import SQLite3
import Testing
@testable import EarlyCore

struct SpacePersistenceTests {
    /// Reproduce a v1 on-disk payload, including the pre-Space multi-window form.
    private func legacyData(_ session: BrowserSession) throws -> Data {
        func downgrade(_ value: [String: Any]) -> [String: Any] {
            var copy = value
            copy["version"] = 1
            copy.removeValue(forKey: "spaces")
            if let windows = copy["additionalWindows"] as? [[String: Any]] {
                copy["additionalWindows"] = windows.map(downgrade)
            }
            return copy
        }
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: downgrade(json))
    }

    @Test func migratesLegacyReferencesWithoutChangingTabFolderOrSpaceIdentity() throws {
        let profile = UUID(), personal = UUID(), other = UUID(), empty = UUID()
        let folder = BrowserFolder(spaceID: other, name: "Saved")
        let url = URL(string: "https://example.com")!
        let today = BrowserTab(spaceID: personal, profileID: profile, title: "Today", currentURL: url)
        var pin = BrowserTab(spaceID: other, profileID: profile, title: "Pin", currentURL: url, pinnedURL: url)
        pin.folderID = folder.id
        let session = BrowserSession(profileID: profile, activeSpaceID: personal, tabs: [today, pin],
            selectionBySpace: [personal: today.id, other: pin.id, empty: UUID()], folders: [folder])
        let data = try legacyData(session)
        let migrated = try JSONDecoder().decode(BrowserSession.self, from: data)
        let again = try JSONDecoder().decode(BrowserSession.self, from: data)
        #expect(migrated == again)
        #expect(migrated.version == 2)
        #expect(migrated.spaces.map(\.id) == [personal, other, empty])
        #expect(migrated.spaces.map(\.name) == ["Personal", "Space 2", "Space 3"])
        #expect(migrated.tabs == session.tabs && migrated.folders == session.folders)
        #expect(migrated.selectionBySpace == [personal: today.id, other: pin.id])
        try migrated.validate()
        #expect(try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(migrated)) == migrated)
    }

    @Test func migratesEmptyAndWindowOnlyAndRecentlyClosedSpacesIntoOneCatalog() throws {
        let profile = UUID(), empty = UUID(), childSpace = UUID(), historySpace = UUID()
        let url = URL(string: "https://example.com")!
        let history = BrowserTab(spaceID: historySpace, profileID: profile, title: "Closed", currentURL: url)
        var session = BrowserSession(profileID: profile, activeSpaceID: empty,
            recentlyClosed: [ClosedTab(tab: history, position: 0)])
        session.additionalWindows = [BrowserSession(profileID: profile, activeSpaceID: childSpace)]
        let result = try JSONDecoder().decode(BrowserSession.self, from: legacyData(session))
        #expect(result.spaces.map(\.id) == [empty, historySpace, childSpace])
        #expect(result.additionalWindows.first?.spaces == result.spaces)
        #expect(result.tabs.isEmpty && result.activeSpaceID == empty)
        #expect(result.recentlyClosed.first?.tab.id == history.id)
        try result.validate()
    }

    @Test func rejectsInvalidCatalogsReferencesAndSelections() throws {
        let valid = BrowserSession()
        func rejected(_ mutate: (inout BrowserSession) -> Void) {
            var value = valid
            mutate(&value)
            #expect(throws: SessionError.self) { try value.validate() }
        }
        rejected { $0.spaces = [] }
        rejected { $0.spaces.append($0.spaces[0]) }
        rejected { $0.spaces[0].name = "" }
        rejected { $0.spaces[0].name = "bad\nname" }
        rejected { $0.spaces[0].name = String(repeating: "a", count: 65) }
        rejected { $0.spaces[0] = BrowserSpace(id: $0.activeSpaceID, profileID: UUID(), name: "Foreign") }
        rejected { $0.activeSpaceID = UUID() }
        rejected { $0.folders = [BrowserFolder(spaceID: UUID(), name: "Dangling")] }
        rejected { $0.selectionBySpace[$0.activeSpaceID] = UUID() }
        let url = URL(string: "https://example.com")!
        rejected { $0.tabs = [BrowserTab(spaceID: UUID(), profileID: $0.profileID, title: "Dangling", currentURL: url)] }
        rejected {
            let tab = BrowserTab(spaceID: $0.activeSpaceID, profileID: $0.profileID,
                title: "Closed", currentURL: url, pinnedURL: url, isOpen: false)
            $0.tabs = [tab]
            $0.selectionBySpace[$0.activeSpaceID] = tab.id
        }
        rejected {
            $0.additionalWindows = [$0.openingWindow(at: url)]
            $0.additionalWindows[0].spaces[0].name = "Different catalog"
        }
    }

    @Test func rejectsFuturePayloadMissingCatalogAndUnknownColors() throws {
        let session = BrowserSession()
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        var future = original
        future["version"] = 99
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: future))
        }
        var missing = original
        missing.removeValue(forKey: "spaces")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: missing))
        }
        var invalid = original
        var catalog = try #require(original["spaces"] as? [[String: Any]])
        catalog[0]["color"] = "unknown-color"
        invalid["spaces"] = catalog
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
    }

    @Test @MainActor func catalogsSelectionsAndEmptySpacePersistWithExistingSnapshotWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlySpaces-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(fileURL: directory.appendingPathComponent("session.sqlite"))
        let browser = BrowserCoordinator(startup: .returningSession)
        let personal = browser.activeSpaceID
        let url = URL(string: "https://example.com")!
        let tab = try #require(browser.navigate(to: url, target: .newTab(spaceID: personal)))
        for color in BrowserSpace.Color.allCases {
            #expect(browser.createSpace(name: color.rawValue, color: color) != nil)
        }
        let empty = try #require(browser.spaces.last?.id)
        browser.switchSpace(to: empty)
        var root = browser.session
        root.additionalWindows = [root.openingWindow(at: url)]
        try await repository.save(root, revision: 1)
        let saved = try #require(try await SessionRepository(fileURL: directory.appendingPathComponent("session.sqlite")).load())
        #expect(saved == root)
        #expect(saved.activeSpaceID == empty && saved.selectionBySpace[empty] == nil)
        #expect(saved.selectionBySpace[personal] == tab)
        #expect(saved.additionalWindows.first?.spaces == root.spaces)
        #expect(saved.additionalWindows.first?.tabs.first?.id != tab)
    }

    @Test func repositoryLoadsActualLegacyPayloadAndSavesTheMigratedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyLegacySpaces-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.sqlite")
        let repository = SessionRepository(fileURL: file)
        let session = BrowserSession()
        try await repository.save(session, revision: 1)
        let legacy = try legacyData(session)
        // Keep the existing SQLite schema and replace only its snapshot payload
        // with the exact old representation.
        do {
            var db: OpaquePointer?
            #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "UPDATE session SET payload = ? WHERE id = 1", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let status = legacy.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            #expect(status == SQLITE_OK)
            #expect(sqlite3_step(statement) == SQLITE_DONE)
        }
        let migrated = try #require(try await repository.load())
        #expect(migrated.version == 2 && migrated.activeSpaceID == session.activeSpaceID)
        #expect(migrated.spaces.first?.name == "Personal")
        try await repository.save(migrated, revision: 2)
        #expect(try await SessionRepository(fileURL: file).load() == migrated)
    }
}
