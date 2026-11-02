// SPDX-License-Identifier: MPL-2.0

import Foundation
@testable import EarlyCore
import Testing

struct BrowserImportPreviewTreeTests {
    private func fixture() -> BrowserImportDocument {
        .init(source: "Preview", nodes: [
            .init(id: "profile", kind: .profile, title: "Personal"),
            .init(id: "folder", parentID: "profile", kind: .folder, title: "Research"),
            .init(id: "one", parentID: "folder", kind: .bookmark, title: "Café guide", url: URL(string: "https://example.invalid/one")),
            .init(id: "nested", parentID: "folder", kind: .folder, title: "Nested"),
            .init(id: "two", parentID: "nested", kind: .pin, title: "Second", url: URL(string: "https://example.invalid/two")),
            .init(id: "empty", parentID: "profile", kind: .folder, title: "Empty"),
            .init(id: "space", parentID: "profile", kind: .space, title: "Empty Space"),
            .init(id: "history", parentID: "profile", kind: .category, title: "History"),
            .init(id: "visit", parentID: "history", kind: .history, title: "Visit", url: URL(string: "https://example.invalid/visit"), visitedAt: Date()),
            .init(id: "tabs", parentID: "profile", kind: .category, title: "Open tabs"),
            .init(id: "tab", parentID: "tabs", kind: .openTab, title: "Today", url: URL(string: "https://example.invalid/today"))
        ])
    }

    /// The previous uncached algorithm is an independent behavior reference.
    private func reference(_ document: BrowserImportDocument, selected: Set<String>, expanded: Set<String>, search: String,
                           index: BrowserImportTree? = nil) -> [BrowserImportTree.Row] {
        let byID = index?.byID ?? Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let children = index?.children ?? Dictionary(grouping: document.nodes, by: { $0.parentID ?? "" }).mapValues { $0.map(\.id) }
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
        var pending = (children[""] ?? []).reversed().map { ($0, 0) }, result: [BrowserImportTree.Row] = []
        while let (id, depth) = pending.popLast() {
            guard let node = byID[id], term.isEmpty || matching.contains(id) else { continue }
            let count = checked[id, default: 0], total = totals[id, default: 0]
            let state: BrowserImportTree.CheckState = count == 0 ? .off : count == total ? .on : .mixed
            result.append(.init(node: node, depth: depth, state: state, hasChildren: children[id] != nil))
            if !term.isEmpty || expanded.contains(id) { pending += (children[id] ?? []).reversed().map { ($0, depth + 1) } }
        }
        return result
    }

    private func compare(_ actual: [BrowserImportTree.Row], _ expected: [BrowserImportTree.Row]) {
        #expect(actual.map(\.id) == expected.map(\.id))
        #expect(actual.map(\.depth) == expected.map(\.depth))
        #expect(actual.map(\.state) == expected.map(\.state))
        #expect(actual.map(\.hasChildren) == expected.map(\.hasChildren))
    }

    @Test func indexedRowsPreservePartialSelectionSearchOrderingAndEmptyContainers() throws {
        var document = fixture()
        // Children need not follow their parents in an exported file.
        document.nodes.swapAt(1, 4)
        let tree = try BrowserImportTree.preparing(document)
        #expect(tree.selectableIDs == ["one", "two", "empty", "space", "visit", "tab"])
        for selected: Set<String> in [[], ["one"], document.initiallySelected, tree.selectableIDs] {
            let selection = tree.selection(selected)
            for expanded: Set<String> in [[], ["profile"], ["profile", "folder", "nested", "history", "tabs"]] {
                for search in ["", "  ", "Café", "example.invalid/two", "Research", "missing"] {
                    compare(try tree.preparedRows(selection: selection, expanded: expanded, search: search),
                        reference(document, selected: selected, expanded: expanded, search: search))
                }
            }
            #expect(selection.selected == selected, "Filtering and collapsing cannot change selection")
        }
    }

    @Test func incrementalCountsRemainCorrectThroughRepeatedSubtreeChanges() throws {
        let document = fixture(), tree = BrowserImportTree(document)
        var selection = tree.selection(document.initiallySelected)
        let expanded = Set(document.nodes.map(\.id))
        for id in ["one", "nested", "folder", "folder", "empty", "space", "history", "profile", "profile", "unknown", "two"] {
            let expected = tree.toggling(id, selected: selection.selected)
            try tree.toggle(id, in: &selection)
            #expect(selection.selected == expected)
            compare(try tree.preparedRows(selection: selection, expanded: expanded, search: ""),
                reference(document, selected: expected, expanded: expanded, search: ""))
        }
    }

    @Test func selectionFromAnotherSourceIsRecountedBeforeRenderingOrChangingIt() throws {
        let document = fixture(), first = BrowserImportTree(document), second = BrowserImportTree(document)
        var selection = first.selection(["one"])
        compare(try second.preparedRows(selection: selection, expanded: ["profile"], search: ""),
            reference(document, selected: ["one"], expanded: ["profile"], search: ""))
        try second.toggle("folder", in: &selection)
        #expect(selection.selected == ["one", "two"])
    }

    @Test func cancelledPreparationAndRenderingStopEvenForSmallOrEmptyInputs() async throws {
        let document = fixture(), tree = BrowserImportTree(document)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try BrowserImportTree.preparing(document) }
            #expect(throws: CancellationError.self) { try BrowserImportTree.preparing(.init(source: "Empty")) }
            #expect(throws: CancellationError.self) { try tree.preparedRows(selection: tree.selection([]), expanded: [], search: "") }
            var selection = tree.selection([])
            #expect(throws: CancellationError.self) { try tree.toggle("folder", in: &selection) }
        }
        await worker.value
    }

    @Test func largePreviewReusesItsIndexAcrossCollapsedAndFilteredResults() throws {
        var nodes: [BrowserImportNode] = [.init(id: "profile", kind: .profile, title: "Profile")]
        for index in 0..<39_999 {
            nodes.append(.init(id: "folder\(index)", parentID: "profile", kind: .folder, title: "Folder \(index)"))
            nodes.append(.init(id: "page\(index)", parentID: "folder\(index)", kind: .bookmark, title: "Page \(index)", url: URL(string: "https://example.invalid/\(index)")))
        }
        let document = BrowserImportDocument(source: "Large", nodes: nodes)
        let clock = ContinuousClock()
        let start = clock.now
        let tree = try BrowserImportTree.preparing(document), selection = tree.selection(document.initiallySelected)
        let indexDuration = start.duration(to: clock.now)
        let originalStart = clock.now
        let original = reference(document, selected: selection.selected, expanded: [], search: "", index: tree)
        let originalDuration = originalStart.duration(to: clock.now)
        let cachedStart = clock.now
        let collapsed = try tree.preparedRows(selection: selection, expanded: [], search: "")
        let cachedDuration = cachedStart.duration(to: clock.now)
        compare(collapsed, original)
        let filtered = try tree.preparedRows(selection: selection, expanded: [], search: "example.invalid/39998")
        #expect(filtered.map(\.id) == ["profile", "folder39998", "page39998"])
        #expect(selection.selected.count == 39_999)
        if ProcessInfo.processInfo.environment["EARLY_IMPORT_BENCHMARKS"] == "1" {
            print("IMPORT PREVIEW 79,999 nodes: index+initial selection \(indexDuration), previous collapsed render \(originalDuration), cached collapsed render \(cachedDuration)")
        }
    }
}
