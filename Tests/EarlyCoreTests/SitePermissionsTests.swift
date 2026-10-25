// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct SitePermissionsTests {
    @Test func originsAreWebSchemeHostAndAnExplicitPortOnly() {
        #expect(SitePermissions.origin(of: URL(string: "https://Meet.Example.com:443/room?x=1")!) == "https://meet.example.com")
        #expect(SitePermissions.origin(of: URL(string: "http://localhost:8080/")!) == "http://localhost:8080")
        #expect(SitePermissions.origin(of: URL(string: "http://example.com:80")!) == "http://example.com")
        #expect(SitePermissions.origin(of: URL(fileURLWithPath: "/tmp/page.html")) == nil)
        #expect(SitePermissions.origin(of: URL(string: "early-test://fixture/one")!) == nil)
        #expect(SitePermissions.origin(scheme: "HTTPS", host: "Meet.Example.com", port: 0) == "https://meet.example.com",
                "WebKit reports a default port as 0")
        #expect(SitePermissions.origin(scheme: "https", host: "example.com", port: 8443) == "https://example.com:8443")
        #expect(SitePermissions.origin(scheme: "about", host: "", port: 0) == nil)
    }

    @Test func choicesAreSavedPerSiteAndTheStrictestRequestedOneWins() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "EarlyPermissions-\(UUID())/profile.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let meet = "https://meet.example.com", maps = "https://maps.example.com"
        let store = SitePermissions(fileURL: file)
        #expect(store.decision(for: meet, .camera) == .ask && store.decision(for: meet, [.camera, .microphone]) == .ask)
        store.set(.allow, for: [.camera], origin: meet)
        #expect(store.decision(for: meet, [.camera]) == .allow)
        #expect(store.decision(for: meet, [.camera, .microphone]) == .ask, "Every requested permission must be allowed")
        store.set(.block, for: [.microphone], origin: meet)
        #expect(store.decision(for: meet, [.camera, .microphone]) == .block, "Any blocked permission blocks the request")
        store.set(.allow, for: [.location], origin: maps)
        #expect(store.decision(for: maps, .camera) == .ask, "Choices belong to one site")

        let reopened = SitePermissions(fileURL: file)
        #expect(reopened.decisions == store.decisions)
        reopened.set(.ask, for: [.location], origin: maps)
        #expect(reopened.decisions[maps] == nil, "Ask is the default and is not stored")
        #expect(SitePermissions(fileURL: file).decisions[maps] == nil)

        reopened.removeFile()
        #expect(reopened.decisions.isEmpty && !FileManager.default.fileExists(atPath: file.path))
        #expect(SitePermissions(fileURL: file).decisions.isEmpty)
    }

    @Test func privateStoresKeepChoicesInMemoryAndUnreadableFilesAreIgnored() throws {
        let memory = SitePermissions(fileURL: nil)
        memory.set(.allow, for: [.camera], origin: "https://meet.example.com")
        #expect(memory.decision(for: "https://meet.example.com", .camera) == .allow && memory.fileURL == nil)

        let file = FileManager.default.temporaryDirectory.appending(path: "EarlyPermissions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        #expect(SitePermissions(fileURL: file).decisions.isEmpty)
        try Data(#"{"https://a.example":{"camera":"allow","speaker":"allow","microphone":"maybe"}}"#.utf8).write(to: file)
        #expect(SitePermissions(fileURL: file).decisions == ["https://a.example": [.camera: .allow]], "Unknown entries are skipped")
    }

    /// A choice that can't reach the disk says so, still applies, and is
    /// written once Try Again succeeds. It never looks saved when it isn't.
    @Test func aChoiceThatCantBeSavedIsReportedAndSavedOnRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EarlyPermissions-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appending(path: "profile.json")
        let store = SitePermissions(fileURL: file)
        store.set(.allow, for: [.camera], origin: "https://meet.example.com")
        #expect(store.saveError == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        store.set(.block, for: [.camera], origin: "https://meet.example.com")
        #expect(store.saveError != nil, "The failed write is reported")
        #expect(store.decision(for: "https://meet.example.com", .camera) == .block, "It applies until Early quits")
        #expect(SitePermissions(fileURL: file).decision(for: "https://meet.example.com", .camera) == .allow, "Not on disk yet")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        store.retrySaving()
        #expect(store.saveError == nil)
        #expect(SitePermissions(fileURL: file).decision(for: "https://meet.example.com", .camera) == .block, "Saved on retry")
    }

    @Test func securityFollowsTheSchemeSecureContentAndCertificateFailures() {
        let secure = URL(string: "https://example.com")!, plain = URL(string: "http://example.com")!
        #expect(PageSecurity.classify(url: secure, hasOnlySecureContent: true, certificateFailed: false) == .secure)
        #expect(PageSecurity.classify(url: secure, hasOnlySecureContent: false, certificateFailed: false) == .mixedContent)
        #expect(PageSecurity.classify(url: plain, hasOnlySecureContent: false, certificateFailed: false) == .notSecure)
        #expect(PageSecurity.classify(url: secure, hasOnlySecureContent: true, certificateFailed: true) == .certificateProblem)
        #expect(PageSecurity.classify(url: URL(fileURLWithPath: "/tmp/a.html"), hasOnlySecureContent: false, certificateFailed: false) == .localFile)
        #expect(PageSecurity.classify(url: URL(string: "early-test://fixture/one"), hasOnlySecureContent: false, certificateFailed: false) == .none)
        #expect(PageSecurity.classify(url: nil, hasOnlySecureContent: false, certificateFailed: false) == .none)
        let insecure = [PageSecurity.notSecure, .mixedContent, .certificateProblem].map(\.isInsecure)
        let trusted = [PageSecurity.secure, .localFile, .none].map(\.isInsecure)
        #expect(insecure == [true, true, true] && trusted == [false, false, false])
    }

    @Test func automaticPictureInPictureIsOnByDefaultAndRemembered() {
        let suite = "local.early.tests.pip.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        #expect(preferences.automaticPictureInPicture)
        preferences.automaticPictureInPicture = false
        #expect(!BrowserPreferences(defaults: defaults).automaticPictureInPicture)
    }
}
