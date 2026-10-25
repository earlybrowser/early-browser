#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
#
# Builds a release of Early: a Release build for Apple Silicon, signed inside
# out with the hardened runtime (ad-hoc unless an identity is given), zipped,
# with its SHA-256. The update key never reaches the build: --appcast, run
# afterwards on the same output folder, writes Sparkle's appcast for that zip
# and signs both with the key in SPARKLE_ED_PRIVATE_KEY.
#
#   Scripts/release.sh 0.2.0 [--build-number 148] [--sign IDENTITY] [--output build/Release]
#   Scripts/release.sh 0.2.0 --appcast [--output build/Release]
#
# The build number defaults to the commit count, which only grows on main.
set -euo pipefail

usage() {
    echo "usage: Scripts/release.sh VERSION [--build-number N] [--sign IDENTITY] [--output DIR]" >&2
    echo "       Scripts/release.sh VERSION --appcast [--output DIR]" >&2
    exit 64
}

[[ $# -ge 1 ]] || usage
version="$1"
shift
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "The version must look like 1.2.3 or 1.2.3-beta.1." >&2; exit 64; }
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
build_number="$(git rev-list --count HEAD)"
identity="-"
appcast=0
output="build/Release"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-number) build_number="${2:?}"; shift 2 ;;
        --sign) identity="${2:?}"; shift 2 ;;
        --appcast) appcast=1; shift ;;
        --output) output="${2:?}"; shift 2 ;;
        *) usage ;;
    esac
done
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo "The build number must be a whole number." >&2; exit 64; }

repository="https://github.com/earlybrowser/early-browser"
derived="$output/DerivedData"
zip="Early-$version.zip"

if [[ $appcast -eq 1 ]]; then
    : "${SPARKLE_ED_PRIVATE_KEY:?--appcast needs SPARKLE_ED_PRIVATE_KEY}"
    [[ -f "$output/$zip" && -f "$output/BUILD_NUMBER" ]] || { echo "Build $version into $output first." >&2; exit 1; }
    build_number="$(cat "$output/BUILD_NUMBER")"
    tools="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
    # sparkle:edSignature="…" length="…"
    enclosure="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - "$output/$zip")"
    published="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    cat > "$output/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Early</title>
    <link>$repository/releases</link>
    <item>
      <title>Early $version</title>
      <pubDate>$published</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$repository/releases/tag/v$version</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>Early $version is ready. See what’s new on GitHub.</p>]]></description>
      <enclosure url="$repository/releases/download/v$version/$zip" type="application/octet-stream" $enclosure/>
    </item>
  </channel>
</rss>
XML
    # Sparkle only reads a feed signed with the same key (SURequireSignedFeed).
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - "$output/appcast.xml"
    echo "Done: $output/appcast.xml"
    exit 0
fi

mkdir -p "$output"
rm -rf "$output/Early.app" "$output"/Early-*.zip "$output/SHA256SUMS" "$output/appcast.xml" "$output/BUILD_NUMBER"

echo "Building Early $version ($build_number)…"
if ! xcodebuild -project Early.xcodeproj -scheme Early -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" build > "$output/build.log" 2>&1; then
    tail -40 "$output/build.log" >&2
    exit 1
fi
ditto "$derived/Build/Products/Release/Early.app" "$output/Early.app"
app="$output/Early.app"

# Inside out, as Sparkle's sandboxing guide asks, and never with --deep. The
# hardened runtime keeps other code out of Early: no injected libraries, no
# debugger. The app keeps the entitlements Xcode gave it, with its bundle
# identifier filled in. A real identity (Developer ID, later) also gets a
# timestamp, and library validation then accepts Sparkle, signed by the same
# team. An ad-hoc build has no team, so validation would refuse Sparkle's
# framework at launch: it alone is allowed to load ad-hoc signed libraries.
options=(--options runtime)
[[ "$identity" != "-" ]] && options+=(--timestamp)
sign() { codesign --force --sign "$identity" "${options[@]}" "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
if [[ "$identity" == "-" ]]; then
    entitlements="$output/Early.entitlements"
    codesign -d --entitlements - --xml "$app" > "$entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$entitlements"
    sign --entitlements "$entitlements" "$app"
    rm "$entitlements"
else
    sign --preserve-metadata=entitlements "$app"
fi
codesign --verify --strict --deep --verbose=1 "$app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$zip"
(cd "$output" && shasum -a 256 "$zip" > SHA256SUMS)
echo "$build_number" > "$output/BUILD_NUMBER"

echo "Done: $output/$zip"
cat "$output/SHA256SUMS"
