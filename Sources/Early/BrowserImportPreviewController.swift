// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import Foundation
import Observation

/// Prepared on the source-reading worker, while selected file access is held.
struct BrowserImportPreparedSource: Sendable {
    let tree: BrowserImportTree
    let selection: BrowserImportTree.Selection
    let expanded: Set<String>
    let rows: [BrowserImportTree.Row]
    let destinations: [String: BrowserImportDestination]

    init(_ document: BrowserImportDocument) throws {
        tree = try BrowserImportTree.preparing(document)
        selection = tree.selection(document.initiallySelected)
        expanded = Set(document.destinationGroups.map(\.id) + document.collections.map(\.id))
        rows = try tree.preparedRows(selection: selection, expanded: expanded, search: "")
        var destinations: [String: BrowserImportDestination] = [:]
        for group in document.destinationGroups {
            try Task.checkCancellation()
            var owner = group
            var ancestors: Set<String> = [owner.id]
            while owner.kind != .profile, let parent = owner.parentID, let next = tree.byID[parent] {
                guard ancestors.insert(next.id).inserted else { throw BrowserImportProblem.invalid }
                owner = next
            }
            destinations[group.id] = BrowserImportDestination(profileName: owner.title,
                spaceName: group.kind == .space ? group.title : "Personal")
        }
        self.destinations = destinations
    }
}

/// Selection edits are replayed from the last published state on a worker. A
/// superseded render cannot drop rapid checkbox edits or publish an older query.
@Observable @MainActor
final class BrowserImportPreviewController {
    private(set) var tree: BrowserImportTree?
    private(set) var selected = Set<String>()
    private(set) var expanded = Set<String>()
    private(set) var rows: [BrowserImportTree.Row] = []
    private(set) var isPreparing = false
    @ObservationIgnored private var selection: BrowserImportTree.Selection?
    @ObservationIgnored private var search = ""
    @ObservationIgnored private var pending: [Change] = []
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var preparation: Task<Prepared, Error>?
    @ObservationIgnored private let render: Render

    typealias Render = @Sendable (BrowserImportTree, BrowserImportTree.Selection, Set<String>, String) async throws -> [BrowserImportTree.Row]
    private enum Change: Sendable { case all, none, toggle(String) }
    private struct Prepared: Sendable {
        let selection: BrowserImportTree.Selection
        let rows: [BrowserImportTree.Row]
    }

    init(render: @escaping Render = { tree, selection, expanded, search in
        try tree.preparedRows(selection: selection, expanded: expanded, search: search)
    }) { self.render = render }

    func install(_ source: BrowserImportPreparedSource) {
        clear()
        tree = source.tree; selection = source.selection; selected = source.selection.selected
        expanded = source.expanded; rows = source.rows
    }

    func clear() {
        request = UUID()
        preparation?.cancel(); preparation = nil
        tree = nil; selection = nil; selected = []; expanded = []; rows = []
        search = ""; pending = []; isPreparing = false
    }

    func setSearch(_ value: String) {
        guard value != search else { return }
        search = value; prepare()
    }
    func toggleExpansion(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
        prepare()
    }
    func selectAll() { pending = [.all]; prepare() }
    func selectNone() { pending = [.none]; prepare() }
    func toggleSelection(_ id: String) { pending.append(.toggle(id)); prepare() }

    private func prepare() {
        guard let tree, let selection else { return }
        preparation?.cancel()
        let token = UUID()
        request = token; isPreparing = true
        let changes = pending, expanded = expanded, search = search, render = render
        let task = Task.detached(priority: .userInitiated) {
            var updated = selection
            for change in changes {
                try Task.checkCancellation()
                switch change {
                case .all: updated = tree.selection(tree.selectableIDs)
                case .none: updated = tree.selection([])
                case .toggle(let id): try tree.toggle(id, in: &updated)
                }
            }
            let rows = try await render(tree, updated, expanded, search)
            try Task.checkCancellation()
            return Prepared(selection: updated, rows: rows)
        }
        preparation = task
        Task { [weak self] in
            do {
                let value = try await task.value
                guard let self, self.request == token else { return }
                self.selection = value.selection; self.selected = value.selection.selected
                self.rows = value.rows; self.pending = []; self.isPreparing = false; self.preparation = nil
            } catch {
                // Cancellation is only initiated by replacement or clear(),
                // which own the newer state and progress indication.
                guard let self, self.request == token else { return }
                self.isPreparing = false; self.preparation = nil
            }
        }
    }
}
