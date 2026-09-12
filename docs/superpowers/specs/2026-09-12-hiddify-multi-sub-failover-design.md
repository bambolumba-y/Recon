# Hiddify fork: cross-subscription auto-failover — design

Date: 2026-09-12. Status: draft for owner review.
Recon this builds on: `docs/2026-09-12_hiddify_recon.md`.

## 1. Goal and non-goals

Goal. A fork of Hiddify (hiddify-app + hiddify-core + hiddify-sing-box) for Android
where the user marks any number of subscriptions as members of one auto group. The
client keeps traffic on a working server from that pool and moves to another one when
the current server fails, stalls, or the network changes. Detection is reactive; the
periodic sweep of the whole pool is rare and can be turned off.

Success metric. Time from the moment the current server stops passing traffic to the
moment traffic flows again through another server. Target: under 15 s for a hard
failure (dial error), under 30 s for a stall, measured from sing-box log lines.
Secondary: no periodic probing of the full pool more often than every 30 min by default.

Non-goals for version 1 (deferred to version 2): latency/speed tuning (DNS, mux, TLS
fragment, TUN stack), iOS/desktop, priority or weights between
subscriptions, the HAPP `crypt5` provider (owner will replace it).

## 2. Decisions already made with the owner

| Topic | Decision |
|---|---|
| Vehicle | Public GitHub fork of hiddify-app (license requires public fork, Actions builds, non-commercial) |
| Pool policy | Variant A: one flat group over all servers of all included subscriptions, subscriptions are equal |
| Detection | Reactive first: dial errors, stalled connections, OS network events. Rare full sweep, configurable, can be disabled |
| Architecture | Merge in Dart, failover logic in the sing-box fork's `balancer`. Two delivery stages |
| Scope | Stage 2 retains failover + minimal UI and includes evidence-led performance work: PC tests, then approximately 48 h of normal-use diagnostics. Broader latency tuning remains deferred |

## 3. Components

```
Flutter app (Dart)                         Go core (hiddify-core -> hiddify-sing-box)
------------------------------------       ------------------------------------------
Profile store (Drift)                      config.parser  : subscription -> flat sing-box JSON (unchanged)
  + column include_in_auto                 config.builder : setOutbounds builds select + balancer
Merge service (new)                                         (small change: pass new balancer options through)
  N profile files -> merged.json           balancer       : lowest-delay strategy + hysteresis (changed)
Connection repository                      monitoring     : stall watchdog, rescue scan, sweep interval (changed)
  auto mode -> start(merged.json)          status         : last switch reason exposed to app (new)
Auto-group UI (new, minimal)
```

Existing flow being extended: `ConnectionRepositoryImpl.connect`
(`hiddify-app/lib/features/connection/data/connection_repository.dart:81-86`) resolves
one profile file and passes it to `singbox.start`. `setOutbounds`
(`hiddify-core/v2/config/builder.go:130-332`) turns whatever flat outbound list it gets
into a `select` group plus a `balancer` group. The fork keeps both mechanisms and feeds
them a merged list.

## 4. Stage 1 — merge in Dart, stock core

### 4.1 Storage

- Drift migration: add `include_in_auto BOOLEAN NOT NULL DEFAULT 0` to `ProfileEntries`.
  Independent of the existing exclusive `active` flag; `setAsActive` does not touch it.
- App preference `autoGroupEnabled` (bool, default false). Manual mode is untouched when false.
- New DAO methods: `watchAutoGroupProfiles()` (stream of profiles with the flag),
  `setIncludeInAuto(id, bool)`.

### 4.2 Merge service

Input: the parsed per-profile sing-box files (output of core `Parse()`, one file per
profile, flat `outbounds`/`endpoints`). Output: `merged.json` next to them.

Rules:
1. Take only leaf outbounds and endpoints. Drop group types (`selector`, `urltest`,
   `balancer`) and predefined tags (`direct`, `block`, `dns-out`, `bypass`) that a native
   sing-box subscription may carry; the core rebuilds groups itself.
2. Tag every server `"<prefix> · <original tag>"` where `prefix` is a short label
   derived from the profile name (first 12 chars, deduplicated with a numeric suffix).
   Rewrite `detour` references inside the same profile to the prefixed tag.
3. Deduplicate servers that are byte-identical after stripping `tag` (same host, port,
   credentials, transport). Keep the first, log the duplicate.
4. If a profile file is missing or fails to parse, skip it and surface a warning in
   the auto-group card; do not abort the merge.
5. If the result has zero servers, refuse to connect in auto mode and show the reason
   ("no subscriptions included" or "all included subscriptions failed to parse").
6. Merge output also records provenance: a sidecar `merged.meta.json` mapping each
   prefixed tag to `{profileId, profileName, originalTag}` for the UI.

Where it runs: in `connect`/`reconnect` when `autoGroupEnabled`, and again after any
included profile finishes updating while connected in auto mode (then reconnect the
same way Hiddify reconnects on profile change today).

### 4.3 UI (minimal)

Owner's constraint: stay within the original Hiddify design. No new visual language:
reuse Hiddify's existing widgets, colours, typography, spacing, iconography and
localisation mechanism. New elements must look like they shipped with upstream.

