# Stage 2 handoff — baseline tooling started

Date: 2026-09-12. Branch: `recon/stage2-baseline` in `hiddify-app`.
Stage 2 is **in progress**, not complete. No application behaviour was changed.
No Android diagnostics build or 48-hour observation has started.

## Decisions and work completed

1. Owner approved PC testing first, then about 48 hours of normal Android use with
   local diagnostics and export. Dedicated screen-off battery tests are optional.
2. Committed the previously agreed plan/specification update as `44999827`
   (`docs(stage2): план измерений на ПК и диагностики за 48 часов`). Stage 2 still
   includes the failover requirements; performance work complements them.
3. Added a bounded first executable slice: an AOT benchmark of the **existing** Dart
   merger, committed as `f22e7b89` (`test(perf): воспроизводимый AOT-бенчмарк слияния
   подписок`). This gives a pre-optimisation reference without changing a scheduler
   or silently substituting a different Go core.
4. Ran the benchmark again on clean `f22e7b89`, without concurrent test/build work
   initiated by this session. The earlier smoke run overlapped Flutter tests and is
   deliberately not used as the baseline. Ordinary host background activity was
   not controlled; this is one PC baseline run, not a statistical performance claim.

## Saved results

Canonical tracked artifacts: [baseline directory](performance/2026-09-12-merge-baseline/).
Includes `manifest.json`, `samples.jsonl` (60 samples) and `summary.csv` (12 scenarios).
The manifest preserves source hashes, runtime, input sizes, clean checkout state and
local repository revisions. The generated executable/compile log remain locally at
`build/performance/20260912T090206.155392Z/` and are reproducible, not committed.

Median elapsed milliseconds per merge, 5 samples of 100 merges after warmup:

| Nodes per subscription | One pool | Two disjoint pools | Two pools, 50% overlap | Two pools with detours |
|---:|---:|---:|---:|---:|
| 10 | 0.042 | 0.087 | 0.082 | 0.096 |
| 100 | 0.419 | 0.826 | 0.817 | 1.004 |
| 1,000 | 4.177 | 7.957 | 8.109 | 9.014 |

Interpretation: these synthetic fixtures show approximately proportional elapsed
merge cost across the sampled sizes. There is no evidence here to prioritise a
merger rewrite over measuring background probes. This does not cover all inputs,
disk IO, core parsing, connection startup, Android CPU or battery. RSS samples include
the runtime/fixtures and are not a retained-heap or allocation measurement.

## Source/build identity — resolved in the follow-up audit

Follow-up: [core provenance report](2026-09-12_recon_core_provenance.md) now pins
the release source chain and verifies the official AAR against local AAR/APKs. It
also identifies `all=-N -l` in the shipped core. The dirty upstream build metadata
limits clean-source reproducibility; see that report before building. The owner
will continue diagnostics and tests in Claude.

Initial observations, retained as historical context without modifying Go repositories:

| Item | Value |
|---|---|
| App baseline parent before this work | `59ddadc5` on `recon/main` |
| Android workflow core | `dependencies.properties`: `core.version=4.1.0` |
| Core download | `.github/workflows/recon-android.yml`: upstream release archive `hiddify-lib-android.tar.gz` |
| App Git submodule core reference | `c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0` |
| Sibling `hiddify-core` HEAD | `db74dfc257d5becb4b4e9dbc7257a3dcdde20692`, branch `main` |
| That core's sing-box submodule reference | `170d8315cab7a8695fd80469073ed2f1d07d63af` |
| Sibling `hiddify-sing-box` HEAD | `8d94f445c72dfb704f2ed4d2984dcefc79362e66`, branch `extended` |

The sibling sing-box checkout is sparse (`adapter`, `common/monitoring`, `constant`,
`option`, `protocol/group`). It is not a complete build tree as checked out.
The core uses relative module replacements for its own nested sing-box and other
components; the sibling directory is not automatically the module being built.

