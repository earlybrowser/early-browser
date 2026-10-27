// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A collection is displayed once, with explicit destinations instead of a
/// fictitious source profile. History without a reliable context has one target.
public struct BrowserImportCollection: Identifiable, Equatable, Sendable {
    public var id: String
    public var profileIDs: [String]
    public var defaultProfileIDs: Set<String>
    public var allowsCopies: Bool
    public var explanation: String
    public init(id: String, profileIDs: [String], defaultProfileIDs: Set<String> = [], allowsCopies: Bool = true, explanation: String) {
        self.id = id; self.profileIDs = profileIDs; self.defaultProfileIDs = defaultProfileIDs
        self.allowsCopies = allowsCopies; self.explanation = explanation
    }
}

public extension BrowserImportDocument {
    var defaultCollectionTargets: [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.defaultProfileIDs) })
    }

    func selectedCollections(_ selected: Set<String>) -> [BrowserImportCollection] {
        let included = included(selected)
        return collections.filter { included.contains($0.id) }
    }

    func collectionFolders(_ collection: BrowserImportCollection, selecting selected: Set<String>) -> [BrowserImportNode] {
        collectionFolders(selecting: selected)[collection.id] ?? []
    }

    func collectionFolders(selecting selected: Set<String>) -> [String: [BrowserImportNode]] {
        let included = included(selected)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let roots = Set(collections.map(\.id))
        var result: [String: [BrowserImportNode]] = [:]
        for node in nodes where node.kind == .folder && included.contains(node.id) {
            var parent = node.parentID
            while let id = parent {
                if roots.contains(id) { result[id, default: []].append(node); break }
                parent = byID[id]?.parentID
            }
        }
        return result
    }

    /// Resolve selected copies before counting capacity or writing any data.
    /// Neither a shared collection nor a matching name combines source profiles.
    func resolvingCollections(selecting selected: Set<String>, targets: [String: Set<String>], destinations mappings: [String: BrowserImportDestination] = [:]) throws -> (document: Self, selected: Set<String>) {
        try validate()
        let included = included(selected)
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let collectionIDs = Set(collections.map(\.id))
        var owned: [String: [BrowserImportNode]] = [:], ordinary: [BrowserImportNode] = []
        for node in nodes {
            var current: String? = node.id, owner: String?
            while let id = current {
                if collectionIDs.contains(id) { owner = id; break }
                current = byID[id]?.parentID
            }
            if let owner { if included.contains(node.id) { owned[owner, default: []].append(node) } }
            else if included.contains(node.id) || node.kind == .profile { ordinary.append(node) }
        }
        var result = Self(source: source, nodes: ordinary, notices: notices)
        var selection = selected.intersection(Set(ordinary.map(\.id)))
        let selectable = BrowserImportTree(self).selectableIDs
        var routedCount = 0
        for collection in collections where included.contains(collection.id) {
            try Task.checkCancellation()
            let contents = (owned[collection.id] ?? []).filter { $0.id != collection.id }
            var required: [String: Set<String>] = [:], representatives: [[String]: String] = [:]
            for node in contents where selected.contains(node.id) && selectable.contains(node.id) {
                try Task.checkCancellation()
                var path = [node.id], parent = node.parentID
                while let id = parent, id != collection.id { path.append(id); parent = byID[id]?.parentID }
                let override = path.first { byID[$0]?.kind == .folder && targets[$0] != nil }
                let key = override ?? collection.id
                let profiles = targets[key] ?? collection.defaultProfileIDs
                guard !profiles.isEmpty, profiles.isSubset(of: Set(collection.profileIDs)), collection.allowsCopies || profiles.count == 1 else {
                    throw BrowserImportProblem.collectionDestination(byID[key]?.title ?? "Shared data")
                }
                for profile in collection.profileIDs where profiles.contains(profile) {
                    var representative = profile
                    if let mapping = mappings[profile] {
                        let canonical = mapping.newProfileGroup.flatMap { mappings[$0] } ?? mapping
                        let owner = mapping.profileID?.uuidString ?? (mapping.newProfileGroup ?? profile)
                        let space = canonical.spaceID?.uuidString ?? (mapping.newProfileGroup ?? profile)
                        let key = [owner, space]
                        representative = representatives[key] ?? profile; representatives[key] = representative
                    }
                    let previous = required[representative]?.count ?? 0
                    required[representative, default: []].formUnion(path)
                    routedCount += required[representative]!.count - previous
                    guard ordinary.count + routedCount <= Self.maximumNodes else { throw BrowserImportProblem.capacity }
                }
            }
            // Each destination gets distinct IDs; intentional URL copies survive.
            for profile in collection.profileIDs where required[profile] != nil {
                let needed = required[profile]!
                guard result.nodes.count + needed.count <= Self.maximumNodes else { throw BrowserImportProblem.capacity }
                func remap(_ id: String) -> String {
                    "routed." + Self.identity([collection.id, profile, id].map { "\($0.utf8.count):" + $0 }.joined())
                }
                for var node in contents where needed.contains(node.id) {
                    try Task.checkCancellation()
                    let originalID = node.id
                    node.id = remap(originalID)
                    node.parentID = node.parentID == collection.id ? profile : node.parentID.map(remap)
                    result.nodes.append(node)
                    if selected.contains(originalID) { selection.insert(node.id) }
                }
            }
        }
        try result.validate()
        return (result, selection)
    }

    /// Only profile-local descriptive metadata is read. Container IDs never
    /// identify a context outside the enclosing source profile.
    mutating func addFirefoxCollections(sharedEssentials: Bool? = nil) {
        let profiles = nodes.filter { $0.kind == .profile }.map(\.id)
        guard profiles.count > 1, profiles.contains("profile") else { return }
        let originals = nodes
        func add(_ id: String, title: String, roots: Set<String>, copies: Bool, defaults: Set<String>, explanation: String) {
            guard !roots.isEmpty else { return }
            nodes.append(.init(id: id, parentID: "profile", kind: .category, title: title))
            for index in nodes.indices where roots.contains(nodes[index].id) { nodes[index].parentID = id }
            collections.append(.init(id: id, profileIDs: profiles, defaultProfileIDs: defaults, allowsCopies: copies, explanation: explanation))
        }
        let bookmarkRoots = Set(originals.filter { $0.parentID == "profile" && [.bookmark, .folder].contains($0.kind) }.map(\.id))
        add("shared.bookmarks", title: "Shared bookmarks", roots: bookmarkRoots, copies: true, defaults: [],
            explanation: "These bookmarks belong to the source profile and are available across its containers. Choose which Early profiles receive copies.")
        let historyRoots = Set(originals.filter { $0.parentID == "profile" && $0.kind == .category && $0.title == "Browsing history" }.map(\.id))
        add("unassigned.history", title: "History without a verified container", roots: historyRoots, copies: false, defaults: [],
            explanation: "The source did not reliably identify a container for these visits. Choose one destination; visits are never assigned by website address.")
        if sharedEssentials == false {
            let roots = Set(originals.filter { $0.kind == .favorite }.map(\.id))
            add("shared.essentials", title: "Shared Essentials", roots: roots, copies: true, defaults: [],
                explanation: "Zen showed these Essentials across containers. Choose which Early profiles receive independent Favorites.")
        }
    }
}
