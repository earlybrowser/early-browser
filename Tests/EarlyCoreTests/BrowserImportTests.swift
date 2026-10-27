// SPDX-License-Identifier: MPL-2.0

import Foundation
import SQLite3
import Testing
@testable import EarlyCore

struct BrowserImportTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/BrowserImport")!)
    }
    func document() throws -> BrowserImportDocument {
        try BrowserImportReaders.read(fixture("ChromiumBookmarks.json"), name: "Test browser")
    }
    func destination(_ workspace: BrowserWorkspace) -> [String: BrowserImportDestination] {
        ["profile": .init(profileID: workspace.defaultProfileID, profileName: "Default",
                          spaceID: workspace.sessions[0].activeSpaceID, spaceName: "Personal")]
    }
    @Test func htmlAndChromiumPreserveLooseItemsFoldersEmptyFoldersAndIntentionalCopies() throws {
        for name in ["Bookmarks.html", "ChromiumBookmarks.json"] {
            let doc = try BrowserImportReaders.read(fixture(name), name: "Test")
            let urls = doc.nodes.compactMap(\.url)
            #expect(urls.count == 3)
            #expect(urls.filter { $0.path == "/reference" }.count == 2)
            #expect(doc.nodes.filter { $0.kind == .folder }.map(\.title) == ["Research", "Empty"])
            let current = BrowserWorkspace()
            let result = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: destination(current))
            #expect(result.workspace.profiles == current.profiles)
            #expect(result.workspace.sessions[0].spaces == current.sessions[0].spaces)
            #expect(result.batch.folders.count == 2)
            #expect(result.batch.tabs.count == 3)
            #expect(result.batch.tabs.allSatisfy { !$0.isOpen && $0.pinnedURL != nil })
            #expect(result.workspace.sessions[0].selectionBySpace.isEmpty)
            #expect(!result.batch.folders.contains { $0.name == "Imported Bookmarks" })
            _ = try EarlyStateArchive.decode(EarlyStateArchive(workspace: result.workspace, settings: nil).encoded())
        }
    }
    @Test func firefoxBookmarkBackupsPreserveEmptyContainersWithoutChildrenArrays() throws {
        let json: [String: Any] = ["typeCode": 2, "children": [["typeCode": 2, "title": "Empty"],
            ["typeCode": 2, "title": "Nested", "children": [["typeCode": 1, "title": "Page", "uri": "https://example.invalid/"]]]]]
        let doc = try BrowserImportReaders.read(JSONSerialization.data(withJSONObject: json), name: "Firefox")
        #expect(doc.nodes.filter { $0.kind == .folder }.map(\.title) == ["Empty", "Nested"])
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: ["profile": .init(profileName: "Firefox", spaceName: "Imported")])
        #expect(result.batch.folders.count == 2 && result.batch.tabs.count == 1)
    }

    @Test func partialSelectionRetainsAncestorsAndSearchNeverChangesIt() throws {
        let doc = try document(), current = BrowserWorkspace()
        let leaf = try #require(doc.nodes.first { $0.title == "Reference" })
        let selected: Set<String> = [leaf.id]
        let tree = BrowserImportTree(doc)
        let rows = tree.rows(selected: selected, expanded: ["profile"], search: "Reference")
        #expect(rows.contains { $0.node.title == "Research" })
        #expect(rows.contains { $0.node.kind == .profile && $0.state == .mixed })
        let result = try doc.candidate(into: current, selecting: selected, destinations: destination(current))
        #expect(result.batch.folders.map(\.name) == ["Research"])
        #expect(result.batch.tabs.map(\.title) == ["Reference"])
        #expect(selected == [leaf.id])
    }
    @Test func optionalHistoryAndOpenTabsAreOffAndOnlyKnownHistoryIsImported() throws {
        let safari = try BrowserImportReaders.read(fixture("SafariHistory.json"), name: "Safari")
        #expect(safari.initiallySelected.isEmpty)
        #expect(safari.nodes.filter { $0.kind == .history }.count == 1)
        let visit = try #require(safari.nodes.first { $0.kind == .history })
        #expect(visit.visitedAt == Date(timeIntervalSince1970: 1_793_059_200))
        let firefox = try BrowserImportReaders.read(fixture("FirefoxSession.json"), name: "Firefox")
        #expect(firefox.nodes.filter { $0.kind == .pin }.count == 1)
        #expect(firefox.nodes.filter { $0.kind == .openTab }.count == 1)
        #expect(firefox.initiallySelected.count == 1)
        #expect(!firefox.nodes.contains { $0.url?.path == "/private" })
        #expect(!String(describing: firefox).contains("DO-NOT-IMPORT"))
    }
    @Test func importedTodayTabsBelongToOneWindowAndExistingBrowsingIsUntouched() throws {
        var current = BrowserWorkspace()
        let profile = current.defaultProfileID, space = current.sessions[0].activeSpaceID
        let existing = BrowserTab(spaceID: space, profileID: profile, title: "Playing video", currentURL: URL(string: "https://example.invalid/video")!)
        current.sessions[0].tabs = [existing]; current.sessions[0].selectionBySpace[space] = existing.id
        current.sessions[0].additionalWindows = [BrowserSession(profileID: profile, activeSpaceID: space, spaces: current.sessions[0].spaces)]
        let doc = try BrowserImportReaders.read(fixture("FirefoxSession.json"), name: "Firefox")
        let result = try doc.candidate(into: current, selecting: Set(doc.nodes.map(\.id)), destinations: destination(current))
        let root = result.workspace.sessions[0]
        #expect(root.tabs.first == existing && root.selectionBySpace[space] == existing.id)
        #expect(root.tabs.filter { $0.pinnedURL == nil }.count == 2)
        #expect(root.additionalWindows[0].tabs.filter { $0.pinnedURL == nil }.isEmpty)
        #expect(root.additionalWindows[0].selectionBySpace.isEmpty)
    }
    @Test func profilesWithTheSameNameNeverMergeWithoutAnExplicitDestination() throws {
        let current = BrowserWorkspace()
        let doc = try document()
        let mapping: [String: BrowserImportDestination] = ["profile": .init(profileName: "Default", spaceName: "Personal")]
        let result = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: mapping)
        #expect(result.workspace.profiles.map(\.name) == ["Default", "Default 2"])
        #expect(result.batch.tabs.allSatisfy { $0.profileID != current.defaultProfileID })
        #expect(result.workspace.sessions[0] == current.sessions[0])
    }
    @Test func deletedDestinationsReturnToMappingAndDeepBranchesRequireAnExplicitChoice() throws {
        var doc = BrowserImportDocument(source: "Deep", nodes: [.init(id: "profile", kind: .profile, title: "Deep")])
        var parent = "profile"
        for index in 0..<11 {
            let id = "folder.\(index)"
            doc.nodes.append(.init(id: id, parentID: parent, kind: .folder, title: id)); parent = id
        }
        doc.nodes.append(.init(id: "link", parentID: parent, kind: .bookmark, title: "Deep link", url: URL(string: "https://example.invalid/deep")!))
        let current = BrowserWorkspace()
        #expect(throws: BrowserImportProblem.self) { try doc.candidate(into: current, selecting: ["link"], destinations: destination(current)) }
        let flat = try doc.candidate(into: current, selecting: ["link"], destinations: destination(current), flattenDeepFolders: true)
        #expect(flat.batch.folders.count == 9)
        #expect(flat.batch.tabs.count == 1 && flat.flattened.count >= 2)
        var mapping = destination(current); mapping["profile"]?.spaceID = UUID()
        #expect(throws: BrowserImportProblem.missingDestination) { try doc.candidate(into: current, selecting: ["link"], destinations: mapping) }
    }
    @Test func undoPreservesEditedItemsLaterChildrenAndLiveSelections() throws {
        let doc = try document(), current = BrowserWorkspace()
        let result = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: destination(current))
        var edited = result.workspace
        let changed = result.batch.tabs[0].id
        let index = try #require(edited.sessions[0].tabs.firstIndex { $0.id == changed })
        edited.sessions[0].tabs[index].customTitle = "Keep my edit"
        let folder = try #require(result.batch.folders.first { $0.name == "Research" })
        var later = BrowserTab(spaceID: folder.spaceID, profileID: current.defaultProfileID, title: "Later", currentURL: URL(string: "https://example.invalid/later")!, pinnedURL: URL(string: "https://example.invalid/later")!)
        later.folderID = folder.id; edited.sessions[0].tabs.append(later)
        let undone = try result.batch.undo(in: edited)
        #expect(undone.preserved == 1)
        #expect(Set(undone.workspace.sessions[0].tabs.map(\.id)) == [changed, later.id])
        #expect(undone.workspace.sessions[0].folders.contains { $0.id == folder.id })
        #expect(undone.workspace.browserImportBatchIDs?.isEmpty == true)
    }
    @Test func undoRetainsSplitPanesAndFoldersOccupiedInAnotherWindow() throws {
        var current = BrowserWorkspace()
        let session = current.sessions[0]
        current.sessions[0].additionalWindows = [BrowserSession(profileID: session.profileID, activeSpaceID: session.activeSpaceID, spaces: session.spaces)]
        let doc = try document()
        var result = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: destination(current))
        let folder = try #require(result.batch.folders.first { $0.name == "Research" })
        var later = BrowserTab(spaceID: folder.spaceID, profileID: session.profileID, title: "Later in second window", currentURL: URL(string: "https://example.invalid/later")!, pinnedURL: URL(string: "https://example.invalid/later")!)
        later.folderID = folder.id
        result.workspace.sessions[0].additionalWindows[0].tabs.append(later)
        let undone = try result.batch.undo(in: result.workspace)
        #expect(undone.workspace.sessions[0].folders.contains { $0.id == folder.id })
        #expect(undone.workspace.sessions[0].additionalWindows[0].tabs.map(\.id) == [later.id])
        #expect(try result.batch.undoConflicts(in: result.workspace).contains("Folder: Research"))
        let firefox = try BrowserImportReaders.read(fixture("FirefoxSession.json"), name: "Firefox")
        result = try firefox.candidate(into: current, selecting: BrowserImportTree(firefox).selectableIDs, destinations: destination(current))
        let a = try #require(result.batch.tabs.first { $0.pinnedURL == nil })
        let b = BrowserTab(spaceID: session.activeSpaceID, profileID: session.profileID, title: "Native", currentURL: URL(string: "https://example.invalid/native")!)
        result.workspace.sessions[0].tabs.append(b)
        let split = BrowserSplitGroup(spaceID: session.activeSpaceID, panes: [.init(tabID: b.id), .init(tabID: a.id)])
        result.workspace.sessions[0].splitGroups = [split]
        result.workspace.sessions[0].selectionBySpace[session.activeSpaceID] = b.id
        result.workspace.sessions[0].focusedPaneByGroupID[split.id] = split.panes[0].id
        let kept = try result.batch.undo(in: result.workspace)
        #expect(kept.workspace.sessions[0].splitGroups == [split])
        #expect(kept.workspace.sessions[0].tabs.contains { $0.id == a.id })
    }

    @Test func rebasingPreservesEditsMadeDuringReadingOrSaving() throws {
        let current = BrowserWorkspace(), doc = try document()
        let result = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: destination(current))
        var latest = current
        let live = BrowserTab(spaceID: latest.sessions[0].activeSpaceID, profileID: latest.defaultProfileID, title: "New while importing", currentURL: URL(string: "https://example.invalid/live")!)
        latest.sessions[0].tabs.append(live)
        latest.sessions[0].selectionBySpace[live.spaceID] = live.id
        let rebased = try result.adding(to: latest)
        #expect(rebased.sessions[0].tabs.first == live)
        #expect(rebased.sessions[0].selectionBySpace[live.spaceID] == live.id)
        #expect(rebased.sessions[0].tabs.count == result.batch.tabs.count + 1)
    }
    @Test func importsAppendAfterLegacyUnpositionedItemsIncludingAfterRebase() throws {
        var current = BrowserWorkspace()
        let profile = current.defaultProfileID, space = current.sessions[0].activeSpaceID
        let oldFolder = BrowserFolder(spaceID: space, name: "Existing folder")
        let oldPin = BrowserTab(spaceID: space, profileID: profile, title: "Existing pin", currentURL: URL(string: "https://example.invalid/old")!, pinnedURL: URL(string: "https://example.invalid/old")!, isOpen: false)
        current.sessions[0].folders = [oldFolder]; current.sessions[0].tabs = [oldPin]
        let doc = try document()
        let candidate = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: destination(current))
        func order(_ session: BrowserSession) -> [UUID] {
            TabStore(tabs: session.tabs, folders: session.folders).pinnedItems(in: space, parentID: nil).map(\.id)
        }
        #expect(Array(order(candidate.workspace.sessions[0]).prefix(2)) == [oldFolder.id, oldPin.id])
        let later = BrowserTab(spaceID: space, profileID: profile, title: "Later pin", currentURL: URL(string: "https://example.invalid/later")!, pinnedURL: URL(string: "https://example.invalid/later")!, isOpen: false)
        current.sessions[0].tabs.append(later)
        let rebased = try candidate.adding(to: current)
        #expect(Array(order(rebased.sessions[0]).prefix(3)) == [oldFolder.id, oldPin.id, later.id])
        let batch = candidate.batch.adjustedPositions(in: rebased)
        let undone = try batch.undo(in: rebased)
        #expect(order(undone.workspace.sessions[0]) == [oldFolder.id, oldPin.id, later.id])
        #expect(undone.preserved == 0)
        #expect(EarlyStateArchive(workspace: rebased, settings: nil).workspace.browserImportBatchIDs == nil)
    }
    @Test func zenInterleavesFoldersWithPinsUsingActualPredecessorFields() throws {
        let json: [String: Any] = ["spaces": [["uuid": "work", "name": "Work"]],
            "folders": [["id": "a", "name": "A", "workspaceId": "work", "prevSiblingInfo": ["type": "tab", "id": "first"]],
                        ["id": "b", "name": "B", "workspaceId": "work", "prevSiblingInfo": ["type": "group", "id": "a"]]],
            "tabs": [["zenWorkspace": "work", "zenSyncId": "first", "pinned": true, "entries": [["url": "https://example.invalid/first", "title": "First"]]],
                     ["zenWorkspace": "work", "zenSyncId": "last", "pinned": true, "entries": [["url": "https://example.invalid/last", "title": "Last"]]]]]
        let doc = try BrowserImportReaders.read(JSONSerialization.data(withJSONObject: json), name: "Zen")
        let current = BrowserWorkspace()
        let mapping = Dictionary(uniqueKeysWithValues: doc.destinationGroups.map { ($0.id, BrowserImportDestination(profileID: current.defaultProfileID, profileName: "Default", spaceID: current.sessions[0].activeSpaceID, spaceName: "Personal")) })
        let result = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: mapping)
        let store = TabStore(tabs: result.workspace.sessions[0].tabs, folders: result.workspace.sessions[0].folders)
        let titles = store.pinnedItems(in: current.sessions[0].activeSpaceID, parentID: nil).map { item in
            switch item { case .tab(let tab): tab.title; case .folder(let folder): folder.name }
        }
        #expect(titles == ["First", "A", "B", "Last"])
    }
    @Test func firefoxGroupsStayOptionalAndActiveImportedPagesSurviveUndo() throws {
        let json: [String: Any] = ["windows": [["groups": [["id": "research", "name": "Research"]],
            "tabs": [["groupId": "research", "entries": [["url": "https://example.invalid/group", "title": "Grouped"]]],
                     ["entries": [["url": "https://example.invalid/today", "title": "Today"]]]]]]]
        let doc = try BrowserImportReaders.read(JSONSerialization.data(withJSONObject: json), name: "Firefox")
        #expect(doc.initiallySelected.isEmpty)
        let tree = BrowserImportTree(doc)
        let current = BrowserWorkspace()
        var candidate = try doc.candidate(into: current, selecting: tree.selectableIDs, destinations: destination(current))
        #expect(candidate.batch.folders.map(\.name) == ["Research"])
        #expect(candidate.batch.tabs.first { $0.title == "Grouped" }?.pinnedURL != nil)
        let today = try #require(candidate.batch.tabs.first { $0.title == "Today" })
        candidate.workspace.sessions[0].selectionBySpace[today.spaceID] = today.id
        #expect(try candidate.batch.undoConflicts(in: candidate.workspace).contains("Page: Today"))
        #expect(try candidate.batch.undo(in: candidate.workspace).workspace.sessions[0].tabs.map(\.id) == [today.id])
        var selected = tree.selectableIDs
        selected = tree.toggling("profile", selected: selected)
        #expect(selected.isEmpty)
        #expect(tree.rows(selected: selected, expanded: ["profile"], search: "").allSatisfy { $0.state == .off })
    }
    @Test func emptyWorkspacesAndSeparateSourceProfilesRemainExplicit() throws {
        let doc = BrowserImportDocument(source: "Empty", nodes: [.init(id: "one", kind: .profile, title: "Same"),
            .init(id: "space", parentID: "one", kind: .space, title: "Empty Space"),
            .init(id: "two", kind: .profile, title: "Same"),
            .init(id: "pin", parentID: "two", kind: .pin, title: "Pin", url: URL(string: "https://example.invalid/pin")!)])
        let mapping = Dictionary(uniqueKeysWithValues: doc.destinationGroups.map { ($0.id, BrowserImportDestination(profileName: "Same", spaceName: $0.title)) })
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: mapping)
        #expect(result.batch.profiles.count == 2)
        #expect(result.workspace.profiles.map(\.name) == ["Default", "Same", "Same 2"])
        #expect(result.workspace.sessions.contains { $0.spaces.contains { $0.name == "Empty Space" } })
    }

    @Test func mozillaSizeAndCopyBoundsRejectInvalidLZ4() throws {
        let json = try fixture("FirefoxSession.json")
        var encoded = Data("mozLz40\0".utf8)
        let count = UInt32(json.count)
        encoded.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
        encoded.append(0xf0)
        var remaining = json.count - 15
        while remaining >= 255 { encoded.append(255); remaining -= 255 }
        encoded.append(UInt8(remaining)); encoded.append(json)
        #expect(try BrowserImportReaders.decompressMozilla(encoded) == json)
        #expect(try BrowserImportReaders.read(encoded, name: "Firefox").nodes.count > 1)
        #expect(throws: (any Error).self) { try BrowserImportReaders.decompressMozilla(encoded.dropLast()) }
        var giant = Data("mozLz40\0".utf8); giant.append(contentsOf: [255,255,255,255])
        #expect(throws: BrowserImportProblem.capacity) { try BrowserImportReaders.decompressMozilla(giant) }
    }
    @Test func unsupportedAndUnsafeInputsNeverBecomeSearchesOrOpenFiles() throws {
        for text in ["file:///tmp/a", "javascript:alert(1)", "chrome://settings", "https://user:secret@example.invalid", "a search query"] {
            #expect(BrowserImportDocument.webURL(text) == nil)
        }
        #expect(throws: (any Error).self) { try BrowserImportReaders.read(Data("{not json}".utf8), name: "Bad") }
        #expect(throws: (any Error).self) { try BrowserImportZIP.entries(Data(repeating: 0, count: 40)) }
        var cyclic = BrowserImportDocument(source: "Cycle", nodes: [.init(id: "a", parentID: "a", kind: .folder, title: "Cycle")])
        #expect(throws: BrowserImportProblem.invalid) { try cyclic.validate() }
        cyclic.nodes.append(cyclic.nodes[0])
        #expect(throws: BrowserImportProblem.capacity) { try cyclic.validate() }
    }

    @Test func sourceCapturedZenAndDiaFixturesPreserveVerifiedOrganization() throws {
        let dia = try BrowserImportReaders.read(fixture("Dia-1.54.2-Bookmarks.json"), name: "Dia")
        #expect(dia.nodes.filter { $0.kind == .bookmark }.map(\.title) == ["Synthetic Reference", "Synthetic Loose"])
        let zen = try BrowserImportReaders.read(fixture("Zen-1.23.4b.json"), name: "Zen")
        #expect(zen.nodes.filter { $0.kind == .space }.map(\.title) == ["Space", "Synthetic Research"])
        #expect(zen.nodes.filter { $0.kind == .folder }.map(\.title) == ["Synthetic Folder"])
        #expect(zen.nodes.filter { $0.kind == .pin }.count == 1)
        #expect(zen.nodes.filter { $0.kind == .openTab }.count == 1)
        let pin = try #require(zen.nodes.first { $0.kind == .pin })
        #expect(zen.nodes.first { $0.id == pin.parentID }?.title == "Synthetic Folder")
    }

    @Test func arcAlternatingDictionariesKeepProfileFavoritesPinsFoldersAndTodayDistinct() throws {
        let doc = try BrowserImportReaders.read(fixture("Arc-sidebar-alternating.json"), name: "Arc")
        #expect(doc.nodes.filter { $0.kind == .profile }.count == 1)
        #expect(doc.nodes.filter { $0.kind == .space }.map(\.title) == ["Research Space"])
        #expect(doc.nodes.filter { $0.kind == .favorite }.count == 1)
        #expect(doc.nodes.filter { $0.kind == .pin }.count == 2)
        #expect(doc.nodes.filter { $0.kind == .openTab }.count == 1)
        let mapping = Dictionary(uniqueKeysWithValues: doc.destinationGroups.map { ($0.id, BrowserImportDestination(profileName: "Arc", spaceName: "Research Space")) })
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: Set(doc.nodes.map(\.id)), destinations: mapping)
        #expect(result.batch.profiles.count == 1)
        #expect(result.batch.tabs.filter(\.isFavorite).count == 1)
        #expect(result.batch.spaces.count == 1)
    }

    @Test func zenContainersStaySeparateUntilMappedExplicitlyAndSessionSecretsAreDropped() throws {
        let input = #"{"spaces":[{"uuid":"work","name":"Work"}],"folders":[],"tabs":[{"zenWorkspace":"work","userContextId":1,"pinned":true,"entries":[{"url":"https://example.invalid/work"}]},{"userContextId":2,"zenEssential":true,"pinned":true,"entries":[{"url":"https://example.invalid/essential"}],"formdata":{"password":"DO-NOT-IMPORT"}}]}"#
        let doc = try BrowserImportReaders.read(Data(input.utf8), name: "Zen")
        let mapping = Dictionary(uniqueKeysWithValues: doc.destinationGroups.map { ($0.id, BrowserImportDestination(profileName: "Zen", spaceName: $0.title)) })
        let result = try doc.candidate(into: BrowserWorkspace(), selecting: doc.initiallySelected, destinations: mapping)
        #expect(result.batch.profiles.count == 2)
        #expect(Set(result.batch.tabs.map(\.profileID)).count == 2)
        #expect(result.batch.tabs.filter(\.isFavorite).count == 1)
        #expect(!String(describing: doc).contains("DO-NOT-IMPORT"))
    }

    @Test func chromiumV3SessionsKeepOnlyCurrentURLsAndRejectEncryptedOrTruncatedRecords() throws {
        func le(_ value: UInt32, _ count: Int = 4) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func record(_ id: UInt8, _ payload: Data) -> Data { le(UInt32(payload.count + 1), 2) + Data([id]) + payload }
        func string(_ value: String, wide: Bool = false) -> Data {
            let bytes = wide ? value.data(using: .utf16LittleEndian)! : Data(value.utf8)
            return le(UInt32(wide ? bytes.count / 2 : bytes.count)) + bytes + Data(repeating: 0, count: (4 - bytes.count % 4) % 4)
        }
        var session = Data("SNSS".utf8) + le(3)
        session += record(0, le(1) + le(2))
        session += record(2, le(2) + le(0))
        session += record(12, le(2) + Data([1,0,0,0]))
        let contents = le(2) + le(0) + string("https://example.invalid/session") + string("Session title", wide: true) + Data("DO-NOT-IMPORT-PAGE-STATE".utf8)
        session += record(6, le(UInt32(contents.count)) + contents)
        let doc = try BrowserImportReaders.read(session, name: "Chromium")
        #expect(doc.nodes.filter { $0.kind == .pin }.map(\.title) == ["Session title"])
        #expect(!String(describing: doc).contains("DO-NOT-IMPORT"))
        #expect(throws: (any Error).self) { try BrowserImportReaders.read(Data("SNSS".utf8) + le(5), name: "Encrypted") }
        #expect(throws: (any Error).self) { try BrowserImportReaders.read(session.dropLast(), name: "Truncated") }
    }

    @Test func nonUTF8BookmarkExportsAndExistingLocalPagesRemainSupported() throws {
        let html = "<html><body><dl><dt><a href='https://example.invalid/'>Café</a></dt></dl></body></html>"
        let utf16 = html.data(using: .utf16)!
        #expect(try BrowserImportReaders.read(utf16, name: "Bookmarks").nodes.contains { $0.title == "Café" })
        var current = BrowserWorkspace()
        let local = BrowserTab(spaceID: current.sessions[0].activeSpaceID, profileID: current.defaultProfileID,
                               title: "Local file", currentURL: URL(fileURLWithPath: "/tmp/import-test.html"))
        current.sessions[0].tabs = [local]
        let doc = try document(), input = NavigationInput(allowedSchemes: ["http", "https", "file"])
        let result = try doc.candidate(into: current, selecting: doc.initiallySelected, destinations: destination(current), using: input)
        #expect(result.workspace.sessions[0].tabs.first == local)
    }
}
