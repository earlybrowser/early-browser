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
