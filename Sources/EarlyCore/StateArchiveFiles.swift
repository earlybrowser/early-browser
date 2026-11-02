// SPDX-License-Identifier: MPL-2.0

import Foundation

extension EarlyStateArchive {
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

    public static func write(workspace: BrowserWorkspace, settings: PortableSettings?, to url: URL) throws {
        let data = try EarlyStateArchive(workspace: workspace, settings: settings).encoded()
        guard data.count <= maximumSize else { throw Problem.tooLarge }
        try Task.checkCancellation()
        try BackgroundFileIO.writeSynchronously(data, to: url)
    }

    public static func backup(workspace: BrowserWorkspace, settings: PortableSettings?, in directory: URL,
                              retaining limit: Int) throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = directory.appendingPathComponent("Before Import \(formatter.string(from: Date())) \(UUID()).json")
        try write(workspace: workspace, settings: settings, to: file)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("Before Import ") && $0.pathExtension == "json" }
            .sorted {
                // Several imports can finish in one displayed second. UUID
                // suffixes do not express age; always retain this new backup.
                if $0.lastPathComponent == file.lastPathComponent { return false }
                if $1.lastPathComponent == file.lastPathComponent { return true }
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
            }
        for old in backups.dropLast(max(1, limit)) { try? FileManager.default.removeItem(at: old) }
        return file
    }
}
