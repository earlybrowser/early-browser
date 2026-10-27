// SPDX-License-Identifier: MPL-2.0

import Foundation

extension BrowserImportReaders {
    private static func supportedIcon(_ name: String?) -> SpaceIcon? {
        guard let name else { return nil }
        let aliases: [String: SpaceIcon.Symbol] = ["flash": .bolt, "musicalNote": .music, "restaurant": .food, "planet": .globe, "gameController": .game]
        let symbol = aliases[name] ?? SpaceIcon.Symbol.allCases.first { $0.rawValue == name || String(describing: $0) == name }
        return symbol.map(SpaceIcon.symbol)
    }

    /// Arc's Swift-enum dictionary encoding uses alternating key/value arrays.
    /// Unknown variants fail explicitly instead of guessing their organization.
    static func arcSidebar(_ json: [String: Any], name: String) throws -> BrowserImportDocument {
        guard let sidebar = json["sidebar"] as? [String: Any], let containers = sidebar["containers"] as? [Any],
              let container = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["items"] != nil && $0["spaces"] != nil }) else {
            throw BrowserImportProblem.invalid
        }
        func pairs(_ value: Any?) throws -> [(String, [String: Any])] {
            guard let values = value as? [Any], values.count.isMultiple(of: 2), values.count <= BrowserImportDocument.maximumNodes * 2 else { throw BrowserImportProblem.invalid }
            var result: [(String, [String: Any])] = [], seen = Set<String>()
            for index in stride(from: 0, to: values.count, by: 2) {
                guard let key = values[index] as? String, let object = values[index + 1] as? [String: Any], seen.insert(key).inserted else { throw BrowserImportProblem.invalid }
                result.append((key, object))
            }
            return result
        }
        let spaces = try pairs(container["spaces"]), items = Dictionary(uniqueKeysWithValues: try pairs(container["items"]))
        var builder = Builder(name: name)
        builder.document.nodes = []
        builder.document.notices.append("Experimental Arc sidebar import: verified against synthetic schema fixtures, not a current Arc installation. Check every Space, profile and folder in this preview. Bookmarks HTML is the verified alternative.")
        var profiles = Set<String>(), visited = Set<String>()
        func profile(_ key: String) -> String {
            let id = "profile." + key
            if profiles.insert(id).inserted { builder.document.nodes.append(.init(id: id, kind: .profile, title: profiles.count == 1 ? name : "\(name) Profile \(profiles.count)")) }
            return id
        }
        func unwrap(_ value: [String: Any]) -> [String: Any] { value["_0"] as? [String: Any] ?? value }
        func walk(_ id: String, parent: String, kind: BrowserImportNode.Kind, depth: Int) throws {
            guard depth <= 64, visited.insert(id + "|" + parent).inserted, let item = items[id] else { throw BrowserImportProblem.invalid }
            try Task.checkCancellation()
            let data = item["data"] as? [String: Any] ?? [:]
            let children = item["childrenIds"] as? [String] ?? []
            if let raw = data["tab"] as? [String: Any] {
                let tab = unwrap(raw)
                try builder.link(tab["savedURL"] as? String ?? tab["url"] as? String,
                                 title: item["title"] as? String ?? tab["savedTitle"] as? String, parent: parent, kind: kind)
            } else {
                var target = parent
                if data["list"] != nil {
                    let list = unwrap(data["list"] as? [String: Any] ?? [:])
                    target = builder.folder(item["title"] as? String ?? list["title"] as? String ?? "Folder", parent: parent)
                } else if data["itemContainer"] == nil && data["splitView"] == nil {
                    throw BrowserImportProblem.unsupported("This Arc sidebar contains an unverified organization type. Export it as bookmarks HTML instead.")
                }
                for child in children { try walk(child, parent: target, kind: kind == .favorite ? .pin : kind, depth: depth + 1) }
            }
        }
        for (id, space) in spaces {
            let owner = profile(space["profileID"] as? String ?? "isolated." + id)
            let spaceID = "space." + id
            builder.document.nodes.append(.init(id: spaceID, parentID: owner, kind: .space,
                                                 title: space["title"] as? String ?? "Space \(builder.document.nodes.count)",
                                                 color: (space["color"] as? String).flatMap(BrowserSpace.Color.init(rawValue:)),
                                                 icon: supportedIcon(((space["customInfo"] as? [String: Any])?["iconType"] as? [String: Any])?["icon"] as? String)))
            guard let roots = (space["newContainerIDs"] ?? space["containerIDs"]) as? [Any], roots.count.isMultiple(of: 2) else { throw BrowserImportProblem.invalid }
            for index in stride(from: 0, to: roots.count, by: 2) {
                guard let rootID = roots[index + 1] as? String else { throw BrowserImportProblem.invalid }
                let key = roots[index] as? String
                let marker = roots[index] as? [String: Any]
                let pinned = key == "pinned" || marker?["pinned"] != nil
                let today = key == "unpinned" || marker?["unpinned"] != nil
                guard pinned || today else { continue }
                try walk(rootID, parent: spaceID, kind: pinned ? .pin : .openTab, depth: 0)
            }
        }
        if let roots = container["topAppsContainerIDs"] as? [Any], roots.count.isMultiple(of: 2) {
            for index in stride(from: 0, to: roots.count, by: 2) {
                guard let id = roots[index + 1] as? String else { throw BrowserImportProblem.invalid }
                let marker = roots[index] as? [String: Any]
                let owner = profile(marker?["profileID"] as? String ?? "favorites")
                guard let root = items[id] else { throw BrowserImportProblem.invalid }
                for child in root["childrenIds"] as? [String] ?? [] { try walk(child, parent: owner, kind: .favorite, depth: 0) }
            }
        }
        builder.document.notices.append("Arc live folders and split groups become ordinary snapshots. Unsupported notes, Easels and Boosts are not imported. When profile identities are absent, Spaces/Favorites stay in separate new profiles until you explicitly map them together.")
        try builder.document.validate(); return builder.document
    }

    /// Zen 1.18+ stores its sidebar as top-level spaces/folders/groups/tabs.
    static func zenSidebar(_ json: [String: Any], name: String) throws -> BrowserImportDocument {
        guard let spaces = json["spaces"] as? [[String: Any]], let tabs = json["tabs"] as? [[String: Any]] else { throw BrowserImportProblem.invalid }
        var builder = Builder(name: name)
        var profiles = Set<String>(["profile"]), groups = Set<String>(), folderCopies = Set<String>()
        let folders = json["folders"] as? [[String: Any]] ?? []
        let allGroups = json["groups"] as? [[String: Any]] ?? []
        guard spaces.count + tabs.count + folders.count + allGroups.count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
        let knownFolders = Set(folders.compactMap { $0["id"] as? String })
        var sourceKeys: [String: String] = [:], predecessors: [String: String] = [:]
        func owner(_ container: Int) -> String {
            guard container > 0 else { return "profile" }
            let id = "container.\(container)"
            if profiles.insert(id).inserted { builder.document.nodes.append(.init(id: id, kind: .profile, title: "\(name) · Container \(container)")) }
            return id
        }
        func space(_ id: String?, owner: String) -> String {
            guard let id, !id.isEmpty else { return owner }
            let key = owner + ".space." + id
            if groups.insert(key).inserted {
                let original = spaces.first { $0["uuid"] as? String == id }
                builder.document.nodes.append(.init(id: key, parentID: owner, kind: .space, title: original?["name"] as? String ?? "Workspace",
                                                     color: (original?["color"] as? String).flatMap(BrowserSpace.Color.init(rawValue:)),
                                                     icon: supportedIcon(original?["icon"] as? String)))
            }
            return key
        }
        func ensureFolders(_ parent: String, workspace: String?) throws {
            for folder in folders where folder["workspaceId"] as? String == workspace {
                guard let id = folder["id"] as? String else { throw BrowserImportProblem.invalid }
                let key = parent + ".folder." + id
                guard folderCopies.insert(key).inserted else { continue }
                let sourceParent = folder["parentId"] as? String
                let target = sourceParent.flatMap { knownFolders.contains($0) ? parent + ".folder." + $0 : nil } ?? parent
                builder.document.nodes.append(.init(id: key, parentID: target, kind: .folder, title: folder["name"] as? String ?? "Folder", icon: supportedIcon(folder["userIcon"] as? String)))
                sourceKeys[key] = "group:" + id
                let previous = folder["prevSiblingInfo"] as? [String: Any]
                if let type = previous?["type"] as? String, ["tab", "group"].contains(type), let id = previous?["id"] as? String {
                    predecessors[key] = type + ":" + id
                } else { predecessors[key] = "start" }
            }
        }
        // Empty workspaces/folders survive even with no tabs.
        for original in spaces {
            guard let id = original["uuid"] as? String else { throw BrowserImportProblem.invalid }
            let contexts = Set(tabs.filter { $0["zenWorkspace"] as? String == id }.map { $0["userContextId"] as? Int ?? 0 })
            for context in contexts.isEmpty ? [0] : contexts.sorted() {
                let parent = space(id, owner: owner(context)); try ensureFolders(parent, workspace: id)
            }
        }
        for tab in tabs {
            guard tab["zenIsEmpty"] as? Bool != true, tab["zenIsGlance"] as? Bool != true,
                  let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
            let context = tab["userContextId"] as? Int ?? 0, favorite = tab["zenEssential"] as? Bool == true
            let originalSpace = tab["zenWorkspace"] as? String
            let root = owner(context)
            let parent = favorite ? root : space(originalSpace, owner: root)
            if !favorite { try ensureFolders(parent, workspace: originalSpace) }
            var target = parent
            if let group = tab["groupId"] as? String {
                if knownFolders.contains(group), !favorite { target = parent + ".folder." + group }
                else if let metadata = allGroups.first(where: { $0["id"] as? String == group }) {
                    let key = parent + ".group." + group
                    if groups.insert(key).inserted { builder.document.nodes.append(.init(id: key, parentID: parent, kind: .folder, title: metadata["name"] as? String ?? "Tab group")) }
                    target = key
                }
            }
            let index = min(max((tab["index"] as? Int ?? entries.count) - 1, 0), entries.count - 1), entry = entries[index]
            let kind: BrowserImportNode.Kind = favorite && target == root ? .favorite : (favorite || tab["pinned"] as? Bool == true ? .pin : .openTab)
            let count = builder.document.nodes.count
            try builder.link(entry["url"] as? String, title: tab["zenStaticLabel"] as? String ?? entry["title"] as? String, parent: target, kind: kind)
            if builder.document.nodes.count > count, let id = tab["zenSyncId"] as? String {
                sourceKeys[builder.document.nodes.last!.id] = "tab:" + id
            }
        }
        // Tabs are serialized in tab order, but folders separately describe
        // their preceding sibling. Interleave both without quadratic inserts.
        let siblings = Dictionary(grouping: builder.document.nodes.filter { $0.kind == .folder || $0.url != nil }, by: \.parentID)
        var order: [String: Int] = [:]
        for values in siblings.values {
            let keys = Set(values.compactMap { sourceKeys[$0.id] })
            let followers = Dictionary(grouping: values.filter { predecessors[$0.id] != nil }) {
                let key = predecessors[$0.id]!
                return keys.contains(key) ? key : "start"
            }
            var emitted = Set<String>(), position = 0
            func emit(_ initial: [BrowserImportNode]) {
                var pending = Array(initial.reversed())
                while let node = pending.popLast(), emitted.insert(node.id).inserted {
                    order[node.id] = position; position += 1
                    if let key = sourceKeys[node.id] { pending += (followers[key] ?? []).reversed() }
                }
            }
            emit(followers["start"] ?? [])
            for node in values where predecessors[node.id] == nil { emit([node]) }
            // A damaged/missing predecessor never drops a folder or its links.
            for node in values where !emitted.contains(node.id) { emit([node]) }
        }
        for index in builder.document.nodes.indices { builder.document.nodes[index].order = order[builder.document.nodes[index].id] }
        builder.document.notices.append("Zen containers become separate Early profiles by default. Essentials remain profile-wide; workspace pins and folders remain in their Space. Live folders and split groups are ordinary snapshots. Website sessions, form data, icons fetched from websites, and other session secrets are discarded.")
        try builder.document.validate(); return builder.document
    }
}
