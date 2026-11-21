// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct ExtensionLoadingTests {
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @available(macOS 15.4, *)
    private func fixture(isPrivate: Bool = false) async throws -> (ExtensionHost, InstalledExtension, WKWebExtension, URL) {
        _ = NSApplication.shared
        let folder = try ExtensionScenarios.extensionFolder(["manifest.json": #"{"manifest_version":3,"name":"Delayed","version":"1","permissions":["storage"],"optional_permissions":["bookmarks"],"host_permissions":["<all_urls>"]}"#])
        let catalog = ExtensionCatalog(fileURL: nil)
        let item = InstalledExtension(source: .files(folderName: folder.lastPathComponent), name: "Delayed", version: "1",
            allowedSites: ["gone.example"], grantedPermissions: ["bookmarks"], allowsPrivateWindows: true, allowsLocalFiles: true)
        catalog.add(item)
        let host = ExtensionHost(catalog: catalog, filesDirectory: folder.deletingLastPathComponent(),
            websiteDataStore: .nonPersistent(), storageIdentifier: nil, isPrivate: isPrivate)
        return (host, item, try await WKWebExtension(resourceBaseURL: folder), folder)
    }

    @Test func lateInitializationUsesCurrentSiteFileAndOptionalPermissions() async throws {
        guard #available(macOS 15.4, *) else { return }
        let (host, item, webExtension, folder) = try await fixture()
        let gate = Gate()
        defer { gate.release(); host.unloadAll(); try? FileManager.default.removeItem(at: folder) }
        host.makeWebExtension = { _, _ in await gate.wait(); return webExtension }
        let loading = Task { await host.load(item.id) }
        try await wait { gate.entered }
        host.catalog.change(item.id) {
            $0.siteAccess = .whenClicked
            $0.allowedSites = ["kept.example"]
            $0.allowsLocalFiles = false
            $0.grantedPermissions = []
        }
        host.refreshAccess(item.id)
        gate.release()
        #expect(await loading.value)
        let context = try #require(host.context(item.id))
        let granted: Set<WKWebExtensionContext.PermissionStatus> = [.grantedExplicitly, .grantedImplicitly]
        #expect(!granted.contains(context.permissionStatus(for: URL(string: "https://gone.example/")!)))
        #expect(!granted.contains(context.permissionStatus(for: URL(string: "https://other.example/")!)))
        #expect(granted.contains(context.permissionStatus(for: URL(string: "https://kept.example/")!)))
        #expect(!granted.contains(context.permissionStatus(for: URL(fileURLWithPath: "/tmp/example.html"))))
        #expect(!host.allowsLocalFiles(context))
        #expect(!granted.contains(context.permissionStatus(for: WKWebExtension.Permission(rawValue: "bookmarks"))))
    }

    enum PromptChange: CaseIterable { case unchanged, disable, replaceContext, changeAccessBack, seal }

    @Test(arguments: PromptChange.allCases)
    func optionalSiteApprovalBelongsToTheContextAndCurrentPermissionChoices(change: PromptChange) async throws {
        guard #available(macOS 15.4, *) else { return }
        let (host, item, _, folder) = try await fixture()
        let gate = Gate()
        defer { gate.release(); host.unloadAll(); try? FileManager.default.removeItem(at: folder) }
        try #require(await host.load(item.id))
        let context = try #require(host.context(item.id))
        host.askForAccess = { _, _ in await gate.wait(); return true }
        let site = URL(string: "https://fixture.example")!
        let permission = Task {
            await host.webExtensionController(host.controller, promptForPermissionToAccess: [site], in: nil, for: context)
        }
        try await wait { gate.entered }
        switch change {
        case .unchanged: break
        case .disable: host.catalog.change(item.id) { $0.isEnabled = false }
        case .replaceContext:
            host.unload(item.id)
            try #require(await host.load(item.id))
        case .changeAccessBack:
            host.catalog.change(item.id) { $0.allowsLocalFiles.toggle() }
            host.catalog.change(item.id) { $0.allowsLocalFiles.toggle() }
        case .seal: host.catalog.acceptsChanges = false
        }
        gate.release()
        let (granted, _) = await permission.value
        #expect(granted == (change == .unchanged ? [site] : []))
        #expect(host.catalog.installed(item.id)?.allowedSites.contains("fixture.example") == (change == .unchanged))
    }

    enum Invalidation: CaseIterable { case disable, privateAccess, unload, unloadAll, remove, replace, disableEnable, cancellation }

    @Test(arguments: Invalidation.allCases)
    func obsoleteInitializationCannotPublish(reason: Invalidation) async throws {
        guard #available(macOS 15.4, *) else { return }
        let (host, item, webExtension, folder) = try await fixture(isPrivate: true)
        let gate = Gate()
        defer { gate.release(); host.unloadAll(); try? FileManager.default.removeItem(at: folder) }
        host.makeWebExtension = { _, _ in await gate.wait(); return webExtension }
        let loading = Task { await host.load(item.id) }
        try await wait { gate.entered }
        switch reason {
        case .disable: host.catalog.change(item.id) { $0.isEnabled = false }
        case .privateAccess: host.catalog.change(item.id) { $0.allowsPrivateWindows = false }
        case .unload: host.unload(item.id)
        case .unloadAll: host.unloadAll()
        case .remove: await host.remove(item.id)
        case .replace:
            host.catalog.remove(item.id)
            host.catalog.add(item)
        case .disableEnable:
            host.catalog.change(item.id) { $0.isEnabled = false }
            host.catalog.change(item.id) { $0.isEnabled = true }
        case .cancellation: loading.cancel()
        }
        gate.release()
        #expect(!(await loading.value))
        #expect(host.contexts.isEmpty && host.controller.extensionContexts.isEmpty && host.problems.isEmpty)
    }

    @Test func anOldLoadFailureCannotReplaceTheNewLoadsResult() async throws {
        guard #available(macOS 15.4, *) else { return }
        let (host, item, webExtension, folder) = try await fixture()
        let gate = Gate()
        defer { gate.release(); host.unloadAll(); try? FileManager.default.removeItem(at: folder) }
        var calls = 0
        host.makeWebExtension = { _, _ in
            calls += 1
            if calls == 1 { await gate.wait(); throw CocoaError(.fileReadUnknown) }
            return webExtension
        }
        let first = Task { await host.load(item.id) }
        try await wait { gate.entered }
        #expect(await host.load(item.id))
        let current = try #require(host.context(item.id))
        gate.release()
        #expect(!(await first.value))
        #expect(host.context(item.id) === current && host.problems[item.id] == nil)
    }

    @Test func closingAHostBeforeItsScheduledTaskStartsPreventsLoading() async throws {
        guard #available(macOS 15.4, *) else { return }
        let (host, _, webExtension, folder) = try await fixture(isPrivate: true)
        defer { host.unloadAll(); try? FileManager.default.removeItem(at: folder) }
        var initialized = false
        host.makeWebExtension = { _, _ in initialized = true; return webExtension }
        let scheduled = host.scheduleLoading()
        host.unloadAll()
        await scheduled.value
        #expect(!initialized && host.contexts.isEmpty)
    }
}
