// SPDX-License-Identifier: MPL-2.0

import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Security state, permission decisions and Automatic Picture in Picture on
/// local fixture pages. No camera, microphone, network or Picture in Picture
/// window is used: page scripts are observed instead of run where noted.
@Suite(.serialized) @MainActor
struct SiteSecurityTests {
    private final class Scripts {
        var runs: [(view: WKWebView, script: String, frame: WKFrameInfo?)] = []
        var result = true
    }

    private func observe(_ manager: WebViewManager) -> Scripts {
        let scripts = Scripts()
        manager.runPageScript = { view, script, frame in
            await Task.yield()
            scripts.runs.append((view, script, frame))
            return scripts.result
        }
        return scripts
    }

    @Test func certificateFailuresShowUntilTheNextNavigation() async throws {
        let fixture = PageToolFixture(pages: ["one": "<title>One</title>", "two": "<title>Two</title>"])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("one")
        let page = try fixture.page(tab)
        #expect(page.security == .none && page.serverTrust == nil, "Early's own pages are not websites")

        let expired = URL(string: "https://expired.example/")!
        fixture.manager.webView(page.view, didFailProvisionalNavigation: nil, withError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: [NSURLErrorFailingURLErrorKey: expired]))
        #expect(page.security == .certificateProblem && page.failure != nil)

        fixture.manager.load(fixture.url("two"), in: tab)
        try await fixture.waitUntil("next page") { page.view.url == fixture.url("two") && !page.isLoading }
        #expect(page.security == .none && page.failure == nil)

