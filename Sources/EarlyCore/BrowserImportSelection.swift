// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Flat indices keep checkbox counts and filtered rows linear in the input size.
public struct BrowserImportTree: Sendable {
    public enum CheckState: Sendable { case off, mixed, on }
    public struct Row: Identifiable, Sendable {
        public var node: BrowserImportNode
        public var depth: Int
        public var state: CheckState
        public var hasChildren: Bool
        public var id: String { node.id }
    }
    public let document: BrowserImportDocument
    public let byID: [String: BrowserImportNode]
    public let children: [String: [String]]
    public var selectableIDs: Set<String> {
        Set(document.nodes.filter { $0.url != nil || ([.folder, .space].contains($0.kind) && children[$0.id] == nil) }.map(\.id))
    }
    public init(_ document: BrowserImportDocument) {
        self.document = document
        byID = Dictionary(document.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        children = Dictionary(grouping: document.nodes, by: { $0.parentID ?? "" }).mapValues { $0.map(\.id) }
    }
    public func descendants(_ id: String) -> Set<String> {
        var pending = [id], found = Set<String>()
        while let next = pending.popLast(), found.insert(next).inserted { pending += children[next] ?? [] }
        return found
    }
    public func toggling(_ id: String, selected: Set<String>) -> Set<String> {
        let subtree = descendants(id)
        let leaves = subtree.intersection(selectableIDs)
        return leaves.isSubset(of: selected) ? selected.subtracting(subtree) : selected.union(leaves)
    }
    public func rows(selected: Set<String>, expanded: Set<String>, search: String) -> [Row] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var matching = Set<String>(), totals: [String: Int] = [:], checked: [String: Int] = [:]
        for node in document.nodes {
            let leaf = node.url != nil || ([.folder, .space].contains(node.kind) && children[node.id] == nil)
            let matches = !term.isEmpty && (node.title.localizedCaseInsensitiveContains(term) || node.url?.absoluteString.localizedCaseInsensitiveContains(term) == true)
            var current: String? = node.id
            while let id = current {
                if leaf { totals[id, default: 0] += 1; if selected.contains(node.id) { checked[id, default: 0] += 1 } }
                if matches { matching.insert(id) }
                current = byID[id]?.parentID
            }
        }
        var pending = (children[""] ?? []).reversed().map { ($0, 0) }, result: [Row] = []
        while let (id, depth) = pending.popLast() {
            guard let node = byID[id], term.isEmpty || matching.contains(id) else { continue }
            let count = checked[id, default: 0], total = totals[id, default: 0]
            let state: CheckState = count == 0 ? .off : count == total ? .on : .mixed
            result.append(Row(node: node, depth: depth, state: state, hasChildren: children[id] != nil))
            if !term.isEmpty || expanded.contains(id) {
                pending += (children[id] ?? []).reversed().map { ($0, depth + 1) }
            }
        }
        return result
    }
}
