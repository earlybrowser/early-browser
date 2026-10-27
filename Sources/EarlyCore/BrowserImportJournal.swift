// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The session's batch marker is the commit point across separate history files.
/// A prepared import without that marker rolls back; a committed undo finishes
/// history cleanup. No rollback ever removes passwords or website data.
public actor BrowserImportJournal {
    public struct Entry: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case importing, complete, undoing }
        public var batch: BrowserImportBatch
        public var state: State
        public init(batch: BrowserImportBatch, state: State) { self.batch = batch; self.state = state }
    }
    public nonisolated let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }
        guard files.count <= 128 else { throw BrowserImportProblem.capacity }
        return try files.map { file in
            let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true, (info.fileSize ?? .max) <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
            return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
        }.sorted { $0.batch.createdAt > $1.batch.createdAt }
    }
    public func write(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(entry)
        guard bytes.count <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        try bytes.write(to: path(entry.batch.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path(entry.batch.id).path)
        let handle = try FileHandle(forWritingTo: path(entry.batch.id))
        defer { try? handle.close() }
        try handle.synchronize()
    }
    public func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: path(id)) }
    private func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    public func recover(workspace: BrowserWorkspace, historyDirectory: URL) async throws -> [BrowserImportBatch] {
        let committed = Set(workspace.browserImportBatchIDs ?? [])
        var available: [BrowserImportBatch] = []
        for var entry in try entries() {
            if committed.contains(entry.batch.id) {
                if entry.state != .complete { entry.state = .complete; try write(entry) }
                available.append(entry.batch)
            } else {
                for profile in entry.batch.historyProfiles {
                    let file = historyDirectory.appendingPathComponent(profile.uuidString + ".sqlite")
                    if FileManager.default.fileExists(atPath: file.path) {
                        let store = HistoryStore(fileURL: file)
                        try await store.undoBrowserImport(entry.batch.id); await store.close()
                    }
                }
                try remove(entry.batch.id)
            }
        }
        return available
    }
}
