<p align="center">
  <img src="Branding/Previews/Early-Horizon-1024.png" width="128" alt="Early icon" />
</p>

<h1 align="center">Early</h1>

<p align="center">A fast, lightweight native macOS browser built with Swift 6, SwiftUI, AppKit, and WebKit.</p>

Inspired by the fluid vertical-tab workflows of **Arc** and **Zen Browser**, Early focuses on a clean, distraction-free browsing experience with a collapsible sidebar, an instant command bar, and macOS integration.

> **Note**: This project is currently in active development.

## Install

Early needs a Mac with Apple Silicon and macOS 14 or later.

```sh
brew install --cask earlybrowser/tap/early
```

Or download `Early-<version>.zip` from [Releases](https://github.com/earlybrowser/early-browser/releases),
check it against `SHA256SUMS`, and move Early to Applications. Early isn't
notarized by Apple yet, so macOS blocks the first launch of a downloaded copy:
open it once, then choose **Open Anyway** in System Settings › Privacy &
Security, or run `xattr -dr com.apple.quarantine /Applications/Early.app`.
Homebrew does this for you. After that, Early updates itself.

## Current limitations

We're working on these and will fix them as soon as we can.

- **Not notarized yet:** macOS asks you to allow Early the first time you open a downloaded copy.
- **Password prompt after updates:** macOS asks once after each update before Early can open your saved passwords. Choose Always Allow.
- **No passkeys yet:** sign in with a password instead.
- **Apple Silicon only:** no Intel build.
- **Extensions:** Safari Web Extensions only (macOS 15.4 and later); no Chrome Web Store.

## Features

| Feature | Description | Status |
| --- | --- | --- |
| Native macOS interface | Light/dark translucent chrome, native window controls, and opaque website content. Solid surfaces respect Reduce Transparency and increased contrast. | Implemented. |
| Vertical tabs | Organize pages in a resizable sidebar with an address bar, auto-hide, and edge-hover reveal. Clear Today tabs, or close the others, in one step. | Implemented. |
| Command-bar navigation | Open URLs or searches with your chosen engine, or Paste and Go from the address bar; new submissions from Favorites or pins open Today tabs without replacing saved pages. Typing or dismissing the bar never creates a tab. | Implemented. |
| Tab search and commands | Find existing tabs, pins, Favorites, and pages from your history; switch Spaces or profiles; and run browser actions from the command bar. Saved pages reopen without duplicate tabs. | Implemented. |
| Search engine and suggestions | Choose Google (the default), DuckDuckGo, Bing, Ecosia, Brave Search or Kagi in Settings › Search. Optional suggestions come from that engine below local matches, with keyboard and mouse selection and a privacy control; Kagi offers none without its sign-in, so nothing typed leaves the Mac until you search, and nothing is sent to another engine instead. | Implemented. |
| Favorites and pins | Keep frequently visited sites as compact Favorites or named pins. Return a pin to its saved address and reopen closed pins on demand. | Implemented. |
| Nested folders | Group and reorder tabs with eight nested levels beneath a root folder. Folder drop previews reserve a single row without opening hidden contents. New subfolders appear inside their parent; deleting a folder removes its contents. Give a folder an icon from the Space icons when you create it, or later with Change Icon…; it's drawn on the folder. | Implemented. |
| Session restoration | Restore tabs, saved pages, ordering, and selection after quitting. Folders start collapsed, and an empty session opens the command bar. | Implemented. |
| Links and windows | Command-click links to open background tabs; copy or share links, and open links or tab copies in separate windows. Windows share saved items, not Today tabs. | Implemented. |
| Right-click menus | Page, link, image, and selected-text menus: download links, open, save, or copy images, search for selected text, and save or print the page. | Implemented. |
| Quick renaming | Option-click a tab, Favorite, or folder to rename without opening it. Ordinary clicks open/toggle immediately; dragging still reorders items. | Implemented. |
| Trackpad zoom | Native pinch-to-zoom and two-finger double-tap Smart Zoom. | Implemented. |
| Browser navigation | Back and Forward with history lists (right-click or hold), Reload, Stop, tab shortcuts, Reopen Closed Tab or Window, and native website alerts, confirmations, and prompts. Copy the current page URL with `⌘⇧C`. `⌘W` closes the current tab, and the window when no page is showing; closing the last window keeps Early running until `⌘Q`. | Implemented. |
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
| Default browser | Make Early the default browser from Settings › General or the welcome (macOS asks first, and your answer is kept). Links from other apps, and web pages opened from Finder, open as new tabs in the frontmost window, or a new one when none is open, even when the link launched Early; never in a private window. | Implemented. |
| State portability | Settings › Sessions exports your profiles, Spaces, folders, pins, Favorites, windows, open tabs and settings to a file, and imports one after showing what it holds: add its profiles beside yours, or replace the matching ones (which keep their website data). Imports are checked in full, a backup of what you had is saved first, and tabs load only when you choose them. Passwords, cookies, history, website data and private windows are never exported, so websites ask you to sign in again. | Implemented. |
| Welcome | The first window shows a short welcome below the command bar: the command bar, Favorites, pins and Today, Spaces, split view, the tab switcher and Downloads. It never takes the command bar's focus and doesn't come back once closed. | Implemented. |
| Developer tools | Inspect Element in every page’s right-click menu and Web Inspector (`⌥⌘I`) docked beside the page, plus a page’s current source (`⌥⌘U`). The inspector uses WebKit preferences that aren’t public API; without them, Safari’s Develop menu can inspect pages. | Implemented. |
| History and private windows | Browse and search history (`⌘Y`), reopen today’s pages and recently closed tabs and windows from the History menu, clear history and website data by period, and open private windows (`⌘⇧N`) that keep nothing after closing. Pins and Favorites are Early’s saved pages. | Implemented. |
| Site permissions and security | See whether each site is secure and open its certificate, and allow or block camera, microphone, and location (macOS 27) per site, and clear one site’s cache and cookies, from the address bar’s site controls. Deceptive and malware sites show WebKit’s warning, and links for other apps such as `mailto:` ask before opening them. Notifications have no public WebKit API yet; content blockers come as extensions. | Implemented. |
| GitHub live folder | Right-click the sidebar and choose GitHub Live Folder for a Pull Requests folder whose pins are your open pull requests on GitHub: ones you opened, ones assigned to you, and ones waiting for your review, each listed once. They're ordinary pinned tabs, so nothing loads until you choose one. Merged and closed ones leave the folder (one you're reading stays open as a Today tab), and right-click › Remove from Folder takes one out for good. It uses the GitHub account you're signed in to in that profile: Early reads GitHub's own pull-request pages in a hidden page and stores no GitHub sign-in or token. It refreshes at the interval you choose in the folder's menu (15 minutes to 8 hours; Last fetch shows when it last did), backs off when GitHub asks it to, and says so when you're offline. Signed out, or when GitHub's pages can't be read, it empties rather than show an old list. Never in private windows; each profile has its own. A GitHub redesign can stop it reading until Early is updated. | Implemented. |
| Picture in Picture | Websites’ Picture in Picture works, and videos playing in a tab you switch away from continue in a floating window and return when you come back, or when you click the window's return button; turn that off in Settings. macOS offers this to web views only through a WebKit preference that isn’t public API, so Early uses it only where WebKit still has it. | Implemented. |
| Settings and customization | Native Settings for profiles, passwords, privacy (website permissions, website data and history for each profile), extensions, Space assignment, appearance, sidebar behavior, search, keyboard shortcuts and sessions. Change or remove the shortcut of almost any command in Settings › Shortcuts (numbered tabs and Spaces, ⌃Tab and macOS's own shortcuts stay). Choose whether pins and Favorites return to their saved page when closed, whether ⌃Tab shows the tab switcher, and whether empty windows show the command bar. | Implemented. |
| Passwords | Save and update sign-ins, fill them in when you click or tab into a secure sign-in field (or pick an account from the list under it), suggest strong passwords, and fill websites’ HTTP sign-in prompts from saved passwords (saving from those prompts comes later). Settings › Passwords, behind Touch ID or your Mac’s password, lists, edits, imports, and exports them (CSV from Chrome, Safari, Firefox, 1Password, or Bitwarden). They’re encrypted on this Mac with a key in your Keychain, which macOS asks about once after each update until Early is signed by an Apple developer account (development builds keep the key in a file instead, so rebuilding never asks). Private windows fill passwords but never save them. Passkeys need an Apple entitlement and are planned with signing. | Partial. |
| Extensions | Safari Web Extensions, through the same part of macOS that Safari uses (macOS 15.4 and later). Settings › Extensions adds those that come with Mac apps from the App Store (such as uBlock Origin Lite) or installs one from a folder or ZIP file. Each profile has its own; choose which websites each can use, whether it runs in private windows, and open its options. Use one on a page from the address bar’s site controls or the Extensions menu. Parts of an extension that talk to its Mac app work only in Safari, and Chrome Web Store installs aren’t supported. | Partial. |
| Import from other browsers | File › Import from Another Browser… or Settings › Sessions previews a selectable tree of bookmarks and verified browser organization. Import compatible bookmarks HTML from any browser, Chromium/Firefox profiles, Safari export ZIPs, and Zen workspaces; Arc sidebar import is experimental. Choose existing or new profiles and Spaces, preserve folders and intentional URL copies, and keep pages unloaded. History and open tabs start unchecked. Undo survives restart and preserves later edits. Passwords use their separate CSV import; cookies and sign-ins never transfer. See the [supported formats and limits](Documentation/BrowserImport.md). | Implemented. |
| Installing and updates | Install with Homebrew or from GitHub Releases. Early checks for updates once a day and installs them when you agree (or automatically, if you choose in Settings); each update is signed with Early's own key. Not notarized by Apple yet. | Partial. |

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

### Make a release

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/release.sh 0.2.0
```

This builds `build/Release/Early-0.2.0.zip` and `SHA256SUMS`. To publish one,
push a tag (`git tag v0.2.0 && git push origin v0.2.0`): GitHub Actions builds
it, signs the update and drafts the release, and publishing the draft updates
the Homebrew tap.

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
