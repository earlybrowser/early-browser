# Run Early locally

These commands are for this Apple silicon Mac with Xcode installed in
`/Applications/Xcode.app`. They select Xcode per command; no global toolchain
change or paid Apple Developer account is needed.

## Build and open the app

Quit Early with Command-Q before rebuilding if it is already running. Paste:

```sh
cd /Users/rnp/Developer/Early/early-browser
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj \
  -scheme Early \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  build && open build/DerivedData/Build/Products/Debug/Early.app
```

## Open an already-built app

```sh
open /Users/rnp/Developer/Early/early-browser/build/DerivedData/Build/Products/Debug/Early.app
```

## Work in Xcode

```sh
open /Users/rnp/Developer/Early/early-browser/Early.xcodeproj
```

Select the **Early** scheme and **My Mac**, then press **Command-R**.

## Run core tests

```sh
cd /Users/rnp/Developer/Early/early-browser
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Run native UI tests

These launch and control Early in your graphical session. They use isolated
preferences, leaving your normal first-launch preference untouched.

```sh
cd /Users/rnp/Developer/Early/early-browser
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Early.xcodeproj \
  -scheme Early \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  test
```

The current Phase 0 shell has a slim content frame and a sidebar address control.
Click that control or press Command-L to open the shared command bar; Command-T
opens it for a new tab. Escape dismisses it. After the first launch, the bar stays
closed until invoked. Website navigation arrives in Phase 1.

## Edit the app icon

```sh
open -a "Icon Composer" /Users/rnp/Developer/Early/early-browser/Resources/Early.icon
```

The document contains a native navy background and four editable SVG artwork
layers: sunset, horizon, warm upper arch, and cool lower curve. Save edits in
Icon Composer, then rebuild the app using the commands above. The original PNG
is preserved; the layers are a reconstruction of that flattened artwork.
