// SPDX-License-Identifier: MPL-2.0

import Foundation

public extension BrowserImportBatch {
    /// Reconcile with the durable profile catalog. Items moved to a surviving
    /// profile remain tracked; their original snapshots keep Undo conservative.
    /// Legacy journals lack folderProfiles, so use surviving IDs/Space ownership.
    func retaining(in workspace: BrowserWorkspace) -> Self? {
        let liveProfiles = Set(workspace.profiles.map(\.id))
        let windows = workspace.sessions.flatMap { [$0] + $0.additionalWindows }
        let liveTabs = Set(windows.flatMap(\.tabs).map(\.id))
        let liveSpaces = Dictionary(windows.flatMap(\.spaces).map { ($0.id, $0.profileID) }, uniquingKeysWith: { first, _ in first })
        let liveFolders = Dictionary(windows.flatMap { session in session.folders.map { ($0.id, session.profileID) } }, uniquingKeysWith: { first, _ in first })
        let originalSpaces = Dictionary(spaces.map { ($0.id, $0.profileID) }, uniquingKeysWith: { first, _ in first })
        var copy = self
        copy.profiles = profiles.filter { liveProfiles.contains($0.id) }
        copy.spaces = spaces.filter { liveProfiles.contains($0.profileID) || liveSpaces[$0.id] != nil }
        copy.tabs = tabs.filter { liveProfiles.contains($0.profileID) || liveTabs.contains($0.id) }
        copy.folders = folders.filter { folder in
            let owner = folderProfiles?[folder.id] ?? originalSpaces[folder.spaceID] ?? liveSpaces[folder.spaceID]
            return liveFolders[folder.id] != nil || owner.map { liveProfiles.contains($0) } == true
        }
        let retainedFolders = Set(copy.folders.map(\.id))
        copy.folderProfiles = folderProfiles?.filter { retainedFolders.contains($0.key) }
        copy.historyProfiles = historyProfiles.filter { liveProfiles.contains($0) }
        return copy.spaces.isEmpty && copy.tabs.isEmpty && copy.folders.isEmpty && copy.historyProfiles.isEmpty ? nil : copy
    }
}
