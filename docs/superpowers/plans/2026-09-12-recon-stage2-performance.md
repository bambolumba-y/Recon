# Recon stage 2 — performance and field diagnostics

Date: 2026-09-12. Status: in progress; first PC baseline completed, Android diagnostics pending.

Owner decision: perform reproducible tests on the PC first, then collect local
diagnostics during approximately 48 hours of normal Android use and analyse an
export. Dedicated hour-long, screen-off phone runs are not a prerequisite.
This plan complements design section 5 (core failover); its functional recovery
requirements remain in force. It brings measurement and evidence-led performance
work into stage 2, without adding unrelated DNS, mux, TLS or TUN tuning.

## 1. Establish the baseline before optimisation

- Pin upstream and Recon app/core revisions, build mode, test configuration,
  node count, probe settings and workload. Use release builds for comparisons;
  label instrumented/profile builds separately.
- Compare upstream with one subscription against Recon with the same subscription,
  nodes and equivalent selection mode. Separately test Recon auto-selection with
  two subscriptions, and Recon with VPN off. These comparisons distinguish fork
  overhead from the cost of the additional pool and selection behaviour.
- Preserve baseline outputs before changing scheduling or failover logic. Adding
  diagnostics comes first; quantify its overhead with enabled/disabled PC runs.
- Do not interpret PC CPU time or emulator battery values as Android energy use.

## 2. Reproducible PC tests

Use fake outbounds, a controllable clock and local controlled endpoints wherever
possible. Do not depend on live provider reliability for repeatable assertions.

Cover healthy idle, controlled traffic, one and two pools, increasing node counts,
hard dial failures, stalls, slow probes, all nodes unavailable, network-change event
bursts, recovery, subscription updates, VPN stop/start and cancellation during scans.

Verify:

- Active checks and sweeps respect configuration; a disabled sweep does not run.
- Concurrent failure signals do not create duplicate rescue scans or probe storms.
- Probe concurrency, timeouts, cancellation and retry backoff are bounded.
- No stale timers, work queues or goroutines survive stop/reconnect unexpectedly.
- Selection hysteresis and failure recovery satisfy design section 5; reduced
  probing must not silently trade away recovery correctness.
- Virtual-time tests cover several days of scheduling; real elapsed-time soak
  runs check memory/goroutine growth and resource cleanup. Virtual time alone
  cannot reveal runtime resource leaks or Android suspend behaviour.

Record CPU time, allocation and memory trends, goroutines where available, probe
counts/results, scan causes and durations, switches and recovery times. Profile
Go hotspots separately; inspect Dart/Kotlin where the runnable target supports it.
Use short profiles around reproducible events rather than continuous profiling.
Android lifecycle, radio, Doze and vendor power behaviour remain field concerns.

Deliver one runner for repeatable PC scenarios and one machine-readable results
table, with raw profiles/logs and a manifest of the tested revisions/configuration.

## 3. Lightweight local Android diagnostics

Implement before the first field baseline. First audit existing app/core counters
and collection permissions; document which measurements are actually available.

Collect:

- Build/core revision, schema version, configuration fingerprint, node counts and
  settings affecting checks, rescues and sweeps.
- Process/session identity, VPN on/off durations, restarts, errors and observable
  gaps. Do not assume a VPN-off app process survives in the background.
- CPU-time deltas for accessible app processes, with process start identity and
  counter-reset handling. Identify omitted processes rather than claiming total
  application CPU coverage. Sample opportunistically, not through wakeup alarms.
- Probes started/completed/succeeded/timed out/cancelled, trigger reason, duration,
  maximum concurrency, full and rescue scans, and switches with reason/duration.
- Probe bytes only where directly instrumented. Specify the measurement layer and
  exclusions such as DNS, TLS and retransmissions; missing values are N/A, not zero.
- Memory samples and available network/screen state on existing events. Mark
  unknown states and gaps; do not invent continuous screen-off coverage.

