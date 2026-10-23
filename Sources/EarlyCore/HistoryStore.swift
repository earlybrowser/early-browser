// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3

/// A visited page, with its visit totals.
public struct HistoryPage: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let lastVisit: Date
    public let visitCount: Int
}

/// One visit, for browsing history by day.
public struct HistoryVisit: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let url: URL
    public let title: String
    public let visitedAt: Date
}

/// The periods Clear History offers, as in Safari.
public enum HistoryClearRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour, today, todayAndYesterday, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastHour: "the Last Hour"
        case .today: "Today"
        case .todayAndYesterday: "Today and Yesterday"
        case .all: "All History"
        }
    }

    /// The first moment cleared; nil clears everything.
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .today: calendar.startOfDay(for: now)
        case .todayAndYesterday: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case .all: nil
        }
    }
}

/// One profile's browsing history in its own SQLite file. All work runs on this
/// actor, never the main actor. Private windows have no store at all.
public actor HistoryStore {
    public nonisolated let fileURL: URL
    /// Visits older than this are removed, as in Safari's default.
    public nonisolated let retention: TimeInterval
    /// Used only on this actor, and in `deinit` once nothing else can.
    nonisolated(unsafe) private var db: OpaquePointer?
    private var insertsSincePrune = 0

    public init(fileURL: URL, retention: TimeInterval = 365 * 24 * 60 * 60) {
        self.fileURL = fileURL
        self.retention = retention
    }

    deinit { if let db { sqlite3_close(db) } }

    /// Pages Early can open again: never local files, nothing past 4 KB.
    /// Not local files, and not a page's source, which is a view of another page.
    public nonisolated static func records(_ url: URL) -> Bool {
        !url.isFileURL && url.scheme != nil && url.scheme?.lowercased() != NavigationInput.pageSourceScheme
            && !NavigationInput.extensionSchemes.contains(url.scheme?.lowercased() ?? "")
            && url.absoluteString.utf8.count <= 4096
    }

    public func record(_ url: URL, title: String?, at date: Date) throws {
        guard Self.records(url) else { return }
        let db = try open()
        let name = Self.clean(title)
        try Self.execute(db, "BEGIN IMMEDIATE;")
        do {
            try Self.run(db, """
                INSERT INTO pages(url, title, visit_count, last_visit) VALUES(?1, ?2, 1, ?3)
                ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = MAX(last_visit, ?3),
                    title = CASE WHEN ?2 = '' THEN title ELSE ?2 END
                """, [.text(url.absoluteString), .text(name), .real(date.timeIntervalSince1970)])
            try Self.run(db, "INSERT INTO visits(page_id, visited_at) SELECT id, ?2 FROM pages WHERE url = ?1",
                         [.text(url.absoluteString), .real(date.timeIntervalSince1970)])
            try Self.execute(db, "COMMIT;")
        } catch {
            try? Self.execute(db, "ROLLBACK;")
            throw error
        }
        insertsSincePrune += 1
        if insertsSincePrune >= 200 {
            insertsSincePrune = 0
            try deleteVisits(before: date.addingTimeInterval(-retention))
        }
    }

    /// A title that arrives after the visit was recorded.
    public func updateTitle(_ url: URL, title: String) throws {
        let name = Self.clean(title)
        guard Self.records(url), !name.isEmpty else { return }
        try Self.run(try open(), "UPDATE pages SET title = ?2 WHERE url = ?1", [.text(url.absoluteString), .text(name)])
    }

    /// Pages whose title or address contains every word, most visited first.
    public func search(_ query: String, limit: Int) throws -> [HistoryPage] {
        let words = Self.words(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        let filter = words.indices.map { "(title LIKE ?\($0 + 1) ESCAPE '\\' OR url LIKE ?\($0 + 1) ESCAPE '\\')" }
        let sql = "SELECT url, title, last_visit, visit_count FROM pages WHERE \(filter.joined(separator: " AND ")) "
            + "ORDER BY visit_count DESC, last_visit DESC LIMIT \(min(limit, 500))"
        return try Self.query(try open(), sql, words.map { .text("%\(Self.escapeLike($0))%") }) { row in
            guard let url = URL(string: row.text(0)) else { return nil }
            return HistoryPage(url: url, title: row.text(1), lastVisit: Date(timeIntervalSince1970: row.real(2)),
                               visitCount: Int(row.integer(3)))
        }
    }

    /// Pages last visited since `date`, most recent first, for the History menu.
    public func recentPages(since date: Date, limit: Int) throws -> [HistoryPage] {
        guard limit > 0 else { return [] }
        let sql = "SELECT url, title, last_visit, visit_count FROM pages WHERE last_visit >= ?1 "
            + "ORDER BY last_visit DESC LIMIT \(min(limit, 500))"
        return try Self.query(try open(), sql, [.real(date.timeIntervalSince1970)]) { row in
            guard let url = URL(string: row.text(0)) else { return nil }
            return HistoryPage(url: url, title: row.text(1), lastVisit: Date(timeIntervalSince1970: row.real(2)),
                               visitCount: Int(row.integer(3)))
        }
    }

    /// Visits newest first, optionally filtered by words and older than `before`.
    public func visits(matching query: String = "", before: Date? = nil, limit: Int = 500) throws -> [HistoryVisit] {
        let words = Self.words(query)
        var conditions = words.indices.map { "(p.title LIKE ?\($0 + 1) ESCAPE '\\' OR p.url LIKE ?\($0 + 1) ESCAPE '\\')" }
        var values: [Value] = words.map { .text("%\(Self.escapeLike($0))%") }
        if let before {
            values.append(.real(before.timeIntervalSince1970))
            conditions.append("v.visited_at < ?\(values.count)")
        }
        let sql = "SELECT v.id, p.url, p.title, v.visited_at FROM visits v JOIN pages p ON p.id = v.page_id"
            + (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND "))
            + " ORDER BY v.visited_at DESC, v.id DESC LIMIT \(max(0, min(limit, 5000)))"
        return try Self.query(try open(), sql, values) { row in
            guard let url = URL(string: row.text(1)) else { return nil }
            return HistoryVisit(id: row.integer(0), url: url, title: row.text(2),
                                visitedAt: Date(timeIntervalSince1970: row.real(3)))
        }
    }

    public func deleteVisits(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let db = try open()
        try Self.transaction(db) {
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let marks = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ",")
                try Self.run(db, "DELETE FROM visits WHERE id IN (\(marks))", chunk.map { .integer($0) })
            }
            try Self.recount(db)
        }
    }

    /// Every visit to these pages.
    public func deletePages(_ urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let db = try open()
        try Self.transaction(db) {
            for url in urls {
                try Self.run(db, "DELETE FROM visits WHERE page_id IN (SELECT id FROM pages WHERE url = ?1)", [.text(url.absoluteString)])
            }
            try Self.recount(db)
        }
    }

    /// Clears visits from `since` to now; nil clears all history.
    public func deleteVisits(since: Date?) throws {
        let db = try open()
        try Self.transaction(db) {
            if let since {
                try Self.run(db, "DELETE FROM visits WHERE visited_at >= ?1", [.real(since.timeIntervalSince1970)])
            } else {
                try Self.execute(db, "DELETE FROM visits;")
            }
            try Self.recount(db)
        }
    }

    public func deleteVisits(before date: Date) throws {
        let db = try open()
        try Self.transaction(db) {
            try Self.run(db, "DELETE FROM visits WHERE visited_at < ?1", [.real(date.timeIntervalSince1970)])
            try Self.recount(db)
        }
    }

    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// Closes and removes this profile's history file, e.g. when the profile is deleted.
    public func removeFile() throws {
        close()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fileURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: SQLite

    enum Value {
        case text(String)
        case real(Double)
        case integer(Int64)
    }

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard let opened = handle else { throw SessionError.database("Cannot open the history file.") }
        guard result == SQLITE_OK else {
            let error = Self.failure(opened)
            sqlite3_close(opened)
            throw error
        }
        sqlite3_busy_timeout(opened, 2000)
        do {
            try Self.execute(opened, """
                PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS pages (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL DEFAULT '', visit_count INTEGER NOT NULL DEFAULT 0, last_visit REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS visits (id INTEGER PRIMARY KEY,
                    page_id INTEGER NOT NULL REFERENCES pages(id) ON DELETE CASCADE, visited_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS visits_time ON visits(visited_at);
                CREATE INDEX IF NOT EXISTS visits_page ON visits(page_id);
                CREATE INDEX IF NOT EXISTS pages_recent ON pages(last_visit);
                PRAGMA user_version=1;
                """)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        db = opened
        return opened
    }

    /// Pages keep totals that match their remaining visits; unvisited pages go.
    private static func recount(_ db: OpaquePointer) throws {
        try execute(db, """
            DELETE FROM pages WHERE id NOT IN (SELECT DISTINCT page_id FROM visits);
            UPDATE pages SET visit_count = (SELECT COUNT(*) FROM visits WHERE page_id = pages.id),
                last_visit = (SELECT MAX(visited_at) FROM visits WHERE page_id = pages.id);
            """)
    }

    private static func transaction(_ db: OpaquePointer, _ body: () throws -> Void) throws {
        try execute(db, "BEGIN IMMEDIATE;")
        do {
            try body()
            try execute(db, "COMMIT;")
        } catch {
            try? execute(db, "ROLLBACK;")
            throw error
        }
    }

    private static func clean(_ title: String?) -> String {
        String((title ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(512))
    }

    private static func words(_ query: String) -> [String] {
        Array(query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(8))
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func bind(_ statement: OpaquePointer, _ values: [Value], _ db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, position, text, -1, transient)
            case .real(let number): result = sqlite3_bind_double(statement, position, number)
            case .integer(let number): result = sqlite3_bind_int64(statement, position, number)
            }
            try check(result, db)
        }
    }

    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db)
        defer { sqlite3_finalize(statement) }
        try bind(statement!, values, db)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
    }

    private static func query<T>(_ db: OpaquePointer, _ sql: String, _ values: [Value], _ read: (Row) -> T?) throws -> [T] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db)
        defer { sqlite3_finalize(statement) }
        try bind(statement!, values, db)
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure(db) }
            if let value = read(Row(statement: statement!)) { rows.append(value) }
        }
        return rows
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil), db)
    }

    private static func check(_ result: Int32, _ db: OpaquePointer) throws {
        guard result == SQLITE_OK else { throw failure(db) }
    }

    private static func failure(_ db: OpaquePointer) -> SessionError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
}

/// History in the command bar: pages whose title or address match, offered
/// below tabs and saved pages.
public struct HistorySearchProvider: CommandSearchProvider {
    let store: HistoryStore
    public init(store: HistoryStore) { self.store = store }

    public func candidates(matching query: String, limit: Int) async throws -> [CommandSearchCandidate] {
        try await store.search(query, limit: limit).map { page in
            CommandSearchCandidate(id: "history.\(page.url.absoluteString)", kind: .history, target: .page(page.url),
                title: page.title.isEmpty ? (page.url.host ?? page.url.absoluteString) : page.title,
                detail: page.url.absoluteString, terms: [page.title, page.url.absoluteString],
                lastUsed: page.lastVisit, useCount: page.visitCount)
        }
    }
}
