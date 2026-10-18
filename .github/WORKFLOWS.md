# Workflow plan

Only files in `.github/workflows/` are active. Files in
`.github/workflow-templates/` are unfinished scaffolds, not release automation.
They are manual-only and contain failing placeholder steps. Even if a template
is moved into the active folder too early, it cannot publish anything or claim
an implementation is complete.

## Current tests

`workflows/tests.yml` runs the package tests and four UI shards on separate
macOS runners. Xcode discovers the enabled tests and assigns each test to one
shard. Keep this complete-suite coverage when extending or reorganizing tests.

## Future workflows

- `workflow-templates/release.yml`: build, sign, notarize, and package on macOS;
  then publish those exact artifacts from Linux. Never publish from a PR run.
- `workflow-templates/homebrew.yml`: update the tap from an already published
  release on Linux; then verify installation on macOS without rebuilding Early.
- `workflow-templates/repository-checks.yml`: documentation/link checks and
  repository security checks on Linux. Website deployment belongs in the website
  repository if it remains separate from the browser.

Before enabling distribution, change the UI matrix to three balanced shards.
Together with the package job, one test run then uses four macOS slots. Release
and Homebrew workflows share a distribution concurrency group so their macOS
work does not overlap. Multiple PRs still share the account's macOS limit; this
is headroom, not a reserved runner or a global priority rule.

## Enabling a template

1. Replace every failing placeholder with real commands and validation. Settle
   the owned bundle identifier, release versioning, signing/notarization, supported
   architectures, and archive format before implementing distribution.
2. Configure and protect the `release` environment. Keep signing credentials out
   of PR jobs. Give tap updates a credential scoped to the tap repository, not a
   broad account token.
3. Require successful tests for the exact release commit. Verify artifact identity
   and checksums before publishing or updating Homebrew; do not silently rebuild
   or substitute a different commit between stages.
4. Review triggers, permissions, and queue behavior. Templates are manual-only;
   add trusted version-tag/release triggers or reusable-workflow connections only
   once implemented. Do not cancel an active release when another is requested.
5. Move the completed file into `.github/workflows/` and validate it with
   `actionlint`. Exercise the distribution pipeline on a prerelease before making
   it part of normal releases.
