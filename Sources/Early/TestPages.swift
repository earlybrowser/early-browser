#if DEBUG
import WebKit

/// Available only to explicitly isolated Debug UI-test sessions, never Release.
@MainActor
final class TestPages: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.path == "/slow" { return } // Stop/close cancels this deliberate pending load.
        if url.path == "/failure" {
            task.didFailWithError(URLError(.notConnectedToInternet))
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
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
#endif
