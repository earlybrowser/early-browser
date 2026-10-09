# Early

A native macOS browser built with Swift and WebKit. Browse without the noise.

Phase 0 provides the native shell, a command-bar-first interaction model, and
tested state boundaries. It does **not** navigate websites yet. Pressing Return
in the command bar explains that browsing is coming in the next build.

## Run

Requires macOS 14 or later and Xcode with a Swift 6 toolchain. Open
`Early.xcodeproj`, select the **Early** scheme and **My Mac**, then Run.
No Apple Developer account or development team is required; the app is signed
locally with an ad-hoc identity. There are no third-party package dependencies.

If Command Line Tools is your selected developer directory, use a per-command
override rather than changing your system configuration:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj -scheme Early -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Early.app
```

The command above selects Apple silicon. Other architectures and macOS 14
runtime compatibility have not yet been tested.

## Current behavior

- First launch: sidebar, empty content, and a focused command bar.
- Slim native frame with rounded corners around the content surface.
- Sidebar URL control: displays the active address (or an empty-state prompt)
  and opens the shared command bar with current-tab intent when clicked.
- ⌘T: open the command bar with new-tab intent; no tab is allocated.
- ⌘L: open that same bar with current-tab intent.
- Escape or the bar's close button: dismiss it without creating anything.
- ⌘W with no active tab: leave the browser window and presentation unchanged.
- ⇧⌘W or the red window button: explicitly close the window.
- Relaunch: preserve an empty session without repeating the first-launch bar.

Favorites, Pinned, Today, and Personal are structural sidebar labels in this
phase. Their management UI and live pages arrive in subsequent phases.

## Verify

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj -scheme Early -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test
```

`swift test` runs the UI-independent browser-state logic (using Foundation
and Observation on macOS). Xcode's test action runs the native UI suite and
requires a logged-in graphical session with UI automation available. UI tests
use unique preferences domains; they do not reset normal Early preferences.

See [ARCHITECTURE.md](ARCHITECTURE.md) for decisions and state transitions,
[PROGRESS.md](PROGRESS.md) for actual verification results,
[KNOWN_ISSUES.md](KNOWN_ISSUES.md) for limitations, and
[Docs/PERFORMANCE.md](Docs/PERFORMANCE.md) for measurement methodology.

Early is a provisional product name. `local.early.browser` is a development-only
bundle identifier, not a verified public namespace. This is not a notarized
release or a production-ready browser.
