// SPDX-License-Identifier: MPL-2.0

import Foundation

public struct BrowserImportDestination: Equatable, Sendable {
    public var profileID: UUID?
    public var profileName: String
    public var spaceID: UUID?
    public var spaceName: String
    /// Explicitly combine source groups into one newly created profile.
    /// A display name alone never establishes shared identity.
    public var newProfileGroup: String?
    public init(profileID: UUID? = nil, profileName: String, spaceID: UUID? = nil, spaceName: String, newProfileGroup: String? = nil) {
        self.profileID = profileID; self.profileName = profileName; self.spaceID = spaceID; self.spaceName = spaceName
        self.newProfileGroup = newProfileGroup
    }
}

/// Exactly the records created, retained outside portable archives for selective undo.
public struct BrowserImportBatch: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var source: String
    public var createdAt: Date
    public var profiles: [BrowserProfile] = []
    public var spaces: [BrowserSpace] = []
    public var folders: [BrowserFolder] = []
    public var tabs: [BrowserTab] = []
    public var historyProfiles: [UUID] = []
    public var folderProfiles: [UUID: UUID]?
    public init(id: UUID = UUID(), source: String, createdAt: Date = Date()) {
        self.id = id; self.source = source; self.createdAt = createdAt
    }
}

public struct BrowserImportCandidate: Sendable {
    public var workspace: BrowserWorkspace
    public var batch: BrowserImportBatch
    public var history: [UUID: [BrowserImportNode]]
    public var flattened: [String]
    public var skippedHistoryCount = 0

    /// Rebase the additive delta onto live state after disk I/O. Page metadata,
    /// selections and unrelated windows may have changed while saving.
    public func adding(to current: BrowserWorkspace, using input: NavigationInput = NavigationInput()) throws -> BrowserWorkspace {
        var merged = current
        let existingProfiles = Set(current.profiles.map(\.id))
        for profile in workspace.profiles where !existingProfiles.contains(profile.id) {
            merged.profiles.append(profile)
            merged.sessions.append(workspace.session(for: profile.id)!)
        }
        for index in merged.sessions.indices where existingProfiles.contains(merged.sessions[index].profileID) {
            var root = merged.sessions[index]
            let profile = root.profileID
            guard workspace.session(for: profile) != nil else { continue }
            let newSpaces = batch.spaces.filter { $0.profileID == profile }
            let newSpaceIDs = Set(newSpaces.map(\.id))
            let oldSpaceIDs = Set(root.spaces.map(\.id))
            let newFolders = batch.folders.filter { folder in
                newSpaceIDs.contains(folder.spaceID) || oldSpaceIDs.contains(folder.spaceID)
            }
            let newTabs = batch.tabs.filter { $0.profileID == profile }
            root.spaces.append(contentsOf: newSpaces.filter { value in !root.spaces.contains { $0.id == value.id } })
            root.folders.append(contentsOf: newFolders)
            root.tabs.append(contentsOf: newTabs)
            let imported = Set(batch.tabs.map(\.id) + batch.folders.map(\.id))
            BrowserImportOrdering.append(in: &root, after: current.sessions[index], imported: imported)
            for w in root.additionalWindows.indices {
                root.additionalWindows[w].spaces = root.spaces
                root.additionalWindows[w].folders = root.folders
                root.additionalWindows[w].tabs.append(contentsOf: newTabs.filter { $0.pinnedURL != nil })
                let rootCopy = root
                BrowserImportOrdering.synchronizePositions(from: rootCopy, to: &root.additionalWindows[w])
            }
            merged.sessions[index] = root
        }
        merged.browserImportBatchIDs = (current.browserImportBatchIDs ?? []) + [batch.id]
        try merged.validate(using: input); return merged
    }
}

public extension BrowserImportDocument {
    /// Destination keys are source Spaces, or the source profile for loose items.
    var destinationGroups: [BrowserImportNode] { nodes.filter { $0.kind == .profile || $0.kind == .space } }

