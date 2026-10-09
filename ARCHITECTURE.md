# Early architecture

Phase 0 · 2026-10-09

## Platform and scope

Swift 6 language mode with complete concurrency checking; SwiftUI presentation,
AppKit application/menu integration, and WebKit runtime ownership. Minimum
deployment target: macOS 14.0. The installed macOS SDK declares Observation's
`Observable`/`@Observable` and `WKWebsiteDataStore.dataStoreForIdentifier:` as
available from macOS 14. The SwiftUI `Window` scene predates that target.
Availability is checked at compile time; running on macOS 14 remains unverified.

The Xcode app target consumes `EarlyCore` as a local Swift package. SwiftPM runs
core tests independently; Xcode owns the app bundle and UI tests. There are no
remote dependencies, project generators, Apple services, or required team IDs.
The current app has one browser window. Multiple-window product behavior is
scheduled for Phase 6, but presentation and runtime ownership are window-scoped.

Phase 0 does not perform navigation, persist sessions, render real tab rows, or
implement full spaces/profiles. Metadata fixtures exercise future transitions
without presenting fake pages in the app. Return exposes a submission boundary
and shows an honest unavailable message; Phase 1 will consume that boundary.

## Ownership and layer boundaries

| Layer | Responsibility and isolation | Phase 0 status |
| --- | --- | --- |
| Window state | `BrowserWindowModel` owns one coordinator and runtime manager on MainActor; local submission feedback belongs here | Implemented |
| BrowserCoordinator | MainActor observable presentation, command intent, selection per space, close policy; never creates a web view | Implemented |
| TabStore | Ordered value-type metadata. Durable IDs, URLs, pin URL, open/closed state; no UI or WebKit reference | Implemented, in memory |
| WebViewManager | MainActor owner of views keyed by tab ID; explicit lookup and disposal. No allocation path in this phase | Ownership boundary implemented |
| Navigation | Validate input, map search input to an engine URL, authorize schemes, then create/navigate according to a request; own navigation delegates | `NavigationRequest` boundary only; Phase 1 |
| Command bar | One SwiftUI component, optional presentation with explicit intent. Focus requests are independent of tab identities | Implemented; ranking/actions in Phase 4 |
| Spaces | Durable names/order/profile binding plus window-local active-space selection; no implied tab creation | IDs and switching test seam; UI/store in Phase 3 |
| Profiles | App-scoped profile registry, stable WebKit data-store UUID per persistent profile | Contract below; Phase 3 |
| Persistence | Dedicated actor owns SQLite connection, migrations, transactions and coalesced saves; sendable snapshots cross actor boundary | Decision/probe only; Phase 1 |
| Downloads | App-scoped MainActor WebKit delegate handles; separate durable metadata writer; not owned by tab/view lifetime | Planned Phase 7 |
| History | Profile-partitioned SQLite tables and bounded, cancellable async queries; never record private sessions | Planned Phase 7, command-search seam in Phase 4 |
| Settings | Typed preferences; small preferences use UserDefaults, migrations stay explicit | First-use flag only; full settings Phase 8 |

`BrowserTab` is Codable and Sendable data. `isOpen` expresses whether a tab belongs
to the open session; it does **not** imply a live `WKWebView`. A discarded open tab
can later have metadata and no view. A closed pin keeps its durable record and
both `pinnedURL` and `currentURL`. A normal closed tab is removed from this store;
recoverable closed-tab/archive storage begins in the appropriate later phases.

The coordinator currently owns its `TabStore` value because the shell is single
window. Before multiple windows, promote durable metadata to an app-scoped
observable store, keeping selections in each coordinator. Assign an open tab a
window owner; never attach one `WKWebView` to two simultaneous content views.
Global Favorites will be app-visible references resolved through the active
profile, not globally shared authenticated web views. Define their profile
behavior before implementing them in Phases 2–3.

## Presentation invariants

- A 6-point native chrome inset and 1-point rounded content outline frame both
  empty and future web content. Layout/styling must not recreate live web views.
- The persistent address control sits near the top of the sidebar, above the
  Space header. It displays the active URL, or a neutral prompt with zero tabs.
  Its accessible value and hover help expose the full URL if visually truncated.
  Clicking it invokes the same current-tab intent as Command+L. The floating
  command bar remains the single shared editor; there is no top URL toolbar.
