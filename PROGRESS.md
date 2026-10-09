# Early progress

## Current checkpoint

Phase 0 implemented and verified on 2026-10-09. The native shell compiles and
runs; architecture, zero-tab invariants, transitions and test seams are in place.
Phase 1 has not started. The user authorized committing and pushing the completed
Phase 0 and chrome adjustment on 2026-10-09. Earlier uncommitted notes below
describe their state at those checkpoints.

## Delivered

- Native SwiftUI/AppKit Xcode app with a local `EarlyCore` package; Swift 6 and
  strict concurrency; macOS 14 deployment target; no external dependencies.
- Persistent first-use distinction, centered focused command bar, sidebar and
  native empty content. One reusable bar with explicit intents and keyboard/menu
  routing. Zero-tab ⌘W is a no-op; ⇧⌘W explicitly closes the window.
- Codable tab metadata independent of runtime web views; tested selection,
  pin-close and last-tab-close transitions. No `WKWebView` allocation path.
- Local ad-hoc signing without credentials and sandboxed app configuration.
  Release disables automatic injection of debug base entitlements.
- Architecture with all planned layer boundaries, state transition table,
  profile-isolation policy, SQLite decision, reference-inspection record, and
  measurement protocol. Original master plan preserved in `Docs/MASTER_PLAN.md`.

## Verification

Host: MacBook Air (Mac16,12), Apple M4, 16 GB, macOS 27.0.1 (26A434), Xcode 27.0
(27A266a), Swift 6.4; arm64 builds with macOS 14 minimum deployment target.
Commands ran from the repository root. All Xcode commands used the per-process
developer-directory override below; the system's selected tools were not changed.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Passed: 16 Swift Testing tests, including two cases for the parameterized
new-tab/current-tab cancellation test. The final run after package configuration
cleanup passed with zero failures. XCTest's compatibility runner prints zero
tests before the separate Swift Testing results; the latter ran all 16 tests.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj -scheme Early -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project Early.xcodeproj -scheme Early -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -resultBundlePath build/Phase0-UI-Retry.xcresult test
```

Debug build passed. Native UI suite: **4 passed, 0 failed, 0 skipped**, verified
from the result bundle:

- Fresh first-launch typing works without clicking; Escape leaves an empty window.
- ⌘W leaves the empty window open; ⌘T and ⌘L open and focus the same bar.
- Relaunch preserves emptiness without repeating the first-use prompt; sidebar
  New Tab remains usable.
- Phase 0 submission reports that navigation is unavailable; no web view appears.

The UI suite reported one runtime QoS/priority-inversion warning during the
submission test. Inspected its result-summary and detailed stack; the stack is
unsymbolicated with no source location. Attribution remains unresolved and is
tracked in `KNOWN_ISSUES.md`. This is not a Swift concurrency compiler warning.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project Early.xcodeproj -scheme Early -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  ARCHS=arm64 build

codesign --verify --strict --verbose=2 build/DerivedData/Build/Products/Release/Early.app
codesign -d --entitlements - build/DerivedData/Build/Products/Release/Early.app
plutil -lint Early.xcodeproj/project.pbxproj Config/Early.entitlements
git diff --check
```

Release build and signature verification passed. Debug signature verification
also passed. The Release bundle declares macOS 14.0 and `local.early.browser`;
its final entitlements contain App Sandbox without `get-task-allow` or test
exceptions. No paid team, certificate or notarization was used. Project/plist
validation and whitespace checks passed. Source compilation produced no Swift
concurrency warnings. Initial build tooling emitted the non-source warning that
App Intents metadata extraction was skipped because the app has no AppIntents
dependency; UI tooling also logged debugger-version lookup diagnostics.

Source review confirmed no placeholder URLs, `WKWebView(...)` construction,
polling, custom observer registrations or unbounded background tasks in the shell.
Core fixtures verify last-tab closing, pin retention, same-space neighbor
selection, empty-space switching, stale selections, and navigation intent.
Live-page acceptance scenarios remain Phase 1 work, not claimed UI passes here.

The SQLite sizing probe was compiled with Swift 6 and `-O` and ran successfully;
exact commands, samples and interpretation are in `Docs/PERFORMANCE.md`.
No browser-level baseline or performance regression claims are made yet.

## Resolved build/test setup issues

- The selected developer directory was Command Line Tools, although full Xcode
  was installed. Used `DEVELOPER_DIR`; no global selection change was needed.
- Initial sandboxed SwiftPM/Xcode attempts could not write normal compiler and
  package caches or launch the manifest sandbox. Retried with the approved
  developer-tool access; builds and tests then ran.
- First UI attempt (`build/Phase0-UI.xcresult`) failed to locate the app bundle
  because an initial same-named Swift package executable confused test-host
  lookup. Removed the redundant package executable. The final package contains
  only the core library and tests; the native app is built by Xcode. The subsequent
  UI suite passed in `build/Phase0-UI-Retry.xcresult`.
- Inspection found automatic debugger entitlements in the first local Release
  artifact. Disabled base-entitlement injection for Release and rebuilt/verified.

## File inventory

Updated: `README.md`.

Added:

