# Early app icon

The editable source is [`Resources/Early.icon`](../Resources/Early.icon), a native
Icon Composer document wired into the Early Xcode target. Open it with:

```sh
open -a "Icon Composer" Resources/Early.icon
```

The input was the user's flattened 1254 × 1254 PNG, retained unmodified at
[`Reference/Early-original.png`](Reference/Early-original.png). There are no
recoverable source layers in that PNG. The deliverable is a visual reconstruction
of its shapes and palette, not a pixel-exact extraction of original design data.

## Editable components

| Back to front | Source | Edit in Icon Composer |
| --- | --- | --- |
| Navy background | Native document fill | Select Background; adjust the two-color gradient |
| Sunset glow | `Assets/01-Sunset.svg` | Select Sunset atmosphere; adjust position/opacity or edit SVG stops |
| Ocean horizon | `Assets/02-Horizon.svg` | Select Ocean horizon; adjust placement or edit its path/gradient |
| Warm upper arch | `Assets/03-E-Upper.svg` | Select Early monogram → Warm upper arch |
| Cool lower curve | `Assets/04-E-Lower.svg` | Select Early monogram → Cool lower curve |

The assets live inside the `.icon` package. In Finder, use **Show Package
Contents** to reach the SVG files. All four artwork layers have 1024 × 1024
canvases and transparent areas. The foreground pieces share one glass group for
combined lighting. The glow and horizon are separate groups without glass.
The installed renderer consumes groups front-to-back, so the document lists the
monogram first even though filenames are numbered back-to-front.

The white photo backdrop, original tile bevel and cast shadow were not retained.
Icon Composer supplies the macOS enclosure, specular treatment and system
appearance rendering. The gradients inside the letter remain part of the SVG
artwork so its warm/cool identity survives appearance changes.

Use the Background inspector for the native navy gradient. Use group inspectors
for shadows, lighting and translucency. Changing a shape requires editing the
SVG path in a vector editor; Icon Composer arranges/materializes artwork rather
than providing a full path editor. Save in Icon Composer, then rebuild Early.

## Preview and build verification

Rendered with installed Icon Composer 27.0 (129), using its `ictool` executable:

```sh
"/Applications/Icon Composer.app/Contents/Executables/ictool" \
  "$PWD/Resources/Early.icon" --export-image \
  --output-file "$PWD/Branding/Previews/Early-Default-1024.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

`Previews/` contains Default, Dark, TintedLight and TintedDark at 1024 pixels, plus
a 64-pixel Default preview. These are native-renderer outputs, not a substitute
for the layered document. Tinted previews use the renderer's default tint, not
a fixed new brand color. All five were visually inspected; this is not an
exhaustive audit across wallpapers, tint selections or display settings.

Xcode references the resource as `folder.iconcomposer.icon` and
`ASSETCATALOG_COMPILER_APPICON_NAME = Early`. The installed Xcode compiler emits
both `Assets.car` and `Early.icns`, and sets `CFBundleIconName`/`CFBundleIconFile`
to Early. This retains a compiled fallback while the deployment target remains
macOS 14. Runtime appearance on macOS 14/15 is still untested; no universal build
or back-deployment runtime test is claimed.

## Method and provenance

The image-generation skill's built-in editor was tried for an isolated alpha
cutout, then a targeted edge cleanup. Both drafts left residual pixels outside
the glyph and were rejected. No generated bitmap draft is shipped or referenced
by the app. The final artwork is newly authored SVG geometry based on the supplied
reference, assembled and rendered with Icon Composer. No CLI image-generation
API, API key, third-party artwork or font was used. The original remains intact.
See [IMAGE_WORKFLOW.md](IMAGE_WORKFLOW.md) for the attempted prompts.

The starting document came from the installed Xcode macOS Icon Composer template.
The installed build specification verified its resource type; native rendering
and the app build verified the resulting package. An optional empirical
`color-space-for-untagged-svg-colors` annotation was rejected by this installed
version and omitted. Treat the package schema as tool-owned: prefer saving edits
through Icon Composer and validate after hand-edited JSON changes.

Sources inspected:

- [Apple: Icon Composer](https://developer.apple.com/icon-composer/)
- [Apple: Create icons with Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/)
- [Apple: Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [IconComposerModel author's empirical format reference](https://github.com/peterpoliwoda/icon-composer-template): consulted for field names only; no implementation or artwork copied.

This is the current working icon, subject to visual approval and the project's
existing name/rights checks before public branding.
