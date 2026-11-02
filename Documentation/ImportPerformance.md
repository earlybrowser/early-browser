# Import performance checks

PR 3 keeps the existing import mappings, duplicate rules, retention, and undo.
Database imports now enforce complete snapshot budgets; password imports read,
parse and prepare a merge off the main actor; history imports reuse five batch
commands; preview trees cache their structure and prepare results on workers.

The following optimized checks used synthetic data on the development Mac.
They are comparisons, not timing requirements for CI or slower storage.

| Operation | Before | After |
| --- | ---: | ---: |
| Merge 10,000 password rows | 1.822 s | 0.0034 s |
| Merge 20,000 password rows | 7.375 s | 0.0065 s |
| Import 10,000 history visits | 0.365 s | 0.278 s |
| Import 20,000 history visits | 0.707 s | 0.538 s |
| Render a collapsed 79,999-node preview using its prepared index | 0.0366 s | 0.0000052 s |

Password timings measure the same in-memory bulk merge, excluding CSV parsing,
encryption and disk saving. History timings include the file-backed import batch.
Preview construction plus initial selection takes about 0.067 s once per source;
subsequent collapsed renders reuse that work. Search still examines source text
on a worker. No benchmark visits real sites or uses personal credentials.

Reproduce the password and preview checks with:

```sh
swift test -c release --no-parallel --filter PasswordImportPerformanceTests
swift test -c release --no-parallel --filter BrowserImportPreviewTreeTests
```

History regression tests check that repeated SQL preparation stays at five
commands for both small and large batches. They also cover retention, source
visit deduplication, rollback, cancellation, retry and undo preserving native
visits. The database budget tests use small injected limits to cover WAL growth,
source changes, busy readers, time/work exhaustion and temporary-file cleanup.

Password tests exercise supported export headers and encodings, quoted Unicode
and long notes, byte/row/field/column limits, pre-commit cancellation, concurrent
edits, profile deletion, save failure/retry and cancellation during saving.
Preview tests compare ordering and mixed states against the previous algorithm
and control delayed workers to verify that rapid edits and old queries cannot
publish into a newer source or a closed wizard.

Native wizard UI tests wait for the published selection and Continue state.
They compile locally and execute on CI. Manual checks should include password
import cancellation and hover backgrounds on the sidebar controls.

Local validation on 2026-11-02: `swift test --no-parallel` passed all 884
tests (413 core, 222 WebKit, 249 application). Debug `build-for-testing` and
Release `build` succeeded. Native UI automation was compiled only.