- `.gitignore`, `Package.swift`
- `Early.xcodeproj/project.pbxproj`
- `Early.xcodeproj/xcshareddata/xcschemes/Early.xcscheme`
- `Config/Early.xcconfig`, `Config/Early.entitlements`
- `Sources/Early/EarlyApp.swift`
- `Sources/Early/BrowserWindowModel.swift`
- `Sources/Early/BrowserWindowView.swift`
- `Sources/Early/BrowserCommands.swift`
- `Sources/Early/CommandBarView.swift`
- `Sources/Early/WebViewManager.swift`
- `Sources/EarlyCore/BrowserModels.swift`
- `Sources/EarlyCore/BrowserCoordinator.swift`
- `Sources/EarlyCore/TabStore.swift`
- `Sources/EarlyCore/FirstLaunchStore.swift`
- `Tests/EarlyCoreTests/BrowserCoordinatorTests.swift`
- `UITests/EarlyUITests.swift`
- `Tools/PersistenceProbe.swift`
- `ARCHITECTURE.md`, `PROGRESS.md`, `KNOWN_ISSUES.md`
- `Docs/MASTER_PLAN.md`, `Docs/PERFORMANCE.md`

Build products, caches and result bundles are ignored. Nothing was committed or
pushed. No external source code, icons or product artwork was copied.

## Next phase, when requested

Phase 1: validating navigation, lazy profile-configured WebKit allocation/reuse,
live tabs, navigation delegates, session persistence, browser shortcuts and live
acceptance tests. Add outgoing-network sandbox permission alongside navigation.
Do not expand the Phase 0 shell into sidebar management or visual-polish work yet.

## Requested chrome adjustment — 2026-10-09

Added a 6-point native frame around the browser surface, rounded content corners,
and a subtle 1-point outline. The sidebar now has a persistent address control
above the Space header. It shows the selected tab's URL when available or a
neutral prompt in the current empty shell. Clicking invokes the same shared
floating editor as Command-L, with no tab or web-view allocation.

Updated the workspace master plan and `Docs/MASTER_PLAN.md` identically with the
frame/sidebar URL requirements, acceptance cases, and phase guidance. Added
`/Users/rnp/Developer/Early/commands.md` with exact build/run, Xcode, core-test,
and UI-test commands. Updated README and architecture notes.

Changed implementation: `Sources/Early/BrowserWindowView.swift`,
`Sources/Early/CommandBarView.swift`, and `UITests/EarlyUITests.swift`.
The first UI run caught a click/focus race; fixed it by yielding within a bounded,
view-lifetime SwiftUI task before focusing the editor. Cancellation is checked;
there is no polling or fixed delay. The expanded relaunch test verifies the new
address control, immediate typing, a single editor, Escape, and zero web views.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project Early.xcodeproj -scheme Early -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -resultBundlePath build/Phase0-Sidebar-Focus-UI.xcresult test
```

Final Debug build and all 4 UI tests passed. The previously recorded runtime QoS
warning also appeared in this run and remains tracked in `KNOWN_ISSUES.md`.
The preceding failing focus run is
preserved in `build/Phase0-Sidebar-UI.xcresult`. The two master-plan files compare
identically, and `git diff --check` passed. No core logic changed, so the existing
16-test core result was not rerun for this UI adjustment. Release was not rebuilt
for this adjustment; use the current Debug artifact or the commands file.
No new performance measurements or visual/accessibility audit are claimed.
All work remained uncommitted at this checkpoint; the user subsequently authorized
committing and pushing it. Local build/run commands are also mirrored into the
repository's `commands.md` so they are included in the push.

## Commit and icon work — 2026-10-09

Committed the completed Phase 0/chrome work as `caea3a7` and successfully pushed
it to `origin/main` (`git@github.com:rangaNP/early-browser.git`). The workspace
commands file is mirrored in the repository. Phase 1 remains unstarted.

Created `Resources/Early.icon` from the user's flattened PNG: native navy
background plus separate sunset, horizon, upper-arch and lower-curve SVG artwork.
This is a visual reconstruction, not recovery of original raster layers. The
source PNG is retained unchanged in `Branding/Reference/Early-original.png`.
The image-generation skill was tried for alpha extraction; residual-pixel drafts
were rejected and are not shipped. Final assets are authored SVG paths/gradients
rendered with Icon Composer. Prompts and workflow are recorded under `Branding/`.

Verified the package with installed Icon Composer 27.0 (129), exported and
visually inspected Default/Dark/TintedLight/TintedDark 1024-pixel previews and
a Default 64-pixel preview. Corrected the package's group order to match the
native renderer's front-to-back order. Omitted an optional color-space annotation
rejected by the installed version. Opened the completed document in Icon Composer.

Wired `Early.icon` into the app's Resources phase with the installed Xcode's
`folder.iconcomposer.icon` file type and `ASSETCATALOG_COMPILER_APPICON_NAME = Early`.
Both Debug and arm64 Release builds passed with the existing commands. Release
`codesign --verify --strict --verbose=2` passed. The app bundles contain
`Assets.car` and `Early.icns`; Info.plist identifies Early as the app icon and
retains the macOS 14 minimum. This verifies compilation/fallback generation,
not runtime appearance on older macOS versions. Browser logic did not change,
so unit/UI tests were not repeated for this resource-only change.

Added `Branding/README.md`, `Branding/IMAGE_WORKFLOW.md`, the preserved reference
and native-renderer previews. Updated Xcode configuration, README, known issues,
architecture and both commands files. The icon work is a separate commit from
the Phase 0 checkpoint.
