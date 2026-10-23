<p align="center">
  <img src="Branding/Previews/Early-Default-1024.png" width="128" alt="Early icon" />
</p>

<h1 align="center">Early</h1>

<p align="center">A fast, lightweight native macOS browser built with Swift 6, SwiftUI, AppKit, and WebKit.</p>

Inspired by the fluid vertical-tab workflows of **Arc** and **Zen Browser**, Early focuses on a clean, distraction-free browsing experience with a collapsible sidebar, an instant command bar, and macOS integration.

> **Note**: This project is currently in active development.

## Features

| Feature | Description | Status |
| --- | --- | --- |
| Native macOS interface | Light/dark translucent chrome, native window controls, and opaque website content. Solid surfaces respect Reduce Transparency and increased contrast. | Implemented. |
| Vertical tabs | Organize pages in a resizable sidebar with an address bar, auto-hide, and edge-hover reveal. Clear Today tabs, or close the others, in one step. | Implemented. |
| Command-bar navigation | Open URLs or Google searches, or Paste and Go from the address bar; new submissions from Favorites or pins open Today tabs without replacing saved pages. Typing or dismissing the bar never creates a tab. | Implemented. |
| Tab search and commands | Find existing tabs, pins, Favorites, and pages from your history; switch Spaces or profiles; and run browser actions from the command bar. Saved pages reopen without duplicate tabs. | Implemented. |
| Search suggestions | Optional Google suggestions below local matches, with keyboard and mouse selection and a privacy control in Settings. | Implemented. |
| Favorites and pins | Keep frequently visited sites as compact Favorites or named pins. Return a pin to its saved address and reopen closed pins on demand. | Implemented. |
| Nested folders | Group and reorder tabs with up to two nesting levels. Folder drop previews reserve a single row without opening hidden contents. New subfolders appear inside their parent; deleting a folder removes its contents. | Implemented. |
| Session restoration | Restore tabs, saved pages, ordering, and selection after quitting. Folders start collapsed, and an empty session opens the command bar. | Implemented. |
| Links and windows | Command-click links to open background tabs; copy or share links, and open links or tab copies in separate windows. Windows share saved items, not Today tabs. | Implemented. |
| Right-click menus | Page, link, image, and selected-text menus: download links, open, save, or copy images, search for selected text, and save or print the page. | Implemented. |
| Quick renaming | Option-click a tab, Favorite, or folder to rename without opening it. Ordinary clicks open/toggle immediately; dragging still reorders items. | Implemented. |
| Trackpad zoom | Native pinch-to-zoom and two-finger double-tap Smart Zoom. | Implemented. |
| Browser navigation | Back and Forward with history lists (right-click or hold), Reload, Stop, tab shortcuts, Reopen Closed Tab or Window, and native website alerts, confirmations, and prompts. Copy the current page URL with `⌘⇧C`. | Implemented. |
| Tab media controls | Click the speaker beside a tab’s icon to mute/unmute HTML audio or video without selecting it. Favorites keep their clean cards; use their context menu instead. Muting is also available in the command bar. | Implemented. |
| Website fullscreen | Let compatible website players enter and exit fullscreen. | Implemented. |
| Spaces and profiles | Named Spaces with icons and adaptive themes, plus separate profiles for cookies, logins, website data, and Favorites. | Implemented. |
| Haptic feedback | Subtle native feedback for sidebar dragging and Space changes on supported devices, respecting macOS preferences. | Implemented. |
| Thumbnail tab switcher | Preview open tabs in a compact strip; confirm a selection or cancel without changing the current page. Missing previews have a clear fallback. | Implemented. |
| Split views | Resizable side-by-side pages, floating drag-to-split targets, and shared controls following the focused pane. Removing a pane keeps its tab open. | Implemented. |
| Page lifecycle | Keep recent pages live, limit retained background pages, and reload released pages on selection. Protect visible panes, media, and editing; recover from page-process crashes with a bounded retry. | Implemented. |
| Downloads and documents | Download files from the sidebar footer with progress, stop and resume, and Finder reveal; saved pages and PDFs appear there too. Upload files, print, view PDFs, save pages as HTML, and open local files or dropped links in new tabs. | Implemented. |
| Find and zoom | Find text on a page with a match count, and zoom each tab from the keyboard or View menu. | Implemented. |
| Reading tools | Reader Mode for articles, on-device page translation (macOS 15 and later), and link addresses previewed on hover. | Implemented. |
| Passwords | Save and update sign-ins, fill them in as secure sign-in pages open (or pick an account from the list under the field), suggest strong passwords, and fill websites’ HTTP sign-in prompts. Settings › Passwords, behind Touch ID or your Mac’s password, lists, edits, imports, and exports them (CSV from Chrome, Safari, Firefox, 1Password, or Bitwarden). They’re encrypted on this Mac with a key in your Keychain, which macOS asks about once after each update until Early is signed. Private windows fill passwords but never save them. Passkeys need an Apple entitlement and are planned with signing. | Partial. |
| Extensions | Safari Web Extensions, through the same part of macOS that Safari uses (macOS 15.4 and later). Settings › Extensions adds those that come with Mac apps from the App Store (such as uBlock Origin Lite) or installs one from a folder or ZIP file. Each profile has its own; choose which websites each can use, whether it runs in private windows, and open its options. Use one on a page from the address bar’s site controls or the Extensions menu. Parts of an extension that talk to its Mac app work only in Safari, and Chrome Web Store installs aren’t supported. | Partial. |
| Default browser | Choose Early as the default browser and handle externally opened links. | Planned. |
| State portability | Export/import supported settings, windows, tabs, folders, pins, Favorites, and workspace metadata; exclude credentials and private sessions. | Planned. |
| Developer tools | Inspect Element in every page’s right-click menu and Web Inspector (`⌥⌘I`) docked beside the page, plus a page’s current source (`⌥⌘U`). The inspector uses WebKit preferences that aren’t public API; without them, Safari’s Develop menu can inspect pages. | Implemented. |
| History and private windows | Browse and search history (`⌘Y`), reopen today’s pages and recently closed tabs and windows from the History menu, clear history and website data by period, and open private windows (`⌘⇧N`) that keep nothing after closing. Pins and Favorites are Early’s saved pages. | Implemented. |
| Site permissions and security | See whether each site is secure and open its certificate, and allow or block camera, microphone, and location (macOS 27) per site, and clear one site’s cache and cookies, from the address bar’s site controls. Deceptive and malware sites show WebKit’s warning, and links for other apps such as `mailto:` ask before opening them. Notifications have no public WebKit API yet; content blockers come as extensions. | Partial. |
| GitHub live folders | Automatically collect pull requests and review requests in a folder linked to your GitHub account. | Planned. |
| Picture in Picture | Websites’ Picture in Picture works, and videos playing in a tab you switch away from continue in a floating window and return when you come back; turn that off in Settings. macOS offers this to web views only through a WebKit preference that isn’t public API, so Early uses it only where WebKit still has it. | Partial. |
| Settings and customization | Native Settings for profiles, passwords, extensions, Space assignment, appearance, sidebar behavior, search suggestions, command-bar actions, and local session restoration. More customization is planned. | Partial. |
| macOS distribution | Install packaged releases or use Homebrew, with optional signing and notarization. | Planned. |

