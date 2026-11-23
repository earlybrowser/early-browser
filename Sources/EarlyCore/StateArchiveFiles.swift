// SPDX-License-Identifier: MPL-2.0

import Foundation

extension EarlyStateArchive {
    private static let backupLock = NSLock()

    /// These operations are synchronous worker bodies; their app callers use
    /// BackgroundFileIO.run so encoding, decoding and disk access stay off UI.
    public static func read(from url: URL, using input: NavigationInput) throws -> Self {
        let data: Data
        do { data = try BackgroundFileIO.read(url, maximumBytes: maximumSize) }
        catch let error as CocoaError where error.code == .fileReadTooLarge { throw Problem.tooLarge }
        catch is CancellationError { throw CancellationError() }
        catch { throw Problem.notAnArchive }
        try Task.checkCancellation()
        let result = try decode(data, using: input)
        try Task.checkCancellation()
        return result
    }

    public static func write(workspace: BrowserWorkspace, settings: PortableSettings?, to url: URL,
                             using input: NavigationInput = NavigationInput()) throws {
        let data = try EarlyStateArchive(workspace: workspace, settings: settings).encoded(using: input)
        try BackgroundFileIO.writeSynchronously(data, to: url)
    }

    public static func backup(workspace: BrowserWorkspace, settings: PortableSettings?, in directory: URL,
                              retaining limit: Int = 5, id: UUID = UUID(),
                              using input: NavigationInput = NavigationInput()) throws -> URL {
        let archive = EarlyStateArchive(workspace: workspace, settings: settings)
        let data = try archive.encoded(using: input)
        // Both import paths share one directory. Finish each write and prune
        // together so a concurrent backup cannot race its retention pass.
        return try backupLock.withLock {
            try Task.checkCancellation()
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let file = directory.appendingPathComponent("Before Import \(formatter.string(from: archive.exportedAt)) \(id).json")
            try BackgroundFileIO.writeSynchronously(data, to: file)
            try pruneBackups(in: directory, keeping: file, retaining: limit)
            return file
        }
    }

    private static func pruneBackups(in directory: URL, keeping newest: URL, retaining limit: Int) throws {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        // Earlier versions used no suffix or four hex digits. Both current
        // import paths use full UUIDs. Leave unrelated entries and links alone.
        let namePattern = #"\ABefore Import [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\.[0-9]{2}\.[0-9]{2}(?: (?:[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}))?\.json\z"#
        let earlier = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .compactMap { url -> (url: URL, modified: Date)? in
                guard url.lastPathComponent != newest.lastPathComponent,
                      url.lastPathComponent.range(of: namePattern, options: .regularExpression) != nil,
                      let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink == false, let modified = values.contentModificationDate else { return nil }
                return (url, modified)
            }
            .sorted { ($0.modified, $0.url.lastPathComponent) > ($1.modified, $1.url.lastPathComponent) }
        for backup in earlier.dropFirst(max(1, limit) - 1) { try? files.removeItem(at: backup.url) }
    }
}