- `BrowserContentPresentation` is `.empty` or `.web(tabID:)`.
- `CommandBarPresentation?` is separate and contains intent and query.
- First use, onboarding completion, active selection, and bar visibility are
  independent facts. No fake UUID, `about:blank`, start page, or hidden web view
  represents an empty window or a command bar.
- Present/dismiss/query changes never mutate the tab store or runtime manager.
- First use is consumed once when the first real browser view appears, stored
  as `hasPresentedFirstBrowserWindow`; it is not inferred from an empty store.
- A stale, closed, missing, or other-space selection resolves to empty content.
- Closing selects the next open tab in sidebar order, then the previous one in
  the same space. It never activates a closed pin or a tab in another space.
- Closing the final active tab clears selection and dismisses the bar.
- ⌘W in an empty browser window is a no-op, even when the bar is visible.
  ⇧⌘W/red close explicitly close the window. Utility windows use native close.
- Switching spaces dismisses the bar, avoiding a stale navigation target, and
  restores that space's explicitly recorded selection. Empty means empty.

## State transitions and test seams

| Event / precondition | Content after event | Bar after event | Metadata / runtime effect | Verification |
| --- | --- | --- | --- | --- |
| First usable window, fresh install | Empty | Focused, newTab | Zero tabs/views; claim first-use flag | Core + UI |
| Returning empty session | Empty | Closed | No automatic tab or prompt | Core + UI relaunch |
| ⌘T, any content | Unchanged | Focused, newTab, empty query | None | Core + UI |
| ⌘L, selected tab | Same page | Focused, navigateCurrentTab, current URL | None | Core; live-page UI in Phase 1 |
| ⌘L, empty window | Empty | Focused, navigateCurrentTab | Submission targets first new tab | Core + UI |
| Sidebar address click | Unchanged | Focused, navigateCurrentTab | Same action as ⌘L; no allocation | Empty-state UI; active URL wiring verified in Phase 1 |
| Escape/dismiss | Unchanged | Closed | None | Core + UI |
| Return, whitespace | Unchanged | Remains open | No request | Core |
| Return, newTab or no selected tab | Unchanged in Phase 0 | Remains open with unavailable message | Produces unvalidated new-tab request; no allocation | Core + UI |
| Return, navigateCurrentTab with selection | Same tab in Phase 0 | Remains open | Produces unvalidated current-tab request | Core |
| Return, commandSearch | Unchanged | Unchanged | No navigation; action dispatcher comes in Phase 4 | Core |
| ⌘W, normal tab with neighbors | Next/previous open neighbor | Closed | Removes metadata; window owner discards old runtime ID | Core fixture |
| ⌘W, final normal tab | Empty | Closed | Removes metadata; no replacement tab/view | Core fixture |
| ⌘W, zero active tabs | Empty | Unchanged | None; window remains open | Core + UI |
| Close active pin | Next/previous neighbor or empty | Closed | Preserve pin/URLs, mark closed, discard runtime | Core fixture |
| Switch to empty space | Empty | Closed | No new tab; remember source selection | Core fixture |
| Switch back to populated space | Recorded valid open tab | Closed | Existing identity reused | Core fixture |
| Relaunch with populated session | Saved valid selection | Closed | Metadata restored first; selected view lazy | Phase 1; not implemented |

On successful Phase 1 submission: validate first, create exactly one tab only if
the target requires it, select it, configure the correct profile, allocate once,
and load. Dismiss the bar only after accepting the request. URL/search parsing
and failed/unsupported input need explicit tests before that behavior ships.

## Persistence decision

Use system SQLite for sessions, hierarchy/order, history, bookmarks, and download
metadata. It provides explicit transactions, migrations and query indexes behind
a single actor without an additional package. UserDefaults is restricted to
small preferences such as the Phase 0 first-use flag.

The initial measured sizing probe uses 1/10/50/100 tab rows and an active-selection
row in one transaction, with disk-backed WAL and synchronous FULL. At 100 rows,
this machine measured 0.264 ms median / 0.291 ms p95 for a synthetic replacement
transaction, and 0.020 / 0.023 ms for the indexed read. Full methodology and limits
are in [PERFORMANCE.md](Docs/PERFORMANCE.md). This establishes small-session
feasibility; it does **not** establish that SQLite is faster than SwiftData, which
was not benchmarked. The deciding requirements are atomic multi-table writes,
explicit recovery/migrations, profile-scoped queries, and predictable bounded
history searches. Reassess if production measurements challenge the choice.

