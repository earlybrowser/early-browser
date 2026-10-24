## Install

- **Homebrew:** `brew install --cask earlybrowser/tap/early`
- **Download:** `Early-@VERSION@.zip` below. Check it with `shasum -a 256 Early-@VERSION@.zip` against `SHA256SUMS`, then move Early to Applications.

Early needs a Mac with Apple Silicon and macOS 14 or later.

Early isn't notarized by Apple yet, so the first time you open a downloaded copy, macOS blocks it. Open it once, then choose **Open Anyway** in System Settings › Privacy & Security, or run `xattr -dr com.apple.quarantine /Applications/Early.app`. Homebrew does this for you. Updates after that install from inside Early.

