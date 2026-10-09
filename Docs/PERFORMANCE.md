# Measurement record

## Environment

2026-10-09: MacBook Air, Mac16,12, Apple M4, 16 GB RAM, arm64;
macOS 27.0.1 (26A434); Xcode 27.0 (27A266a); Apple Swift 6.4;
macOS 27 SDK, deployment target 14.0. Power/thermal state and competing workloads
were not controlled. These measurements are initial engineering observations.

## Persistence sizing probe

`Tools/PersistenceProbe.swift` uses system SQLite 3.54.0 with an isolated temporary
disk database, WAL, synchronous FULL, foreign keys and a space/order index. Each
transaction replaces synthetic tab metadata and its selection atomically. Read
timing includes preparing an indexed query and materializing ID/URL/title values.
Write timing includes statement preparation. No real user data is accessed.

```sh
mkdir -p build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -swift-version 6 -O -module-cache-path .build/ModuleCache \
  Tools/PersistenceProbe.swift -o build/persistence-probe
build/persistence-probe
```

One run; five warmups then 30 samples per row count; percentiles select index
`floor((n - 1) * fraction)` from sorted samples. Times are milliseconds.

| Tab rows | Write p50 | Write p95 | Read p50 | Read p95 |
| --- | --- | --- | --- | --- |
| 1 | 0.120 | 0.131 | 0.008 | 0.010 |
| 10 | 0.134 | 0.168 | 0.009 | 0.013 |
| 50 | 0.194 | 0.225 | 0.014 | 0.016 |
| 100 | 0.264 | 0.291 | 0.020 | 0.023 |

This is not the production schema, crash-durability proof, history benchmark,
browser resource benchmark, or a comparison with SwiftData. It does not include
actor scheduling, migrations, save coalescing, favicon data or large histories.
The temporary database and WAL are removed after the probe. No performance
budgets have been set from these small synthetic timings.

## Browser baseline protocol

The full browser baseline is pending real navigation in Phase 1. Phase 0 cannot
measure meaningful live-tab switching or website resource use. Before setting
budgets, capture Release runs on the machine above (and record future changes):

1. Use a dedicated test profile and a fixed saved fixture list; proposed seed
   sites are `https://example.com`, `https://www.wikipedia.org`, and
   `https://www.swift.org`. Record exact URLs, loading/settling conditions, network
   conditions and test date. Sites have not been navigated by Early in Phase 0.
2. Distinguish cold process launch, warm relaunch, and filesystem-cache effects;
   measure time to usable window and focused command bar with instrumentation.
3. Record idle CPU, process RSS and Instruments memory/allocations for the app
   **and associated WebKit processes**. App-only RSS is not browser-total memory.
4. Measure zero/1/10/50/100 tabs, command-bar key-to-presentation latency, tab
   switch latency, and repeated open/close resource recovery using fixed cycles.
5. Profile leaks and time on MainActor, observer disposal, and memory-pressure
   behavior. Record raw samples, median and p95, then choose budgets.

No cold/warm launch, idle RSS/CPU, live-tab latency, long-session growth, or
Instruments results are claimed in Phase 0. Automated UI-test wall times are
functional-test timing, not launch benchmarks.
