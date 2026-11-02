// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A source is indexed once. Contiguous subtrees and cached totals keep search,
/// expansion and checkbox rendering independent of repeated ancestry scans.
public struct BrowserImportTree: Sendable {
    public enum CheckState: Sendable { case off, mixed, on }
    public struct Row: Identifiable, Sendable {
        public var node: BrowserImportNode
        public var depth: Int
        public var state: CheckState
        public var hasChildren: Bool
        public var id: String { node.id }
    }
    public struct Selection: Sendable {
        public fileprivate(set) var selected: Set<String>
        fileprivate let treeID: UUID
        fileprivate var checked: [Int]
    }
    public let document: BrowserImportDocument
    public let byID: [String: BrowserImportNode]
    public let children: [String: [String]]
    public let selectableIDs: Set<String>
    private let identity = UUID()
    private let ordered: [BrowserImportNode]
    private let indices: [String: Int]
    private let parents: [Int?]
    private let depths: [Int]
    private let ends: [Int]
    private let totals: [Int]

    public init(_ document: BrowserImportDocument) {
        self.init(document, check: {})
    }

    public static func preparing(_ document: BrowserImportDocument) throws -> Self {
        try Self(document, check: { try Task.checkCancellation() })
    }

    private init(_ document: BrowserImportDocument, check: () throws -> Void) rethrows {
        try check()
        self.document = document
        var lookup: [String: BrowserImportNode] = [:], children: [String: [String]] = [:]
        for (index, node) in document.nodes.enumerated() {
            if index.isMultiple(of: 256) { try check() }
            if lookup[node.id] == nil { lookup[node.id] = node }
            children[node.parentID ?? "", default: []].append(node.id)
        }
        byID = lookup
        self.children = children
        let selectableIDs = Set(document.nodes.filter {
            $0.url != nil || ([.folder, .space].contains($0.kind) && children[$0.id] == nil)
        }.map(\.id))
        self.selectableIDs = selectableIDs
        var ordered: [BrowserImportNode] = [], indices: [String: Int] = [:], parents: [Int?] = [], depths: [Int] = []
        var pending = (children[""] ?? []).reversed().map { ($0, Optional<Int>.none, 0) }
        while let (id, parent, depth) = pending.popLast() {
            if ordered.count.isMultiple(of: 256) { try check() }
            guard indices[id] == nil, let node = lookup[id] else { continue }
            let index = ordered.count
            indices[id] = index; ordered.append(node); parents.append(parent); depths.append(depth)
            pending += (children[id] ?? []).reversed().map { ($0, Optional(index), depth + 1) }
        }
        var totals = ordered.map { selectableIDs.contains($0.id) ? 1 : 0 }
        var ends = Array(ordered.indices).map { $0 + 1 }
        for index in ordered.indices.reversed() {
            if index.isMultiple(of: 256) { try check() }
            if let parent = parents[index] {
                totals[parent] += totals[index]
                ends[parent] = max(ends[parent], ends[index])
            }
        }
        self.ordered = ordered; self.indices = indices; self.parents = parents
        self.depths = depths; self.ends = ends; self.totals = totals
        try check()
    }
    public func descendants(_ id: String) -> Set<String> {
        if let start = indices[id] { return Set(ordered[start..<ends[start]].map(\.id)) }
        var pending = [id], found = Set<String>()
        while let next = pending.popLast(), found.insert(next).inserted { pending += children[next] ?? [] }
        return found
    }

    public func selection(_ selected: Set<String>) -> Selection {
        var checked = ordered.map { selectableIDs.contains($0.id) && selected.contains($0.id) ? 1 : 0 }
        for index in ordered.indices.reversed() {
            if let parent = parents[index] { checked[parent] += checked[index] }
        }
        return Selection(selected: selected, treeID: identity, checked: checked)
    }

    /// Only changed selectable records and their ancestors need updated counts.
    public func toggle(_ id: String, in selection: inout Selection) throws {
        try Task.checkCancellation()
        if selection.treeID != identity { selection = self.selection(selection.selected) }
        guard let start = indices[id], totals[start] > 0 else { return }
        let selecting = selection.checked[start] != totals[start]
        for index in start..<ends[start] {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let id = ordered[index].id
            guard selectableIDs.contains(id) else {
                if !selecting { selection.selected.remove(id) }
                continue
            }
            let changed = selecting ? selection.selected.insert(id).inserted : selection.selected.remove(id) != nil
            guard changed else { continue }
            var ancestor: Int? = index
            while let current = ancestor {
                selection.checked[current] += selecting ? 1 : -1
                ancestor = parents[current]
            }
        }
        try Task.checkCancellation()
    }
    public func toggling(_ id: String, selected: Set<String>) -> Set<String> {
        let subtree = descendants(id)
        let leaves = subtree.intersection(selectableIDs)
        return leaves.isSubset(of: selected) ? selected.subtracting(subtree) : selected.union(leaves)
    }
    public func rows(selected: Set<String>, expanded: Set<String>, search: String) -> [Row] {
        rows(selection: selection(selected), expanded: expanded, search: search, check: {})
    }

    public func preparedRows(selection: Selection, expanded: Set<String>, search: String) throws -> [Row] {
        try rows(selection: selection, expanded: expanded, search: search, check: { try Task.checkCancellation() })
    }

    private func rows(selection: Selection, expanded: Set<String>, search: String, check: () throws -> Void) rethrows -> [Row] {
        let selection = selection.treeID == identity ? selection : self.selection(selection.selected)
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var matching = [Bool]()
        if !term.isEmpty {
            matching = Array(repeating: false, count: ordered.count)
            for index in ordered.indices.reversed() {
                if index.isMultiple(of: 256) { try check() }
                let node = ordered[index]
                if node.title.localizedCaseInsensitiveContains(term) || node.url?.absoluteString.localizedCaseInsensitiveContains(term) == true {
                    matching[index] = true
                }
                if matching[index], let parent = parents[index] { matching[parent] = true }
            }
        }
        var result: [Row] = [], index = 0
        while index < ordered.count {
            if index.isMultiple(of: 256) { try check() }
            if !term.isEmpty, !matching[index] { index = ends[index]; continue }
            let node = ordered[index], checked = selection.checked[index], total = totals[index]
            let state: CheckState = checked == 0 ? .off : checked == total ? .on : .mixed
            result.append(Row(node: node, depth: depths[index], state: state, hasChildren: children[node.id] != nil))
            index = term.isEmpty && !expanded.contains(node.id) ? ends[index] : index + 1
        }
        try check()
        return result
    }
}
