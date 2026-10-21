// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct NavigationResponsePolicyTests {
    private let url = URL(string: "https://example.com/private/document?secret=token#fragment")!

    private func response(_ mime: String?, status: Int = 200, disposition: String? = nil, url: URL? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let mime { headers["Content-Type"] = mime }
        if let disposition { headers["Content-Disposition"] = disposition }
        return HTTPURLResponse(url: url ?? self.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func fixture() -> (WebViewManager, BrowserTab, BrowserPage) {
        _ = NSApplication.shared
        let profile = UUID()
        let manager = WebViewManager(profileID: profile, ephemeral: true, observesMemoryPressure: false)
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Page", currentURL: url)
        return (manager, tab, manager.prepare(tab)) // Prepare only: no network.
    }

    private func interruption(_ url: URL? = nil, domain: String = "WebKitErrorDomain", code: Int = 102) -> NSError {
        NSError(domain: domain, code: code, userInfo: url.map { [NSURLErrorFailingURLErrorKey: $0] } ?? [:])
    }

    @Test func renderableInlineAndNoContentResponsesAreNotMistakenForDownloads() {
        #expect(NavigationResponseDisposition.classify(response("text/html"), canShowMIMEType: true, isMainFrame: true) == .allow)
        #expect(NavigationResponseDisposition.classify(response("application/pdf", disposition: "inline; filename=sample.pdf"), canShowMIMEType: true, isMainFrame: true) == .allow)
        for status in [204, 205] {
            #expect(NavigationResponseDisposition.classify(response(nil, status: status), canShowMIMEType: false, isMainFrame: true) == .allow)
        }
        #expect(NavigationResponseDisposition.classify(response("text/html", status: 404), canShowMIMEType: true, isMainFrame: true) == .allow)
    }

    @Test func attachmentsBinaryDownloadsAndUnknownUnsupportedTypesAreDistinct() {
        #expect(NavigationResponseDisposition.classify(response("text/html", disposition: " Attachment ; filename=page.html"), canShowMIMEType: true, isMainFrame: true) == .download)
        #expect(NavigationResponseDisposition.classify(response("application/octet-stream"), canShowMIMEType: false, isMainFrame: true) == .download)
        #expect(NavigationResponseDisposition.classify(response("application/x-unknown"), canShowMIMEType: false, isMainFrame: true) == .unsupported)
        #expect(NavigationResponseDisposition.classify(response(nil), canShowMIMEType: false, isMainFrame: true) == .unsupported)
    }

    @Test func unsupportedSubframeIsQuietAndItsMatchingFailureCannotFailTheMainDocument() {
        let (manager, tab, page) = fixture()
        defer { manager.discardAll() }
        let embedded = URL(string: "https://media.example.com/embed/binary")!
        #expect(manager.navigationResponsePolicy(for: page.view, response: response("application/octet-stream", url: embedded),
            canShowMIMEType: false, isMainFrame: false) == .cancel)
        #expect(page.navigationNotice == nil && page.failure == nil)
        manager.webView(page.view, didFail: nil, withError: interruption(embedded))
        #expect(page.failure == nil && page.requestedURL == tab.currentURL)
        #expect(manager.navigationDiagnostics.last?.event == "expected-policy-cancellation")
        #expect(manager.navigationDiagnostics.last?.isMainFrame == false)
    }

    @Test func intentionalMainFrameCancellationShowsOnlyItsNoticeAndNextNavigationClearsIt() {
        let (manager, tab, page) = fixture()
        defer { manager.discardAll() }
        #expect(manager.navigationResponsePolicy(for: page.view, response: response("application/zip"),
            canShowMIMEType: false, isMainFrame: true) == .cancel)
        #expect(page.navigationNotice == NavigationResponseDisposition.download.notice)
        manager.webView(page.view, didFailProvisionalNavigation: nil, withError: interruption(url))
        #expect(page.failure == nil && page.requestedURL == tab.currentURL)
        #expect(page.navigationNotice != nil && manager.lifecycle(for: tab.id).state != .failed)
        manager.webView(page.view, didStartProvisionalNavigation: nil)
        #expect(page.navigationNotice == nil && page.failure == nil)
        #expect(manager.navigationResponsePolicy(for: page.view, response: response("text/html"),
            canShowMIMEType: true, isMainFrame: true) == .allow)
        manager.webView(page.view, didCommit: nil)
        #expect(page.navigationNotice == nil && page.requestedURL == tab.currentURL)
    }

    @Test func unrelatedPolicyErrorsAndRealNetworkFailuresRemainVisible() {
        for error in [interruption(), interruption(domain: "UnrelatedDomain"),
                      interruption(domain: "UnrelatedDomain", code: NSURLErrorCancelled),
                      URLError(.notConnectedToInternet) as NSError] {
            let (manager, tab, page) = fixture()
            defer { manager.discardAll() }
            manager.webView(page.view, didFailProvisionalNavigation: nil, withError: error)
            #expect(page.failure != nil && manager.lifecycle(for: tab.id).state == .failed)
            #expect(page.requestedURL == tab.currentURL)
        }
        let (manager, _, page) = fixture()
        defer { manager.discardAll() }
        manager.webView(page.view, didFail: nil, withError: URLError(.cancelled))
        #expect(page.failure == nil)
    }

    @Test func cancellationRequiresTheSameURLAndCannotLeakIntoALaterNavigation() {
        let (manager, _, page) = fixture()
        defer { manager.discardAll() }
        _ = manager.navigationResponsePolicy(for: page.view, response: response("application/zip"), canShowMIMEType: false, isMainFrame: true)
        manager.webView(page.view, didFail: nil, withError: interruption(URL(string: "https://other.example/failure")!))
        #expect(page.failure != nil)
        manager.webView(page.view, didStartProvisionalNavigation: nil)
        #expect(page.failure == nil && page.navigationNotice == nil)
        manager.webView(page.view, didFail: nil, withError: interruption(url))
        #expect(page.failure != nil, "An old cancellation cannot suppress a new failure")
    }

    @Test func subframeWithoutAFailingURLCannotHideAnUnrelatedMainFrameError() {
        let (manager, _, page) = fixture()
        defer { manager.discardAll() }
        _ = manager.navigationResponsePolicy(for: page.view, response: response("application/octet-stream"), canShowMIMEType: false, isMainFrame: false)
        manager.webView(page.view, didFail: nil, withError: interruption())
        #expect(page.failure != nil)
    }

    @Test func diagnosticsAreBoundedRedactedAndClearedOnCloseAndRetiredCallbacksAreIgnored() throws {
        let (manager, tab, page) = fixture()
        defer { manager.discardAll() }
        let sensitive = URL(string: "https://person:password@example.com/private/token?credential=secret#fragment")!
        for _ in 0..<100 {
            _ = manager.navigationResponsePolicy(for: page.view, response: response("text/html", status: 201, url: sensitive), canShowMIMEType: true, isMainFrame: true)
        }
        #expect(manager.navigationDiagnostics.count == 24)
        let diagnostic = try #require(manager.navigationDiagnostics.last)
        #expect(diagnostic.origin == "https://example.com" && diagnostic.status == 201)
        #expect(diagnostic.mimeType == "text/html" && diagnostic.isMainFrame)
        for secret in ["person", "password", "private", "token", "credential", "fragment", "secret"] {
            #expect(!diagnostic.origin.contains(secret))
        }
        manager.discard(tabID: tab.id)
        #expect(manager.navigationDiagnostics.isEmpty)
        #expect(manager.navigationResponsePolicy(for: page.view, response: response("application/zip"), canShowMIMEType: false, isMainFrame: true) == .cancel)
        manager.webView(page.view, didFail: nil, withError: interruption(url))
        #expect(manager.navigationDiagnostics.isEmpty && page.failure == nil && page.navigationNotice == nil)
    }
}