        // Other failures are not certificate problems.
        fixture.manager.webView(page.view, didFailProvisionalNavigation: nil, withError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: expired]))
        #expect(page.security == .none && page.failure != nil)
        #expect(WebViewManager.isCertificateError(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)))
        #expect(!WebViewManager.isCertificateError(NSError(domain: "WebKitErrorDomain", code: NSURLErrorServerCertificateUntrusted)))
    }

    @Test func savedChoicesAnswerAtOnceAndUnansweredPromptsSaveNothing() async throws {
        let fixture = PageToolFixture(pages: ["one": "<title>One</title>"])
        defer { fixture.cleanup() }
        let view = try fixture.page(try await fixture.open("one")).view
        let manager = fixture.manager
        let meet = "https://meet.example.com"
        var answers: [Bool] = []
        manager.decidePermission([.camera], origin: meet, host: "meet.example.com", in: view) { answers.append($0) }
        #expect(answers == [false], "Without a profile's choices nothing is allowed")

        let store = SitePermissions(fileURL: nil)
        manager.sitePermissions = store
        store.set(.allow, for: [.camera, .microphone], origin: meet)
        manager.decidePermission([.camera, .microphone], origin: meet, host: "meet.example.com", in: view) { answers.append($0) }
        store.set(.block, for: [.microphone], origin: meet)
        manager.decidePermission([.camera, .microphone], origin: meet, host: "meet.example.com", in: view) { answers.append($0) }
        manager.decidePermission([.camera], origin: nil, host: "", in: view) { answers.append($0) }
        #expect(answers == [false, true, false, false])

        // This page has no window to ask in: the request is denied, unsaved.
        manager.decidePermission([.location], origin: "https://maps.example.com", host: "maps.example.com", in: view) { answers.append($0) }
        #expect(answers.last == false && store.decisions["https://maps.example.com"] == nil)
        #expect(WebViewManager.permissionPhrase([.camera, .microphone]) == "your camera and microphone")
        #expect(WebViewManager.permissionPhrase([.location]) == "your location")
    }

    @Test func leavingAPlayingTabMovesItsVideoOutAndReturningBringsItBack() async throws {
        let fixture = PageToolFixture(pages: ["video": "<title>Video</title>", "other": "<title>Other</title>"])
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let video = try await fixture.open("video"), other = try await fixture.open("other")
        let page = try fixture.page(video)
        let scripts = observe(manager)
        var enabled = true
        manager.automaticPictureInPicture = { enabled }
        #expect(manager.setPresentation(visibleTabIDs: [video.id], focusedTabID: video.id))
        _ = manager.updateMediaActivity(in: page.view, token: "player", playing: true)

        #expect(manager.setPresentation(visibleTabIDs: [other.id], focusedTabID: other.id))
        try await fixture.waitUntil("entered") {
            if case .entered = manager.automaticPictureInPictureTabs[video.id] { return true }
            return false
        }
        #expect(scripts.runs.map(\.script) == [WebViewManager.enterPictureInPictureScript])
        #expect(scripts.runs.first?.view === page.view && scripts.runs.first?.frame == nil, "The main frame when no frame is known")

        #expect(manager.setPresentation(visibleTabIDs: [video.id], focusedTabID: video.id))
        try await fixture.waitUntil("returned") { scripts.runs.count == 2 }
        #expect(scripts.runs.last?.script == WebViewManager.exitPictureInPictureScript)
        #expect(manager.automaticPictureInPictureTabs.isEmpty)

        // Coming back before the video has moved out returns it at once (the
        // request may have stalled) and again if it lands afterwards.
        #expect(manager.setPresentation(visibleTabIDs: [other.id], focusedTabID: other.id))
        #expect(manager.setPresentation(visibleTabIDs: [video.id], focusedTabID: video.id))
        try await fixture.waitUntil("returned while moving") { scripts.runs.count == 5 }
        #expect(Set(scripts.runs.suffix(3).map(\.script)) == [WebViewManager.enterPictureInPictureScript, WebViewManager.exitPictureInPictureScript])
        #expect(scripts.runs.suffix(3).filter { $0.script == WebViewManager.exitPictureInPictureScript }.count == 2)
        #expect(manager.automaticPictureInPictureTabs.isEmpty)

        // Nothing moves when the setting is off, in fullscreen, or with nothing playing.
        enabled = false
        #expect(manager.setPresentation(visibleTabIDs: [other.id], focusedTabID: other.id))
        enabled = true
        #expect(manager.setPresentation(visibleTabIDs: [video.id], focusedTabID: video.id))
        page.isFullscreen = true
        #expect(manager.setPresentation(visibleTabIDs: [other.id], focusedTabID: other.id))
        page.isFullscreen = false
        #expect(manager.setPresentation(visibleTabIDs: [video.id], focusedTabID: video.id))
        _ = manager.updateMediaActivity(in: page.view, token: "player", playing: false)
        #expect(manager.setPresentation(visibleTabIDs: [other.id], focusedTabID: other.id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(scripts.runs.count == 5 && manager.automaticPictureInPictureTabs.isEmpty)

        // A video that cannot move out is not brought back later.
        _ = manager.updateMediaActivity(in: page.view, token: "player", playing: true)
        #expect(manager.setPresentation(visibleTabIDs: [video.id], focusedTabID: video.id))
        scripts.result = false
        #expect(manager.setPresentation(visibleTabIDs: [other.id], focusedTabID: other.id))
        try await fixture.waitUntil("refused") { scripts.runs.count == 6 && manager.automaticPictureInPictureTabs.isEmpty }
        #expect(manager.setPresentation(visibleTabIDs: [video.id], focusedTabID: video.id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(scripts.runs.count == 6)
    }

    @Test func pagesAllowPictureInPictureAndItsScriptsRunWithoutAVideo() async throws {
        let fixture = PageToolFixture(pages: ["one": "<title>One</title><p>No video here</p>"])
        defer { fixture.cleanup() }
        let view = try fixture.page(try await fixture.open("one")).view
        // macOS 26 and 27 WebKit both have the preference; without it nothing is set.
        #expect(WebViewManager.supportsPictureInPicture)
        #expect(view.configuration.preferences.value(forKey: WebViewManager.pictureInPicturePreference) as? Bool == true)
        for script in [WebViewManager.enterPictureInPictureScript, WebViewManager.exitPictureInPictureScript] {
            let result = try await view.callAsyncJavaScript(script, contentWorld: .defaultClient)
            #expect(result as? Bool == false, "Valid JavaScript that finds nothing to do")
        }
    }

    @Test func developerModeMakesOnlyThatTabInspectableUntilItCloses() async throws {
        let fixture = PageToolFixture(pages: ["one": "<title>One</title>", "two": "<title>Two</title>"])
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let one = try await fixture.open("one"), two = try await fixture.open("two")
        let first = try fixture.page(one), second = try fixture.page(two)
        #expect(!first.view.isInspectable && !second.view.isInspectable, "Inspection is off unless asked for")
        #expect(manager.setDeveloperMode(true, for: one.id))
        #expect(first.view.isInspectable && manager.isDeveloperModeOn(one.id))
        #expect(!second.view.isInspectable && !manager.isDeveloperModeOn(two.id))
        #expect(manager.setDeveloperMode(false, for: one.id) && !first.view.isInspectable)
        #expect(manager.setDeveloperMode(true, for: one.id))
        manager.discard(tabID: one.id)
        #expect(!manager.isDeveloperModeOn(one.id) && !manager.canToggleDeveloperMode(one.id))
        #expect(!manager.setDeveloperMode(true, for: UUID()))
    }

    @Test func pageSourceIsTheCurrentDocumentReadWithoutAskingTheWebsiteAgain() async throws {
        let html = "<!doctype html><title>Source</title><p id=a>Original</p><script>document.getElementById('a').textContent = 'Changed'</script>"
        let fixture = PageToolFixture(pages: ["source": html])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("source")
        #expect(fixture.manager.canShowPageSource(tab.id))
        let source = try #require(await fixture.manager.pageSource(tab.id))
        #expect(source.hasPrefix("<!DOCTYPE html>") && source.contains("<p id=\"a\">Changed</p>"), "Scripts' changes are included")
        #expect(source.contains("<title>Source</title>"))

        let page = try fixture.page(tab)
        fixture.manager.webView(page.view, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        #expect(!fixture.manager.canShowPageSource(tab.id), "A failed load has no source to show")
        #expect(await fixture.manager.pageSource(tab.id) == nil)
        #expect(await fixture.manager.pageSource(UUID()) == nil)
    }

    @Test func clearingOneWebsitesDataLeavesOtherWebsitesAlone() async throws {
        let fixture = PageToolFixture(pages: ["one": "<title>One</title>"])
        defer { fixture.cleanup() }
        _ = try await fixture.open("one")
        let store = fixture.manager.websiteDataStore
        for domain in ["example.com", "other.org"] {
            let cookie = try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "session", .value: "1"]))
            await store.httpCookieStore.setCookie(cookie)
        }
        let cookies = Set([WKWebsiteDataTypeCookies])
        #expect(Set(await store.dataRecords(ofTypes: cookies).map(\.displayName)) == ["example.com", "other.org"])
        #expect(await fixture.manager.clearWebsiteData(forHost: "www.example.com") == 1)
        #expect(await store.dataRecords(ofTypes: cookies).map(\.displayName) == ["other.org"])
        #expect(await fixture.manager.clearWebsiteData(forHost: "nothing.example") == 0)

        #expect(WebViewManager.dataRecord("example.com", belongsTo: "Shop.Example.com"))
        #expect(WebViewManager.dataRecord("example.com", belongsTo: "example.com"))
        #expect(!WebViewManager.dataRecord("example.com", belongsTo: "notexample.com"), "Only a dot separates a subdomain")
        #expect(!WebViewManager.dataRecord("", belongsTo: "example.com"))
    }
}
