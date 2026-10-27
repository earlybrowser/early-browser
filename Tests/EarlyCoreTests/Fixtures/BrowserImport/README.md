# Browser-import fixtures

All content is synthetic. URLs use `example.invalid`; no personal browsing data,
cookies, tokens or credentials were copied. `DO-NOT-IMPORT` strings are fake
sentinels to prove unrelated session/CSV fields are discarded.

- `Bookmarks.html`: Netscape format with deliberately unclosed DT/P markup,
  folders, Unicode, intentional URL copies and unsupported scheme examples.
- `ChromiumBookmarks.json`: synthetic Chromium bookmarks schema.
- `Dia-1.54.2-Bookmarks.json`: created through Dia's own bookmarks API in a
  separate temporary headless profile (Dia 1.54.2, Chromium 156.0.8078.48).
  Only organization fields retained; synthetic IDs normalized.
- `FirefoxSession.json`: synthetic Mozilla session format. Additional groups,
  container, cancellation and SNSS fixtures are built in test code for explicit
  boundary control; no third-party binary browsing session is retained.
- `Zen-1.23.4b.json`: a workspace, folder, pin and lazy Today tab created through
  Zen's native workspace/folder APIs in a separate temporary offline/headless
  profile. The browser's serialized spaces/folders/groups/tabs were captured;
  only organization fields retained and UUIDs normalized. Empty placeholder tabs
  remain to test their exclusion. Test profile/process removed after verification.
- `Arc-sidebar-alternating.json`: entirely synthetic known alternating-dictionary
  schema, checked against published format examples. **Experimental:** no current
  Arc installation tested, explicitly accepted by the user. It must not be
  described as live-verified Arc compatibility.
- `SafariHistory.json`: synthetic Apple's schema v1 (Safari 18.2) with latest
  known timestamps and aggregate counts, based on Apple's developer document.
- `Safari-localized.zip`: Python `zipfile` DEFLATE of the synthetic HTML/history
  with localized entry names and an excluded fake password CSV. Stored ZIP and
  malicious/CRC variants are generated directly in the tests.

The capability matrix and primary format references are in
[Documentation/BrowserImport.md](../../../../Documentation/BrowserImport.md).
Private formats can change; a new advertised schema needs a sanitized fixture and
corresponding parser tests. Selecting a browser brand never implies access to
its undocumented data.
