// SPDX-License-Identifier: MPL-2.0

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
    public nonisolated let fileURL: URL
    private let input: NavigationInput
    private var latestRevision: UInt64 = 0
    /// One connection for every save, opened by the first: opening the file,
    /// setting its journal mode and closing it again more than doubled each
    /// save's time. A failed save closes it, so the next opens afresh. Used
    /// only on this actor, and in `deinit` once nothing else can.
    nonisolated(unsafe) private var writer: OpaquePointer?
    /// The file the connection has open, by device and inode: one deleted or
    /// replaced meanwhile must not keep taking saves no one would find.
    private var writerFile: (device: dev_t, inode: ino_t)?

    public init(fileURL: URL, input: NavigationInput = NavigationInput()) {
        self.fileURL = fileURL
        self.input = input
    }

    deinit { if let writer { sqlite3_close(writer) } }

    public func load() throws -> BrowserSession? {
        try Self.readSession(fileURL: fileURL, input: input)
    }

    public func loadWorkspace() throws -> BrowserWorkspace? {
        guard let data = try Self.readPayload(fileURL: fileURL) else { return nil }
        return try BrowserWorkspace.decodeMigrating(data, using: input)
    }

    private static func readSession(fileURL: URL, input: NavigationInput) throws -> BrowserSession? {
        guard let data = try readPayload(fileURL: fileURL) else { return nil }
        let snapshot = try JSONDecoder().decode(BrowserSession.self, from: data)
        try snapshot.validate(using: input)
        return snapshot
    }

    private static func readPayload(fileURL: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try withDatabase(fileURL: fileURL, readOnly: true) { db in
            guard try schemaVersion(db) == 1 else { throw SessionError.invalidData }
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "SELECT payload FROM session WHERE id = 1", -1, &statement, nil), db)
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
                throw SessionError.invalidData
            }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
    }

    public func save(_ snapshot: BrowserSession, revision: UInt64) throws {
        guard revision >= latestRevision else { return }
        try snapshot.validate(using: input)
        try write(try JSONEncoder().encode(snapshot), revision: revision)
    }

    public func saveWorkspace(_ snapshot: BrowserWorkspace, revision: UInt64) throws {
        guard revision >= latestRevision else { return }
        try snapshot.validate(using: input)
        try write(try JSONEncoder().encode(snapshot), revision: revision)
    }

    private func fileIdentity() -> (device: dev_t, inode: ino_t)? {
        var info = stat()
        guard stat(fileURL.path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    private func closeWriter() {
        if let writer { sqlite3_close(writer) }
        writer = nil
        writerFile = nil
    }

    private func writeConnection() throws -> OpaquePointer {
        if let writer {
            if let open = writerFile, let now = fileIdentity(), open.device == now.device, open.inode == now.inode { return writer }
            closeWriter()
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard let db = handle else { throw SessionError.database("Cannot open the session file.") }
        do {
            try Self.check(result, db)
            sqlite3_busy_timeout(db, 2000)
            try Self.execute(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        } catch {
            sqlite3_close(db)
            throw error
        }
        writer = db
        writerFile = fileIdentity()
        return db
    }

    private func write(_ payload: Data, revision: UInt64) throws {
        do {
            try Self.write(payload, to: try writeConnection())
        } catch {
            closeWriter()
            throw error
        }
        latestRevision = revision
    }

    private static func write(_ payload: Data, to db: OpaquePointer) throws {
        let version = try schemaVersion(db)
        guard version == 0 || version == 1 else { throw SessionError.invalidData }
        try execute(db, "BEGIN IMMEDIATE;")
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

    private static func withDatabase<T>(fileURL: URL, readOnly: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(fileURL.path, &handle, flags, nil)
        guard let db = handle else { throw SessionError.database("Cannot open the session file.") }
        defer { sqlite3_close(db) }
        try check(result, db)
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    private static func schemaVersion(_ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure(db) }
        return sqlite3_column_int(statement, 0)
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
