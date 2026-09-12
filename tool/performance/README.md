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