- Profile tile: a toggle "in auto group" in the tile's action row or context menu.
- Home screen: a card "Auto group" shown when at least one profile has the flag.
  Contents: switch to enable auto mode, count of included subscriptions and servers,
  current server with its subscription name, last switch reason and time.
  Warnings from the merge (skipped profile, zero servers) appear on this card.
- Proxies screen: unchanged. In auto mode it shows the merged pool with prefixed
  names; picking a server manually still works through the `select` group.

### 4.4 Stage 1 acceptance

- App builds on Windows with `flutter build apk` using the prebuilt core from Hiddify
  release 4.1.0 (no Go toolchain).
- With two real subscriptions included, the proxies screen lists both pools under one
  auto group; the existing `lowest-delay` balancer picks a server and traffic flows.
- Unit tests for the merge cover: tag prefixing, detour rewrite, group dropping,
  dedupe, skipped broken profile, empty result.

## 5. Stage 2 — failover logic and performance measurement

Measurement and optimisation plan (owner decision, 2026-09-12):
[Stage 2 performance and field diagnostics](../plans/2026-09-12-recon-stage2-performance.md).
Run reproducible PC tests first, then collect lightweight local diagnostics during
approximately 48 hours of normal use. Dedicated hour-long phone benchmarks are
optional follow-ups, not an entry requirement.

All changes live in `hiddify-sing-box` (`protocol/group/balancer`, `common/monitoring`,
`option/balancer.go`) plus pass-through of new options in `hiddify-core`
`config/builder.go`. Behaviour is driven by options so defaults can be tuned from the
app later without a core rebuild.

### 5.1 New balancer options

| Option | Default | Meaning |
|---|---|---|
| `tolerance` (ms) | 150 | A candidate must beat the current server by more than this to trigger a "better latency" switch. Field exists today but is unimplemented |
| `min_dwell` | 60s | No latency-motivated switch sooner than this after the previous switch. Failure-motivated switches ignore it |
| `stall_timeout` | 8s | A connection that has written at least 1 byte and read 0 bytes for this long counts as stalled |
| `stall_threshold` | 3 | Consecutive stalled connections on the current server within `stall_window` mark it failed |
| `stall_window` | 30s | Window for counting consecutive stalls |
| `rescue_batch` | 6 | Number of candidates probed in parallel during a rescue scan |
| `rescue_timeout` | 5s | Per-candidate probe timeout during rescue |
| `sweep_interval` | 30m | Full-pool probe interval. `0` disables the sweep entirely |
| `active_check_interval` | 3m | Light probe of the current server only (single URL test) |

### 5.2 Selection rule (`lowest-delay` strategy)

- Keep the current server while it is healthy. "Healthy" = last probe succeeded and no
  failure signal since.
- Switch on failure immediately (dial error, stall threshold reached, probe of the
  current server failed). Ignore `min_dwell`.
- Switch on latency only if a candidate's last measured delay is lower than the
  current one by more than `tolerance` and `min_dwell` has elapsed.
- Servers with no measurement yet count as unknown, not as worst; they are eligible
  for rescue probing but never selected without a successful probe.

### 5.3 Failure signals

1. Dial error: already wired (`Balancer.DialContext` calls `monitoring.InvalidateTest`).
   Extend: also emit a failure event for the strategy so it switches without waiting
   for the retest result.
2. Stall watchdog: wrap connections returned by the balancer (the `interruptGroup`
   wrapper is the place) to track last write time and bytes read since; a background
   ticker (1 s) checks open connections of the current server. Reaching
   `stall_threshold` within `stall_window` emits a failure event. Counters reset on
   any successful read.
3. Network change: hiddify-core already receives the Android network callback. On
   change, run a light probe of the current server first; on failure emit the failure
   event; either way reset stall counters.

### 5.4 Rescue scan

On a failure event for the current server:
1. Candidates = pool minus the failed server, ordered by last known delay, unknowns
   last.
2. Probe in batches of `rescue_batch` with `rescue_timeout`. On the first success,
   select it, interrupt existing connections of the failed server, stop the scan.
3. If a batch fully fails, continue with the next batch. If the whole pool fails,
   stay on the last server, record state "no live servers", and retry the scan with
   backoff 10s, 30s, 60s, then every 2 min until something answers.
4. Every probe result updates monitoring history, so the rescue doubles as a partial
   sweep.

### 5.5 Sweep and light checks

- `sweep_interval` replaces the current fixed 5 min ticker for the auto group. Sweep
  is skipped while the pause manager reports the device asleep (existing behaviour).
- `active_check_interval` probes only the current server. Failure feeds 5.3.

### 5.6 Status for the app

Extend the core status stream that the app already consumes for the connected proxy
name with: current tag, previous tag, reason enum (`dial_error`, `stall`,
`network_change`, `probe_failed`, `better_latency`, `initial`, `manual`,
`rescue_exhausted`), timestamp, and rescue duration in ms. `initial` marks the
strategy replacing its provisional first pick with the first measured best; `manual`
is reserved for a user-driven switch through the `select` group and is not emitted
by the failover controller today. Each switch also logs one line:
`failover: <from> -> <to> reason=<r> took=<ms>ms` so the metric in section 1 can be read
from sing-box logs.

