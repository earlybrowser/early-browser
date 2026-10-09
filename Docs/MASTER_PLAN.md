# Early — Native macOS Browser · Astra 6 / Sol 6.1 Master Build Plan

> A single, phased engineering specification for a native macOS WebKit browser with Arc-inspired sidebar and tab management, Zen-like minimalism, and a command-bar-first new-tab experience.

## How to use this document

Paste **Phase 0** into your coding agent first. After it builds and verifies that phase, paste the next phase from this file. Keep the repository and a living `ARCHITECTURE.md`, `PROGRESS.md`, and `KNOWN_ISSUES.md`. Do not ask the agent to implement every phase in one response. Each phase is a complete prompt.

**Product inspiration:** [Search by Office Commun](https://officecommun.com/search), [Arc Browser](https://arc.net/), and [Zen Browser](https://zen-browser.app/). Study their ideas and public source where available; do not copy proprietary branding, icons, or code without checking licenses. This project is an independent browser, not a fork unless explicitly decided later.

## Product identity and naming — Early

**Working product name:** **Early** (display wordmark: **early**). This is the name to use consistently throughout implementation, UI copy, onboarding, application menus, settings, About window, release documentation, and sample packaging. The visual identity should feel minimal, calm, fast, and genuinely native to macOS. The intended product promise is an efficient, low-distraction browser with exceptional sidebar-based tab management and a command-bar-first workflow.

**Working tagline:** *Browse without the noise.* This is provisional marketing copy, not a requirement to display it in the browser UI.

**Provisional identifiers and distribution conventions:**

- User-facing application name: `Early`
- Display wordmark: `early` (lowercase stylistic treatment)
- Xcode app/product name: `Early`
- Example repository: `early-browser`
- Example Homebrew Cask token: `early-browser`
- Example GitHub tap: `homebrew-tap` (installed as `<github-owner>/tap`)
- Bundle identifier: `com.<verified-owned-domain>.early` **only after** a suitable reverse-DNS namespace is chosen. Do not ship literal placeholders or claim ownership of an unverified domain.
- Internal Swift module naming: `Early` / `EarlyCore` as appropriate; prefer coherent, stable names over unnecessary renaming.

**Name availability and legal caution:** *Early* is a common English word. Its uniqueness, trademark availability, domains, GitHub organization/repository names, Homebrew Cask token, and potential conflicts with existing software **have not been verified**. Before public branding or distribution, research relevant trademarks, software/app listings, GitHub names, and domains. Do not claim the name is exclusive or legally cleared. If a conflict is found, keep branding and bundle identifiers configurable so the product can be renamed without changing core browser architecture or user data unnecessarily.

**Design guidance:** Favor a restrained lowercase wordmark and a simple, distinctive `e`-based icon concept, but do not copy another company's icon or use a placeholder mark as final release artwork. Support macOS light/dark appearances, legibility at small icon sizes, and accessible contrast. Do not let branding work block functional milestones.

**Instructions to the coding agent:** In each phase, refer to the product as **Early**, while treating the name as provisional until availability checks are complete. Ensure all newly authored sample commands, file names, documentation, and release artifacts use Early consistently, except where a verified external constraint requires an alternative. Do not rename unrelated APIs or destructively migrate existing app data merely for branding.

## Distribution constraint: no paid Apple Developer membership initially

The developer currently has **no paid Apple Developer Program membership**. This is **not a blocker** for local development, testing, source publication, GitHub Releases, or distributing an unsigned/ad-hoc-signed app through a custom Homebrew tap. It **does** affect Developer ID signing, notarization, and the smoothness of installation on other Macs. A Homebrew tap does not bypass Gatekeeper; unsigned or unnotarized downloads may require explicit user approval under macOS Privacy & Security.

**Rules for every phase:**

- Make the project compile and run locally without paid Apple credentials. Do not require an Apple Developer team ID for debug builds.
- Do not make paid Apple services a dependency of core browser functionality.
- Support a clearly labeled **unnotarized early-access** release artifact (`.zip` or `.dmg`) when legally and technically appropriate. Ad-hoc signing is not Developer ID signing.
- Do not silently remove quarantine, disable Gatekeeper, or tell users to disable system-wide security protections. Provide accurate, user-controlled installation guidance instead.
- Prepare a custom Homebrew Cask tap and GitHub Releases workflow with SHA-256 checksums. Homebrew tap publication and Gatekeeper acceptance are separate concerns.
- Add **optional** Developer ID signing, hardened runtime configuration, and notarization later, when valid paid credentials are available. Never claim a release is notarized without verification.
- Review sandboxing, entitlements, permissions, app updates, and macOS security requirements; do not assume all distribution channels share the same requirements.
- Clearly label unsupported distribution or installation configurations. Never fabricate a successful install test.

## Non-negotiable engineering quality and efficiency

The browser must be **efficient, responsive, stable, accessible, and genuinely native**, not merely visually polished. Optimize from measured bottlenecks, not speculative micro-optimizations.

### Performance and resource architecture

- Prefer SwiftUI for state-driven presentation and AppKit for precise window, focus, keyboard, and drag/drop integration; avoid Electron and embedded Chromium unless a documented product requirement forces reconsideration.
- **Zero active tab means zero live web views needed for the content surface.** Command+T must not allocate a web view before submission.
- Keep tab metadata lightweight; instantiate `WKWebView` lazily. Reuse live views while useful, then discard eligible inactive views based on documented policies and observed resource pressure.
- Never recreate a web view due to SwiftUI body evaluation, sidebar selection redraws, space color changes, or transient command-bar presentation.
- Keep the main actor free of blocking database work, file I/O, network operations, large history searches, and expensive favicon/image decoding.
- Use structured concurrency with cancellation, bounded work, and correct actor isolation. Avoid unbounded background tasks, redundant observers, and polling when event-driven updates exist.
- Cache bounded favicon and UI resources; deduplicate concurrent fetches; avoid unlimited in-memory history, thumbnails, or per-tab state.
- Batch/coalesce frequent persistence writes while preserving crash-recovery correctness. Use transactions and schema migrations for state changes that must be atomic.
- Make sidebar lists efficient for large collections: stable IDs, targeted updates, lazy rendering where appropriate, and drag/drop without excessive whole-tree recomputation.
- Keep transitions responsive and accessible; honor Reduce Motion. Avoid animations that block interaction or trigger expensive web-content work.
- Treat multi-profile isolation, security, and correctness as higher priority than saving a small amount of memory.

### Measurement and release gates

- Establish a reproducible baseline on a documented Mac, macOS version, build configuration, and fixed set of test websites. Record **cold/warm launch, idle RSS/memory, 1/10/50/100-tab scenarios, tab-switch latency, command-bar response, CPU while idle, and memory after repeated open/close cycles**.
- Use Instruments (Allocations, Leaks, Time Profiler, and relevant WebKit diagnostics) where available; document that WebKit content may run in separate processes and measure appropriately.
- Set numerical performance budgets **after** baseline measurement; never invent targets or benchmark results from other browsers.
- Include regression tests for zero-tab behavior, web-view reuse, sidebar operations, profile isolation, crash restoration, and long-session resource growth.
- Do not trade away website compatibility, privacy, or data integrity to improve superficial benchmark numbers.
- At the end of **every phase**, report measured regressions (if measurements are available), exact tests/builds run, and remaining risks. Never claim optimization or verification without evidence.

## Non-negotiable product behavior

### Browser frame and sidebar URL bar

- Keep a slim, continuous native chrome frame around the browser content, inspired by Arc: start with a 6-point inset, gently rounded content corners, and a subtle 1-point outline. Preserve the frame in both empty and loaded states; use appearance-aware system colors and keep web content dominant.
- Place the persistent URL/address control near the top of the sidebar, above the Space header and tab sections. Do not add a separate horizontal URL toolbar above the page.
- With an active tab, the sidebar control displays its current URL; with no active tab, show a neutral search/address prompt. It remains usable with zero tabs and never creates a placeholder tab or web view.
- Clicking the sidebar URL control performs the same action as Command+L: present and focus the single shared command bar in navigate/current-tab intent, prefilling the active URL when available. The sidebar control is the persistent address display and entry point; the centered floating command bar remains the shared editing, search, and new-tab experience.
- Keep the sidebar URL control keyboard-accessible and expose the full active URL to accessibility and hover help when visually truncated. If the sidebar is collapsed in a later phase, Command+L must still invoke the shared bar.

### Command bar is the new-tab experience

- **Fresh first launch, with no tabs:** show the sidebar, an otherwise empty content surface, and a **centered, focused command bar**. Do not load a start-page website, a fake new-tab URL, or `about:blank` just to display the UI.
- **Command+T:** present and focus the command bar in **new-tab intent**. Do **not** create a `BrowserTab` or `WKWebView` until the user submits a URL/search or chooses a result that requires a new tab.
- **Command+L:** present the same command bar in **navigate/current-tab intent**. If a tab exists, prefill or select its URL as appropriate; if no tab exists, treat submission as creation of the first tab. The command bar is one reusable component with explicit intent, not two independent implementations.
- **Enter a URL/search:** parse and validate the input; create a tab only when required by intent and execute navigation. Existing-tab search results may switch to that tab rather than creating another one.
- **Escape / dismiss:** close the command bar without creating a tab or web view. Preserve underlying tab and space state.
- **Command+W with a normal active tab:** close the active tab and activate the next appropriate existing tab if one exists.
- **Command+W when the last tab closes:** show **empty browser content with the sidebar still visible**. Do **not** automatically reopen the command bar, create a placeholder tab, load a homepage, or close the window.
- **Command+W when zero tabs exist:** do not create a tab. Choose and document consistent native behavior (for example, no-op in the main browser window; closing a separate utility window may follow normal macOS semantics). Browser windows must remain usable in the zero-tab state.
- **Zero-tab state after normal closing:** show only the native window chrome, sidebar, and empty content surface. The command bar appears **only when invoked**. Distinguish this from fresh first launch, where it appears automatically.
- **Sidebar and spaces:** remain usable with zero tabs. Switching to an empty space shows the same empty content surface; it should not manufacture a tab.
- **Pinned-tab semantics:** closing a pinned tab can hide/unload its live page while keeping the pinned record in the sidebar. The UI must distinguish *persistent pins* from *open/live tabs* so the empty content state is correct. A pinned item may remain visible while no web content is active.
- **No tab == no WKWebView:** do not instantiate a hidden web view merely to fill the browser content area.

### Explicit UI state machine

Model the window presentation independently of tab storage:

```swift
enum CommandBarIntent: Equatable {
    case newTab
    case navigateCurrentTab
    case commandSearch
}

enum BrowserContentPresentation: Equatable {
    case empty
    case web(tabID: UUID)
}

struct CommandBarPresentation: Equatable {
    var intent: CommandBarIntent
    var query: String
}
```

Use an optional `CommandBarPresentation` in the window coordinator. Never encode a fake tab ID to represent the command bar. Keep **first-launch onboarding state**, **zero active tab**, and **command bar visible** as independent facts.

### Required acceptance scenarios

| Scenario | Expected result |
|---|---|
| Fresh install, first window | Sidebar + empty content + focused command bar; zero tabs/web views |
| Escape on first-launch command bar | Sidebar + empty content; zero tabs |
| Command+T on empty window | Command bar appears; zero tabs until submission |
| Enter `example.com` from Command+T | Exactly one tab and one web view created as needed |
| Command+T, then Escape with existing tab | No extra tab; previous page unchanged |
| Command+L with active tab, submit URL | Current tab navigates; no duplicate tab |
| Command+W with two Today tabs | Closes one; remaining tab selected |
| Command+W with final Today tab | Empty content + sidebar; command bar stays closed |
| Command+T after all tabs closed | Command bar appears over empty content |
| Switch to empty space | Empty content, no placeholder tab |
| Relaunch after closing all tabs | Restore empty session; do not auto-create tab; first-run auto-prompt is not repeated |
| Close pinned tab | Pin remains, active web content may disappear; no accidental deletion |
| Empty or loaded browser content | Slim native frame and rounded content boundary remain visible |
| Sidebar URL control with active tab | Shows current URL; click opens the shared bar in current-tab intent |
| Sidebar URL control with zero tabs | Neutral prompt; click focuses the shared bar without creating a tab/view |

---

# Phase 0 — Architecture, repository, and native shell

**Paste this prompt into Astra/Sol:**

> You are the principal macOS engineer building an independent, production-quality native browser. Use Swift 6 (strict concurrency), SwiftUI, AppKit, and WebKit/WKWebView. Use SwiftData or SQLite based on measured persistence requirements; justify the choice. Avoid Electron and unnecessary dependencies.
>
> Inspect the repository and toolchain first. Study Search by Office Commun and relevant Arc/Zen interaction references if accessible; report what was actually inspected. Choose a macOS deployment target based on verified API availability. Create `ARCHITECTURE.md`, `PROGRESS.md`, `KNOWN_ISSUES.md`, and an Xcode project with a minimal compilable app.
>
> Define distinct layers for window state, BrowserCoordinator, TabStore, WebViewManager, navigation, spaces, profiles, command bar, persistence, downloads, history, and settings. `BrowserTab` is persisted data; `WKWebView` is a separately owned runtime object. Use MainActor for UI/WebKit work and clean up delegates and observers.
>
> Build the initial chrome with a slim native frame around the content and a compact URL/address control at the top of the sidebar. Clicking it invokes the same command-bar action as Command+L; keep one shared floating editor and no separate top URL toolbar.
>
> **Critical:** design the zero-tab state now. A browser window must be able to display an empty content area with the sidebar and **no** BrowserTab or WKWebView. The first launch automatically presents a focused command bar, but returning to zero tabs by closing the last tab must **not** automatically present it. `Command+T` opens a command bar without creating a tab. `Command+L` uses the same bar with different intent. Keep the command bar independent of tabs.
>
> Specify a state-transition table for first launch, Command+T, Command+L, Escape, Enter, Command+W, space switching, pinned-tab closing, and relaunch. Establish test seams for each. Do not implement advanced features. Build and report real results; never claim tests ran if they did not.

**Exit gate:** compilable native shell; documented architecture and zero-tab invariants.

# Phase 1 — WebKit navigation and command-bar-first tabs

> Continue the existing project; do not reinitialize it. Build a functional WKWebView browser with address parsing, search engine fallback, back/forward/reload/stop, page title, loading state, navigation errors, JavaScript dialogs, new-window handling, and basic session persistence.
>
> **The new tab UI is the command bar, not a tab page.** Implement a single reusable native floating command bar with `newTab`, `navigateCurrentTab`, and `commandSearch` intents. On first-ever launch with no tabs, show the bar focused in the center of the otherwise empty content surface. `Command+T` opens it without creating any tab or web view. `Command+L` opens it to navigate the current tab if present. Escape dismisses without side effects. On submission, create a tab only if needed, then navigate. Do not render `about:blank` or a homepage as a placeholder.
>
> `Command+W` closes the active normal tab. Closing the last normal tab leaves an empty content surface and the sidebar; it does **not** reopen the bar or close the main window. With zero tabs, Command+W must not manufacture a tab. On relaunch after a legitimately empty session, restore emptiness rather than treating it as fresh installation.
>
> Connect the sidebar URL control to the active tab's current URL and the shared navigate/current-tab command-bar intent. Keep the content inset inside its slim native frame when attaching WKWebView; frame/layout updates must not recreate or reload it. Test sidebar URL activation with and without an active tab.
>
> Implement native shortcuts: Command+T, Command+W, Command+L, Command+R, Command+[ / Command+], Command+Shift+T, and documented tab-selection shortcuts. Web views must be retained across SwiftUI recomputations and ordinary tab switches. Add unit tests for command-bar intent, tab-creation-on-submit, cancel-without-tab, last-tab closing, and first-launch-versus-relaunch distinction. Build and test before proceeding.

**Exit gate:** navigate real sites; tab switching preserves live pages; all zero-tab and command-bar scenarios pass.

# Phase 2 — Arc-inspired sidebar, favorites, pins, Today, folders

> Implement a polished native sidebar with the persistent URL/address control above the Space header, globally accessible Favorites, space-specific Pinned tabs and folders, temporary Today tabs, and space controls in the footer. Support hover, selected/loading states, context menus, drag-and-drop ordering, renaming, pin/unpin, nested folders with cycle prevention, and accessibility. Persist all ordering and hierarchy.
>
> Maintain separate `pinnedURL` and `currentURL`. Closing a pinned tab should retain its persistent pin and close or unload its live page according to the documented policy; it must not remove the pin. Provide Reset to Pinned URL. Today tabs can be closed, reopened, archived, or promoted to pinned. Keep archive behavior recoverable and configurable later.
>
> **Never use a fake Today tab as the new-tab button.** The plus button and Command+T present the command bar, and the tab is created only on successful submission. If no active tab remains, show empty content while keeping the sidebar visible, even if persistent pinned entries exist. Ensure sidebar selection accurately reflects the absence of an active web page.
>
> Test 30+ tabs, reordering, nested folders, pin lifecycle, last-tab close, command-bar cancellation, persistence, and tab switches without unnecessary reloads. Fix issues and compile.

**Exit gate:** Arc-like tab-management flows work with zero or many tabs.

# Phase 3 — Spaces and isolated browsing profiles

> Implement named/color-coded Spaces, switching by sidebar and keyboard, persistent active-tab-per-space, moving tabs between spaces, create/rename/duplicate/delete, and subtle native transitions. Favorites remain globally accessible according to the architecture. Switching into a space with no active tab must show empty content, **not** auto-open a tab or command bar.
>
> Implement browsing profiles using supported WebKit data-store APIs for the chosen deployment target. Verify API availability and document isolation limits for cookies, authentication, and website storage. A WKWebView's data-store configuration must be correct at creation. Explicitly define what happens when moving a tab between profiles; do not silently leak or transfer authenticated state.
>
> Test empty spaces, last-tab closing in each space, space switching while command bar is visible, profile separation, and relaunch restoration. Compile and fix failures.

**Exit gate:** independent spaces, documented profile isolation, reliable empty-space behavior.

# Phase 4 — Universal command bar and keyboard-first workflow

> Upgrade the existing command bar into a unified, native, Spotlight-like interaction. **Do not create a second command-bar implementation.** Support URLs, web searches, open-tab search, pinned tabs, history, bookmarks, spaces, and browser actions. Use exact/prefix/fuzzy matching, recency, frequency, and pin status for ranking. Results must be keyboard-navigable with arrows, Return, and Escape.
>
> Preserve explicit intent: Command+T = create new tab only on navigation/search submission; Command+L = navigate current tab when appropriate; selecting an existing tab = switch without duplication; selecting an action = execute without creating a tab. On zero-tab windows, both shortcuts may create the first tab only when a navigation result is submitted. On initial launch, focus the bar; after closing the final tab, leave it closed.
>
> Add actions for pin/unpin, move, rename, reset pinned URL, duplicate, close, reopen, switch space/profile, toggle sidebar, downloads, history, and settings. Use one underlying action dispatcher shared by keyboard, menus, and sidebar. Ensure focus returns correctly to web content or empty browser content. Test result ranking, action side effects, focus, and cancel behavior.

**Exit gate:** command bar is the primary entry point for new tabs and browser commands.

# Phase 5 — Web view lifecycle, memory, and restoration

> Define explicit runtime tab states such as unloaded/loading/active/background/suspended/discarded/failed, independent of persisted tab metadata. Lazily create WKWebViews. Keep recently used live pages alive, and discard eligible inactive pages when appropriate without promising preservation of DOM or JavaScript state. Never discard the active web view or interfere with ongoing downloads and important user interactions.
>
> Persist tab identity, URL, pinned URL, ordering, space/folder association, and active-tab selection. Do not claim exact back-forward history or form restoration unless supported and verified. On WebKit process termination, recover safely. Avoid observer/delegate leaks.
>
> **No active tab must require zero live web views if all others are discarded**; the empty content surface is a native view, not a hidden WKWebView. Test 10/50/100-tab scenarios, repeated open/close, last-tab close, empty-session relaunch, tab suspension, and process termination. Profile with Instruments when available; report measured results only.

**Exit gate:** responsive tab lifecycle and predictable restoration without fake tabs.

# Phase 6 — Native macOS visual polish and motion

> Refine the browser's macOS presentation using SwiftUI/AppKit: integrated titlebar, appropriate traffic-light placement, materials, native menus, full-screen and multiple windows, focus management, light/dark mode, accessibility, reduced motion, subtle hover states, drag feedback, and polished sidebar collapse/temporary reveal. Keep web content dominant and browser chrome minimal. Preserve and refine the slim native content frame, rounded content corners, and sidebar URL placement in light/dark, fullscreen, and sidebar collapse/reveal states. The URL control must keep invoking the same shared floating command bar; do not introduce a top URL toolbar.
>
> Design **two intentionally different empty states**: (1) fresh first launch = quiet empty content with centered focused command bar, and (2) all tabs closed = quiet empty content with sidebar and **no command bar**. Neither should display a fake web page, marketing dashboard, distracting illustration, or automatically created tab. The same bar should appear on Command+T/Command+L in both states. Keep a consistent overlay position, keyboard focus, and animation across empty and loaded content.
>
> Validate small/large windows, full screen, VoiceOver, keyboard-only usage, light/dark mode, reduced motion, and multiple displays when possible. Preserve browser logic; do not rewrite state management for cosmetic changes.

**Exit gate:** polished native feel and correct empty-state visual behavior.

# Phase 7 — Browser essentials, security, and privacy

> Implement supported WebKit download handling (progress, cancel, destination, Finder reveal), browsing history with deletion, bookmarks and search, private browsing using nonpersistent data stores, website permissions, file upload, printing, PDF handling, find-in-page, zoom, media playback, popups, and appropriate WebKit content blocking. Research availability of camera, microphone, location, notifications, and other APIs for the selected macOS target rather than inventing support.
>
> Validate URL schemes, handle TLS failures safely, use Keychain for app-managed secrets, and follow sandbox/entitlement rules. Private sessions must not persist private history. Download state must not disappear merely because a tab is suspended or closed. New-window requests must follow documented tab/window rules; do not accidentally open a placeholder new tab.
>
> Verify with real websites and automated tests where feasible. Clearly document WebKit/Chromium extension compatibility limits and unsupported capabilities.

**Exit gate:** core browser tasks work with documented security and platform limitations.

# Phase 8 — Settings, onboarding, and customization

> Build a native macOS Settings window for search engine, startup behavior, tab archival, pin closing/reset, sidebar appearance, space themes, browsing profiles, history/site-data deletion, permissions, privacy, and keyboard shortcuts. Persist typed settings and migrate schemas safely.
>
> Add lightweight first-run onboarding without requiring an account. Explain Favorites, Pinned, Today, Spaces, and the command bar. On a clean install, the browser's first usable state must still be **sidebar + empty content + focused command bar**. On subsequent launches, restore the previous session exactly, including a legitimately zero-tab session. Make startup command-bar appearance configurable only if it does not violate the default first-run/zero-tab behavior.
>
> Test onboarding completion, migration, fresh install, relaunch with open tabs, relaunch with zero tabs, and settings persistence.

**Exit gate:** clear preferences and predictable startup state.

# Phase 9 — Quality, regression, and accessibility audit

> Perform a full review of tab identity, WebKit ownership, Swift 6 concurrency, memory, profile isolation, permissions, window focus, persistence, crash recovery, downloads, keyboard routing, VoiceOver, contrast, and reduced motion. Add unit/UI tests for tab operations, pinned/favorite behavior, folders, spaces, command-bar ranking/actions, session restoration, and settings.
>
> Treat the following as **release-blocking regression tests**: fresh launch has no placeholder tab and shows focused bar; Command+T opens bar without creating a tab; Escape leaves tab count unchanged; Command+L navigates current tab; Command+W closing the final Today tab leaves empty content + sidebar with bar closed; pinned close retains pin; switching to empty space does not create tab; empty-session relaunch stays empty; no hidden WKWebView is required for empty content.
>
> Test failure recovery for corrupt persistence, WebKit crashes, download errors, and interrupted navigation. Run real tests and report exact passes/failures and unsupported cases. Do not claim production readiness with unresolved critical failures.

**Exit gate:** reproducible quality report and passing core regression suite.

# Phase 10 — Packaging, Homebrew distribution, optional signing and notarization

> Prepare **two explicitly separate release paths**. **Path A (available now, no paid Apple Developer account):** reproducible release build, unsigned or ad-hoc-signed app as appropriate, ZIP/DMG packaging, GitHub Releases, checksums, a custom Homebrew Cask tap, version updates, release notes, and clear Gatekeeper/installation documentation. Test the cask syntax and actual installation on a clean Mac if a suitable test machine is available. Do not bypass Gatekeeper, strip quarantine automatically, or misrepresent the artifact as trusted/notarized. **Path B (optional later, requires paid credentials):** Developer ID signing, appropriate hardened runtime/entitlements, notarization, stapling where applicable, and verification. Never block Path A on unavailable signing credentials. Never assume Apple signing credentials are available; document manual steps and do not claim successful signing/notarization without evidence.
>
> For CI/CD, create GitHub Actions build/test/package/release jobs that do not require a paid Apple account, with a separate opt-in signing/notarization job using protected secrets. Confirm the chosen macOS runner, Xcode version, deployment target, architecture(s), app entitlements, and WebKit availability. Avoid promising universal builds unless both slices are actually produced and tested. Maintain a release checklist and a clear compatibility matrix.
>
> Validate clean install (including Gatekeeper behavior on another Mac), first launch, zero-tab behavior, navigation, multi-window behavior, session restoration, permissions, downloads, profiles, light/dark mode, and supported macOS versions. Provide a release checklist, known limitations, build instructions, and a tested artifact if the environment permits.

**Exit gate:** verifiable release workflow and no unaddressed release blockers.

---

# Reusable review prompt — run after every phase

> Review the phase just implemented. Enforce the efficiency and distribution constraints from this master plan, including no mandatory paid Apple credentials. Inspect changed files, compile with the available Xcode toolchain, run relevant unit/UI tests, inspect Swift 6 concurrency warnings, WebKit lifecycle, observer cleanup, persistence invariants, and focus routing. Re-test the slim content frame, sidebar URL display and activation with zero/active tabs, the first-launch command bar, Command+T without tab creation, Escape cancellation, Command+L intent, last-tab Command+W empty state, pinned-tab close semantics, and empty-session relaunch. Fix confirmed regressions without unrelated rewrites. Update `ARCHITECTURE.md`, `PROGRESS.md`, and `KNOWN_ISSUES.md`. Report exact files changed, build/test commands, outcomes, and remaining risks. Never fabricate successful tests or benchmarks. Stop before the next phase.

# Recommended implementation order and checkpoints

1. **Phase 0–1:** establish the window, command-bar-first interaction, and zero-tab state before complex UI.
2. **Phase 2–4:** build the differentiated Arc-style workflow: sidebar, spaces, and one universal command bar.
3. **Phase 5–7:** make the browser reliable, fast, secure, and useful on real websites.
4. **Phase 8–10:** onboarding, quality audit, signing, and release.

Create a Git commit after each verified phase. Do not move forward on a broken build. Prioritize correctness of tab lifecycle and command-bar intent over visual flourishes.
