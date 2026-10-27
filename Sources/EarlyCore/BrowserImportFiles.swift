// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3

/// Call on a worker task while the app holds user-selected folder access.
public enum BrowserImportFiles {
    public static func read(_ url: URL, source: String) throws -> BrowserImportDocument {
        try Task.checkCancellation()
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true else { throw BrowserImportProblem.invalid }
        if info.isDirectory == true { return try profileFolder(url, source: source) }
        if url.pathExtension.lowercased() == "sqlite" || url.lastPathComponent == "History" {
            return try database(url, source: source, firefox: url.lastPathComponent != "History")
        }
        let data = try bounded(url)
        if url.pathExtension.lowercased() == "zip" {
            var documents: [BrowserImportDocument] = []
            for entry in try BrowserImportZIP.entries(data) {
                if ["html", "htm"].contains(URL(fileURLWithPath: entry.name).pathExtension.lowercased()) {
                    documents.append(try BrowserImportReaders.read(entry.data, name: source))
                } else if let header = try? JSONSerialization.jsonObject(with: entry.data) as? [String: Any],
                          (header["metadata"] as? [String: Any])?["data_type"] as? String == "history" {
                    documents.append(try BrowserImportReaders.read(entry.data, name: String(URL(fileURLWithPath: entry.name).deletingPathExtension().lastPathComponent.prefix(64))))
                }
            }
            guard !documents.isEmpty else { throw BrowserImportProblem.invalid }
            var result = try combine(documents, source: source)
            result.notices.append("Safari exports one bookmarks collection and separate history files for profiles. They remain separate in this preview because the export has no shared profile identity; map them together only when appropriate. Reading List imports as an ordinary folder.")
            return result
        }
        return try BrowserImportReaders.read(data, name: source)
    }