Delivered for stage 2: the `failover:` line above, plus a `diag:` summary line every
15 minutes, both readable through the app's existing log export (Logs page, "share
core logs" action, `box.log`). The gRPC status stream extension described in the
paragraph above is deferred — it needs protoc and Dart code regeneration, which is
out of this task's scope — so current/previous tag, the reason enum and rescue
duration are not yet exposed as structured fields to the app; they exist only in the
log line. Revisit when the app needs the failover reason in the UI rather than in an
exported log file.

### 5.7 Build and delivery

- GitHub Actions in the fork builds `hiddify-sing-box` + `hiddify-core` for Android
  (Linux runner, Go, gomobile, NDK) and publishes the AAR as a release asset. The app
  workflow downloads that asset instead of upstream's. This is also how the license
  conditions 1 and 2 are met.
- Local Windows machine builds only the Flutter app. WSL is optional for faster core
  iteration.

### 5.8 Stage 2 acceptance

- Go unit tests with fake outbounds: hysteresis (no switch under tolerance or dwell),
  stall counter reaching threshold, rescue picks first responder, backoff after full
  failure, unknown servers never selected blind.
- Reproduce hard failures and stalls on controlled PC endpoints and verify the
  recovery targets in section 1. During normal Android use, report recovery for
  observed failures; mark unobserved cases as unverified on device. Targeted manual
  device tests are follow-ups for unresolved Android-specific behaviour.
- Analyse approximately 48 h of local normal-use diagnostics: CPU coverage, probes,
  scan triggers, switches, memory trends and gaps. Scheduled sweeps respect the
  configured interval; failure-driven rescues are counted separately.
- Preserve a pre-optimisation baseline, rerun PC scenarios after each relevant fix,
  and use a follow-up field session when claiming real-world improvement. CPU and
  probe reductions alone do not establish a percentage of battery energy saved.

## 6. Error handling summary

| Situation | Behaviour |
|---|---|
| No profile has the flag | Auto card hidden; auto mode cannot be enabled |
| Included profile file broken | Skipped with warning on the card |
| Merge yields zero servers | Connect refused with reason, manual mode still works |
| Duplicate servers across subscriptions | First kept, duplicate logged |
| Current server fails, pool has live servers | Rescue scan, switch, reason shown |
| Whole pool fails | Stay, state "no live servers", backoff retries |
| Included profile updates while connected | Re-merge and reconnect; current server kept if still present |

## 7. Risks

- License obligations: fork must stay public and up to date with our own releases.
- Core toolchain: first CI build of hiddify-sing-box + hiddify-core may take a few
  iterations; Stage 1 does not depend on it.
- Upstream drift: main is 3 months past the last tag. Fork from tag `v4.1.2`
  (app) and `v4.1.0` (core) to match the prebuilt core used in Stage 1; rebase later.
- Provider formats: the two remaining subscriptions must be fetched with Hiddify's
  User-Agent to confirm they serve link lists or sing-box JSON. Not verified yet.
- Xray compatibility: "X-ray support" in Hiddify means Xray links and JSON are
  converted to sing-box outbounds by `ray2sing`, and the sing-box fork carries a port of
  Xray's XHTTP transport (`transport/v2rayxhttp`) and helper code (`common/xray/*`).
  An embedded Xray core (`xray` outbound type, `use-xray-core-when-possible` switch)
  exists only as scaffolding: no xray-core dependency in `go.mod`, the patch path in
  `hiddify-core/v2/config/outbound.go:145-150` is commented out. Do not rely on it.
- Network-change hook: the design assumes the core receives Android network callbacks
  (sing-box platform interface). Verify the exact entry point during planning.

## 8. Facts gathered for implementation (2026-09-12)

- Fork name: **Recon**. GitHub account `bambolumba-y`, `gh` authenticated with `repo`
  and `workflow` scopes. License condition 5 only restricts store names; "Recon" is fine.
- Local machine: Windows 11, JDK 21, Android SDK at `%LOCALAPPDATA%\Android\Sdk` with
  platforms 34/35/36, no NDK, Go 1.25.6, WSL Ubuntu present, Flutter absent (must be
  installed), 49 GB free on C:.
- Providers: both remaining subscriptions are Remnawave panels
  (hostnames withheld: provider A, provider B). Both serve per-client formats by
  User-Agent (Happ gets Xray JSON, sing-box gets sing-box JSON, others get link lists)
  and both answered every probe without HWID headers with a stub server
  `0.0.0.0:1` named "App not supported / Приложение не поддерживается". Alpha also
  returns 403 to unknown User-Agents. Consequence: the fork's subscription fetch must
  send the Remnawave HWID headers (`x-hwid`, `x-device-os`, `x-ver-os`,
  `x-device-model`) with a stable per-install id, and the owner must free a device slot
  in each provider's bot for the new client (device limit is currently reached).
  Stage 1 acceptance depends on this.
