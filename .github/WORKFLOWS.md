# GitHub Actions workflows

Files in `.github/workflows/` are active. Files in
`.github/workflow-templates/` are inactive historical scaffolds and must not be
copied over the working release or publication workflows.

## Tests

`workflows/tests.yml` runs on pull requests, pushes to `main`, and manual dispatch.
It uses macOS 26 runners and Xcode 26.6. One job runs
`swift test --no-parallel`; four separate jobs run native UI tests. Xcode discovers
the enabled UI tests, and the sorted identifiers are interleaved across the four
shards. Each shard executes serially to avoid competing mouse/keyboard input.

The workflow has read-only repository permissions and disables persisted checkout
credentials. New commits cancel obsolete test runs for the same ref. Logs,
selected test lists, crash reports and UI result bundles are retained for seven
days. Keep complete-suite discovery when adding tests; do not maintain separate
manual lists of tests or reduce the shard count as a release prerequisite.

## Release

`workflows/release.yml` runs when a `v*` tag is pushed. It validates the version,
runs package tests, builds the Apple Silicon Release app with
`Scripts/release.sh`, signs its Sparkle update feed, and creates a **draft** GitHub
release containing the ZIP, `SHA256SUMS` and `appcast.xml`. Version and build number
are passed to the packaged build; tagging does not edit `Config/Early.xcconfig`.

Before tagging, merge the intended version/configuration changes and confirm the
package job and all four UI shards passed for that exact `main` commit. The
release job itself does not rerun the UI shards. Review the resulting draft and
assets before publishing it. A tag with a version suffix creates a prerelease.

The job uses the `release` environment and repository write permission to create
the draft. `SPARKLE_ED_PRIVATE_KEY` is exposed only to the feed-signing step,
after the app is built. Keep its value outside Git and logs. The current workflow
uses ad-hoc app signing and does not notarize: Sparkle update signing is separate
from Developer ID signing. Paid-account signing/notarization remains future work.

Release concurrency is grouped by tag and is not cancelled by newer test runs.
Published tags and signed assets must not be moved or replaced; fix code in a
new unused version.

## Homebrew publication

`workflows/publish.yml` runs when a stable release is published. It downloads the
published checksum, writes the cask in `earlybrowser/homebrew-tap`, and runs
`brew style` and `brew audit` before pushing a changed cask. It uses the existing
release artifact; it does not rebuild Early. An unchanged cask is a no-op.

The workflow uses the `release` environment. `TAP_DEPLOY_KEY` is supplied to the
tap checkout; repository access for the app stays read-only. Tap updates are
serialized by the `homebrew-tap` concurrency group. Prereleases are skipped by
the automatic release event. To retry publication deliberately, manually run
the workflow with the intended release tag selected as its ref.

Tests, releases and tap publication do not share a global macOS-slot reservation;
GitHub queues jobs according to account capacity.

## Remaining templates

`workflow-templates/release.yml` and `homebrew.yml` describe an earlier proposed
distribution architecture; the active files above are the current implementation.
`workflow-templates/repository-checks.yml` is still unfinished and inactive.
Website deployment belongs to the separate website repository. Any future
workflow change needs validation against the actual files, permissions and
artifact paths rather than treating a template as implemented automation.
