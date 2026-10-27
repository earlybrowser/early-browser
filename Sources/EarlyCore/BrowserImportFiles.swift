// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3

/// Call on a worker task while the app holds user-selected folder access.
public enum BrowserImportFiles {
    /// Safari's unpacked export is selected as one batch. Other JSON exports,
    /// password CSVs and extension lists never enter this import route.
    public static func readSafariExports(_ urls: [URL]) throws -> BrowserImportDocument {
        guard !urls.isEmpty, urls.count <= 64,
              Set(urls.map(\.standardizedFileURL)).count == urls.count else { throw BrowserImportProblem.capacity }
        var result = BrowserImportDocument(source: "Safari"), totalBytes = 0
        var shared: [String] = []
        for (index, url) in urls.sorted(by: { $0.path < $1.path }).enumerated() {
            try Task.checkCancellation()
            let type = url.pathExtension.lowercased()
            guard ["html", "htm", "json"].contains(type) else {
                throw BrowserImportProblem.unsupported("Choose Safari’s exported bookmarks HTML and history JSON files only. Passwords, extensions and credit cards aren’t imported here.")
            }
            let data = try bounded(url)
            totalBytes += data.count
            guard totalBytes <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
            var document: BrowserImportDocument
            let prefix = "safari.file.\(index)."
            if type == "json" {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["metadata"] as? [String: Any])?["data_type"] as? String == "history" else {
                    throw BrowserImportProblem.unsupported("Choose Safari’s history JSON, not its extensions or credit-card export. Passwords use the separate import in Settings → Passwords.")
                }
                let stem = url.deletingPathExtension().lastPathComponent
                let suffix = [" — ", " – ", " - "].compactMap { separator in
                    stem.range(of: separator).map { String(stem[$0.upperBound...]) }
                }.first
                let name = suffix?.isEmpty == false ? suffix! : "Safari profile"
                document = try BrowserImportReaders.read(data, name: String(name.prefix(64)))
                document.nodes[0].detail = url.lastPathComponent
            } else {
                document = try BrowserImportReaders.bookmarksHTML(data, name: "Safari")
                let root = prefix + "shared"
                let stem = url.deletingPathExtension().lastPathComponent
                let readingList = stem.replacingOccurrences(of: " ", with: "").lowercased() == "readinglist"
                result.nodes.append(.init(id: root, kind: .category, title: readingList ? "Reading List" : "Bookmarks", detail: url.lastPathComponent))
                shared.append(root)
                let wrapper = root + ".readingList"
                let hasWrapper = document.nodes.contains { $0.parentID == "profile" && $0.kind == .folder && $0.title.replacingOccurrences(of: " ", with: "").lowercased() == "readinglist" }
                if readingList && !hasWrapper { result.nodes.append(.init(id: wrapper, parentID: root, kind: .folder, title: "Reading List")) }
                for var node in document.nodes where node.kind != .profile {
                    node.id = prefix + node.id
                    node.parentID = node.parentID == "profile" ? (readingList && !hasWrapper ? wrapper : root) : node.parentID.map { prefix + $0 }
                    result.nodes.append(node)
                }
                result.notices += document.notices
                guard result.nodes.count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
                continue
            }
            for var node in document.nodes {
                node.id = prefix + node.id; node.parentID = node.parentID.map { prefix + $0 }
                result.nodes.append(node)
            }
            result.notices += document.notices
            guard result.nodes.count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
        }
        if !result.nodes.contains(where: { $0.kind == .profile }) {
            result.nodes.insert(.init(id: "safari.profile", kind: .profile, title: "Safari"), at: 0)
        }
        let profiles = result.nodes.filter { $0.kind == .profile }.map(\.id)
        for id in shared {
            result.collections.append(.init(id: id, profileIDs: profiles, defaultProfileIDs: profiles.count == 1 ? Set(profiles) : [],
                explanation: "Safari shares this collection across profiles. Choose which Early profiles receive independent copies. Favorites folders keep their organization; choose their intended destinations in the preview."))
        }
        result.notices = Array(Set(result.notices)).sorted()
        try result.validate()
        return result
    }

    /// The Chromium folder route is deliberately history-only. Bookmark files
    /// and session storage are not even read by this route.
    public static func readChromiumHistory(_ url: URL, source: String) throws -> BrowserImportDocument {
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw BrowserImportProblem.invalid }
        return try profileFolder(url, source: source, historyOnly: true)
    }

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

    static func bounded(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard info.isSymbolicLink != true, info.isRegularFile == true,
              let size = info.fileSize, size <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: BrowserImportDocument.maximumBytes + 1) ?? Data()
        guard data.count <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        return data
    }

    private static func profileFolder(_ url: URL, source: String, depth: Int = 0, historyOnly: Bool = false) throws -> BrowserImportDocument {
        guard depth < 4 else { throw BrowserImportProblem.capacity }
        var documents: [BrowserImportDocument] = []
        var count = 0
        func append(_ document: BrowserImportDocument) throws {
            count += document.nodes.count
            guard count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            documents.append(document)
        }
        // Only approved organization files are examined, never Login Data, Cookies, or Preferences.
        let files = historyOnly ? ["History"] : ["StorableSidebar.json", "Bookmarks", "places.sqlite", "History", "zen-sessions.jsonlz4", "sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4"]
        for name in files {
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
        if !historyOnly, FileManager.default.fileExists(atPath: encrypted.path) {
            try append(.init(source: source, notices: ["Current Chromium session storage is encrypted. Open tabs and groups are unavailable here; save them as bookmarks and export HTML instead. Older cleartext files alongside encrypted sessions are not imported as current tabs."]))
        } else if !historyOnly, FileManager.default.fileExists(atPath: clear.path) {
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
                    return try profileFolder(nested, source: source, depth: depth + 1, historyOnly: historyOnly)
                }
            }
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard children.count <= 512 else { throw BrowserImportProblem.capacity }
            let candidates = children.filter { child in
                guard let info = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      info.isDirectory == true, info.isSymbolicLink != true else { return false }
                return (historyOnly ? ["History"] : ["Bookmarks", "places.sqlite", "zen-sessions.jsonlz4", "History"]).contains { FileManager.default.fileExists(atPath: child.appendingPathComponent($0).path) }
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard candidates.count <= 32 else { throw BrowserImportProblem.capacity }
            var profileNames: [String: String] = [:]
            let localState = url.appendingPathComponent("Local State")
            if FileManager.default.fileExists(atPath: localState.path),
               let json = try JSONSerialization.jsonObject(with: bounded(localState)) as? [String: Any],
               let profile = json["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] {
                profileNames = cache.compactMapValues { $0["name"] as? String }
            }
            for child in candidates { try append(profileFolder(child, source: profileNames[child.lastPathComponent] ?? child.lastPathComponent, depth: depth + 1, historyOnly: historyOnly)) }
            guard !documents.isEmpty else { throw BrowserImportProblem.unsupported(historyOnly
                ? "No browser history was found. Select the browser’s saved-data folder or a profile folder containing History."
                : "Select the browser’s profile folder or a bookmarks HTML export.") }
            return try combine(documents, source: source)

        }
        guard !documents.isEmpty else {
            throw BrowserImportProblem.unsupported("No verified browser organization was found in this folder. Select a profile folder or export bookmarks as HTML. Dia’s proprietary workspace formats are not assumed to match Chromium bookmarks.")
        }
        var result = try combine(documents, source: source, mergeProfile: true)
        for index in result.nodes.indices where result.nodes[index].kind == .profile {
            result.nodes[index].detail = String(url.lastPathComponent.prefix(255))
        }
        if historyOnly { return result }
        let firefox = ["places.sqlite", "zen-sessions.jsonlz4", "sessionstore.jsonlz4", "sessionstore-backups/recovery.jsonlz4"].contains {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
        if firefox {
            try configureFirefoxProfile(&result, at: url)
        }
        if url.pathComponents.contains("Dia") || source.localizedCaseInsensitiveContains("Dia") {
            result.notices.append("Dia’s Chromium bookmarks and history are verified. Proprietary workspace organization has no verified format here; export those links as bookmarks HTML. Names inferred from profile folders can be changed in Destinations.")
        }
        if !firefox { result.notices.append("Encrypted Chromium session files are not decrypted. If open tabs or groups are not listed, save them as bookmarks in the source browser and export HTML instead.") }
        return result
    }

    static func combine(_ documents: [BrowserImportDocument], source: String, mergeProfile: Bool = false) throws -> BrowserImportDocument {
        var result = BrowserImportDocument(source: source)
        var mergedProfiles = Set<String>()
        for (index, document) in documents.enumerated() {
            guard result.nodes.count + document.nodes.count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            let prefix = "\(index)."
            let localProfiles = Set(document.nodes.filter { mergeProfile && $0.kind == .profile && ($0.id == "profile" || $0.id.hasPrefix("container.")) }.map(\.id))
            func remap(_ id: String) -> String { localProfiles.contains(id) ? id : prefix + id }
            for var node in document.nodes {
                if localProfiles.contains(node.id), !mergedProfiles.insert(node.id).inserted { continue }
                node.id = remap(node.id)
                node.parentID = node.parentID.map(remap)
                result.nodes.append(node)
            }
            for var collection in document.collections {
                collection.id = remap(collection.id)
                collection.profileIDs = collection.profileIDs.map(remap)
                collection.defaultProfileIDs = Set(collection.defaultProfileIDs.map(remap))
                result.collections.append(collection)
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
        let contextualHistory = try firefox && query(copy, "PRAGMA table_info(moz_historyvisits)").contains { $0[1] == "userContextId" }
        let sql = firefox
            ? "SELECT p.url,p.title,v.visit_date\(contextualHistory ? ",v.userContextId" : "") FROM moz_historyvisits v JOIN moz_places p ON p.id=v.place_id WHERE v.visit_date>=?1 ORDER BY v.visit_date DESC,v.id DESC LIMIT 50001"
            : "SELECT u.url,u.title,v.visit_time FROM visits v JOIN urls u ON u.id=v.url WHERE v.visit_time>=?1 ORDER BY v.visit_time DESC,v.id DESC LIMIT 50001"
        let cutoff = (Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970 + (firefox ? 0 : 11_644_473_600)) * 1_000_000
        let visits = try query(copy, sql, minimumTime: cutoff)
        if visits.count > BrowserImportDocument.maximumVisits {
            builder.document.notices.append("History preview contains the latest 50,000 known visits within Early’s one-year retention period. Use a smaller export to select older visits within that period.")
        }
        for row in visits.prefix(BrowserImportDocument.maximumVisits) {
            guard let value = Double(row[2]) else { continue }
            let seconds = value / 1_000_000 - (firefox ? 0 : 11_644_473_600)
            let profile = try builder.context(contextualHistory ? (Int(row[3]) ?? 0) : 0)
            try builder.visit(row[0], title: row[1], time: Date(timeIntervalSince1970: seconds), profile: profile)
        }
        if firefox { builder.document.addFirefoxCollections() }
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
