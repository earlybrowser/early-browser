// SPDX-License-Identifier: MPL-2.0

import Foundation

public enum BrowserImportReaders {
    public static func read(_ data: Data, name: String) throws -> BrowserImportDocument {
        try Task.checkCancellation()
        guard data.count <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        if data.starts(with: Array("SNSS".utf8)) { return try chromiumSession(data, name: name) }
        if data.starts(with: Array("mozLz40\0".utf8)) { return try read(decompressMozilla(data), name: name) }
        let prefix = String(decoding: data.prefix(2048), as: UTF8.self).replacingOccurrences(of: "\u{feff}", with: "")
        if prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            return try bookmarksHTML(data, name: name)
        }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let text = String(data: data, encoding: .utf16), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            return try bookmarksHTML(Data([0xef, 0xbb, 0xbf]) + Data(text.utf8), name: name)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BrowserImportProblem.invalid }
        if json["sidebar"] != nil { return try arcSidebar(json, name: name) }
        if json["spaces"] != nil && json["tabs"] != nil { return try zenSidebar(json, name: name) }
        var builder = Builder(name: name)
        if let roots = json["roots"] as? [String: Any] {
            builder.document.notices.append("This bookmarks file does not contain open tabs, tab groups, or history.")
            for key in ["bookmark_bar", "other", "synced"] {
                if let root = roots[key] as? [String: Any] {
                    for node in root["children"] as? [[String: Any]] ?? [] { try builder.bookmark(node, parent: "profile", firefox: false) }
                }
            }
        } else if let metadata = json["metadata"] as? [String: Any], metadata["data_type"] as? String == "history" {
            guard (metadata["schema_version"] as? Int) == 1, let visits = json["history"] as? [[String: Any]],
                  visits.count <= BrowserImportDocument.maximumVisits else { throw BrowserImportProblem.invalid }
            builder.document.notices.append("Safari provides each page’s latest known visit and an aggregate count. Only the known visit is imported; additional visits are not invented.")
            for row in visits {
                guard row["latest_visit_was_load_failure"] as? Bool != true else { continue }
                try builder.visit(row["url"] as? String, title: row["title"] as? String,
                                  time: (row["time_usec"] as? NSNumber)?.doubleValue.mapDateMicroseconds)
            }
        } else if let windows = json["windows"] as? [[String: Any]] {
            try builder.sessions(windows, zen: json["zenWorkspaces"] as? [[String: Any]])
        } else if json["type"] as? String == "text/x-moz-place-container" || json["typeCode"] as? Int == 2 {
            for node in json["children"] as? [[String: Any]] ?? [] { try builder.bookmark(node, parent: "profile", firefox: true) }
        } else {
            throw BrowserImportProblem.unsupported("This organization format is not verified. Export bookmarks as HTML from the source browser and choose that file instead.")
        }
        try builder.document.validate()
        return builder.document
    }

    /// libxml's HTML recovery handles Netscape's intentionally unclosed DT/P tags.
    /// External entities are disabled; parsing creates no web view or resource loader.
    public static func bookmarksHTML(_ data: Data, name: String) throws -> BrowserImportDocument {
        guard data.count <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        let xml = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        guard let root = try xml.nodes(forXPath: "//dl").first as? XMLElement else { throw BrowserImportProblem.invalid }
        var builder = Builder(name: name)
        func walk(_ element: XMLElement, parent: String, depth: Int) throws {
            guard depth <= 64 else { throw BrowserImportProblem.capacity }
            var pending: String?
            for child in element.children ?? [] {
                try Task.checkCancellation()
                guard let node = child as? XMLElement else { continue }
                let tag = node.name?.lowercased()
                if tag == "h3" { pending = node.stringValue ?? "Folder" }
                else if tag == "a" { try builder.link(node.attribute(forName: "href")?.stringValue, title: node.stringValue, parent: parent) }
                else if tag == "dl" {
                    let id = pending.map { builder.folder($0, parent: parent) } ?? parent
                    try walk(node, parent: id, depth: depth + 1); pending = nil
                } else if tag == "dt" || tag == "p" || tag == "dd" {
                    // Tidy may place DL inside DT, or beside it.
                    if let heading = node.elements(forName: "h3").first {
                        let id = builder.folder(heading.stringValue ?? "Folder", parent: parent)
                        if let list = node.elements(forName: "dl").first { try walk(list, parent: id, depth: depth + 1) }
                        else { pending = heading.stringValue; builder.document.nodes.removeLast() }
                    } else { try walk(node, parent: parent, depth: depth + 1) }
                }
                guard builder.document.nodes.count <= BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            }
        }
        try walk(root, parent: "profile", depth: 0)
        try builder.document.validate()
        return builder.document
    }

    /// Mozilla's size-prefixed raw LZ4 block, with explicit bounds at every copy.
    public static func decompressMozilla(_ data: Data) throws -> Data {
        let input = Array(data)
        guard input.count >= 12, data.starts(with: Array("mozLz40\0".utf8)) else { throw BrowserImportProblem.invalid }
        let expected = (0..<4).reduce(0) { $0 | Int(input[8 + $1]) << ($1 * 8) }
        guard expected <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        var output = [UInt8](); output.reserveCapacity(expected)
        var cursor = 12
        func length(_ initial: Int) throws -> Int {
            var value = initial
            if initial == 15 {
                while true {
                    guard cursor < input.count else { throw BrowserImportProblem.invalid }
                    let next = Int(input[cursor]); cursor += 1; value += next
                    guard value <= expected else { throw BrowserImportProblem.capacity }
                    if next != 255 { break }
                }
            }
            return value
        }
        while cursor < input.count {
            try Task.checkCancellation()
            let token = input[cursor]; cursor += 1
            let literals = try length(Int(token >> 4))
            guard cursor + literals <= input.count, output.count + literals <= expected else { throw BrowserImportProblem.invalid }
            output.append(contentsOf: input[cursor..<(cursor + literals)]); cursor += literals
            if cursor == input.count { break }
            guard cursor + 2 <= input.count else { throw BrowserImportProblem.invalid }
            let offset = Int(input[cursor]) | Int(input[cursor + 1]) << 8; cursor += 2
            let count = try length(Int(token & 15)) + 4
            guard offset > 0, offset <= output.count, output.count + count <= expected else { throw BrowserImportProblem.invalid }
            for index in 0..<count {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                output.append(output[output.count - offset])
            }
        }
        guard output.count == expected else { throw BrowserImportProblem.invalid }
        return Data(output)
    }
}

