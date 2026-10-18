# Contributing to Early

Small, focused contributions are welcome. For a larger feature or design change,
open an issue first so we can agree on the direction before you spend time on it.

## Getting started

Use macOS 14 or later and full Xcode with Swift 6 support. CI uses Xcode 26.6.
Fork the repository, create a branch from `main`, and follow the build and test
commands in the [README](README.md#commands).

Keep changes scoped, follow the surrounding Swift style, and add regression
coverage for bug fixes. Use public platform APIs and keep accessibility and
Reduce Motion support intact.

## Testing and pull requests

Run `swift test` for core and WebKit changes. Run relevant UI tests for interface
changes, and describe any manual checks. UI tests control the mouse and keyboard:
keep your Mac unlocked, allow Xcode's requested automation permissions, and close
overlays that could cover the app. The HTTPS smoke test needs internet access.

Open a PR against `main` with a short explanation of what changed, why, and what
you tested. Include screenshots or a recording for visible changes. If a check
was not run, say so; don't report a build as a passing test run.

GitHub Actions runs package and UI tests on PRs and pushes to `main`. Logs and
UI result bundles are attached to the workflow run for seven days. Maintainers
can also start the workflow from the Actions tab. A green run does not replace
manual review of animation, accessibility, or behavior on other macOS versions.

## AI-assisted contributions

AI tools are allowed. You are responsible for understanding, reviewing, and
testing everything you submit, including generated code. If maintainers ask
questions in issue or PR comments, you must be able to explain your changes,
their reasoning, and their behavior, and follow up on requested revisions.
Do not submit changes you cannot explain or include private data in prompts,
logs, screenshots, or test results.

By contributing, you agree that your contribution is licensed under the
project's [Mozilla Public License 2.0 (MPL-2.0)](LICENSE).
