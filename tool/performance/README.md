# PC performance baseline — first slice

From the `hiddify-app` checkout:

```powershell
python tool/performance/run_baseline.py
```

Requires Python 3.10+, Git and the Dart SDK (the installed Flutter SDK supplies it).
No new packages, subscription access, network requests or Go build are required.
The runner compiles the production `AutoGroupMerger` to a standalone AOT executable.
Run correctness tests separately; avoid other builds/tests while timing.

Outputs go into a new `build/performance/<UTC timestamp>/` directory:

- `manifest.json`: completion/failure, Git revisions and dirty state, source SHA-256,
  runtime/platform, workload parameters and declared Android core version.
- `samples.jsonl`: all individual measurements (preserved on partial failure).
- `summary.csv`: one row per successful scenario; written only after every scenario
  finishes. Check `manifest.status == complete` before using results.
- `compile.log` and the executable: local reproducibility aids, not for Git.

`--samples 5 --iterations 100` are defaults; `--dart <SDK executable>` overrides SDK
discovery. `--output <new directory>` selects a destination and refuses to overwrite
an existing directory. Failures return a nonzero process exit code.

## Workloads and scope

Four scenarios at 10, 100 and 1,000 nodes **per subscription**:

| Scenario | Profiles | Input |
|---|---:|---|
| single | 1 | Unique nodes |
| disjoint | 2 | No shared nodes |
| overlap | 2 | Half of each pool shared across subscriptions |
| detours | 2 | Unique pools, all non-first nodes refer to their pool's first node |

Each scenario runs in a fresh process, warms up with 20 merges, and times five
batches of 100 merges. Fixture construction, JSON output and structural validation
are outside the timed region. The timed region includes a cheap output-node checksum.
Checks validate output counts, unique tags, provenance count, resolved detour targets,
expected warning count and no input mutation. Existing merger unit tests remain the
broader correctness suite, including endpoints, invalid references and empty inputs.

`us_per_merge` is elapsed **wall time**, not process CPU time. RSS is a point sample
after validation and includes the runtime, fixtures and garbage not yet collected;
it does not measure allocations, retained heap or prove a leak. Median/min/max show
sample spread, not a confidence interval. Fixed scenario order is recorded; repeat
whole runs under comparable PC conditions before claiming an improvement.

This measures only pure Dart merging. It excludes parsing, file IO, Flutter UI,
Go probes, Android lifecycle, radio and battery. There is no upstream merger
equivalent here: this is a Recon pre-optimisation baseline, not a Hiddify/Recon
end-to-end comparison. Preserve manifests and raw samples with any reported numbers.

## Verification

```powershell
dart analyze tool/performance/merge_benchmark.dart
flutter test test/features/auto_group/data/auto_group_merger_test.dart
python tool/performance/run_baseline.py
```

The first complete baseline and continuation instructions are recorded in
`docs/2026-09-12_recon_stage2_handoff.md`. Remaining plan work includes establishing
the exact Android core source/artifact relationship, controlled Go scheduling tests,
and bounded local diagnostics/export before the 48-hour observation.

## Go balancer scenario runner

```powershell
python tool/performance/go_scenarios.py
```

Runs the three controller-level scenario tests in the sing-box fork's
`protocol/group/balancer/scenario_test.go` (`go test ./protocol/group/balancer/
-run 'TestScenario' -v -count=1 -json`) and collects the machine-readable
`SCENARIO name=... probes=... switches=... recovery_ms=...` line each test
prints. Python 3.12, stdlib only.

`--singbox <path>` overrides the sing-box workspace; the default is
`../recon-core/hiddify-sing-box` resolved from this script's own location.
`--out <path>` overrides the results directory; the default is
`docs/performance/<UTC date>-go-scenarios`. The script refuses to overwrite an
existing results directory and exits non-zero.

Outputs:

- `summary.csv`: columns `scenario,probes,switches,recovery_ms,status`, one row
  per scenario test in source order. `status` is `pass` or `fail`. A test that
  fails before it reaches its `t.Logf` call still gets a row, with empty
  numeric fields.
- `manifest.json`: `go_version`, `singbox_commit`, `core_commit`,
  `timestamp_utc` and the exact `command` run, for provenance.

The runner exits non-zero if any scenario test failed.

Known semantics of the current three scenarios, not defects to fix:

- `latency_jitter_24h` reports `switches=1` by design. The test has a negative
  arm (jitter under tolerance, must not switch) and a positive arm (a real
  latency excursion past the tolerance, must switch once); the printed line
  covers the whole test, so it always shows the one switch from the positive
  arm.
- `dial_error_with_candidates` reports `recovery_ms=0` because the balancer
  switches on the same tick as the dial error; there is no probe delay to
  measure.
- `rescue_unknown_pool` reports `recovery_ms` from the harness's fake clock,
  not wall time, so it measures probe scheduling, not real elapsed time.
