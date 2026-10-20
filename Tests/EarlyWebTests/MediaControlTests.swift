// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
@testable import EarlyWeb
import Testing
import WebKit

@Suite @MainActor
struct MediaControlTests {
    @Test func htmlMediaAndCrossOriginFramesMuteWithoutChangingVolumeOrPlayerMutePreferences() async throws {
        _ = NSApplication.shared
        let profile = UUID()
        let input = NavigationInput(allowedSchemes: ["http", "https", "early-media"])
        let fixture = MediaPages()
        let manager = WebViewManager(profileID: profile, ephemeral: true, input: input,
            faviconStore: FaviconStore { _, _, _ in nil }) {
            $0.setURLSchemeHandler(fixture, forURLScheme: "early-media")
        }
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Media",
            currentURL: URL(string: "early-media://main/one")!)
        manager.load(tab.currentURL, in: tab)
        let page = try #require(manager.pages[tab.id])
        let view = page.view
        try await waitForState([false, true, false], in: view)
        #expect(manager.setMuted(true, for: tab.id))
        try await waitForState([true, true, true], in: view)
        #expect(try await view.evaluateJavaScript("document.getElementById('normal').volume") as? Double == 0.35)

        // Muted state applies to elements inserted after the original click.
        _ = try await view.evaluateJavaScript("document.body.append(Object.assign(document.createElement('audio'), {id:'added'}))")
        try await waitUntil {
            try await view.evaluateJavaScript("document.getElementById('added').muted") as? Bool == true
        }
        _ = try await view.evaluateJavaScript("window.removedPlayer = document.getElementById('added'); window.removedPlayer.remove()")
        try await waitUntil {
            try await view.evaluateJavaScript("window.removedPlayer.muted") as? Bool == false
        }
        _ = try await view.evaluateJavaScript("document.body.append(window.removedPlayer)")
        try await waitUntil {
            try await view.evaluateJavaScript("document.getElementById('added').muted") as? Bool == true
        }
        // And to a new document loaded into a cross-origin embedded frame.
        _ = try await view.evaluateJavaScript("window.frameState = null; document.getElementById('embed').src = 'early-media://embedded/replacement'")
        try await waitForState([true, true, true], in: view)

        // Older replies must not override rapid, newer native choices.
        manager.setMuted(false, for: tab.id)
        manager.setMuted(true, for: tab.id)
        manager.setMuted(false, for: tab.id)
        try await waitForState([false, true, false], in: view)
        #expect(try await view.evaluateJavaScript("document.getElementById('added').muted") as? Bool == false)
        #expect(try await view.evaluateJavaScript("document.getElementById('normal').volume") as? Double == 0.35)

