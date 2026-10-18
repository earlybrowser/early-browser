// SPDX-License-Identifier: MPL-2.0

// Synthetic Phase 0 sizing probe, not production persistence or a browser benchmark.
// Compile with swiftc -O Tools/PersistenceProbe.swift -o build/persistence-probe.
import Foundation
import SQLite3

struct ProbeError: Error { let message: String }

func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw ProbeError(message: String(cString: sqlite3_errmsg(db)))
    }
}

func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[Int(Double(sorted.count - 1) * fraction)]
}

func run() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("early-persistence-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    var handle: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("probe.sqlite").path, &handle) == SQLITE_OK,
          let db = handle else { throw ProbeError(message: "Cannot open probe database") }
    defer { sqlite3_close(db) }
    try execute(db, """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE tabs (id INTEGER PRIMARY KEY, space_id TEXT NOT NULL,
            profile_id TEXT NOT NULL, url TEXT NOT NULL, pinned_url TEXT,
            title TEXT NOT NULL, position INTEGER NOT NULL, is_open INTEGER NOT NULL);
        CREATE INDEX tabs_by_space ON tabs(space_id, position);
        CREATE TABLE selections (space_id TEXT PRIMARY KEY, tab_id INTEGER REFERENCES tabs(id));
        """)
    print("SQLite \(String(cString: sqlite3_libversion())); WAL; synchronous=FULL; 30 samples after 5 warmups")
    print("tabs,write_p50_ms,write_p95_ms,read_p50_ms,read_p95_ms")
    for count in [1, 10, 50, 100] {
        var writes: [Double] = []
        var reads: [Double] = []
        // Includes SQL preparation cost. Controlled synthetic constants only.
        let inserts = (1...count).map { index in
            "INSERT INTO tabs VALUES (\(index), 'personal', 'default', 'https://example.com/\(index)', NULL, 'Tab \(index)', \(index), 1);"
        }.joined()
        for iteration in 0..<35 {
            let writeStart = DispatchTime.now().uptimeNanoseconds
            try execute(db, "BEGIN IMMEDIATE; DELETE FROM selections; DELETE FROM tabs;"
                + inserts + "INSERT INTO selections VALUES ('personal', 1); COMMIT;")
            let writeTime = milliseconds(since: writeStart)
            let readStart = DispatchTime.now().uptimeNanoseconds
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id, url, title FROM tabs WHERE space_id = 'personal' ORDER BY position;", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw ProbeError(message: "Cannot prepare read") }
            var rows = 0
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                _ = sqlite3_column_int64(statement, 0)
                _ = String(cString: sqlite3_column_text(statement, 1))
                _ = String(cString: sqlite3_column_text(statement, 2))
                rows += 1
                status = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE, rows == count else {
                throw ProbeError(message: "Unexpected read result")
            }
            let readTime = milliseconds(since: readStart)
            if iteration >= 5 {
                writes.append(writeTime)
                reads.append(readTime)
            }
        }
        print(String(format: "%d,%.3f,%.3f,%.3f,%.3f", count,
                     percentile(writes, 0.5), percentile(writes, 0.95),
                     percentile(reads, 0.5), percentile(reads, 0.95)))
    }
}

try run()
