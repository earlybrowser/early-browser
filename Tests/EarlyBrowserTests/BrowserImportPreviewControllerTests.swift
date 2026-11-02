// SPDX-License-Identifier: MPL-2.0

import EarlyCore
@testable import EarlyBrowser
import Foundation
import Testing

@Suite(.serialized) @MainActor
struct BrowserImportPreviewControllerTests {
    private nonisolated static func checkWorkerThread() { #expect(!Thread.isMainThread) }
    private actor Gate {
        private var suspended: CheckedContinuation<Void, Never>?
        private(set) var started = false
        func wait() async {
            started = true
            await withCheckedContinuation { suspended = $0 }
        }
        func release() { suspended?.resume(); suspended = nil }
    }

    private func fixture(_ prefix: String = "") -> BrowserImportDocument {
        .init(source: prefix + "Browser", nodes: [
            .init(id: prefix + "profile", kind: .profile, title: prefix + "Personal"),
            .init(id: prefix + "folder", parentID: prefix + "profile", kind: .folder, title: "Research"),
            .init(id: prefix + "one", parentID: prefix + "folder", kind: .bookmark, title: "One", url: URL(string: "https://example.invalid/one")),
            .init(id: prefix + "two", parentID: prefix + "folder", kind: .bookmark, title: "Two", url: URL(string: "https://example.invalid/two")),
            .init(id: prefix + "empty", parentID: prefix + "profile", kind: .folder, title: "Empty"),
            .init(id: prefix + "history", parentID: prefix + "profile", kind: .category, title: "History"),
            .init(id: prefix + "visit", parentID: prefix + "history", kind: .history, title: "Visit", url: URL(string: "https://example.invalid/visit"), visitedAt: Date())
        ])
    }

    private func settled(_ controller: BrowserImportPreviewController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.isPreparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isPreparing)
    }

    private func started(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.started)
    }

    @Test func sourcePreparationKeepsOptionalHistoryOffAndPreservesDestinationNames() async throws {
        let document = fixture(), controller = BrowserImportPreviewController()
        let prepared = try await Task.detached {
            Self.checkWorkerThread()
            return try BrowserImportPreparedSource(document)
        }.value
        controller.install(prepared)
        #expect(controller.selected == ["one", "two", "empty"])
        #expect(controller.rows.map(\.id) == ["profile", "folder", "empty", "history"])
        #expect(prepared.destinations["profile"]?.profileName == "Personal")
        #expect(prepared.destinations["profile"]?.spaceName == "Personal")
        controller.clear()
    }

    @Test func rapidCheckboxChangesAreReplayedWithoutLosingLaterEdits() async throws {
        let controller = BrowserImportPreviewController()
        controller.install(try BrowserImportPreparedSource(fixture()))
        controller.selectNone()
        controller.toggleSelection("folder")
        controller.toggleSelection("one")
        controller.toggleSelection("empty")
        #expect(controller.isPreparing, "Continue must wait for the current selection to be prepared")
        try await settled(controller)
        #expect(controller.selected == ["two", "empty"])
        #expect(controller.rows.first { $0.id == "profile" }?.state == .mixed)
        #expect(controller.rows.first { $0.id == "folder" }?.state == .mixed)
        controller.selectAll()
        controller.toggleSelection("folder")
        try await settled(controller)
        #expect(controller.selected == ["empty", "visit"])
        controller.selectNone()
        try await settled(controller)
        #expect(controller.selected.isEmpty)
        #expect(controller.rows.allSatisfy { $0.state == .off })
        controller.clear()
    }

    @Test func searchAndCollapsingPreserveExactSelectionAndCandidateContents() async throws {
        let document = fixture(), controller = BrowserImportPreviewController()
        controller.install(try BrowserImportPreparedSource(document))
        controller.selectNone(); controller.toggleSelection("one")
        controller.setSearch("One")
        try await settled(controller)
        #expect(controller.rows.map(\.id) == ["profile", "folder", "one"])
        #expect(controller.selected == ["one"])
        controller.toggleExpansion("profile")
        controller.setSearch("")
        try await settled(controller)
        #expect(controller.rows.map(\.id) == ["profile"])
        #expect(controller.selected == ["one"])
        let candidate = try document.candidate(into: BrowserWorkspace(), selecting: controller.selected,
            destinations: ["profile": .init(profileName: "Destination", spaceName: "Research")])
        #expect(candidate.batch.tabs.count == 1)
        #expect(candidate.batch.tabs.first?.currentURL == URL(string: "https://example.invalid/one"))
        #expect(candidate.batch.folders.map(\.name) == ["Research"])
        controller.clear()
    }

    @Test func lateSearchCannotReplaceANewerQueryOrItsQueuedSelection() async throws {
        let gate = Gate()
        let controller = BrowserImportPreviewController { tree, selection, expanded, search in
            Self.checkWorkerThread()
            if search == "One" { await gate.wait() }
            // Deliberately ignore cancellation inside the renderer. Publication
            // still belongs only to the current request after it returns.
            return tree.rows(selected: selection.selected, expanded: expanded, search: search)
        }
        controller.install(try BrowserImportPreparedSource(fixture()))
        controller.setSearch("One")
        try await started(gate)
        controller.selectNone(); controller.toggleSelection("two"); controller.setSearch("Two")
        try await settled(controller)
        #expect(controller.rows.map(\.id) == ["profile", "folder", "two"])
        #expect(controller.selected == ["two"])
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(controller.rows.map(\.id) == ["profile", "folder", "two"])
        #expect(controller.selected == ["two"])
        controller.clear()
    }

    @Test func replacingOrClosingTheSourceFencesLateWorkerResults() async throws {
        for replacing in [true, false] {
            let gate = Gate()
            let controller = BrowserImportPreviewController { tree, selection, expanded, search in
                if search == "One" { await gate.wait() }
                return tree.rows(selected: selection.selected, expanded: expanded, search: search)
            }
            controller.install(try BrowserImportPreparedSource(fixture()))
            controller.setSearch("One")
            try await started(gate)
            if replacing { controller.install(try BrowserImportPreparedSource(fixture("new."))) }
            else { controller.clear() }
            await gate.release()
            try await Task.sleep(for: .milliseconds(20))
            #expect(!controller.isPreparing)
            #expect(controller.selected == (replacing ? ["new.one", "new.two", "new.empty"] : []))
            #expect(controller.rows.allSatisfy { replacing ? $0.id.hasPrefix("new.") : false })
            #expect(controller.tree?.document.source == (replacing ? "new.Browser" : nil))
            controller.clear()
        }
    }
}
