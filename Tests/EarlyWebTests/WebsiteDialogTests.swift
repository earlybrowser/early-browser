// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

/// Website dialogs (alert, confirm, prompt) can't trap anyone: the person can
/// stop a page's dialogs, and a page asking where no one can answer is
/// answered at once, then silenced.
@Suite(.serialized) @MainActor
struct WebsiteDialogTests {
    @Test func theSecondDialogOffersToStopThemAndTheChoiceLastsForTheDocument() async throws {
        let fixture = PageToolFixture(pages: ["blank": "<title>Blank</title>"])
        defer { fixture.cleanup() }
        let page = try fixture.page(try await fixture.open("blank"))
        #expect(WebViewManager.nextDialog(of: page, canShow: true) == .present(offersSuppression: false), "The first asks plainly")
        #expect(WebViewManager.nextDialog(of: page, canShow: true) == .present(offersSuppression: true))
        page.suppressesDialogs = true
        #expect(WebViewManager.nextDialog(of: page, canShow: true) == .answerNow, "Once stopped, the rest are answered at once")
    }

    @Test func dialogsNoOneCanAnswerAreAnsweredAtOnceThenSilenced() async throws {
        let fixture = PageToolFixture(pages: ["blank": "<title>Blank</title>", "other": "<title>Other</title>"])
        defer { fixture.cleanup() }
        let page = try fixture.page(try await fixture.open("blank"))
        for _ in 1..<WebViewManager.unshownDialogLimit {
            #expect(WebViewManager.nextDialog(of: page, canShow: false) == .answerNow)
        }
        #expect(!page.suppressesDialogs, "A few unanswered dialogs aren't a flood")
        #expect(WebViewManager.nextDialog(of: page, canShow: false) == .answerNow)
        #expect(page.suppressesDialogs, "Asking faster than anyone could answer silences the page")
        let other = try fixture.page(try await fixture.open("other"))
        for _ in 0..<5 { _ = WebViewManager.nextDialog(of: other, canShow: false) }
        #expect(WebViewManager.nextDialog(of: other, canShow: true) == .present(offersSuppression: true))
        for _ in 1..<WebViewManager.unshownDialogLimit { _ = WebViewManager.nextDialog(of: other, canShow: false) }
        #expect(!other.suppressesDialogs, "Only unanswered dialogs in a row count")
    }

    /// A background tab looping on alert() is answered at once, then
    /// silenced, so it can't flood Early with requests; a new document asks again.
    @Test func aBackgroundPageLoopingOnAlertsIsSilencedAndANewDocumentStartsOver() async throws {
        let fixture = PageToolFixture(pages: [
            "loop": "<title>Loop</title><script>window.answered = 0; for (let i = 0; i < 200; i++) { alert(i); answered++; } document.title = 'done'</script>",
            "next": "<title>Next</title>"
        ])
        defer { fixture.cleanup() }
        let tab = try await fixture.open("loop")
        let page = try fixture.page(tab)
        try await fixture.waitUntil("the loop ran out") { page.view.title == "done" }
        #expect(page.suppressesDialogs && page.dialogRequests == 200)
        fixture.manager.load(fixture.url("next"), in: tab)
        try await fixture.waitUntil("the next page") { page.view.title == "Next" }
        #expect(!page.suppressesDialogs && page.dialogRequests == 0, "A new document asks again")
    }
}