    func destinationGroups(selecting selected: Set<String>) -> [BrowserImportNode] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var groups = Set<String>()
        for id in selected {
            var current = byID[id]
            while let node = current {
                if node.kind == .space || node.kind == .profile { groups.insert(node.id); break }
                current = node.parentID.flatMap { byID[$0] }
            }
        }
        return destinationGroups.filter { groups.contains($0.id) }
    }

    func candidate(into current: BrowserWorkspace, selecting selected: Set<String>,
                   destinations: [String: BrowserImportDestination], flattenDeepFolders: Bool = false,
                   collectionTargets: [String: Set<String>] = [:],
                   using input: NavigationInput = NavigationInput()) throws -> BrowserImportCandidate {
        try validate()
        if !collections.isEmpty {
            let resolved = try resolvingCollections(selecting: selected, targets: collectionTargets, destinations: destinations)
            return try resolved.document.candidate(into: current, selecting: resolved.selected, destinations: destinations,
                flattenDeepFolders: flattenDeepFolders, using: input)
        }
        let included = included(selected)
        guard !selected.isEmpty else { throw BrowserImportProblem.invalid }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var result = BrowserImportCandidate(workspace: current, batch: .init(source: source), history: [:], flattened: [])
        var profileMap: [[String]: UUID] = [:]
        var spaceMap: [String: UUID] = [:], folderMap: [String: UUID] = [:]
        var initialSpaceUsed = Set<UUID>(), initialSpaceRecord: [UUID: Int] = [:]
        var positions: [String: Int] = [:]
        func positionKey(_ space: UUID, _ folder: UUID?) -> String { space.uuidString + (folder?.uuidString ?? "root") }
        func allocate(_ space: UUID, _ folder: UUID?) throws -> Int {
            let key = positionKey(space, folder)
            let (next, overflow) = positions[key, default: 0].addingReportingOverflow(1)
            guard !overflow else { throw BrowserImportProblem.capacity }
            positions[key] = next
            return next
        }
        func ancestors(_ node: BrowserImportNode) -> [BrowserImportNode] {
            var path = [node], parent = node.parentID
            while let id = parent, let next = byID[id] { path.append(next); parent = next.parentID }
            return path
        }
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let children = Dictionary(grouping: nodes, by: \.parentID).mapValues { values in
            values.sorted { ($0.order ?? indices[$0.id]!, indices[$0.id]!) < ($1.order ?? indices[$1.id]!, indices[$1.id]!) }
        }
        var ordered: [BrowserImportNode] = [], pending = Array((children[nil] ?? []).reversed())
        while let node = pending.popLast() {
            ordered.append(node); pending += (children[node.id] ?? []).reversed()
        }
        let parents = Set(nodes.compactMap(\.parentID))
        let now = Date()
        for node in ordered where included.contains(node.id) && ![.profile, .category].contains(node.kind) {
            try Task.checkCancellation()
            if node.kind == .space && (!selected.contains(node.id) || parents.contains(node.id)) { continue }
            if node.kind == .history, let date = node.visitedAt,
               date < now.addingTimeInterval(-365 * 86_400) || date > now.addingTimeInterval(300) {
                result.skippedHistoryCount += 1; continue
            }
            let path = ancestors(node)
            guard let sourceProfile = path.first(where: { $0.kind == .profile }) else { throw BrowserImportProblem.invalid }
            let group = path.first(where: { $0.kind == .space }) ?? sourceProfile
            guard var destination = destinations[group.id] ?? destinations[sourceProfile.id] else { throw BrowserImportProblem.missingDestination }
            if let shared = destination.newProfileGroup {
                guard byID[shared]?.kind == .profile, let canonical = destinations[shared], canonical.newProfileGroup == nil,
                      canonical.profileID == nil else { throw BrowserImportProblem.missingDestination }
                destination.profileName = canonical.profileName
                if group.kind == .profile { destination.spaceID = canonical.spaceID; destination.spaceName = canonical.spaceName }
            }
            let spaceGroup = group.kind == .profile ? (destination.newProfileGroup ?? group.id) : group.id
            let profileKey = [destination.newProfileGroup ?? sourceProfile.id, destination.profileName]
            let profile: UUID
            if let id = destination.profileID {
                guard result.workspace.profiles.contains(where: { $0.id == id }) else { throw BrowserImportProblem.missingDestination }
                profile = id
            } else if let id = profileMap[profileKey] { profile = id }
            else {
                guard result.workspace.profiles.count < EarlyStateArchive.maximumProfiles else { throw BrowserImportProblem.capacity }
                let name = EarlyStateArchive.uniqueName(destination.profileName, in: result.workspace.profiles)
                guard let id = result.workspace.createProfile(name: name, color: sourceProfile.color ?? .blue) else { throw BrowserImportProblem.invalid }
                profileMap[profileKey] = id; profile = id
                result.batch.profiles.append(result.workspace.profiles.last!)
                initialSpaceRecord[profile] = result.batch.spaces.count
                result.batch.spaces.append(result.workspace.sessions.last!.spaces[0])
            }
            guard let sessionIndex = result.workspace.sessions.firstIndex(where: { $0.profileID == profile }) else { throw BrowserImportProblem.missingDestination }
            let space: UUID
            if node.kind == .history || node.kind == .favorite {
                space = result.workspace.sessions[sessionIndex].activeSpaceID
            } else if let id = destination.spaceID {
                guard result.workspace.sessions[sessionIndex].spaces.contains(where: { $0.id == id }) else { throw BrowserImportProblem.missingDestination }
                space = id
            } else if let id = spaceMap[spaceGroup + profile.uuidString] { space = id }
            else {
                let name = BrowserSpace.normalizedName(String(destination.spaceName.prefix(64))) ?? "Imported"
                // A new profile already has a first Space; reuse it for its first source group.
                let created: BrowserSpace
                if let record = initialSpaceRecord[profile], initialSpaceUsed.insert(profile).inserted {
                    space = result.workspace.sessions[sessionIndex].activeSpaceID
                    result.workspace.sessions[sessionIndex].spaces[0].name = name
                    result.workspace.sessions[sessionIndex].spaces[0].color = group.color ?? .blue
                    result.workspace.sessions[sessionIndex].spaces[0].icon = group.icon
                    created = result.workspace.sessions[sessionIndex].spaces[0]
                    result.batch.spaces[record] = created
                } else {
                    created = BrowserSpace(profileID: profile, name: name, color: group.color ?? .blue, icon: group.icon)
                    space = created.id
                    result.workspace.sessions[sessionIndex].spaces.append(created)
                    result.batch.spaces.append(created)
                }
                spaceMap[spaceGroup + profile.uuidString] = space
            }
            let sourceFolders = path.filter { $0.kind == .folder }.reversed()
            var parent: UUID?
            var depth = 0
            for folder in sourceFolders {
                if let id = folderMap[folder.id + profile.uuidString + space.uuidString] { parent = id; depth += 1; continue }
                guard depth <= BrowserFolder.maximumNestingDepth else {
                    if flattenDeepFolders { result.flattened.append(folder.title); continue }
                    throw BrowserImportProblem.tooDeep(path.reversed().filter { $0.kind == .folder }.map(\.title).joined(separator: " › "))
                }
                var created = BrowserFolder(spaceID: space, parentID: parent, name: String(folder.title.prefix(128)), icon: folder.icon)
                created.sidebarPosition = try allocate(space, parent)
                result.workspace.sessions[sessionIndex].folders.append(created); result.batch.folders.append(created)
                if result.batch.folderProfiles == nil { result.batch.folderProfiles = [:] }
                result.batch.folderProfiles?[created.id] = profile
                folderMap[folder.id + profile.uuidString + space.uuidString] = created.id
                parent = created.id; depth += 1
            }
            if node.kind == .history, let url = node.url, Self.webURL(url.absoluteString) != nil {
                result.history[profile, default: []].append(node)
            } else if let url = node.url {
                let isToday = node.kind == .openTab && parent == nil
                var tab = BrowserTab(spaceID: space, profileID: profile, title: node.title, currentURL: url,
                                     pinnedURL: isToday ? nil : url, isOpen: isToday, isFavorite: node.kind == .favorite)
                tab.folderID = tab.isFavorite ? nil : parent
                tab.sidebarPosition = try allocate(space, tab.folderID)
                result.workspace.sessions[sessionIndex].tabs.append(tab); result.batch.tabs.append(tab)
            }
        }
        // Synchronize organization once per window, rather than copying every
        // window's arrays after every imported item.
        for index in result.workspace.sessions.indices {
            var session = result.workspace.sessions[index]
            let pins = result.batch.tabs.filter { $0.profileID == session.profileID && $0.pinnedURL != nil }
            BrowserImportOrdering.append(in: &session, after: current.session(for: session.profileID), imported: Set(result.batch.tabs.map(\.id) + result.batch.folders.map(\.id)))
            for window in session.additionalWindows.indices {
                session.additionalWindows[window].spaces = session.spaces
                session.additionalWindows[window].folders = session.folders
                session.additionalWindows[window].tabs.append(contentsOf: pins)
                let rootCopy = session
                BrowserImportOrdering.synchronizePositions(from: rootCopy, to: &session.additionalWindows[window])
            }
            result.workspace.sessions[index] = session
        }
        result.batch = result.batch.adjustedPositions(in: result.workspace)
        guard result.history.values.allSatisfy({ $0.count <= Self.maximumVisits }) else { throw BrowserImportProblem.capacity }
        result.batch.historyProfiles = result.history.keys.sorted { $0.uuidString < $1.uuidString }
        result.workspace.browserImportBatchIDs = (current.browserImportBatchIDs ?? []) + [result.batch.id]
        try result.workspace.validate(using: input)
        let windows = result.workspace.sessions.flatMap { [$0] + $0.additionalWindows }
        guard result.workspace.profiles.count <= EarlyStateArchive.maximumProfiles,
              windows.reduce(0, { $0 + $1.tabs.count }) <= EarlyStateArchive.maximumTabs else { throw BrowserImportProblem.capacity }
        let archive = EarlyStateArchive(workspace: result.workspace, settings: nil)
        let encoded = try archive.encoded()
        guard encoded.count <= EarlyStateArchive.maximumSize else { throw BrowserImportProblem.capacity }
        _ = try EarlyStateArchive.decode(encoded, using: input)
        return result
    }


}

