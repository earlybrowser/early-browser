// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Lets a local file the person opened open again after Early restarts.
/// macOS lets Early read a file someone opened (in Finder, File › Open File…
/// or by dropping it) only until Early quits; a read-only security-scoped
/// bookmark, made when they open it, keeps that permission. Kept per profile
/// beside the session, never in an export; a private window's stay in memory.
@MainActor
public final class LocalFileBookmarks {
    public enum Access: Equatable {
        /// Readable now, at this address (a moved file is followed).
        case readable(URL)
        /// Moved where no bookmark could follow, deleted, or opened before
        /// Early kept bookmarks: the person needs to open it again.
        case unavailable
    }

    public let fileURL: URL?
    /// File paths to their bookmarks.
    private(set) var bookmarks: [String: Data] = [:]
    /// Files whose permission is open, with how many pages read them.
    private var open: [String: (url: URL, readers: Int)] = [:]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return }
        bookmarks = saved
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// A file the person just opened, while macOS lets Early read it.
    public func remember(_ url: URL) {
        guard url.isFileURL,
              let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        bookmarks[Self.key(url)] = data
        save()
    }

    /// Before a page reads a local file: its permission opens, by bookmark
    /// when it has one, and the file is found where it is now.
    public func access(_ url: URL) -> Access {
        let key = Self.key(url)
        if let reading = open[key] {
            open[key] = (reading.url, reading.readers + 1)
            return .readable(reading.url)
        }
        guard let data = bookmarks[key] else {
            // Folders Early may always read, such as Downloads, need no bookmark.
            return FileManager.default.isReadableFile(atPath: url.path) ? .readable(url) : .unavailable
        }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                      bookmarkDataIsStale: &stale) else { return .unavailable }
        let started = resolved.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: resolved.path) else {
            if started { resolved.stopAccessingSecurityScopedResource() }
            return .unavailable
        }
        if started { open[key] = (resolved, 1) }
        var changed = false
        // macOS asks for a fresh bookmark now and then, as for a moved file.
        if stale, let fresh = try? resolved.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                         includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[key] = fresh
            changed = true
        }
        // A moved file's tab takes its new address, so the bookmark is kept
        // there too; the old address keeps it while anything still uses it,
        // and pruning drops whichever no tab needs.
        let moved = Self.key(resolved)
        if moved != key, bookmarks[moved] != bookmarks[key] {
            bookmarks[moved] = bookmarks[key]
            changed = true
        }
        if changed { save() }
        return .readable(resolved)
    }

    /// A page stopped reading the file; its permission closes with the last one.
    public func release(_ url: URL) {
        let key = Self.key(url)
        guard let reading = open[key] else { return }
        if reading.readers > 1 {
            open[key] = (reading.url, reading.readers - 1)
        } else {
            open[key] = nil
            reading.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Bookmarks only for files the profile's tabs still show or keep.
    public func keepOnly(_ urls: [URL]) {
        let kept = Set(urls.filter(\.isFileURL).map(Self.key))
        let pruned = bookmarks.filter { kept.contains($0.key) }
        guard pruned.count != bookmarks.count else { return }
        bookmarks = pruned
        save()
    }

    public func removeFile() {
        bookmarks.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// A bookmark that can't be written only means the file asks to be opened
    /// again after a restart, as before; nothing else depends on it.
    private func save() {
        guard let fileURL, let data = try? PropertyListEncoder().encode(bookmarks) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
