<p align="center">
  <img src="Branding/Previews/Early-Default-1024.png" width="128" alt="Early icon" />
</p>

<h1 align="center">Early</h1>

<p align="center">A fast, lightweight native macOS browser built with Swift 6, SwiftUI, AppKit, and WebKit.</p>

Inspired by the fluid vertical-tab workflows of **Arc** and **Zen Browser**, Early focuses on a clean, distraction-free browsing experience with a collapsible sidebar, an instant command bar, and  macOS integration.

> **Note**: This project is currently in active development.

## Features

- **Arc & Zen Inspired Design**: Collapsible vertical sidebar with auto-hide and edge-hover reveal.
- **Command Bar**: Quick navigation and tab creation via `⌘T` and `⌘L`.
- **Tab Organization**: Persistent pins, icon-only Favorites, nested folders, custom names, and drag-and-drop ordering with website favicons.
- **Native macOS Performance**: Native AppKit and SwiftUI architecture with Swift 6 concurrency and low overhead.
- **SQLite Session Restoration**: Preserves tabs and active sessions across restarts.

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
