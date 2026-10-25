// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Foundation
import Testing
import WebKit

/// Local files the person opened open again after a restart, through a
/// read-only bookmark kept per profile. Only temporary files are used.
@Suite(.serialized) @MainActor
struct LocalFileBookmarksTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyLocalFiles-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aRememberedFileOpensAgainEvenAfterItMoves() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appending(path: "notes.html")
        try Data("<p>notes".utf8).write(to: page)
        let storeFile = folder.appending(path: "LocalFiles/profile.plist")
        LocalFileBookmarks(fileURL: storeFile).remember(page)

        // After a restart: a new store from the saved file.
        let restarted = LocalFileBookmarks(fileURL: storeFile)
        guard case .readable(let reopened) = restarted.access(page) else {
            Issue.record("A remembered file opens again")
            return
        }
        #expect(reopened.standardizedFileURL.resolvingSymlinksInPath() == page.standardizedFileURL.resolvingSymlinksInPath())
        restarted.release(page)

        let moved = folder.appending(path: "Moved/notes.html")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: page, to: moved)
        guard case .readable(let found) = LocalFileBookmarks(fileURL: storeFile).access(page) else {
            Issue.record("A moved file is followed")
            return
        }
        #expect(found.standardizedFileURL.resolvingSymlinksInPath() == moved.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test func aDeletedOrNeverOpenedFileIsUnavailableAndPruningKeepsWhatTabsNeed() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appending(path: "kept.html"), dropped = folder.appending(path: "dropped.html")
        try Data("kept".utf8).write(to: kept)
        try Data("dropped".utf8).write(to: dropped)
        let storeFile = folder.appending(path: "profile.plist")
        let store = LocalFileBookmarks(fileURL: storeFile)
        store.remember(kept)
        store.remember(dropped)
        store.keepOnly([kept, URL(string: "https://example.com")!])
        #expect(LocalFileBookmarks(fileURL: storeFile).bookmarks.count == 1, "Only what tabs still need is kept")

        try FileManager.default.removeItem(at: kept)
        #expect(LocalFileBookmarks(fileURL: storeFile).access(kept) == .unavailable, "Deleted")
        #expect(store.access(URL(fileURLWithPath: "/nowhere/never-opened.html")) == .unavailable)
        store.removeFile()
        #expect(!FileManager.default.fileExists(atPath: storeFile.path))
    }

    @Test func aFileThatCantBeOpenedSaysWhyInsteadOfABlankPage() async throws {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true,
                                     input: NavigationInput(allowedSchemes: ["http", "https", "file"]), observesMemoryPressure: false)
        defer { manager.discardAll() }
        manager.localFiles = LocalFileBookmarks(fileURL: nil)
        let missing = URL(fileURLWithPath: "/nowhere/report.html")
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Report", currentURL: missing)
        manager.load(missing, in: tab)
        let page = try #require(manager.pages[tab.id])
        #expect(page.failure == WebViewManager.unavailableFileMessage(missing) && !page.isLoading)
        #expect(page.failure?.contains("“report.html”") == true)
    }
}
