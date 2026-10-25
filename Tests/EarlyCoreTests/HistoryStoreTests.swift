// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite
struct HistoryStoreTests {
    private func store() -> HistoryStore {
        HistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "EarlyHistory-\(UUID().uuidString)/history.sqlite"))
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let swift = URL(string: "https://swift.org/documentation/")!
    private let early = URL(string: "https://github.com/earlybrowser/early-browser")!

    /// 210 visits at one moment: pages of 200 and 10, none skipped or repeated.
    @Test func pagingContinuesThroughVisitsThatShareATime() async throws {
        let history = store()
        defer { Task { try? await history.removeFile() } }
        for index in 0..<210 {
            try await history.record(URL(string: "https://example.com/\(index)")!, title: "Page \(index)", at: start)
        }
        let first = try await history.visits(limit: 200)
        let second = try await history.visits(continuing: first.last, limit: 200)
        #expect(first.count == 200 && second.count == 10)
        #expect(Set((first + second).map(\.id)).count == 210, "Every visit once")
        #expect(try await history.visits(continuing: second.last, limit: 200).isEmpty)
    }

    /// Deleting recounts only the pages it touched; the rest keep their totals.
    @Test func deletingUpdatesOnlyThePagesItTouched() async throws {
        let history = store()
        defer { Task { try? await history.removeFile() } }
        try await history.record(swift, title: "Swift", at: start)
        try await history.record(swift, title: nil, at: start.addingTimeInterval(60))
        try await history.record(early, title: "Early", at: start.addingTimeInterval(120))
        let newestSwift = try #require(try await history.visits(matching: "swift").first)
        try await history.deleteVisits([newestSwift.id])
        let swiftPage = try #require(try await history.search("swift", limit: 5).first)
        #expect(swiftPage.visitCount == 1 && swiftPage.lastVisit == start, "Its count and last visit follow")
        #expect(try await history.search("early", limit: 5).first?.visitCount == 1, "Another page keeps its total")
        try await history.deleteVisits(before: start.addingTimeInterval(45))
        #expect(try await history.search("swift", limit: 5).isEmpty, "A page without visits goes")
        #expect(try await history.search("early", limit: 5).first?.visitCount == 1)
        try await history.deletePages([early])
        #expect(try await history.recentPages(since: .distantPast, limit: 5).isEmpty)
    }

    @Test func visitsAreCountedTitlesFollowAndSearchMatchesEveryWord() async throws {
        let history = store()
        defer { Task { try? await history.removeFile() } }
        try await history.record(swift, title: "Swift Documentation", at: start)
        try await history.record(swift, title: nil, at: start.addingTimeInterval(60))
        try await history.record(early, title: "", at: start.addingTimeInterval(120))
        try await history.updateTitle(early, title: "Early\nBrowser  ")
        try await history.record(URL(fileURLWithPath: "/Users/me/secret.html"), title: "Local", at: start)

        let pages = try await history.search("swift", limit: 10)
        #expect(pages.map(\.url) == [swift] && pages.first?.visitCount == 2 && pages.first?.title == "Swift Documentation",
                "A later visit without a title keeps the known one")
        #expect(try await history.search("early browser", limit: 10).map(\.title) == ["Early Browser"])
        #expect(try await history.search("github swift", limit: 10).isEmpty, "Every word must match")
        #expect(try await history.search("100%_", limit: 10).isEmpty, "LIKE wildcards are literal")
        #expect(try await history.search("secret", limit: 10).isEmpty, "Local files are never recorded")
        #expect(try await history.search("   ", limit: 10).isEmpty)

        let visits = try await history.visits()
        #expect(visits.map(\.url) == [early, swift, swift], "Newest first")
        #expect(try await history.visits(matching: "documentation").count == 2)
        #expect(try await history.visits(before: start.addingTimeInterval(60)).map(\.url) == [swift])
    }

    @Test func deletingVisitsPagesAndRangesKeepsTotalsConsistent() async throws {
        let history = store()
        defer { Task { try? await history.removeFile() } }
        for minute in 0..<3 { try await history.record(swift, title: "Swift", at: start.addingTimeInterval(Double(minute) * 60)) }
        try await history.record(early, title: "Early", at: start.addingTimeInterval(3600))

        let newest = try #require(try await history.visits(matching: "swift").first)
        try await history.deleteVisits([newest.id])
        let swiftPage = try #require(try await history.search("swift", limit: 5).first)
        #expect(swiftPage.visitCount == 2 && swiftPage.lastVisit == start.addingTimeInterval(60))

        try await history.deleteVisits(since: start.addingTimeInterval(1800))
        #expect(try await history.search("early", limit: 5).isEmpty, "Clearing the last hour removes its pages")
        #expect(try await history.search("swift", limit: 5).count == 1)

        try await history.deletePages([swift])
        #expect(try await history.visits().isEmpty)

        try await history.record(early, title: "Early", at: start)
        try await history.deleteVisits(since: nil)
        #expect(try await history.visits().isEmpty)
        #expect(try await history.search("early", limit: 5).isEmpty)
    }

    @Test func recentPagesListEachPageOnceSinceADateByItsLatestVisit() async throws {
        let history = store()
        defer { Task { try? await history.removeFile() } }
        let old = URL(string: "https://example.com/old")!
        try await history.record(old, title: "Old", at: start.addingTimeInterval(-86_400))
        try await history.record(swift, title: "Swift", at: start)
        try await history.record(early, title: "Early", at: start.addingTimeInterval(60))
        try await history.record(swift, title: nil, at: start.addingTimeInterval(120))
        let pages = try await history.recentPages(since: start, limit: 10)
        #expect(pages.map(\.url) == [swift, early], "Each page once, newest first; earlier days are left out")
        #expect(pages.first?.title == "Swift" && pages.first?.visitCount == 2)
        #expect(try await history.recentPages(since: start, limit: 1).map(\.url) == [swift])
        #expect(try await history.recentPages(since: start, limit: 0).isEmpty)

        // Deleting a page's latest visit moves it back to its earlier one.
        let latest = try #require(try await history.visits(matching: "swift").first)
        try await history.deleteVisits([latest.id])
        #expect(try await history.recentPages(since: start, limit: 10).map(\.url) == [early, swift])
    }

    @Test func oldVisitsExpireAndTheFileCanBeRemoved() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EarlyHistory-\(UUID().uuidString)/history.sqlite")
        let history = HistoryStore(fileURL: file, retention: 60 * 60)
        try await history.record(swift, title: "Old", at: start)
        try await history.deleteVisits(before: start.addingTimeInterval(30 * 60))
        #expect(try await history.visits().isEmpty)
        try await history.record(early, title: "Kept", at: start)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await history.removeFile()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func clearRangesStartAtTheHourTodayYesterdayOrNever() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 15, minute: 30)))
        #expect(HistoryClearRange.lastHour.start(now: now, calendar: calendar) == now.addingTimeInterval(-3600))
        #expect(HistoryClearRange.today.start(now: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2026, month: 10, day: 22)))
        #expect(HistoryClearRange.todayAndYesterday.start(now: now, calendar: calendar)
            == calendar.date(from: DateComponents(year: 2026, month: 10, day: 21)))
        #expect(HistoryClearRange.all.start(now: now, calendar: calendar) == nil)
        #expect(HistoryClearRange.allCases.map(\.title) == ["the Last Hour", "Today", "Today and Yesterday", "All History"])
    }

    @Test func providerOffersMatchingPagesAsHistoryResults() async throws {
        let history = store()
        defer { Task { try? await history.removeFile() } }
        try await history.record(early, title: "Early Browser", at: start)
        try await history.record(swift, title: "", at: start)
        let provider = HistorySearchProvider(store: history)
        let candidates = try await provider.candidates(matching: "early", limit: 5)
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1 && candidate.kind == .history && candidate.target == .page(early))
        #expect(candidate.title == "Early Browser" && candidate.detail == early.absoluteString && candidate.useCount == 1)
        #expect(try await provider.candidates(matching: "swift", limit: 5).first?.title == "swift.org", "Untitled pages show their host")
    }
}
