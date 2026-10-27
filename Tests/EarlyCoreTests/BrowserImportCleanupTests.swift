// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

struct BrowserImportCleanupTests {
    func candidate() throws -> BrowserImportCandidate {
        let workspace = BrowserWorkspace()
        let doc = BrowserImportDocument(source: "Mixed", nodes: [
            .init(id: "a", kind: .profile, title: "Personal"),
            .init(id: "af", parentID: "a", kind: .folder, title: "Personal folder"),
            .init(id: "at", parentID: "af", kind: .pin, title: "Personal page", url: URL(string: "https://example.invalid/personal")!),
            .init(id: "b", kind: .profile, title: "Work"),
            .init(id: "bf", parentID: "b", kind: .folder, title: "Work folder"),
            .init(id: "bt", parentID: "bf", kind: .pin, title: "Work page", url: URL(string: "https://example.invalid/work")!)])
        return try doc.candidate(into: workspace, selecting: doc.initiallySelected, destinations: [
            "a": .init(profileID: workspace.defaultProfileID, profileName: "Default", spaceID: workspace.sessions[0].activeSpaceID, spaceName: "Personal"),
            "b": .init(profileName: "Work", spaceName: "Work")])
    }
    @Test func legacyAndCurrentRecordsKeepOnlySurvivingOwners() throws {
        let result = try candidate()
        let work = try #require(result.batch.profiles.first?.id)
        var workspace = result.workspace
        let deleted = workspace.deleteProfile(work); #expect(deleted)
        for legacy in [false, true] {
            var batch = result.batch
            if legacy { batch.folderProfiles = nil }
            let retained = try #require(batch.retaining(in: workspace))
            #expect(retained.profiles.isEmpty && retained.spaces.isEmpty)
            #expect(retained.tabs.map(\.title) == ["Personal page"])
            #expect(retained.folders.map(\.name) == ["Personal folder"])
            #expect(try retained.undo(in: workspace).workspace.sessions[0].tabs.isEmpty)
        }
        let decoded = try JSONDecoder().decode(BrowserImportBatch.self, from: JSONEncoder().encode(result.batch))
        #expect(decoded == result.batch)
        var legacy = result.batch; legacy.folderProfiles = nil
        #expect(try JSONDecoder().decode(BrowserImportBatch.self, from: JSONEncoder().encode(legacy)).folderProfiles == nil)
    }
    @Test func movedItemsRemainTrackedAndUndoPreservesTheirNewContext() throws {
        let result = try candidate()
        let work = try #require(result.batch.profiles.first?.id)
        let space = try #require(result.batch.spaces.first { $0.profileID == work }?.id)
        var workspace = result.workspace
        let moved = workspace.moveSpace(space, from: work, to: workspace.defaultProfileID); #expect(moved)
        let deleted = workspace.deleteProfile(work); #expect(deleted)
        let retained = try #require(result.batch.retaining(in: workspace))
        #expect(retained.tabs.count == 2 && retained.folders.count == 2)
        let undo = try retained.undo(in: workspace)
        #expect(undo.workspace.sessions[0].tabs.map(\.title) == ["Work page"])
        #expect(undo.workspace.sessions[0].tabs[0].profileID == workspace.defaultProfileID)
        #expect(undo.workspace.sessions[0].folders.map(\.name) == ["Work folder"])
    }
    @Test(arguments: [false, true], [false, true])
    func movedEmptyFoldersSurviveUndo(deleteOriginalProfile: Bool, legacyJournal: Bool) throws {
        let original = BrowserWorkspace()
        let document = BrowserImportDocument(source: "Empty folders", nodes: [
            .init(id: "p", kind: .profile, title: "Imported"),
            .init(id: "parent", parentID: "p", kind: .folder, title: "Parent"),
            .init(id: "child", parentID: "parent", kind: .folder, title: "Empty child")])
        let result = try document.candidate(into: original, selecting: document.initiallySelected,
            destinations: ["p": .init(profileName: "Imported", spaceName: "Imported")])
        // Unchanged empty folders still disappear when Undo is used before a move.
        #expect(try result.batch.undo(in: result.workspace).workspace.sessions.flatMap(\.folders).isEmpty)
        let source = try #require(result.batch.profiles.first?.id)
        let space = try #require(result.batch.spaces.first?.id)
        var workspace = result.workspace
        let moved = workspace.moveSpace(space, from: source, to: original.defaultProfileID)
        #expect(moved)
        if deleteOriginalProfile {
            let deleted = workspace.deleteProfile(source)
            #expect(deleted)
        }
        var batch = result.batch
        if legacyJournal { batch.folderProfiles = nil }
        batch = try JSONDecoder().decode(BrowserImportBatch.self, from: JSONEncoder().encode(batch))
        let retained = try #require(batch.retaining(in: workspace))
        #expect(try retained.undoConflicts(in: workspace) == ["Folder: Parent", "Folder: Empty child"])
        let undone = try retained.undo(in: workspace).workspace
        let destination = try #require(undone.session(for: original.defaultProfileID))
        #expect(destination.folders.map(\.id) == result.batch.folders.map(\.id))
        #expect(destination.spaces.first { $0.id == space }?.profileID == original.defaultProfileID)
        #expect(undone.browserImportBatchIDs?.contains(batch.id) == false)
    }

    @Test func legacyEmptyFoldersWithUnknownOwnershipArePreservedConservatively() throws {
        let workspace = BrowserWorkspace()
        let document = BrowserImportDocument(source: "Legacy folders", nodes: [
            .init(id: "p", kind: .profile, title: "Imported"),
            .init(id: "f", parentID: "p", kind: .folder, title: "Empty folder")])
        let result = try document.candidate(into: workspace, selecting: document.initiallySelected,
            destinations: ["p": .init(profileID: workspace.defaultProfileID, profileName: "Default",
                spaceID: workspace.sessions[0].activeSpaceID, spaceName: "Personal")])
        #expect(try result.batch.undo(in: result.workspace).workspace.sessions[0].folders.isEmpty)
        var legacy = result.batch
        legacy.folderProfiles = nil
        #expect(legacy.spaces.isEmpty && legacy.tabs.isEmpty)
        #expect(try legacy.undoConflicts(in: result.workspace) == ["Folder: Empty folder"])
        #expect(try legacy.undo(in: result.workspace).workspace.sessions[0].folders == result.batch.folders)
    }

    @Test func recoveryPrunesCommittedRecordsWithoutOpeningMissingHistoryFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyImportPruning-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = BrowserImportJournal(directory: root.appendingPathComponent("BrowserImports"))
        let history = root.appendingPathComponent("History")
        let result = try candidate()
        let work = try #require(result.batch.profiles.first?.id)
        var workspace = result.workspace, batch = result.batch
        batch.historyProfiles = [workspace.defaultProfileID, work]
        try await journal.write(.init(batch: batch, state: .importing))
        let deleted = workspace.deleteProfile(work); #expect(deleted)
        let retained = try await journal.recover(workspace: workspace, historyDirectory: history)
        #expect(retained.first?.historyProfiles == [workspace.defaultProfileID])
        #expect(retained.first?.folders.count == 1)
        #expect(try await journal.entries().first?.state == .complete)
        #expect(!FileManager.default.fileExists(atPath: history.path))
        // Removing the workspace marker finishes Undo without recreating either history DB.
        workspace.browserImportBatchIDs = []
        #expect(try await journal.recover(workspace: workspace, historyDirectory: history).isEmpty)
        #expect(try await journal.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }
}
