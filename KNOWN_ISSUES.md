# Known issues and planned limitations

## Phase 0 scope

- No URL/search navigation yet. Return leaves the command bar open with an
  unavailable message. There is intentionally no tab/web-view creation path.
- Sidebar sections and Personal space are structural labels. Tabs/pins/spaces
  and closing behavior are verified in core fixtures; full management UI comes
  in later phases. There are no placeholder tab records.
- Only the first-use preference is persisted. SQLite sessions, migrations,
  corruption handling, closed-tab recovery, and populated-session restoration
  begin in Phase 1. Empty relaunch uses the persistent first-use distinction.
- Back/forward/reload, downloads, history, settings, private browsing, profile
  isolation, and full multi-window behavior are not implemented.
- The command bar focuses its input; selecting an existing page URL and returning
  focus to real web content must be verified when Phase 1 adds live pages.
- The web-view manager currently has no observers or creation path. It must gain
  explicit observer-token cleanup and allocation/reuse tests alongside Phase 1.

## Verification and release limits

- The passing UI suite reported one runtime priority-inversion warning during
  the submission test: a user-interactive thread waited on a default-QoS thread.
  The result bundle contains an unsymbolicated stack and no source location, so
  responsibility is not established. No functional test failed. Investigate in
  Instruments before setting responsiveness budgets; do not suppress the checker
  or assume the warning is harmless. See `build/Phase0-UI-Retry.xcresult`.
  It also recurred in the passing `build/Phase0-Sidebar-Focus-UI.xcresult` run.
- Only Apple silicon on macOS 27.0.1 has been exercised. Deployment target 14.0
  compiles against SDK availability annotations; oldest-supported-OS runtime,
  Intel, universal output, multiple displays, and website compatibility remain
  unverified.
- Full VoiceOver, contrast, Reduce Motion, light/dark, fullscreen and resize
  audits remain for Phase 6/9. The shell uses system materials/colors, labeled
  controls, native menus, keyboard input, and no custom animated transitions.
- Browser-level performance and Instruments profiling await real web content.
  The recorded SQLite probe is synthetic and not a release performance gate.
- Name availability, owned bundle namespace, application icon, release license,
  public distribution, Gatekeeper on a second Mac, signing and notarization need
  explicit release work. Local ad-hoc signing is not Developer ID/notarization.
- Debug UI tests use unique `local.early.tests.*` preference suites. Small test
  preference domains can remain in the app sandbox after UI runs; tests do not
  erase the normal browser domain or change its first-use preference.

Actual commands, outcomes and any outstanding test failures are recorded in
[PROGRESS.md](PROGRESS.md).
