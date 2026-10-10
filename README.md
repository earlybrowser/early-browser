# Early

A native macOS browser built with Swift 6, SwiftUI, AppKit and WebKit.

Early uses a command bar for new tabs, a compact sidebar URL control, retained
web views and SQLite session restoration. This is a development build; downloads,
advanced sidebar organization, profiles and other browser essentials are still planned.

## Build locally

Requires macOS 14+ and Xcode with Swift 6 and Icon Composer support (Xcode 27 tested).
No paid Apple Developer membership is needed for local ad-hoc signing.

Open `Early.xcodeproj`, select **Early → My Mac**, and press **Command-R**. Or, from
this repository on Apple silicon:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj -scheme Early -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Early.app
```

Quit Early before rebuilding. Run core tests with the same `DEVELOPER_DIR` override
and `swift test`; replace `build` with `test` in the Xcode command for UI tests.

## Controls

- Command-T: new-tab command bar; Command-L: edit current address; Escape: dismiss.
- Command-W: close tab; Command-Shift-T: reopen; Command-1–9: select tabs.
- Command-R: reload; Command-[ / ]: back/forward; Command-.: stop.
- Sidebar button or Command-Shift-S: toggle auto-hide. Hover at the left edge to reveal.

Sessions restore URLs and selection, not unsaved forms or page history.
The editable app icon is `Resources/Early.icon`; save Composer changes and rebuild.

## License

[MIT](LICENSE).