private extension Double {
    var mapDateMicroseconds: Date { Date(timeIntervalSince1970: self / 1_000_000) }
}

extension BrowserImportReaders {
    struct Builder {
        var document: BrowserImportDocument
        var serial = 0
        var skipped = 0
        var visitIDs = Set<String>()
        var historyGroups = Set<String>()
        var contextIDs = Set<String>()
        init(name: String) {
            document = .init(source: name, nodes: [.init(id: "profile", kind: .profile, title: name)])
        }
        mutating func next() -> String { serial += 1; return "item.\(serial)" }
        mutating func folder(_ title: String, parent: String) -> String {
            let id = next(); document.nodes.append(.init(id: id, parentID: parent, kind: .folder, title: title)); return id
        }
        mutating func link(_ text: String?, title: String?, parent: String, kind: BrowserImportNode.Kind = .bookmark) throws {
            guard let text, let url = BrowserImportDocument.webURL(text) else {
                skipped += 1
                if skipped == 1 { document.notices.append("Unsupported links (browser-internal pages, bookmarklets, local files, or addresses containing credentials) are skipped.") }
                return
            }
            guard document.nodes.count < BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            let id = next()
            document.nodes.append(.init(id: id, parentID: parent, kind: kind, title: title ?? url.host ?? "Page", url: url))
        }
        mutating func context(_ value: Int) throws -> String {
            guard value >= 0 else { throw BrowserImportProblem.invalid }
            guard value > 0 else { return "profile" }
            let id = "container.\(value)"
            if contextIDs.insert(id).inserted {
                document.nodes.append(.init(id: id, kind: .profile, title: "\(document.source) · Container \(value)"))
            }
            return id
        }
        mutating func visit(_ text: String?, title: String?, time: Date?, profile: String = "profile") throws {
            guard let text, let url = BrowserImportDocument.webURL(text), let time,
                  time.timeIntervalSince1970.isFinite, time.timeIntervalSince1970 > 0 else { return }
            let id = "visit." + BrowserImportDocument.identity(profile + "|" + url.absoluteString + "|" + String(time.timeIntervalSince1970))
            guard visitIDs.insert(id).inserted else { return }
            let group = profile == "profile" ? "history" : profile + ".history"
            if historyGroups.insert(group).inserted {
                document.nodes.append(.init(id: group, parentID: profile, kind: .category, title: "Browsing history"))
            }
            document.nodes.append(.init(id: id, parentID: group, kind: .history, title: title ?? url.host ?? "Page", url: url, visitedAt: time))
        }
        mutating func bookmark(_ value: [String: Any], parent: String, firefox: Bool, depth: Int = 0) throws {
            guard depth <= 64, document.nodes.count < BrowserImportDocument.maximumNodes else { throw BrowserImportProblem.capacity }
            try Task.checkCancellation()
            let isFolder = firefox ? (value["typeCode"] as? Int == 2 || value["type"] as? String == "text/x-moz-place-container") : value["type"] as? String == "folder"
            if isFolder || value["children"] is [[String: Any]] {
                let id = folder(value[firefox ? "title" : "name"] as? String ?? "Folder", parent: parent)
                for child in value["children"] as? [[String: Any]] ?? [] { try bookmark(child, parent: id, firefox: firefox, depth: depth + 1) }
            } else { try link(value[firefox ? "uri" : "url"] as? String, title: value[firefox ? "title" : "name"] as? String, parent: parent) }
        }
        mutating func sessions(_ windows: [[String: Any]], zen: [[String: Any]]?) throws {
            document.notices.append("Only current URLs, titles, pins and verified organization are read. Form data, back/forward entries, cookies and other session secrets are discarded.")
            var spaces = Set<String>(), containers = Set<String>(), tabGroups = Set<String>()
            for (windowIndex, window) in windows.enumerated() where window["isPrivate"] as? Bool != true {
                let groupMetadata = (window["groups"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { result, group in
                    if let id = group["id"] as? String { result[id] = group["name"] as? String ?? "Tab group" }
                }
                for tab in window["tabs"] as? [[String: Any]] ?? [] {
                    guard tab["zenIsEmpty"] as? Bool != true, tab["zenIsGlance"] as? Bool != true,
                          let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
                    let index = min(max((tab["index"] as? Int ?? entries.count) - 1, 0), entries.count - 1)
                    let entry = entries[index]
                    let container = tab["userContextId"] as? Int ?? 0
                    var parent = "profile"
                    if container > 0 {
                        parent = "container.\(container)"
                        if containers.insert(parent).inserted {
                            document.nodes.append(.init(id: parent, kind: .profile, title: "\(document.source) · Container \(container)"))
                        }
                    }
                    if let workspace = tab["zenWorkspace"] as? String, !workspace.isEmpty {
                        let id = parent + ".space." + workspace
                        if spaces.insert(id).inserted {
                            let name = zen?.first { $0["uuid"] as? String == workspace }?["name"] as? String ?? "Workspace \(spaces.count)"
                            document.nodes.append(.init(id: id, parentID: parent, kind: .space, title: name))
                        }
                        parent = id
                    }
                    let favorite = tab["zenEssential"] as? Bool == true
                    let kind: BrowserImportNode.Kind = favorite && !parent.contains(".space.") ? .favorite
                        : (favorite || tab["pinned"] as? Bool == true ? .pin : .openTab)
                    if let group = tab["groupId"] as? String, let title = groupMetadata[group] {
                        let id = parent + ".window.\(windowIndex).group." + group
                        if tabGroups.insert(id).inserted { document.nodes.append(.init(id: id, parentID: parent, kind: .folder, title: title)) }
                        parent = id
                    }
                    try link(entry["url"] as? String, title: tab["zenStaticLabel"] as? String ?? entry["title"] as? String, parent: parent, kind: kind)
                }
            }
            if !containers.isEmpty { document.notices.append("Containers become separate Early profiles by default. Their website sessions do not transfer. Review destinations before combining them.") }
            if !tabGroups.isEmpty { document.notices.append("Firefox tab groups become ordinary folders with unloaded pins. Ungrouped open tabs become Today tabs.") }
        }
    }
}
