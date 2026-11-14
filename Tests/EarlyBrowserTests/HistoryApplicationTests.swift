// SPDX-License-Identifier: MPL-2.0

import AppKit
import SQLite3
import Testing
@testable import EarlyBrowser
@testable import EarlyCore
@testable import EarlyWeb

/// Real controllers and SQLite files; no windows or input automation.
@Suite(.serialized) @MainActor struct HistoryApplicationTests {
    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    private final class SQL {
        private var db: OpaquePointer?
        init(_ file: URL) throws { try #require(sqlite3_open(file.path, &db) == SQLITE_OK) }
        deinit { sqlite3_close(db) }
        func execute(_ sql: String) throws { try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyHistoryApplication-\(UUID())")
        let suite = "local.early.tests.history.\(UUID())"
        let defaults: UserDefaults
        let app = EarlyAppDelegate()
        var opened: [UUID] = []
        init() {
            _ = NSApplication.shared
            defaults = UserDefaults(suiteName: suite)!
            app.presentWindow = { [weak self] in self?.opened.append($0) }
        }
        func start() async throws -> BrowserWindowModel {
            let preferences = BrowserPreferences(defaults: defaults)
            preferences.haptics = false
            _ = await app.bootstrap(launchStore: FirstLaunchStore(defaults: defaults), preferences: preferences,
                defaults: defaults, storageDirectory: root, isTesting: true)
            let model = try #require(app.model)
            await model.flushHistory()
            return model
        }
        func cleanup(_ models: BrowserWindowModel...) async {
            for model in models {
                model.cancelCommandBarQueries()
                model.webViews.discardAll()
                await model.flushHistory()
                await model.webViews.favicons.shutdown()
                await model.history?.close()
            }
            for id in opened { app.closeWindow(id) }
            app.closeWindow(nil)
            _ = await app.persistence?.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func acceptVisit(_ model: BrowserWindowModel, _ url: URL) throws -> UUID {
        let id = try #require(model.coordinator.navigate(to: url, target: .newTab(spaceID: model.coordinator.activeSpaceID)))
        let tab = try #require(model.coordinator.tabStore.tab(id: id))
        model.webViews.prepare(tab)
        model.webViews.onMetadata?(id, url, "Accepted visit")
        return id
    }

    enum Deletion: CaseIterable { case window, closedProfile, visit, page }
    @Test(arguments: Deletion.allCases)
    func deletionFailureIsVisibleAndTheOriginalRequestCanBeRetried(kind: Deletion) async throws {
        let fixture = Fixture(), model = try await fixture.start()
        let history = try #require(model.history), profile = model.coordinator.profileID
        let url = URL(string: "https://history.invalid/remove")!
        try await history.record(url, title: "Keep until deletion succeeds", at: Date())
        let visit = try #require(try await history.visits().first)
        let sql = try SQL(history.fileURL)
        try sql.execute("CREATE TRIGGER refuse_delete BEFORE DELETE ON visits BEGIN SELECT RAISE(ABORT, 'Synthetic deletion failure'); END;")
        let before = model.historyRevision
        let success: Bool
        switch kind {
        case .window: success = await model.clearHistory(.all)
        case .closedProfile:
            fixture.app.closeWindow(nil)
            success = await fixture.app.clearHistory(.all, profile: profile)
        case .visit: success = await model.deleteHistory(.visits([visit.id]))
        case .page: success = await model.deleteHistory(.pages([url]))
        }
        #expect(!success)
        let removal = fixture.app.historyRemoval(for: profile)
        #expect(removal === model.historyRemoval, "Settings and windows share the failure and retry")
        let error = try #require(removal.error)
        #expect(error.contains("Synthetic deletion failure"))
        #expect(error.contains("Website data was cleared") == (kind == .window || kind == .closedProfile))
        #expect(model.historyRevision == before, "A failed database deletion must not signal success")
        #expect(try await history.visits().map(\.id) == [visit.id])
        try sql.execute("DROP TRIGGER refuse_delete;")
        #expect(await removal.retry())
        #expect(removal.error == nil && !removal.isWorking)
        #expect(try await history.visits().isEmpty)
        await fixture.cleanup(model)
    }

    @Test func clearingOneWindowOrdersTheOtherWindowsAcceptedVisitsAndKeepsNewBrowsing() async throws {
        let fixture = Fixture(), first = try await fixture.start()
        let second = try #require(fixture.app.openNewWindow(from: first).flatMap { fixture.app.windowModel($0) })
        let history = try #require(first.history)
        #expect(second.history === history)
        await second.flushHistory()
        let gate = Gate()
        history.pendingWrites.enqueue { await gate.wait() }
        try await wait { gate.continuation != nil }
        defer { gate.release() }
        let old = URL(string: "https://history.invalid/before-clear")!
        let tab = try acceptVisit(second, old)
        var cleared = false
        let clearing = Task { let result = await first.clearHistory(.all); cleared = true; return result }
        try await wait { first.historyRemoval.isWorking || cleared }
        #expect(!cleared, "Clear waits behind the other window's accepted visit")
        gate.release()
        #expect(await clearing.value)
        await second.flushHistory()
        #expect(try await history.visits().isEmpty, "No pre-clear visit can return after another window drains")
        second.webViews.onMetadata?(tab, old, "A late title is not a new visit")
        await second.flushHistory()
        #expect(try await history.visits().isEmpty)
        let new = URL(string: "https://history.invalid/after-clear")!
        second.webViews.onMetadata?(tab, new, "New browsing")
        await second.flushHistory()
        #expect(try await history.visits().map(\.url) == [new])
        await fixture.cleanup(first, second)
    }

    @Test(arguments: [false, true])
    func terminationWaitsForAcceptedVisitsEvenAfterTheirWindowClosed(closeWindow: Bool) async throws {
        let fixture = Fixture(), model = try await fixture.start()
        let history = try #require(model.history), app = fixture.app
        let blocker = try SQL(history.fileURL)
        try blocker.execute("BEGIN IMMEDIATE;")
        let url = URL(string: "https://history.invalid/before-quit")!
        _ = try acceptVisit(model, url)
        if closeWindow { app.closeWindow(nil) }
        var reply: Bool?
        app.terminationReply = { reply = $0 }
        app.askToQuitWithUnsavedHistory = { _ in Issue.record("The delayed write succeeds"); return .alertSecondButtonReturn }
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await wait { !history.pendingWrites.acceptsWrites || reply != nil }
        #expect(reply == nil, "Termination cannot be approved while accepted history is pending")
        try blocker.execute("ROLLBACK;")
        try await wait { reply != nil }
        #expect(reply == true)
        let reopened = HistoryStore(fileURL: history.fileURL)
        #expect(try await reopened.visits().map(\.url) == [url], "A separate connection sees durable history before quit approval")
        await reopened.close()
        await fixture.cleanup(model)
    }

    @Test func aRemovalRetryStillRefreshesOtherWindowsAfterTheOriginalWindowCloses() async throws {
        let fixture = Fixture(), first = try await fixture.start()
        let second = try #require(fixture.app.openNewWindow(from: first).flatMap { fixture.app.windowModel($0) })
        let history = try #require(first.history), url = URL(string: "https://history.invalid/retry")!
        try await history.record(url, title: "Remove", at: Date())
        let sql = try SQL(history.fileURL)
        try sql.execute("CREATE TRIGGER refuse_delete BEFORE DELETE ON visits BEGIN SELECT RAISE(ABORT, 'Synthetic deletion failure'); END;")
        #expect(await first.deleteHistory(.pages([url])) == false)
        fixture.app.closeWindow(nil)
        let revision = second.historyRevision
        try sql.execute("DROP TRIGGER refuse_delete;")
        #expect(await fixture.app.historyRemoval(for: first.coordinator.profileID).retry())
        #expect(second.historyRevision == revision + 1)
        #expect(try await history.visits().isEmpty)
        await fixture.cleanup(first, second)
    }

    @Test func cancellingQuitLetsTheCurrentPageBeRecordedAfterIgnoredCallbacks() async throws {
        let fixture = Fixture(), model = try await fixture.start(), gate = Gate()
        let history = try #require(model.history), app = fixture.app
        history.pendingWrites.enqueue { await gate.wait() }
        try await wait { gate.continuation != nil }
        defer { gate.release() }
        let before = URL(string: "https://history.invalid/before-quit")!
        let during = URL(string: "https://history.invalid/while-quitting")!
        let tab = try acceptVisit(model, before)
        var reply: Bool?
        app.terminationReply = { reply = $0 }
        app.historyQuitTimeout = .milliseconds(100)
        app.askToQuitWithUnsavedHistory = { _ in .alertSecondButtonReturn }
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        try await wait { !history.pendingWrites.acceptsWrites }
        model.webViews.onMetadata?(tab, during, "Arrived while quitting")
        try await wait { reply != nil }
        #expect(reply == false && history.pendingWrites.acceptsWrites)
        model.webViews.onMetadata?(tab, during, "After Cancel")
        gate.release()
        await model.flushHistory()
        #expect(try await history.visits().map(\.url) == [during, before])
        await fixture.cleanup(model)
    }

    @Test(arguments: [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn])
    func failedWritesOfferRetryCancelAndQuitAnyway(answer: NSApplication.ModalResponse) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyHistoryQuit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appending(path: "blocked")
        try Data().write(to: blocker)
        let history = HistoryStore(fileURL: blocker.appending(path: "history.sqlite"))
        let url = URL(string: "https://history.invalid/unsaved")!
        history.queueVisit(url, title: "First", at: Date())
        history.queueTitle(url, title: "Later title", visitedAt: Date())
        var asked = 0
        let quit = await EarlyAppDelegate.historySaved([history]) { reason in
            asked += 1
            #expect(!reason.isEmpty)
            if answer == .alertFirstButtonReturn { try? FileManager.default.removeItem(at: blocker) }
            return asked == 1 ? answer : .alertSecondButtonReturn
        }
        #expect(asked == 1 && quit == (answer != .alertSecondButtonReturn))
        if answer == .alertFirstButtonReturn {
            #expect(try await history.visits().map(\.title) == ["Later title"])
            #expect(history.pendingWrites.failure == nil)
        } else { #expect(history.pendingWrites.failure != nil) }
        #expect(history.pendingWrites.acceptsWrites == (answer == .alertSecondButtonReturn))
        await history.close()
    }

    @Test func aQuitTimeoutCanBeRetriedWithoutDuplicatingTheStillPendingWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EarlyHistoryQuit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(fileURL: root.appending(path: "history.sqlite")), gate = Gate()
        history.pendingWrites.enqueue { await gate.wait() }
        try await wait { gate.continuation != nil }
        defer { gate.release() }
        history.queueVisit(URL(string: "https://history.invalid/delayed")!, title: "Pending", at: Date())
        var asked = 0
        let began = ContinuousClock.now
        let cancelled = await EarlyAppDelegate.historySaved([history], timeout: .milliseconds(50)) { _ in
            asked += 1; return .alertSecondButtonReturn
        }
        #expect(!cancelled && asked == 1 && history.pendingWrites.acceptsWrites)
        #expect(began.duration(to: .now) < .seconds(2))
        let quit = await EarlyAppDelegate.historySaved([history], timeout: .milliseconds(50)) { _ in
            gate.release(); return .alertFirstButtonReturn
        }
        #expect(quit)
        #expect(try await history.visits().count == 1)
        await history.close()
    }
}
