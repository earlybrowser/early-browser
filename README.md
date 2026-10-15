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
| Native macOS interface | Light and dark appearances, native window controls, and WebKit browsing in a compact SwiftUI/AppKit window. | Implemented. |
| Vertical tabs | Organize pages in a resizable sidebar with an address bar, auto-hide, and edge-hover reveal. | Implemented. |
| Command-bar navigation | Open URLs or Google searches with `⌘T`; edit the current address with `⌘L`. A tab is created when you submit. | Implemented. |
| Search suggestions | Google suggestions while typing, with keyboard and mouse selection. Enabled by default; typed search phrases are sent to Google. A Settings control is planned. | Implemented. |
| Favorites and pins | Keep frequently visited sites as compact Favorites or named pins. Return a pin to its saved address and reopen closed pins on demand. | Implemented. |
| Nested folders | Group and reorder tabs with up to two nesting levels. Folder drop previews reserve a single row without opening hidden contents. New subfolders appear inside their parent; deleting a folder removes its contents. | Implemented. |
| Session restoration | Restore tabs, saved pages, ordering, and selection after quitting. Folders start collapsed, and an empty session opens the command bar. | Implemented. |
| Links and windows | Command-click links to open background tabs; copy or share links, and open links or tab copies in separate windows. Windows share saved items, not Today tabs. | Implemented. |
| Quick renaming | Double-click a tab, Favorite, or folder to rename it; dragging still reorders items. | Implemented. |
| Trackpad zoom | Native pinch-to-zoom and two-finger double-tap Smart Zoom. | Implemented. |
| Browser navigation | Back, Forward, Reload, Stop, tab shortcuts, and native website alerts, confirmations, and prompts. | Implemented. |
| Media indicators | Identify tabs playing unmuted HTML audio or video with a speaker icon. | Implemented. |
| Website fullscreen | Let compatible website players enter and exit fullscreen. | Implemented. |
| Spaces and profiles | Separate workspaces with colored space dots and isolated browsing profiles. | Planned. |
| Universal search and commands | Find tabs, history, and bookmarks, and run browser actions from the command bar. | Planned. |
| Split views and tab previews | Side-by-side pages with shared controls following the focused pane; thumbnail tab switcher. | Planned. |
| Page lifecycle | Create pages on demand and release them when closed. Automatic suspension and recovery are planned. | Partial. |
| Downloads and page tools | Manage downloads, upload files, print, view PDFs, find text, and adjust zoom. | Planned. |
| Developer tools | Inspect pages through supported WebKit developer facilities. | Planned. |
| History, bookmarks, and privacy | Search browsing history and bookmarks, use private sessions, manage permissions, and clear site data. | Planned. |
| GitHub live folders | Automatically collect pull requests and review requests in a folder linked to your GitHub account. | Planned. |
| Picture in Picture | Watch compatible videos in a floating window, with an on/off preference. | Planned. |
| Settings and customization | Choose search and startup preferences, themes, keyboard shortcuts, and privacy settings. | Planned. |
| macOS distribution | Install packaged releases or use Homebrew, with optional signing and notarization. | Planned. |

Early uses a Safari-compatible browser identity to improve website compatibility.

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

### Run core and WebKit ownership tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
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

## License

[MIT](LICENSE)