        manager.setMuted(true, for: tab.id)
        let document = try #require(try await view.evaluateJavaScript("window.documentToken") as? String)
        manager.reload(tab.id)
        try await waitUntil {
            let next = (try? await view.evaluateJavaScript("window.documentToken")) as? String
            return next != nil && next != document && !view.isLoading
        }
        try await waitForState([true, true, true], in: view)
        manager.load(URL(string: "early-media://main/two")!, in: tab)
        try await waitUntil { view.url?.path == "/two" && !view.isLoading }
        try await waitForState([true, true, true], in: view)
        #expect(page.isMuted && manager.prepare(tab) === page && manager.creationCount == 1)
        manager.setMuted(false, for: tab.id)
        try await waitForState([false, true, false], in: view)
    }

    @Test func playIntentIsNotActivityUntilPlaybackProgressesEvenInAnUnselectedView() async throws {
        try await withPlaybackPage { manager, tab, page in
            let view = page.view
            #expect(!page.isPlayingMedia)
            try await mediaEvent("mediaFixture.readyState = 4; emitMedia('volumechange');", in: view)
            #expect(!page.isPlayingMedia, "An unpaused, loaded player may still be waiting for foreground/autoplay permission")
            try await mediaEvent("emitMedia('playing'); emitMedia('timeupdate');", in: view)
            #expect(!page.isPlayingMedia, "Playback intent with a stationary playhead must not show the speaker")
            try await mediaEvent("mediaFixture.currentTime = 0.2; emitMedia('timeupdate');", in: view)
            #expect(page.isPlayingMedia, "Real progress must still count for background tabs")

            manager.setMuted(true, for: tab.id)
            try await mediaEvent("", in: view)
            #expect(page.isMuted && page.isPlayingMedia)
            manager.setMuted(false, for: tab.id)
            try await mediaEvent("", in: view)
            #expect(!page.isMuted && page.isPlayingMedia)

            try await mediaEvent("document.getElementById('normal').volume = 0; emitMedia('volumechange');", in: view)
            #expect(!page.isPlayingMedia)
            try await mediaEvent("document.getElementById('normal').volume = 0.35; emitMedia('volumechange');", in: view)
            #expect(page.isPlayingMedia)
            try await mediaEvent("mediaFixture.paused = true; emitMedia('pause');", in: view)
            #expect(!page.isPlayingMedia)
        }
    }

    @Test(arguments: [false, true])
    func repeatedLongSeeksRecoverWithoutAnotherPlayingEvent(buffering: Bool) async throws {
        try await withPlaybackPage { _, _, page in
            let view = page.view
            try await mediaEvent("mediaFixture.readyState = 4; emitMedia('playing'); mediaFixture.currentTime = 0.2; emitMedia('timeupdate');", in: view)
            #expect(page.isPlayingMedia)

            // Exercise long forward and backward seeks without foregrounding
            // the page or relying on another `playing` event after each seek.
            for target in [3600.0, 25.0, 7200.0] {
                try await mediaEvent("""
                    mediaFixture.seeking = true;
                    mediaFixture.readyState = \(buffering ? 2 : 4);
                    emitMedia('seeking');
                    \(buffering ? "emitMedia('waiting');" : "")
                    """, in: view)
                #expect(!page.isPlayingMedia)
                try await mediaEvent("mediaFixture.currentTime = \(target); emitMedia('timeupdate');", in: view)
                #expect(!page.isPlayingMedia, "Movement while seeking is not playback")
                try await mediaEvent("mediaFixture.seeking = false; emitMedia('seeked'); emitMedia('timeupdate');", in: view)
                #expect(!page.isPlayingMedia, "The seek jump and a stationary playhead must not show the speaker")
                if buffering {
                    try await mediaEvent("mediaFixture.readyState = 4; emitMedia('timeupdate');", in: view)
                    #expect(!page.isPlayingMedia, "The first post-buffer sample establishes a new baseline")
                }
                try await mediaEvent("mediaFixture.currentTime += 0.2; emitMedia('timeupdate');", in: view)
                #expect(page.isPlayingMedia, "Playback progress after seeking must restore the speaker without `playing`")
                #expect(view.window == nil, "Recovery must also work for an unselected background tab")
            }
        }
    }

    @Test func bufferingRecoversFromContinuedProgressWithoutAnotherPlayingEvent() async throws {
        try await withPlaybackPage { _, _, page in
            let view = page.view
            try await mediaEvent("mediaFixture.readyState = 4; emitMedia('playing'); mediaFixture.currentTime = 0.2; emitMedia('timeupdate');", in: view)
            #expect(page.isPlayingMedia)
            try await mediaEvent("mediaFixture.readyState = 2; emitMedia('waiting');", in: view)
            #expect(!page.isPlayingMedia)
            try await mediaEvent("mediaFixture.currentTime = 1; emitMedia('timeupdate');", in: view)
            #expect(!page.isPlayingMedia, "Buffering is not playback")
            try await mediaEvent("mediaFixture.readyState = 4; mediaFixture.currentTime = 2; emitMedia('timeupdate');", in: view)
            #expect(!page.isPlayingMedia, "The first post-buffer position alone must not count as playback")
            try await mediaEvent("emitMedia('timeupdate');", in: view)
            #expect(!page.isPlayingMedia, "Repeated stationary updates must not count as playback")
            try await mediaEvent("mediaFixture.currentTime = 2.2; emitMedia('timeupdate');", in: view)
            #expect(page.isPlayingMedia)

            try await mediaEvent("mediaFixture.playbackRate = 0; emitMedia('ratechange'); mediaFixture.currentTime = 3; emitMedia('timeupdate');", in: view)
            #expect(!page.isPlayingMedia)
            try await mediaEvent("mediaFixture.playbackRate = 1; emitMedia('ratechange'); mediaFixture.currentTime = 3.2; emitMedia('timeupdate');", in: view)
            #expect(page.isPlayingMedia)
        }
    }

    @Test func seekingDoesNotActivateNeverStartedOrPausedMedia() async throws {
        try await withPlaybackPage { _, _, page in
            let view = page.view
            try await mediaEvent("""
                mediaFixture.readyState = 4;
                mediaFixture.seeking = true; emitMedia('seeking');
                mediaFixture.currentTime = 3600;
                mediaFixture.seeking = false; emitMedia('seeked');
                emitMedia('timeupdate');
                mediaFixture.currentTime += 0.2; emitMedia('timeupdate');
                """, in: view)
            #expect(!page.isPlayingMedia, "Seeking must not unlock a player that never started")

            try await mediaEvent("emitMedia('playing'); mediaFixture.currentTime += 0.2; emitMedia('timeupdate');", in: view)
            #expect(page.isPlayingMedia)
            try await mediaEvent("mediaFixture.paused = true; emitMedia('pause');", in: view)
            #expect(!page.isPlayingMedia)
            try await mediaEvent("""
                mediaFixture.seeking = true; emitMedia('seeking');
                mediaFixture.currentTime = 7200;
                mediaFixture.seeking = false; emitMedia('seeked');
                emitMedia('timeupdate');
                mediaFixture.currentTime += 0.2; emitMedia('timeupdate');
                """, in: view)
            #expect(!page.isPlayingMedia, "Seeking a paused player must not show the speaker")

            try await mediaEvent("mediaFixture.paused = false; emitMedia('play'); mediaFixture.currentTime += 0.2; emitMedia('timeupdate');", in: view)
            #expect(!page.isPlayingMedia, "A new play request still needs playback confirmation")
            try await mediaEvent("emitMedia('playing'); mediaFixture.currentTime += 0.2; emitMedia('timeupdate');", in: view)
            #expect(page.isPlayingMedia)
        }
    }

    private func withPlaybackPage(_ test: @MainActor (WebViewManager, BrowserTab, BrowserPage) async throws -> Void) async throws {
        _ = NSApplication.shared
        let profile = UUID()
        let fixture = MediaPages()
        let manager = WebViewManager(profileID: profile, ephemeral: true,
            input: NavigationInput(allowedSchemes: ["early-media"]),
            faviconStore: FaviconStore { _, _, _ in nil }) {
            $0.setURLSchemeHandler(fixture, forURLScheme: "early-media")
        }
        defer { manager.discardAll() }
        let tab = BrowserTab(spaceID: UUID(), profileID: profile, title: "Media",
            currentURL: URL(string: "early-media://main/one")!)
        manager.load(tab.currentURL, in: tab)
        let page = try #require(manager.pages[tab.id])
        let view = page.view
        try await waitForState([false, true, false], in: view)
        #expect(view.window == nil) // Never selected or attached to a visible page host.

        // Control only this fixture's isolated-world DOM wrapper. No real sound,
        // playback-policy changes, UI events, or remote streaming site is needed.
        try await mediaEvent("""
            globalThis.mediaFixture = {paused:false, ended:false, seeking:false, readyState:0, currentTime:0, playbackRate:1};
            const player = document.getElementById('normal');
            for (const key of Object.keys(mediaFixture))
                Object.defineProperty(player, key, {configurable:true, get:() => mediaFixture[key]});
            globalThis.emitMedia = name => player.dispatchEvent(new Event(name));
            emitMedia('play');
            """, in: view)
        try await test(manager, tab, page)
    }

    private func mediaEvent(_ script: String, in view: WKWebView) async throws {
        // Wait behind the observer's queued update and native message, rather
        // than assuming a sleep was long enough for a false-state assertion.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            view.callAsyncJavaScript("""
                \(script)
                await Promise.resolve();
                await window.webkit.messageHandlers.earlyMediaActivity.postMessage({token:'fixture-barrier', playing:false});
                return true;
                """, arguments: [:], in: nil, in: .defaultClient) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    private func waitForState(_ expected: [Bool], in view: WKWebView) async throws {
        try await waitUntil {
            let result = try? await view.evaluateJavaScript("""
                window.frameState === null || !document.getElementById('normal') ? null :
                    [document.getElementById('normal').muted, document.getElementById('siteMuted').muted, window.frameState]
                """)
            return result as? [Bool] == expected
        }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw MediaPages.Failure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class MediaPages: NSObject, WKURLSchemeHandler {
    enum Failure: Error { case timeout }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let html: String
        if url.host == "embedded" {
            html = """
                <!doctype html><audio id="player"></audio><script>
                const player = document.getElementById('player');
                const report = () => parent.postMessage(player.muted, '*');
                player.addEventListener('volumechange', report); report();
                </script>
                """
        } else {
            html = """
                <!doctype html><title>Media fixture</title>
                <audio id="normal"></audio><audio id="siteMuted" muted></audio>
                <script>
                window.documentToken = String(Math.random());
                window.frameState = null;
                document.getElementById('normal').volume = 0.35;
                addEventListener('message', event => {
                    if (event.source === document.getElementById('embed').contentWindow)
                        window.frameState = event.data;
                });
                </script><iframe id="embed" src="early-media://embedded/frame"></iframe>
                """
        }
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count,
                                    textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
