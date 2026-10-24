// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3
import Testing

/// A real competing writer: SQLite must reject the app's transaction while
/// readers can still inspect the last durable snapshot. No storage is removed.
@MainActor
func withLockedSession<T>(at file: URL, _ body: () async throws -> T) async throws -> T {
    var handle: OpaquePointer?
    try #require(sqlite3_open(file.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    try #require(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
    return try await body()
}
