import Foundation
import SQLite3

public enum SessionError: LocalizedError, Sendable {
    case invalidData
    case database(String)
    public var errorDescription: String? {
        switch self {
        case .invalidData: "The saved session is damaged or uses an unsupported version."
        case .database(let message): "Session storage: \(message)"
        }
    }
}

/// SQLite work and JSON encoding run on this actor, never MainActor.
/// Version 1 stores one coherent snapshot; later normalized schemas can migrate it.
public actor SessionRepository {
    public let fileURL: URL
    private let input: NavigationInput
    private var latestRevision: UInt64 = 0

    public init(fileURL: URL, input: NavigationInput = NavigationInput()) {
        self.fileURL = fileURL
        self.input = input
    }

    public func load() throws -> BrowserSession? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try withDatabase(readOnly: true) { db in
            guard try schemaVersion(db) == 1 else { throw SessionError.invalidData }
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "SELECT payload FROM session WHERE id = 1", -1, &statement, nil), db)
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
                throw SessionError.invalidData
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let snapshot = try JSONDecoder().decode(BrowserSession.self, from: data)
            try snapshot.validate(using: input)
            return snapshot
        }
    }

    public func save(_ snapshot: BrowserSession, revision: UInt64) throws {
        guard revision >= latestRevision else { return }
        try snapshot.validate(using: input)
        let payload = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withDatabase(readOnly: false) { db in
            let version = try schemaVersion(db)
            guard version == 0 || version == 1 else { throw SessionError.invalidData }
            try execute(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; BEGIN IMMEDIATE;")
            do {
                try execute(db, "CREATE TABLE IF NOT EXISTS session (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL); PRAGMA user_version=1;")
                var statement: OpaquePointer?
                try check(sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO session(id,payload) VALUES(1,?)", -1, &statement, nil), db)
                defer { sqlite3_finalize(statement) }
                let result = payload.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                try check(result, db)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
                try execute(db, "COMMIT;")
            } catch {
                try? execute(db, "ROLLBACK;")
                throw error
            }
        }
        latestRevision = revision
    }

    private func withDatabase<T>(readOnly: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(fileURL.path, &handle, flags, nil)
        guard let db = handle else { throw SessionError.database("Cannot open the session file.") }
        defer { sqlite3_close(db) }
        try check(result, db)
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    private func schemaVersion(_ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure(db) }
        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil), db)
    }

    private func check(_ result: Int32, _ db: OpaquePointer) throws {
        guard result == SQLITE_OK else { throw failure(db) }
    }

    private func failure(_ db: OpaquePointer) -> SessionError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
}