    private static func bounded(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard info.isSymbolicLink != true, info.isRegularFile == true,
              let size = info.fileSize, size <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: BrowserImportDocument.maximumBytes + 1) ?? Data()
        guard data.count <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        return data
    }

    private static func profileFolder(_ url: URL, source: String, depth: Int = 0) throws -> BrowserImportDocument {
        guard depth < 4 else { throw BrowserImportProblem.capacity }
        var documents: [BrowserImportDocument] = []
        var count = 0
        func append(_ document: BrowserImportDocument) throws {
            count += document.nodes.count
            guard count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            documents.append(document)
        }
        // Only approved organization files are examined, never Login Data, Cookies, or Preferences.
        for name in ["StorableSidebar.json", "Bookmarks", "places.sqlite", "History", "zen-sessions.jsonlz4", "sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4"] {
            let file = url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard file.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().path + "/") else { throw BrowserImportProblem.invalid }
            if name == "History" || name == "places.sqlite" {
                try append(database(file, source: source, firefox: name == "places.sqlite"))
            } else { try append(BrowserImportReaders.read(bounded(file), name: source)) }
            if name == "zen-sessions.jsonlz4" || name == "sessionstore.jsonlz4" { break }
        }
        let encrypted = url.appendingPathComponent("Sessions_Encrypted")
        let clear = url.appendingPathComponent("Sessions")
        if FileManager.default.fileExists(atPath: encrypted.path) {
            try append(.init(source: source, notices: ["Current Chromium session storage is encrypted. Open tabs and groups are unavailable here; save them as bookmarks and export HTML instead. Older cleartext files alongside encrypted sessions are not imported as current tabs."]))
        } else if FileManager.default.fileExists(atPath: clear.path) {
            let info = try clear.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw BrowserImportProblem.invalid }
            let files = try FileManager.default.contentsOfDirectory(at: clear, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Session_") && UInt64($0.lastPathComponent.dropFirst(8)) != nil }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard files.count <= 128 else { throw BrowserImportProblem.capacity }
            if let file = files.last { try append(BrowserImportReaders.read(bounded(file), name: source)) }
        }
        if documents.isEmpty {
            for name in ["Profiles", "User Data"] {
                let nested = url.appendingPathComponent(name)
                if let info = try? nested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), info.isDirectory == true, info.isSymbolicLink != true {
                    return try profileFolder(nested, source: source, depth: depth + 1)
                }
            }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard children.count <= 512 else { throw BrowserImportProblem.capacity }
            let candidates = children.filter { child in
                guard let info = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      info.isDirectory == true, info.isSymbolicLink != true else { return false }
                return ["Bookmarks", "places.sqlite", "zen-sessions.jsonlz4", "History"].contains { FileManager.default.fileExists(atPath: child.appendingPathComponent($0).path) }
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard candidates.count <= 32 else { throw BrowserImportProblem.capacity }
            var profileNames: [String: String] = [:]
            let localState = url.appendingPathComponent("Local State")
            if FileManager.default.fileExists(atPath: localState.path),
               let json = try JSONSerialization.jsonObject(with: bounded(localState)) as? [String: Any],
               let profile = json["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] {
                profileNames = cache.compactMapValues { $0["name"] as? String }
            }
            for child in candidates { try append(profileFolder(child, source: profileNames[child.lastPathComponent] ?? child.lastPathComponent, depth: depth + 1)) }
            guard !documents.isEmpty else { throw BrowserImportProblem.unsupported("Select the browser’s profile folder or a bookmarks HTML export.") }
            return try combine(documents, source: source)

        }
        guard !documents.isEmpty else {
            throw BrowserImportProblem.unsupported("No verified browser organization was found in this folder. Select a profile folder or export bookmarks as HTML. Dia’s proprietary workspace formats are not assumed to match Chromium bookmarks.")
        }
        var result = try combine(documents, source: source, mergeProfile: true)
        if url.pathComponents.contains("Dia") || source.localizedCaseInsensitiveContains("Dia") {
            result.notices.append("Dia’s Chromium bookmarks and history are verified. Proprietary workspace organization has no verified format here; export those links as bookmarks HTML. Names inferred from profile folders can be changed in Destinations.")
        }
        result.notices.append("Encrypted Chromium session files are not decrypted. If open tabs or groups are not listed, save them as bookmarks in the source browser and export HTML instead.")
        return result
    }

    static func combine(_ documents: [BrowserImportDocument], source: String, mergeProfile: Bool = false) throws -> BrowserImportDocument {
        var result = BrowserImportDocument(source: source)
        for (index, document) in documents.enumerated() {
            guard result.nodes.count + document.nodes.count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            let prefix = "\(index)."
            for var node in document.nodes {
                if mergeProfile, node.id == "profile", result.nodes.contains(where: { $0.id == "profile" }) { continue }
                node.id = mergeProfile && node.id == "profile" ? "profile" : prefix + node.id
                node.parentID = node.parentID.map { mergeProfile && $0 == "profile" ? "profile" : prefix + $0 }
                result.nodes.append(node)
            }
            result.notices.append(contentsOf: document.notices)
        }
        result.notices = Array(Set(result.notices)).sorted()
        try result.validate(); return result
    }

    /// Online backup produces one coherent read snapshot, even with an active WAL.
    public static func database(_ url: URL, source: String, firefox: Bool) throws -> BrowserImportDocument {
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? 0) <= 1024 * 1024 * 1024 else { throw BrowserImportProblem.capacity }
        var original: OpaquePointer?, copy: OpaquePointer?
        guard sqlite3_open_v2(url.path, &original, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let original { sqlite3_close(original) }
            throw BrowserImportProblem.unsupported("The source database cannot be read. Quit that browser and select its profile folder again, or use its export option.")
        }
        defer { sqlite3_close(original) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyBrowserImport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(temporary.appendingPathComponent("snapshot.sqlite").path, &copy) == SQLITE_OK, let copy else {
            if let copy { sqlite3_close(copy) }; try? FileManager.default.removeItem(at: temporary)
            throw BrowserImportProblem.invalid
        }
        defer { sqlite3_close(copy); try? FileManager.default.removeItem(at: temporary) }
        sqlite3_limit(copy, SQLITE_LIMIT_LENGTH, 64 * 1024)
        sqlite3_progress_handler(copy, 10_000, { _ in Task.isCancelled ? 1 : 0 }, nil)

        guard let backup = sqlite3_backup_init(copy, "main", original, "main") else { throw BrowserImportProblem.invalid }
        var status: Int32 = SQLITE_OK, retries = 0
        repeat {
            if Task.isCancelled { sqlite3_backup_finish(backup); throw CancellationError() }
            status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { retries += 1; Thread.sleep(forTimeInterval: 0.02) }
        } while status == SQLITE_OK || ((status == SQLITE_BUSY || status == SQLITE_LOCKED) && retries < 10)
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else {
            throw BrowserImportProblem.unsupported("The source database is busy. Quit the source browser, then try again.")
        }
        var builder = BrowserImportReaders.Builder(name: source)
        if firefox {
            let rows = try query(copy, "SELECT b.id,b.parent,b.type,b.title,p.url,b.position FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id=b.fk ORDER BY b.position,b.id LIMIT 80001")
            guard rows.count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            let ids = Set(rows.map { $0[0] })
            let roots = Set(rows.filter { !ids.contains($0[1]) || $0[1] == $0[0] }.map { $0[0] })
            for row in rows where !roots.contains(row[0]) {
                let parent = ids.contains(row[1]) && !roots.contains(row[1]) && row[1] != row[0] ? "bookmark." + row[1] : "profile"
                if row[2] == "2" {
                    builder.document.nodes.append(.init(id: "bookmark." + row[0], parentID: parent, kind: .folder, title: row[3], order: Int(row[5])))
                } else if row[2] == "1", let url = BrowserImportDocument.webURL(row[4]) {
                    builder.document.nodes.append(.init(id: "bookmark." + row[0], parentID: parent, kind: .bookmark, title: row[3], url: url, order: Int(row[5])))
                }
            }
        }
        let sql = firefox
            ? "SELECT p.url,p.title,v.visit_date FROM moz_historyvisits v JOIN moz_places p ON p.id=v.place_id WHERE v.visit_date>=?1 ORDER BY v.visit_date DESC,v.id DESC LIMIT 50001"
            : "SELECT u.url,u.title,v.visit_time FROM visits v JOIN urls u ON u.id=v.url WHERE v.visit_time>=?1 ORDER BY v.visit_time DESC,v.id DESC LIMIT 50001"
        let cutoff = (Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970 + (firefox ? 0 : 11_644_473_600)) * 1_000_000
        let visits = try query(copy, sql, minimumTime: cutoff)
        if visits.count > BrowserImportDocument.maximumVisits {
            builder.document.notices.append("History preview contains the latest 50,000 known visits within Early’s one-year retention period. Use a smaller export to select older visits within that period.")
        }
        for row in visits.prefix(BrowserImportDocument.maximumVisits) {
            guard let value = Double(row[2]) else { continue }
            let seconds = value / 1_000_000 - (firefox ? 0 : 11_644_473_600)
            try builder.visit(row[0], title: row[1], time: Date(timeIntervalSince1970: seconds))
        }
        try builder.document.validate(); return builder.document
    }

    private static func query(_ db: OpaquePointer, _ sql: String, minimumTime: Double? = nil) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw BrowserImportProblem.invalid }
        defer { sqlite3_finalize(statement) }
        if let minimumTime { sqlite3_bind_double(statement, 1, minimumTime) }
        var rows: [[String]] = [], totalBytes = 0
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw BrowserImportProblem.invalid }
            var row: [String] = []
            for column in 0..<sqlite3_column_count(statement) {
                let length = Int(sqlite3_column_bytes(statement, column))
                totalBytes += length
                guard totalBytes <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
                row.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            }
            rows.append(row)
        }
    }
}
