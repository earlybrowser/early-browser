// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct ExtensionCatalogTests {
    @Test func extensionsAndTheirChoicesAreSavedPerProfile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EarlyExtensions-\(UUID())/profile.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let catalog = ExtensionCatalog(fileURL: file)
        let app = InstalledExtension(source: .app(extensionPath: "/Applications/Blocker.app/Contents/PlugIns/B.appex",
                                                  bundleIdentifier: "com.example.blocker"), name: "Blocker", version: "1.0")
        catalog.add(app)
        catalog.add(app)
        catalog.add(InstalledExtension(source: app.source, name: "Again", version: "2"))
        #expect(catalog.extensions.count == 1, "One entry per extension and per source")
        #expect(app.isEnabled && app.siteAccess == .allSites && !app.allowsPrivateWindows, "On, everywhere, not in private windows")
        catalog.change(app.id) {
            $0.siteAccess = .whenClicked
            $0.allowedSites = ["example.com"]
            $0.allowsPrivateWindows = true
        }
        let files = InstalledExtension(source: .files(folderName: "abc"), name: "Folder", version: "0.1")
        catalog.add(files)
        #expect(catalog.installed(source: .files(folderName: "abc"))?.id == files.id)

        let reopened = ExtensionCatalog(fileURL: file)
        #expect(reopened.extensions == catalog.extensions)
        #expect(reopened.installed(app.id)?.siteAccess == .whenClicked && reopened.installed(app.id)?.allowsPrivateWindows == true)
        #expect(reopened.installed(app.id)?.source.isFromApp == true && reopened.installed(files.id)?.source.isFromApp == false)
        reopened.remove(app.id)
        #expect(ExtensionCatalog(fileURL: file).extensions.map(\.id) == [files.id])
        reopened.removeFile()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Turning an extension off when its catalog can't be written says so;
    /// it stays off until Early quits, and is written once Try Again succeeds.
    @Test func aChangeThatCantBeSavedIsReportedAndSavedOnRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyExtensions-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appending(path: "profile.json")
        let catalog = ExtensionCatalog(fileURL: file)
        let item = InstalledExtension(source: .files(folderName: "abc"), name: "Folder", version: "1")
        catalog.add(item)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        catalog.change(item.id) { $0.isEnabled = false }
        #expect(catalog.saveError != nil && catalog.installed(item.id)?.isEnabled == false)
        #expect(ExtensionCatalog(fileURL: file).installed(item.id)?.isEnabled == true, "Not on disk yet")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        catalog.retrySaving()
        #expect(catalog.saveError == nil && ExtensionCatalog(fileURL: file).installed(item.id)?.isEnabled == false)
    }

    /// A catalog from before the local-files switch keeps every extension,
    /// with local files not allowed.
    @Test func aCatalogFromAnEarlierVersionStillOpens() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EarlyExtensions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"""
            [{"id":"6E1C8F7A-3B7D-4C3E-9D4B-2C1E0F9A8B7C","source":{"files":{"folderName":"abc"}},"name":"Old","version":"1",
              "isEnabled":true,"siteAccess":"allSites","allowedSites":[],"grantedPermissions":[],"allowsPrivateWindows":true,
              "added":767000000}]
            """#.utf8).write(to: file)
        let catalog = ExtensionCatalog(fileURL: file)
        #expect(catalog.extensions.count == 1 && catalog.extensions.first?.name == "Old")
        #expect(catalog.extensions.first?.allowsLocalFiles == false && catalog.extensions.first?.allowsPrivateWindows == true)
    }

    @Test func oneWebsiteIsItsHost() {
        #expect(ExtensionCatalog.site(of: URL(string: "https://Docs.Example.com/page?x=1")!) == "docs.example.com")
        #expect(ExtensionCatalog.site(of: URL(string: "http://127.0.0.1:8080/")!) == "127.0.0.1")
        #expect(ExtensionCatalog.site(of: URL(string: "safari-web-extension://id/popup.html")!) == nil)
        #expect(ExtensionCatalog.site(of: URL(fileURLWithPath: "/tmp/page.html")) == nil)
    }

    @Test func extensionPagesOpenInTabsButStayOutOfHistory() throws {
        let page = URL(string: "safari-web-extension://4d7b5a02-635b-4290-9d12-5d6231d61c90/dashboard.html")!
        let input = NavigationInput(allowedSchemes: Set(["http", "https"]).union(NavigationInput.extensionSchemes))
        #expect(try input.validate(page) == page)
        #expect(throws: NavigationInputError.self) { try NavigationInput().validate(page) }
        #expect(!HistoryStore.records(page))
        #expect(!HistoryStore.records(URL(string: "webkit-extension://id/options.html")!))
        #expect(HistoryStore.records(URL(string: "https://example.com/")!))
    }
}