Phase 1 must implement a schema version and transactional migrations, stable
space/profile IDs, coherent tab/selection snapshots, debounced bounded writes
with lifecycle flush, and empty-session persistence. Store files in Early's
sandbox Application Support directory. A decode/schema/open failure must preserve
the original data, report recovery needs, and never be treated as fresh install.
First-use preference and session storage are separate. Never promise lossless
DOM, form, or back-forward restoration without a supported verified API.

## Concurrency and resource policy

UI/coordinator/WebKit are MainActor-isolated. Durable records and requests are
Sendable. No synchronous database, file, image decoding, or network work belongs
in the coordinator or a SwiftUI body. The shell has no background tasks, polling,
custom observers, downloads, or external network requests.

Phase 1 must allocate through `WebViewManager` only, after a profile-configured
navigation is accepted. SwiftUI representables only attach/look up retained
views; body evaluation must not allocate or navigate. The manager must retain
delegate/observation tokens, invalidate them on disposal, stop loading, clear
delegates and detach the view. Disposal is separate from removing a pin record.
Add a counting view factory to prove allocation/reuse before live tabs ship.

Phase 5 adds runtime states, bounded caching, memory pressure handling, and
discard eligibility. Never discard active content or interfere with downloads,
media, forms, or important user interactions. Empty content requires no view;
background open tabs may retain useful live views until independently discarded.

## Profile and security contracts

Create persistent profiles using a stable `WKWebsiteDataStore(forIdentifier:)`
UUID configured before creating a view. Verify cookies, authentication and site
storage isolation on actual supported systems in Phase 3. A space is an
organizational grouping; it does not itself imply storage isolation.

Cross-profile moves must dispose/recreate the runtime in the destination data
store and navigate its URL without transferring cookies or authenticated state.
Private sessions use nonpersistent stores and must not enter normal history or
session restoration. Permissions, OS/network caches, and system-level state are
not automatically proven isolated by choosing a data store.

The Xcode bundle uses App Sandbox and local ad-hoc signing. Phase 0 requests no
network, file-selection, camera, microphone or location entitlement. Add only
needed access when the implementing phase validates it; Phase 1 needs outgoing
network access. Hardened runtime, Developer ID and notarization are release work.
Do not change quarantine or system security settings. UI testing may add test
instrumentation entitlements to Debug products; those are not release policy.

`local.early.browser` is a deliberate local-development namespace configured in
`Config/Early.xcconfig`. Select a verified owned namespace and review data
migration before public release. Early's name and final artwork are not cleared.

## Reference inspection

The working app icon is the native `Resources/Early.icon` package, compiled by
Xcode's asset compiler. A native background gradient and four SVG artwork layers
reconstruct the user's flattened reference. `Branding/README.md` documents editing,
previews and provenance. Xcode 27 produced layered assets plus an `.icns` fallback
while preserving the macOS 14 target; older-system icon rendering is unverified.

Inspected on 2026-10-09; no external implementation or artwork was copied:

- [Search product page](https://officecommun.com/search),
  [repository README](https://github.com/driceroland/Search), and
  [MIT license](https://github.com/driceroland/Search/blob/main/LICENSE): useful
  references for minimal chrome, native WebKit ownership, and lazy restoration.
  Reviewed documentation and license, not a source-code audit or runtime test.
  Its published performance and compatibility claims are not Early measurements.
- [Arc product page](https://arc.net/),
  [Pinned Tabs](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around),
  and [Favorites](https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space):
  references for space-specific pins, cross-space favorites, and reset URLs.
  Proprietary source was not inspected.
- [Zen product page](https://zen-browser.app/),
  [Compact Mode documentation](https://docs.zen-browser.app/user-manual/compact-mode),
  and [public repository overview](https://github.com/zen-browser/desktop):
  references for content-dominant layout and restrained chrome. No Firefox code
  was reused; Early remains an independent WebKit app.
- [Apple data-store API](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)):
  web documentation required JavaScript, so availability was verified directly
  in installed `WKWebsiteDataStore.h`; Observation availability was read from
  the SDK's Swift interface.