Do not describe local source findings as measured behaviour of the release AAR.
Establish the release tag/source/submodule chain and pin the actual downloaded
artifact hash before comparing upstream/fork Go results. No core build was attempted
in this first slice, and no upstream reference or toolchain was silently changed.

## Initial instrumentation map (source inspection, not runtime measurements)

At the sibling sing-box revision above, `common/monitoring/outbound_monitoring.go`:

- Defaults include 10 workers, 5 s URL-test timeout, 5 min interval and 10 min idle
  timeout. These are source defaults; effective app options may override them.
- `InterfaceUpdated` calls `startCycleOnce`; `scheduleLoop` also starts cycles.
  Count triggers and coalesced/skipped requests separately at their call sites.
- `executeTask` handles queue work and a delayed retry for not-ready outbounds.
  Distinguish queued/retried tasks from actual network probes. Test cancellation
  and stop/reconnect lifecycle before inferring resource leaks from the code.
- `tester` calls `urltest.URLTest`, then may call `ipinfo.GetIpInfo` with a separate
  timeout. IP lookup work needs a separate category. A successful test log line
  does not account for all network activity or bytes.
- `startCycleOnce` uses an atomic flag. Verify coalescing with concurrent-event tests;
  the existence of that flag alone is not proof against all duplicate work.

At the sibling core revision, `v2/hcore/grpc_server.go` starts a localhost pprof HTTP
server only when `params.Debug` is set. The import alone does not mean release
profiling is enabled. Keep diagnostic profiles separate from baseline timing.

In the app source manifest, VPNService and ProxyService have no explicit
`android:process`. Verify the merged release manifest/runtime before deciding CPU
coverage. Existing lifecycle callbacks in `bg/BoxService.kt` are candidates for
opportunistic samples/flushes; Android permissions and available counters still need
verification. No new timer, wakelock, or streaming logger was added.

## Verification performed

- `dart analyze tool/performance/merge_benchmark.dart`: no issues.
- `flutter test test/features/auto_group/data/auto_group_merger_test.dart`: 13 passed.
- AOT runner: all 12 scenarios / 60 samples passed structural and input-mutation
  checks; final manifest status `complete`.
- Negative runner checks: an invalid compiler records `failed` and produces no
  summary; an existing output directory is preserved; zero iterations are rejected.
- Flutter test regenerated tracked plugin files with line-ending-only changes.
  These session-generated changes were restored; no production files are included.

## Continue from here

1. Read the [stage 2 plan](superpowers/plans/2026-09-12-recon-stage2-performance.md)
   and [runner instructions](../tool/performance/README.md). Stay on this branch or
   create the next focused branch from it. Keep meaningful commits per work slice.
2. Source/artifact identification is complete: follow the pinned revisions, hashes
   and preparation instructions in the [core provenance report](2026-09-12_recon_core_provenance.md).
   Claude should prepare complete isolated build trees, reproduce the unmodified
   reference, and evaluate the Go compiler flags separately before changing scheduling.
   Diagnostics implementation and tests are reserved for Claude.
3. Add controlled Go tests for scheduling, concurrency, retries and stop/reconnect,
   using fake time/outbounds and locally controlled endpoints. Extend the baseline
   runner with explicitly separate Go scenarios, not simulated substitutes for the
   production scheduler. Preserve pre-change results.
4. Specify and implement bounded local diagnostics: schema/version, process identity,
   coverage/gaps, interval aggregates, per-trigger counters, separate URL/IP work,
   safe export/rotation and no raw server or subscription details. Reuse existing
   events for sampling/flushes. Validate persistence after process death and quantify
   enabled/disabled overhead before deploying the observation build.
5. Only then start the owner's approximately 48-hour baseline observation. Analyse
   export, choose measured optimisation targets and compare a later candidate.

The root `Recon/docs` copy is a convenience mirror. Tracked app documentation is the
canonical history for continuing in Claude. No push, merge or APK deployment was
performed in this work slice; all commits are local on the branch above.
