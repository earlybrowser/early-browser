// SPDX-License-Identifier: MPL-2.0

#if DEBUG
import WebKit

/// Available only to explicitly isolated Debug UI-test sessions, never Release.
@MainActor
final class TestPages: NSObject, WKURLSchemeHandler {
    /// Deterministic metadata fixture for scrolling/lazy-loading tests. Never
    /// used in a normal profile, and does not allocate 32 WebKit processes.
    static func installClosedPins(in model: BrowserWindowModel) {
        guard model.isTesting, model.coordinator.tabStore.tabs.isEmpty else { return }
        let coordinator = model.coordinator
        for number in 1...32 {
            let url = URL(string: "early-test://fixture/one?pin=\(number)")!
            guard let id = coordinator.navigate(to: url, target: .newTab(spaceID: coordinator.activeSpaceID)) else { return }
            coordinator.updateMetadata(id, url: nil, title: "Test Pin \(number)")
            coordinator.setPinned(id, pinned: true)
            coordinator.closeTab(id)
        }
        model.save()
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.path == "/fullscreen" {
            respond(to: task, url: url, html: """
            <!doctype html><meta charset="utf-8"><title>Fullscreen fixture</title>
            <style>body{font:18px -apple-system}#player{background:#222;color:white;padding:24px}video{width:320px;height:180px}</style>
            <button onclick="document.getElementById('player').requestFullscreen().catch(e=>document.getElementById('state').textContent=e.message)">Enter video fullscreen</button>
            <div id="player"><video controls aria-label="Test video"></video>
            <button onclick="document.exitFullscreen()">Exit video fullscreen</button>
            <p id="state">Fullscreen closed</p></div>
            <script>document.addEventListener('fullscreenchange',()=>{
              document.getElementById('state').textContent=document.fullscreenElement?'Fullscreen active':'Fullscreen closed';
            });</script>
            """)
            return
        }
        if url.path == "/identity" {
            respond(to: task, url: url, html: """
            <!doctype html><html><head><title>Browser identity</title></head>
            <body style="font:18px -apple-system;padding:32px">
            <h1>Browser identity</h1><p id="identity"></p>
            <a href="early-test://fixture/identity" target="_blank">Open identity tab</a>
            <script>document.getElementById('identity').textContent = navigator.userAgent;</script>
            </body></html>
            """)
            return
        }
        if url.path == "/scroll" {
            respond(to: task, url: url, html: """
            <!doctype html><html><head><title>Scroll fixture</title>
            <style>
              body{font:18px -apple-system;margin:0;padding:32px;min-height:3000px}
              #controls{position:fixed;left:24px;bottom:24px;background:white;color:black;padding:12px;border:1px solid #aaa}
              #controls label{display:block;margin-top:8px} #controls input{width:5em}
            </style></head><body>
            <h1>Scroll fixture</h1><p>Scroll the page while the command bar remains open.</p>
            <div id="controls">
              <button onclick="document.getElementById('clicks').value=String(++clicks)">Count page click</button>
              <label>Page clicks <input id="clicks" aria-label="Page clicks" value="0" readonly></label>
              <label>Scroll position <input id="position" aria-label="Scroll position" value="0" readonly></label>
            </div>
            <script>
              let clicks=0;
              addEventListener('scroll',()=>{
                document.getElementById('position').value=String(Math.round(scrollY));
              },{passive:true});
            </script></body></html>
            """)
            return
        }
        if url.path == "/slow" { return } // Stop/close cancels this deliberate pending load.
        if url.path == "/failure" {
            task.didFailWithError(URLError(.notConnectedToInternet))
            return
        }
        if url.path == "/download" {
            // A data: download link: WebKit cannot download this test scheme itself.
            respond(to: task, url: url, html: """
            <!doctype html><html><head><title>Page Download</title></head>
            <body style="font:18px -apple-system;padding:32px">
            <h1>Page Download</h1>
            <p><a id="note" download="early-note.txt" href="data:text/plain;base64,RWFybHkgZG93bmxvYWQ=">Download note</a></p>
            <p style="height:300px">Plain page area</p></body></html>
            """)
            return
        }
        let name = url.path == "/two" ? "Two" : "One"
        let html = """
        <!doctype html><html><head><title>Page \(name)</title></head>
        <body style="font:18px -apple-system;padding:32px">
        <h1>Page \(name)</h1><label>Saved text <input aria-label="Saved text" id="saved"></label>
        <p><a href="early-test://fixture/two">Go to Two</a></p>
        <p><a href="early-test://fixture/two" target="_blank">Open new tab</a></p>
        <button onclick="alert('Test alert');document.getElementById('result').textContent='Alert done'">Alert</button>
        <button onclick="document.getElementById('result').textContent=confirm('Test confirm')?'Confirmed':'Cancelled'">Confirm</button>
        <button onclick="document.getElementById('result').textContent=prompt('Test prompt','default')??'Cancelled'">Prompt</button>
        <p id="result" aria-live="polite"></p></body></html>
        """
        respond(to: task, url: url, html: html)
    }

    private func respond(to task: any WKURLSchemeTask, url: URL, html: String) {
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
#endif
