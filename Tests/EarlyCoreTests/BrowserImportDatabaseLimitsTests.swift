// SPDX-License-Identifier: MPL-2.0

import Foundation
import Darwin
import SQLite3
import Testing
@testable import EarlyCore

struct BrowserImportDatabaseLimitsTests {
    private final class Fixture {
        let root: URL
        let file: URL
        let db: OpaquePointer
        init(firefox: Bool = false, padding: Int = 0) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyDatabaseLimits-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            file = root.appendingPathComponent(firefox ? "places.sqlite" : "History")
            var opened: OpaquePointer?
            try #require(sqlite3_open(file.path, &opened) == SQLITE_OK)
            db = try #require(opened)
            try exec("PRAGMA page_size=1024; PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            let time = Int64((Date().timeIntervalSince1970 + (firefox ? 0 : 11_644_473_600)) * 1_000_000)
            if firefox {
                try exec("""
                CREATE TABLE moz_places(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
                CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY,parent INTEGER,type INTEGER,title TEXT,fk INTEGER,position INTEGER);
                CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY,place_id INTEGER,visit_date INTEGER);
                INSERT INTO moz_places VALUES(1,'https://example.invalid/bounded','Bounded');
                INSERT INTO moz_bookmarks VALUES(1,0,2,'Root',NULL,0),(2,1,1,'Bookmark',1,0);
                INSERT INTO moz_historyvisits VALUES(1,1,\(time));
                """)
            } else {
                try exec("""
                CREATE TABLE urls(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
                CREATE TABLE visits(id INTEGER PRIMARY KEY,url INTEGER,visit_time INTEGER);
                INSERT INTO urls VALUES(1,'https://example.invalid/bounded','Bounded');
                INSERT INTO visits VALUES(1,1,\(time));
                """)
            }
            try exec("CREATE TABLE padding(bytes BLOB); PRAGMA wal_checkpoint(TRUNCATE);")
            if padding > 0 { try exec("INSERT INTO padding VALUES(zeroblob(\(padding)))") }
        }
        func exec(_ sql: String) throws {
            try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        var hooks: BrowserImportFiles.DatabaseHooks {
            var hooks = BrowserImportFiles.DatabaseHooks()
            hooks.temporaryDirectory = root
            return hooks
        }
        func checkClean() throws {
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("EarlyBrowserImport-") })
        }
        func cleanup() {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func committedWALPagesCountTowardTheSizeLimitBeforeCopying() throws {
        let f = try Fixture(padding: 128 * 1024); defer { f.cleanup() }
        let main = try Data(contentsOf: f.file)
        let walURL = URL(fileURLWithPath: f.file.path + "-wal")
        let wal = try Data(contentsOf: walURL)
        var limits = BrowserImportFiles.DatabaseLimits(); limits.maximumBytes = 32 * 1024
        try #require(main.count < limits.maximumBytes && wal.count > limits.maximumBytes)
        var calls = 0, hooks = f.hooks
        hooks.step = { _, _ in calls += 1; return SQLITE_OK }
        #expect(throws: BrowserImportProblem.self) {
            try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        #expect(calls == 0)
        #expect(try Data(contentsOf: f.file) == main)
        #expect(try Data(contentsOf: walURL) == wal)
        try f.checkClean()
    }

    @Test func onlyRegularLocalFilesCanBeOpenedAsSourceDatabases() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let fifo = f.root.appendingPathComponent("pipe.sqlite")
        let link = f.root.appendingPathComponent("linked.sqlite")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
        for url in [f.root, fifo, link, URL(string: "https://example.invalid/History")!] {
            #expect(throws: BrowserImportProblem.self) {
                try BrowserImportFiles.database(url, source: "Chromium", firefox: false, limits: .init(), hooks: f.hooks)
            }
        }
        try f.checkClean()
    }

    @Test(arguments: [false, true])
    func ordinarySourcesRemainReadableAndDoNotChangeTheirFiles(_ firefox: Bool) throws {
        let f = try Fixture(firefox: firefox, padding: 16 * 1024); defer { f.cleanup() }
        let main = try Data(contentsOf: f.file)
        let walURL = URL(fileURLWithPath: f.file.path + "-wal")
        let wal = try Data(contentsOf: walURL)
        let result = try BrowserImportFiles.database(f.file, source: firefox ? "Firefox" : "Chromium", firefox: firefox,
            limits: .init(), hooks: f.hooks)
        #expect(result.nodes.filter { $0.kind == .history }.count == 1)
        #expect(result.nodes.filter { $0.kind == .bookmark }.count == (firefox ? 1 : 0))
        #expect(try Data(contentsOf: f.file) == main)
        #expect(try Data(contentsOf: walURL) == wal)
        try f.checkClean()
        // A fresh writer can obtain an exclusive transaction after all importer
        // connections and backup handles have been released.
        try f.exec("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; COMMIT;")
    }

    @Test func sourceChangesRestartTheBackupButProduceOneCoherentCompletedResult() throws {
        let f = try Fixture(padding: 16 * 1024); defer { f.cleanup() }
        var limits = BrowserImportFiles.DatabaseLimits(); limits.pagesPerStep = 1
        var steps = 0, hooks = f.hooks
        let newTime = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        hooks.step = { backup, pages in
            let status = sqlite3_backup_step(backup, pages)
            steps += 1
            if steps == 1 {
                #expect(sqlite3_exec(f.db, "BEGIN; UPDATE urls SET title='Changed'; INSERT INTO visits VALUES(2,1,\(newTime)); COMMIT;", nil, nil, nil) == SQLITE_OK)
            }
            return status
        }
        let result = try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        let visits = result.nodes.filter { $0.kind == .history }
        #expect(steps > 1 && visits.count == 2)
        #expect(visits.allSatisfy { $0.title == "Changed" })
        try f.checkClean()
    }

    @Test func endlesslyChangingSourcesExhaustTheCopiedWorkBudget() throws {
        let f = try Fixture(padding: 8 * 1024); defer { f.cleanup() }
        var limits = BrowserImportFiles.DatabaseLimits()
        limits.pagesPerStep = 1; limits.maximumCopiedBytes = 64 * 1024; limits.maximumSteps = 200
        var steps = 0, hooks = f.hooks
        hooks.step = { backup, pages in
            let status = sqlite3_backup_step(backup, pages)
            steps += 1
            #expect(sqlite3_exec(f.db, "UPDATE urls SET title='Change \(steps)'", nil, nil, nil) == SQLITE_OK)
            return status
        }
        #expect(throws: BrowserImportProblem.self) {
            try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        #expect(steps == 64)
        try f.checkClean()
    }

    @Test func aGrowingWALCannotProduceAnOversizedDestination() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var limits = BrowserImportFiles.DatabaseLimits(); limits.pagesPerStep = 1; limits.maximumBytes = 32 * 1024
        var steps = 0, hooks = f.hooks
        hooks.step = { backup, pages in
            let status = sqlite3_backup_step(backup, pages)
            steps += 1
            if steps == 1 { #expect(sqlite3_exec(f.db, "INSERT INTO padding VALUES(zeroblob(131072))", nil, nil, nil) == SQLITE_OK) }
            return status
        }
        #expect(throws: BrowserImportProblem.self) {
            try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        #expect(steps <= 2)
        try f.checkClean()
    }

    @Test func successfulStepsStillHaveADeadlineAndStepLimit() throws {
        let f = try Fixture(padding: 32 * 1024); defer { f.cleanup() }
        var limits = BrowserImportFiles.DatabaseLimits(); limits.pagesPerStep = 1; limits.maximumDuration = 0.5
        var time: TimeInterval = 0, steps = 0, hooks = f.hooks
        hooks.now = { time }
        hooks.step = { backup, pages in
            steps += 1; time += 1
            return sqlite3_backup_step(backup, pages)
        }
        #expect(throws: BrowserImportProblem.self) {
            try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        #expect(steps == 1)
        try f.checkClean()
        hooks.now = { 0 }
        hooks.step = { backup, pages in steps += 1; return sqlite3_backup_step(backup, pages) }
        limits.maximumSteps = 2; steps = 0
        #expect(throws: BrowserImportProblem.self) {
            try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        #expect(steps == 2)
        try f.checkClean()
    }

    @Test func busyRetriesAreBoundedAndCopyFailuresReleaseThePartialSnapshot() throws {
        let f = try Fixture(padding: 32 * 1024); defer { f.cleanup() }
        var limits = BrowserImportFiles.DatabaseLimits(); limits.maximumBusyRetries = 2
        var steps = 0, waits = 0, hooks = f.hooks
        hooks.step = { _, _ in steps += 1; return SQLITE_BUSY }
        hooks.sleep = { _ in waits += 1 }
        #expect(throws: BrowserImportProblem.self) {
            try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        #expect(steps == 3 && waits == 2)
        try f.checkClean()
        hooks.step = { backup, _ in
            #expect(sqlite3_backup_step(backup, 1) == SQLITE_OK)
            return SQLITE_IOERR | (3 << 8) // SQLITE_IOERR_WRITE is not imported by Swift.
        }
        #expect(throws: BrowserImportProblem.self) {
            try BrowserImportFiles.database(f.file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        try f.checkClean()
    }

    @Test func cancellationDuringCopyNeverReturnsPartialData() async throws {
        let f = try Fixture(padding: 32 * 1024); defer { f.cleanup() }
        let file = f.file, root = f.root
        let task = Task {
            var limits = BrowserImportFiles.DatabaseLimits(); limits.pagesPerStep = 1
            var hooks = BrowserImportFiles.DatabaseHooks(); hooks.temporaryDirectory = root
            hooks.step = { backup, pages in
                let status = sqlite3_backup_step(backup, pages)
                withUnsafeCurrentTask { $0?.cancel() }
                return status
            }
            return try BrowserImportFiles.database(file, source: "Chromium", firefox: false, limits: limits, hooks: hooks)
        }
        do { _ = try await task.value; Issue.record("Cancelled snapshot returned data") }
        catch is CancellationError {}
        try f.checkClean()
    }
}