Update in-memory counters during existing work. Persist bounded interval aggregates
and a small rotating event journal in batches using existing execution opportunities,
plus best-effort flush on lifecycle transitions. No diagnostic wakeup alarm,
dedicated wakelock, continuous logcat streaming or two-day Perfetto recording.
Specify storage caps, retention sufficient for at least 48 hours, schema migration,
crash-safe writes and reporting of lost/overwritten intervals. Keep collection local;
provide an export action and a way to disable/reset diagnostics.

Use session-local opaque node identifiers. Do not export subscription URLs, server
addresses, credentials, raw tags, visited destinations or traffic contents. Aggregate
configured behaviour without exporting full configurations; sanitise errors too.

Verify counter correctness with deterministic scenarios, rotation/export, abrupt
process death, restart, counter reset and missing-data handling. Compare collection
enabled/disabled to establish its CPU, allocation, storage and write overhead.

## 4. Approximately 48 hours of normal use

1. Install the baseline release with diagnostics. Record version/configuration and
   begin a new observation session. No permanent ADB connection is required.
2. The owner uses Recon normally, including ordinary charging, screen use and
   network changes. Do not prescribe artificial airplane-mode or server-firewall
   experiments as a condition for completing this observation.
3. Keep the build/settings stable where practical; record changes and split results
   into separate segments. Record user-noted outages for correlation.
4. Export diagnostics after about two days. If convenient, collect available Android
   batterystats at boundaries as supplementary evidence. Its retention/reset and
   attribution limitations mean it is not the primary two-day data source.

If a state (VPN off, a failure, a network transition) does not occur, mark it unobserved.
Extend observation only when important coverage or a specific investigation requires
it. Charging and process-death gaps must not be silently counted as observed idle.

## 5. Analysis and optimisation

Provide one summary table with build, scenario/state, observed duration, coverage,
CPU seconds per observed hour, probes per VPN hour, successes/timeouts/cancellations,
probe bytes per VPN hour where available, scan reasons/counts, switches, recovery
times, memory trends, restarts and diagnostic gaps. Keep raw exports alongside it.
Only normalise by durations actually covered by the relevant counter; label each
denominator. Keep PC and Android results separate in the same report.

Rank measured causes: unnecessary checks, duplicate rescues, busy timers, ineffective
backoff, needless allocations, background work with VPN off. For each proposed fix,
record evidence, expected effect and the correctness constraint it must preserve.
Apply bounded changes and rerun affected PC scenarios. Follow with a comparable
normal-use session on the candidate when assessing real-world improvements.

Two days of Recon alone establish behaviour and optimisation targets, not a measured
battery saving against Hiddify. An optional original-Hiddify observation on comparable
days can add system-level context, but instrumentation and workloads differ. Report
these limitations; do not manufacture a precise percentage of energy saved from
CPU, probe counts, modelled battery estimates or uncontrolled daily discharge.

Short targeted Android profiles or controlled battery runs are follow-ups only when
field evidence leaves a concrete question unresolved. Do not promise automatic
Go/Dart/Kotlin attribution from a standard Perfetto system trace; check sampling,
symbols and build/device access before selecting the profiling method.

## 6. Completion criteria

- Baseline manifests, reproducible PC scenarios and results are saved.
- Diagnostics export is bounded, local, sanitised and validated; its overhead and
  measurement gaps are documented.
- Approximately 48 hours of baseline field use are analysed, with actual coverage
  stated and missing states identified.
- Optimisations are tied to measured causes and preserve failover acceptance tests.
- Candidate PC results and, when claiming field improvement, a follow-up observation
  are compared with baseline. Remaining Android-only uncertainties are explicit.
- No claim of quantified battery savings without a suitable energy comparison.

## 7. Implementation log

- 2026-09-12: added standalone AOT merger benchmark and saved a clean-commit PC
  baseline (12 scenarios, 60 samples). No production optimisation yet. Core artifact
  identity must be resolved before Go comparisons. See
  [handoff and results](../../2026-09-12_recon_stage2_handoff.md) for decisions,
  checks, commits and next steps. Android diagnostics and field observation remain
  pending.