Early uses a Safari-compatible browser identity to improve website compatibility.

Released pages restore their saved address and organization, not live forms,
JavaScript state, or exact back/forward history. Profile-local tab thumbnails
are bounded and kept only in memory for the tab switcher.

Tab mute choices survive reloads/navigation and memory eviction until the tab closes; they are
not site preferences or restored session state. Public HTML media APIs cover
page elements and embedded frames, not Web Audio-only output, inaccessible
shadow-tree players, or audio elements never attached to a document. Player
volume and pre-existing mute settings are preserved.

## Commands

Run all commands from the repository root directory (`early-browser`):

### Build and open the app

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj \
  -scheme Early \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  build && open build/DerivedData/Build/Products/Debug/Early.app
```

### Open an already-built app

```sh
open build/DerivedData/Build/Products/Debug/Early.app
```

### Work in Xcode

```sh
open Early.xcodeproj
```

### Run core, WebKit, and application integration tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel
```

### Run native UI tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj \
  -scheme Early \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  test
```

### Measure page lifecycle

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Scripts/measure-lifecycle.sh
```

This opt-in Release benchmark uses local pages for 0/1/10/50/100 tabs and emits
JSON timing, resource-count, idle CPU and host-memory samples. It opens no windows;
rendered launch, real-site performance and separate WebKit-process memory require
additional profiling. Normal package tests enforce deterministic resource/work
limits rather than machine-dependent timing thresholds.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development and review workflow.
AI-assisted contributions are welcome; contributors must understand their changes
and explain them when maintainers ask questions in comments.

Package and native UI tests run in GitHub Actions on pull requests and pushes to
`main`. Test logs and UI result bundles are available as workflow artifacts.

## License

[Mozilla Public License 2.0 (MPL-2.0)](LICENSE). Reader Mode includes
[Mozilla Readability](Sources/EarlyWeb/Resources/Readability) under the Apache License 2.0.

Copyright (c) 2026 rangaNP.