public extension BrowserImportBatch {
    /// Edited/used items and folders with later contents are preserved by default.
    /// Profiles are always retained: they may now own passwords or website data.
    func undo(in current: BrowserWorkspace, using input: NavigationInput = NavigationInput()) throws -> (workspace: BrowserWorkspace, preserved: Int) {
        var draft = current, preserved = 0
        let originalTabs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let originalFolders = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for index in draft.sessions.indices {
            var root = draft.sessions[index]
            var windows = [root] + root.additionalWindows
            let selectedTabs = Set(windows.flatMap { $0.selectionBySpace.values })
                .union(windows.flatMap { $0.splitGroups.flatMap { $0.panes.map(\.tabID) } })
            let keepTabs = Set(windows.flatMap(\.tabs).compactMap { tab -> UUID? in
                guard let original = originalTabs[tab.id] else { return nil }
                return tab == original && !selectedTabs.contains(tab.id) ? nil : tab.id
            })
            preserved += keepTabs.count
            // Saved folders belong to the profile. A later edit or child in
            // any window keeps the folder everywhere, including its ancestors.
            let survivingTabs = windows.flatMap(\.tabs).filter { originalTabs[$0.id] == nil || keepTabs.contains($0.id) }
            let occupied = Set(survivingTabs.compactMap(\.folderID))
            let allFolders = windows.flatMap(\.folders)
            let localFolders = Dictionary(allFolders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let editedFolders = Set(allFolders.filter { originalFolders[$0.id] != nil && originalFolders[$0.id] != $0 }.map(\.id))
            var childCounts = Dictionary(grouping: localFolders.values, by: \.parentID).mapValues(\.count)
            var pending = localFolders.values.filter { childCounts[$0.id, default: 0] == 0 }.map(\.id)
            var removed = Set<UUID>()
            while let id = pending.popLast() {
                guard let folder = localFolders[id], originalFolders[id] != nil, !editedFolders.contains(id),
                      !occupied.contains(id), childCounts[id, default: 0] == 0, removed.insert(id).inserted else { continue }
                if let parent = folder.parentID {
                    childCounts[parent, default: 0] -= 1
                    if childCounts[parent] == 0 { pending.append(parent) }
                }
            }
            for w in windows.indices {
                windows[w].tabs.removeAll { originalTabs[$0.id] != nil && !keepTabs.contains($0.id) }
                windows[w].folders.removeAll { removed.contains($0.id) }
                let snapshot = windows[w]
                windows[w].spaces.removeAll { space in
                    spaces.contains(space) && space.id != snapshot.activeSpaceID && snapshot.spaces.count > 1
                        && !snapshot.tabs.contains { $0.spaceID == space.id }
                        && !snapshot.folders.contains { $0.spaceID == space.id }
                }
                windows[w].selectionBySpace = windows[w].selectionBySpace.filter { _, id in windows[w].tabs.contains { $0.id == id } }
                windows[w].pruneSplitMetadata()
            }
            root = windows[0]; root.additionalWindows = Array(windows.dropFirst())
            // All windows retain a common Space catalog, including a selected Space.
            let retained = Set(windows.flatMap { $0.spaces.map(\.id) })
            root.spaces = draft.sessions[index].spaces.filter { retained.contains($0.id) }
            for w in root.additionalWindows.indices { root.additionalWindows[w].spaces = root.spaces }
            draft.sessions[index] = root
        }
        draft.browserImportBatchIDs?.removeAll { $0 == id }
        try draft.validate(using: input)
        return (draft, preserved)
    }

    /// Names shown before destructive undo. New contents keep their ancestor
    /// folders; selected pages and edits always win over the import snapshot.
    func undoConflicts(in current: BrowserWorkspace, using input: NavigationInput = NavigationInput()) throws -> [String] {
        let remaining = try undo(in: current, using: input).workspace.sessions.flatMap { [$0] + $0.additionalWindows }
        let keptTabs = Set(remaining.flatMap(\.tabs).map(\.id))
        let keptFolders = Set(remaining.flatMap(\.folders).map(\.id))
        return tabs.filter { keptTabs.contains($0.id) }.map { "Page: " + $0.title }
            + folders.filter { keptFolders.contains($0.id) }.map { "Folder: " + $0.name }
    }
}
