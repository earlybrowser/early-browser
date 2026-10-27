// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3
import Testing
@testable import EarlyCore

struct BrowserImportContextTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyImportContexts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func history(_ name: String, in directory: URL) throws -> URL {
        let json: [String: Any] = ["metadata": ["data_type": "history", "schema_version": 1],
            "history": [["url": "https://example.invalid/shared-url", "title": name, "time_usec": Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000_000)]]]
        let url = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: json).write(to: url); return url
    }
    func html(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(#"<DL><DT><H3>Personal</H3><DL><DT><A HREF="https://example.invalid/same">Personal link</A></DL><DT><H3>Work</H3><DL><DT><A HREF="https://example.invalid/same">Work link</A></DL></DL>"#.utf8).write(to: url)
        return url
    }
    func destinations(_ document: BrowserImportDocument) -> [String: BrowserImportDestination] {
        let byID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: document.destinationGroups.map { group in
            var node = group
            while node.kind != .profile { node = byID[node.parentID!]! }
            return (group.id, .init(profileName: node.title, spaceName: group.kind == .space ? group.title : "Personal"))
        })
    }
    @Test func safariSingleProfileCombinesFilesWithoutAnExtraBookmarksProfile() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = try BrowserImportFiles.readSafariExports([html("Bookmarks.html", in: root), history("History.json", in: root), html("ReadingList.html", in: root)])
        #expect(doc.nodes.filter { $0.kind == .profile }.count == 1)
        #expect(doc.collections.count == 2)
        #expect(doc.nodes.contains { $0.kind == .folder && $0.title == "Reading List" })
        var mapping = destinations(doc)
        mapping[doc.destinationGroups[0].id]?.profileName = "Personal"
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: BrowserImportTree(doc).selectableIDs, destinations: mapping)
        #expect(result.batch.profiles.map(\.name) == ["Personal"])
        #expect(result.batch.tabs.count == 4)
        #expect(result.history.count == 1)
        #expect(result.batch.spaces.count == 1)
        #expect(result.batch.tabs.allSatisfy { !$0.isOpen })
    }
    @Test func safariFourProfilesRequireExplicitSharedDestinationsAndKeepHistorySeparate() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try ["History.json", "History - Work.json", "History - Banking.json", "History - Study.json"].map { try history($0, in: root) }
        let doc = try BrowserImportFiles.readSafariExports(files + [html("Bookmarks.html", in: root)])
        let profiles = doc.nodes.filter { $0.kind == .profile }
        #expect(profiles.count == 4)
        #expect(!doc.nodes.contains { $0.kind == .profile && $0.title == "Safari Bookmarks" })
        let mapping = destinations(doc), selected = BrowserImportTree(doc).selectableIDs
        #expect(throws: BrowserImportProblem.self) { try doc.candidate(into: BrowserWorkspace(), selecting: selected, destinations: mapping) }
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: selected, destinations: mapping,
            collectionTargets: [doc.collections[0].id: Set(profiles.prefix(2).map(\.id))])
        #expect(result.batch.profiles.count == 4)
        #expect(result.history.count == 4)
        #expect(result.batch.tabs.count == 4)
        #expect(Set(result.batch.tabs.map(\.profileID)).count == 2)
        #expect(doc.initiallySelected.isDisjoint(with: doc.nodes.filter { $0.kind == .history }.map(\.id)))
    }
    @Test func safariFoldersCanBeAssignedIndividuallyWithoutDuplicatingOtherBranches() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = try BrowserImportFiles.readSafariExports([html("Bookmarks.html", in: root), history("History.json", in: root), history("History - Work.json", in: root)])
        let profiles = doc.nodes.filter { $0.kind == .profile }
        let work = try #require(profiles.first { $0.title == "Work" })
        let personal = try #require(profiles.first { $0.id != work.id })
        let folders = doc.collectionFolders(doc.collections[0], selecting: doc.initiallySelected)
        let targets = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, Set([$0.title == "Work" ? work.id : personal.id])) })
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: destinations(doc), collectionTargets: targets)
        #expect(result.batch.tabs.count == 2 && result.batch.folders.count == 2)
        #expect(result.batch.profiles.count == 2)
        let workProfile = try #require(result.batch.profiles.first { $0.name == "Work" })
        #expect(result.batch.tabs.first { $0.title == "Work link" }?.profileID == workProfile.id)
        #expect(result.batch.tabs.first { $0.title == "Personal link" }?.profileID != workProfile.id)
    }
    @Test func sameNamedSafariFilesRemainSeparateUntilExplicitlyCombined() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = try BrowserImportFiles.readSafariExports([history("History - Work.json", in: root), history("History — Work.json", in: root), html("Bookmarks.html", in: root)])
        let profiles = doc.nodes.filter { $0.kind == .profile }
        #expect(profiles.map(\.title) == ["Work", "Work"])
        var mapping = destinations(doc)
        var targets = [doc.collections[0].id: Set(profiles.map(\.id))]
        let selected = BrowserImportTree(doc).selectableIDs
        #expect(try doc.candidate(into: BrowserWorkspace(), selecting: selected, destinations: mapping, collectionTargets: targets).batch.profiles.count == 2)
        mapping[profiles[1].id]?.newProfileGroup = profiles[0].id
        mapping[profiles[0].id]?.spaceName = "Research"
        let combined = try doc.candidate(into: BrowserWorkspace(), selecting: selected, destinations: mapping, collectionTargets: targets)
        #expect(combined.batch.profiles.count == 1)
        #expect(combined.batch.spaces.map(\.name) == ["Research"])
        #expect(combined.batch.tabs.count == 2, "A shared collection is copied once into a combined destination")
        targets[doc.collections[0].id] = ["unknown"]
        #expect(throws: BrowserImportProblem.self) { try doc.candidate(into: BrowserWorkspace(), selecting: selected, destinations: mapping, collectionTargets: targets) }
    }
    func firefoxProfile(_ directory: URL, contextual: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("places.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let timestamp = Int64(Date().addingTimeInterval(-30).timeIntervalSince1970 * 1_000_000)
        let visits = contextual
            ? "INSERT INTO moz_historyvisits VALUES(1,1,\(timestamp),0),(2,1,\(timestamp),1),(3,1,\(timestamp),2);"
            : "INSERT INTO moz_historyvisits VALUES(1,1,\(timestamp));"
        let sql = """
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY,url TEXT,title TEXT);
        CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY,parent INTEGER,type INTEGER,title TEXT,fk INTEGER,position INTEGER);
        CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY,place_id INTEGER,visit_date INTEGER\(contextual ? ",userContextId INTEGER" : ""));
        INSERT INTO moz_places VALUES(1,'https://example.invalid/same','Same URL');
        INSERT INTO moz_bookmarks VALUES(1,0,2,'Root',NULL,0),(2,1,1,'Shared bookmark',1,0);
        \(visits)
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let containers: [String: Any] = ["identities": [["userContextId": 1, "public": true, "name": "Personal"], ["userContextId": 2, "public": true, "name": "Work"]]]
        try JSONSerialization.data(withJSONObject: containers).write(to: directory.appendingPathComponent("containers.json"))
        let session: [String: Any] = ["windows": [["tabs": [["userContextId": 1, "pinned": true, "entries": [["url": "https://example.invalid/personal"]]],
            ["userContextId": 2, "pinned": true, "entries": [["url": "https://example.invalid/work"]]]]]]]
        try JSONSerialization.data(withJSONObject: session).write(to: directory.appendingPathComponent("sessionstore.jsonlz4"))
    }
    @Test func firefoxFourProfilesScopeContainerIDsAndCombineMatchingContextFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for number in 1...4 { try firefoxProfile(root.appendingPathComponent("Profile \(number)"), contextual: true) }
        let doc = try BrowserImportFiles.read(root, source: "Firefox")
        #expect(doc.nodes.filter { $0.kind == .profile }.count == 12)
        #expect(doc.nodes.filter { $0.kind == .history }.count == 12, "Equal URL/time in different containers survives normalization")
        #expect(doc.collections.count == 8)
        for collection in doc.collections { #expect(collection.profileIDs.count == 3) }
        let targets = Dictionary(uniqueKeysWithValues: doc.collections.map { ($0.id, Set([$0.profileIDs[0]])) })
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: BrowserImportTree(doc).selectableIDs,
            destinations: destinations(doc), collectionTargets: targets)
        #expect(result.batch.profiles.count == 12)
        #expect(result.history.count == 12)
        #expect(result.batch.tabs.count == 12)
    }
    @Test func firefoxLegacyHistoryRequiresOneExplicitContextAndStartsUnchecked() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try firefoxProfile(root, contextual: false)
        let doc = try BrowserImportFiles.read(root, source: "Firefox")
        let unassigned = try #require(doc.collections.first { !$0.allowsCopies })
        #expect(doc.initiallySelected.isDisjoint(with: doc.nodes.filter { $0.kind == .history }.map(\.id)))
        var targets = Dictionary(uniqueKeysWithValues: doc.collections.map { ($0.id, Set([$0.profileIDs[0]])) })
        targets[unassigned.id] = Set(unassigned.profileIDs.prefix(2))
        #expect(throws: BrowserImportProblem.self) { try doc.candidate(into: BrowserWorkspace(), selecting: BrowserImportTree(doc).selectableIDs, destinations: destinations(doc), collectionTargets: targets) }
        targets[unassigned.id] = [unassigned.profileIDs[1]]
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: BrowserImportTree(doc).selectableIDs, destinations: destinations(doc), collectionTargets: targets)
        #expect(result.history.count == 1)
        #expect(result.history.values.first?.count == 1)
    }
    @Test func zenUsesRealContextsIncludingEmptyWorkspacesAndSplitsMixedWorkspaces() throws {
        let json: [String: Any] = ["spaces": [["uuid": "one", "name": "Personal", "containerTabId": 3],
            ["uuid": "two", "name": "Study", "containerTabId": 3], ["uuid": "empty", "name": "Empty Work", "containerTabId": 7]],
            "folders": [["id": "folder", "workspaceId": "one", "name": "Research"]],
            "tabs": [["zenWorkspace": "one", "userContextId": 3, "pinned": true, "entries": [["url": "https://example.invalid/personal"]]],
                ["zenWorkspace": "one", "userContextId": 7, "pinned": true, "entries": [["url": "https://example.invalid/work"]]],
                ["zenWorkspace": "two", "userContextId": 3, "pinned": true, "entries": [["url": "https://example.invalid/study"]]]]]
        let doc = try BrowserImportReaders.read(JSONSerialization.data(withJSONObject: json), name: "Zen")
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: destinations(doc))
        #expect(result.batch.profiles.count == 2)
        #expect(result.batch.tabs.first { $0.currentURL.path == "/personal" }?.profileID == result.batch.tabs.first { $0.currentURL.path == "/study" }?.profileID)
        #expect(result.batch.tabs.first { $0.currentURL.path == "/work" }?.profileID != result.batch.tabs.first { $0.currentURL.path == "/study" }?.profileID)
        let empty = try #require(result.batch.spaces.first { $0.name == "Empty Work" })
        #expect(result.batch.tabs.first { $0.currentURL.path == "/work" }?.profileID == empty.profileID)
        #expect(doc.notices.contains { $0.contains("multiple website contexts") })
    }
    @Test func zenDeduplicatesMirrorsByIdentityWhilePreservingIntentionalURLCopies() throws {
        let tab: [String: Any] = ["zenSyncId": "same-tab", "userContextId": 1, "pinned": true, "entries": [["url": "https://example.invalid/same"]]]
        var another = tab; another["zenSyncId"] = "intentional-copy"
        var json: [String: Any] = ["spaces": [], "tabs": [tab, tab, another]]
        let doc = try BrowserImportReaders.read(JSONSerialization.data(withJSONObject: json), name: "Zen")
        #expect(doc.nodes.filter { $0.url != nil }.count == 2)
        another["zenSyncId"] = "same-tab"; another["userContextId"] = 2
        json["tabs"] = [tab, another]
        #expect(throws: BrowserImportProblem.self) { try BrowserImportReaders.read(JSONSerialization.data(withJSONObject: json), name: "Zen") }
    }
    @Test func sharedZenEssentialsUseExplicitCopiesAndDiscardOtherPreferences() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let json: [String: Any] = ["spaces": [], "tabs": [["zenEssential": true, "userContextId": 1, "entries": [["url": "https://example.invalid/essential"]]],
            ["pinned": true, "userContextId": 2, "entries": [["url": "https://example.invalid/work"]]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("zen-sessions.jsonlz4"))
        try Data("user_pref(\"zen.workspaces.separate-essentials\", false);\nuser_pref(\"secret\", \"DO-NOT-IMPORT\");\n".utf8).write(to: root.appendingPathComponent("prefs.js"))
        let doc = try BrowserImportFiles.read(root, source: "Zen")
        let collection = try #require(doc.collections.first { $0.id == "shared.essentials" })
        #expect(!String(describing: doc).contains("DO-NOT-IMPORT"))
        let contexts = doc.nodes.filter { $0.kind == .profile && $0.id.hasPrefix("container.") }
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: destinations(doc), collectionTargets: [collection.id: Set(contexts.map(\.id))])
        #expect(result.batch.tabs.filter(\.isFavorite).count == 2)
        #expect(result.batch.profiles.count == 2)
    }
    @Test func profileCapacityIsCheckedWithoutCombiningContextsOrChangingInput() throws {
        var doc = BrowserImportDocument(source: "Many contexts")
        for number in 0..<36 {
            doc.nodes += [.init(id: "p\(number)", kind: .profile, title: "Context \(number)"),
                .init(id: "t\(number)", parentID: "p\(number)", kind: .pin, title: "Page", url: URL(string: "https://example.invalid/")!)]
        }
        let current = BrowserWorkspace(), before = current
        #expect(throws: BrowserImportProblem.capacity) { try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: destinations(doc)) }
        #expect(current == before)
        #expect(try doc.candidate(into: current, selecting: ["t0"], destinations: destinations(doc)).batch.profiles.count == 1)
    }

    @Test func sharedCopiesAreBoundedBeforeAllocatingTheExpandedWorkspace() throws {
        var doc = BrowserImportDocument(source: "Shared")
        let profiles = (0..<31).map { "profile.\($0)" }
        doc.nodes = profiles.map { .init(id: $0, kind: .profile, title: $0) }
        doc.nodes.append(.init(id: "shared", kind: .category, title: "Shared bookmarks"))
        for number in 0..<3_000 {
            doc.nodes.append(.init(id: "page.\(number)", parentID: "shared", kind: .bookmark, title: "Page", url: URL(string: "https://example.invalid/\(number)")!))
        }
        doc.collections = [.init(id: "shared", profileIDs: profiles, explanation: "Choose copies")]
        #expect(throws: BrowserImportProblem.capacity) {
            try doc.resolvingCollections(selecting: doc.initiallySelected, targets: ["shared": Set(profiles)])
        }
        #expect(doc.nodes.count == 3_032)
    }

    @Test func separatorsInNamesAndIdentitiesCannotAccidentallyCombineProfiles() throws {
        let doc = BrowserImportDocument(source: "Distinct", nodes: [
            .init(id: "profile|Work", kind: .profile, title: "Account"),
            .init(id: "first", parentID: "profile|Work", kind: .pin, title: "First", url: URL(string: "https://example.invalid/first")!),
            .init(id: "profile", kind: .profile, title: "Work|Account"),
            .init(id: "second", parentID: "profile", kind: .pin, title: "Second", url: URL(string: "https://example.invalid/second")!)])
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: destinations(doc))
        #expect(result.batch.profiles.count == 2)
        #expect(Set(result.batch.tabs.map(\.profileID)).count == 2)
    }

    @Test func cancellingSharedRoutingLeavesTheSourceUntouched() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = try BrowserImportFiles.readSafariExports([html("Bookmarks.html", in: root)])
        let mapping = destinations(doc)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: mapping)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled routing must throw") } catch is CancellationError {} catch { throw error }
        #expect(doc.nodes.filter { $0.kind == .bookmark }.count == 2)
    }
}
