# Recon stage 3: throughput auto mode (`fastest`)

Status: design, no code. Written 2026-09-12. Predecessors:
[stage 2 design](2026-09-12-hiddify-multi-sub-failover-design.md) sections 5.1-5.6,
[stage 2 hand-over](../../2026-09-12_recon_stage2_core_failover.md),
[stage 2 measurement plan](../plans/2026-09-12-recon-stage2-performance.md).

## 1. Goal and non-goals

Goal: a second automatic balancer mode that picks the proxy server by measured download throughput
instead of by URL-test latency, selectable from the app, shipped off by default.

In scope: a new sing-box strategy `throughput` and a second balancer outbound `fastest` built by the
core next to `lowest`; an active download measurement with a byte budget, a schedule and hysteresis;
an app setting choosing which auto entry is selected on connect; an idle-balancer rule so the
unselected balancer costs nothing; extraction of a `failoverStrategy` interface so the stage 2
failover controller serves both strategies instead of being duplicated.

Non-goals: exposing throughput in the UI or over gRPC (the status-stream extension of stage 2
section 5.6 stays deferred); per-connection routing decisions, the balancer keeps one selection per
network; passive throughput estimation from real traffic; any change to `lowest` behaviour, its
defaults or the stage 2 measurement baseline; throughput tunables in the settings UI, they travel
with defaults and stay reachable through the JSON override path.

Subscription URLs and provider names never appear in this document, in tests or in commits. Servers
are `s1`, `s2`, … in every example.

## 2. Context: what exists today

- `protocol/group/balancer/balancer.go` builds one strategy by name (`:117-128`) and wires the
  failover controller plus the stall tracker only for `*LowestDelay` (`:132-153`); every dial path
  calls `strategyFn.Select` and reports dial errors to the controller (`:240-296`). `lowest_delay.go`
  holds the selection state: history, `failedAt`, provisional pick, per-network selection, switch
  event buffer. `failover.go` is written against the concrete `*LowestDelay` and calls exactly seven
  of its methods (listed in 3.2). Latency comes from the shared monitoring sweep;
  `monitoring.TestAndWait` is the single active probe path, adapted by `monitorProber` (`:70-78`).
- The core builds one balancer, tag `lowest`, strategy `lowest-delay`
  (`recon-core/v2/config/builder.go:269-296`), first in `select` and its default (`:298-330`).
  `balance` is no longer built, though `OutboundRoundRobinTag` still exists unused.
  `v2/config/hiddify_option.go` embeds `URLTestOptions` and `FailoverOptions` anonymously, so their
  JSON keys are flat.
- The app selects the auto entry after connect and reconnect of the auto group: `_selectLowest()` in
  `connection_repository.dart:114-165`, three attempts one second apart, a failure never fails the
  connect.

## 3. Design

### 3.1 Components

| Component | Location | Role |
|---|---|---|
| `failoverStrategy` | `protocol/group/balancer/strategy.go` | The contract `failover.go` needs; implemented by `LowestDelay` and `Throughput` |
| `ranker` seam | `protocol/group/balancer/lowest_delay.go` | Best candidate and candidate order: latency by default, throughput-first for `fastest` |
| `Throughput` | `protocol/group/balancer/throughput.go` | Value table, hysteresis, scheduler, budget |
| `downloader` seam | `protocol/group/balancer/downloader.go` | One method; production dials through the candidate outbound, tests inject a fake |
| Activity gate | `protocol/group/balancer/balancer.go` | `lastDial` timestamp feeding the idle-balancer rule |
| Core builder and app setting | `recon-core/v2/config/builder.go`, `hiddify-app/lib/core/preferences/general_preferences.dart` | Build `fastest` into `select`; choose the mode on connect (section 4) |

### 3.2 `failoverStrategy`

```go
type failoverStrategy interface {
    Now() string
    IsSelected(tag string) bool
    Healthy(tag string) bool
    Candidates(exclude string) []string
    MarkFailed(tag, reason string) (switched bool, hasCandidate bool)
    ForceSelect(tag, reason string, delay uint16) bool
    Events() []switchEvent
    config() failoverConfig
}
```

The first seven are exactly what `failover.go` calls today. `config()` is added because
`Balancer.Start` reads `ld.cfg` to build the stall tracker and the controller, and a type assertion
on the concrete strategy is what this refactor removes. `newFailover` takes `failoverStrategy`;
nothing else in `failover.go` changes. `Balancer` keeps `strategyFn Strategy` and adds
`foStrategy failoverStrategy`, set when the built strategy implements it; the wiring block at
`balancer.go:132-153` then reads "if `foStrategy != nil` and the monitor is present", covering
`lowest-delay` and `throughput` and leaving round-robin, consistent-hashing and sticky-sessions
untouched.

### 3.3 Reuse of `LowestDelay`

`Throughput` embeds `*LowestDelay` (field `ld`) and delegates all eight interface methods to it.
Latency, health, failure marks, per-network selection and the event buffer stay in one place; there
is no second URL-test path and no second copy of the switch bookkeeping.

Three unexported additions to `lowest_delay.go`, all extracted from code that exists:
`ingest(history)`, the copy loop at the top of `UpdateOutboundsInfo`; `promoteHealthy() (changed
bool)`, the `wasProvisional || !healthy(current)` arm for both networks including the provisional
clearing; `sinceLastSwitch(now) time.Duration`. `UpdateOutboundsInfo` is rewritten as `ingest` +
`promoteHealthy` + the existing tolerance arm, so `lowest` behaviour and its tests are unchanged.
`Throughput.UpdateOutboundsInfo` calls `ingest` and `promoteHealthy` only: latency keeps a dead or
unmeasured server from being selected, but a latency difference never moves a throughput selection.

The `ranker` seam replaces the two places where `LowestDelay` hardcodes "lowest delay wins":

```go
type ranker interface {
    best(network, exclude string) (adapter.Outbound, uint16) // called with ld.mu held
    order(exclude string) []string                            // called with ld.mu held
}
```

`bestLocked` and the body of `Candidates` become the default latency ranker. `Throughput` installs a
throughput-first ranker: healthy tags with a known value first, sorted by MB/s descending; then
healthy tags without a value, sorted by delay ascending; then unknown or failed tags in
configuration order. That is what makes the failover rule hold: a dial error, a stall, a
network-change failure or a rescue ranks by throughput where it is known and by latency where it is
not, through the same `MarkFailed` and `Candidates` code the controller already calls.

The value table lives in `Throughput` but is guarded by `ld.mu` through unexported `ld.lock()` /
`ld.unlock()` helpers. One lock, because the ranker reads the table while holding `ld.mu` and the
scheduler writes it while calling `ld` methods; two locks would be a lock-order cycle.

### 3.4 Measurement

One HTTP GET per candidate through that candidate's outbound. URL `throughput_test_url`, default
`https://speed.cloudflare.com/__down?bytes=3000000`. Total timeout 8 s, covering connect, TLS and
body. The body is read into a 32 KiB scratch buffer and discarded. Timing starts when the first
262144 bytes have arrived; earlier bytes are not timed, which drops TCP slow start and the handshake
out of the rate. `MB/s = timed_bytes / 1e6 / elapsed_seconds`; MB is 1,000,000 bytes, decimal,
matching how link rates and data caps are quoted, and the budget uses the same unit. Fewer than
524288 bytes received before the timeout is a failed measurement: value 0, counted as a ranking
failure, logged. Failure reasons: `short` below the 524288-byte floor, `timeout` above it,
`dial_error` for a dial or TLS error, `http_<code>` for a non-2xx status.

```go
type downloader interface {
    Download(ctx context.Context, tag, url string) (throughputResult, error)
}

type throughputResult struct {
    Bytes   int64         // everything received, warm-up included; charged to the budget
    Timed   int64         // bytes received after the warm-up threshold
    Elapsed time.Duration // warm-up threshold to last byte
    Status  int           // HTTP status, 0 if no response arrived
}
```

Production implementation: an `http.Client` whose `Transport.DialContext` is the candidate
`adapter.Outbound`'s `DialContext`, keep-alives disabled, redirects refused, one request per call, no
connection reuse between candidates. Latency is never derived from this request; it keeps coming
from the monitoring history. Measurements are strictly sequential, at most one download at a time
per balancer, because two downloads share the uplink and would measure each other.

### 3.5 Selection algorithm

Shortlist: `ld.Candidates("")` truncated to the first `throughput_shortlist` (3) entries that are
`Healthy`. `Candidates` already orders healthy-measured by delay ascending, so this is "the three
healthy candidates with the lowest latest delay" with no new method.

A full round measures each shortlisted tag in order, recording `value[tag]` and `at[tag]`. Then
`best` is the healthy tag with the highest value; if it is the current selection, nothing happens.
If the current selection has no valid value (never measured, invalidated, or last measurement
failed), switch to `best` at once, reason `better_throughput`, ignoring hysteresis and dwell: a
missing value is a failure state, not an optimisation. Otherwise switch only if both hold,
`value[best] >= value[current] * 1.25` (`throughput_hysteresis_percent` 25) and
`ld.sinceLastSwitch(now) >= throughput_min_dwell` (600 s). The switch is
`ld.ForceSelect(best, reasonBetterThroughput, 0)`: it moves both networks, emits the events the
controller drains and clears a stale failure mark. Delay 0 leaves the latency history untouched,
which is right, because the round measured bandwidth and not latency.

Before the first round the selection is whatever `LowestDelay` holds: the provisional first outbound,
replaced by the lowest-delay measured server on the first sweep (reason `initial`). Connecting never
waits for a download.

### 3.6 Schedule

One goroutine started in `Balancer.PostStart`, bound to the balancer context, using the same
injectable clock and sleep seams as the failover controller. It wakes on a 30 s tick: one cheap timer
instead of several, and 30 s is 0.4 % of the 7200 s recheck interval, so the scheduling error is
irrelevant. Each tick, in order: (1) gates, all must pass or the tick is skipped, namely the balancer
is active (3.8), `IsPaused()` is false, no rescue scan is in flight, and the budget has room for
`throughput_probe_bytes`; (2) if a full round is armed, run it, subject to the 300 s floor between
full-round starts; (3) otherwise, if the current selection was last measured more than
`throughput_recheck_interval` (7200 s) ago, re-measure only the current server, and if the new value
is below 50 % of the previous one, arm a full round.

Full rounds are armed by: the first activation of the balancer; a recheck that halved; a failover
switch, armed to fire `throughput_min_dwell` (600 s) after it so the round measures a settled
selection; an interface change (3.9); a round where every measurement failed, with backoff (6). The
failover-switch hook is the balancer's own `onSwitch` closure passed to `newFailover`: it already
fires exactly once per switch and already lives in `balancer.go`, so no new plumbing enters
`failover.go`. Switches the scheduler made itself are skipped by the hook via a flag, so a
`better_throughput` switch does not arm another round. The 300 s floor between full rounds is decided
here: it bounds a flapping trigger to at most 3 x 3 MB per five minutes, with the daily cap as the
second backstop.

### 3.7 Budget

`throughput_daily_budget_mb`, default 100, is a rolling 24 h cap on measurement bytes, represented as
a fixed `[24]int64` ring of hourly buckets plus the index and hour number of the newest. A write
advances the ring and zeroes buckets skipped since the last write; spent is the sum of the 24.
Bounded memory, O(24) to read, and hour granularity is far finer than a 100 MB/day cap needs.

- A measurement starts only if `spent + throughput_probe_bytes <= cap`.
- Every byte actually received is charged, warm-up bytes and the partial bytes of a failed or aborted
  measurement included.
- When the cap blocks a round, the strategy logs one line and keeps ranking with the values it has;
  where a candidate has no value, latency fills in, exactly as before the first round.
- The counter is in memory only and resets with the core process, so a restart loop can exceed the
  nominal daily cap. The exposure is bounded: a full round costs at most 3 x 3,000,000 bytes = 9 MB,
  so ten restarts with a round each cost 90 MB. Persisting it would mean a new on-disk file in the
  core, not worth it at this size.

### 3.8 Idle-balancer rule

With `lowest` and `fastest` both in the config, both would otherwise run active checks, rescues and
measurements while only one is selected in `select`. `Balancer` gains `lastDial atomic.Int64` (unix
nanos), stored on every path that calls `strategyFn.Select`: `DialContext`, `ListenPacket`,
`NewConnectionEx`, `NewPacketConnectionEx`, `NewDirectRouteConnection`. `active()` is
`lastDial != 0 && now-lastDial <= active_check_interval` (180 s default).

Gated on `active()`: the failover active-check loop, next to its existing `isPaused()` check; the
throughput scheduler; the rescue backoff loop, which parks the way it already parks on
`isNetworkPaused()`, sleeping `rescueBackoff[0]` (10 s) and re-checking without spending an attempt.
Not gated: `reportFailure` and everything downstream of it (stall confirmation, the first rescue
attempt, the interface-change probe), because those react to real traffic and traffic is what makes a
balancer active; the `diag:` loop, which must keep printing; and the shared monitoring sweep, which
is per outbound rather than per balancer.

Interaction with the provisional pick: at start `lastDial == 0`, the balancer is inactive and runs
nothing. The first `DialContext` uses the provisional or already promoted selection without waiting
and sets `lastDial` in the same call, so the balancer is active from that moment; the first full
round starts at the next tick, at most 30 s later, and the active check resumes at its next tick.
Selecting `fastest` without sending traffic through it still measures nothing, as intended.

### 3.9 Network change

`Balancer.InterfaceUpdated` already calls `failover.onInterfaceChange`. For `throughput` it also
calls `Throughput.invalidate()`: clear the whole value table and the recheck timestamps, arm a full
round. The budget counter is not cleared, those bytes were really spent. Until the new round lands
the ranker has no values and falls back to latency, which is correct on a network the values were not
measured on.

## 4. Options and defaults

Three layers, same numbers at each.

| sing-box `BalancerOutboundOptions` | core `ThroughputOptions` (flat JSON) | Default | Meaning |
|---|---|---|---|
| `throughput_test_url` (string) | `throughput-test-url` | `https://speed.cloudflare.com/__down?bytes=3000000` | Download URL for a measurement |
| `throughput_probe_bytes` (int) | `throughput-probe-bytes` | 3000000 | Bytes requested per measurement, also the budget reservation |
| `throughput_recheck_interval` (duration) | `throughput-recheck-interval` (s) | 7200 s | Re-measure the current server this often |
| `throughput_daily_budget_mb` (int) | `throughput-daily-budget-mb` | 100 | Rolling 24 h cap on measurement bytes |
| `throughput_shortlist` (int) | `throughput-shortlist` | 3 | Candidates measured in a full round |
| `throughput_hysteresis_percent` (int) | `throughput-hysteresis-percent` | 25 | How much faster a challenger must be |
| `throughput_min_dwell` (duration) | `throughput-min-dwell` (s) | 600 s | Minimum time on a server before a throughput switch |

Normalisation lives next to `normalizeFailover`, same convention (zero means default): empty URL
takes the default; `throughput_probe_bytes` clamped to [524288, 100000000], below the floor the
failure threshold could never be met; negative `throughput_recheck_interval` disables the periodic
recheck, leaving the first round, failover rounds and interface-change rounds; negative
`throughput_daily_budget_mb` disables measurement entirely, logged once at start, the strategy then
behaving as a latency balancer with an empty table; `throughput_shortlist` clamped to [1, number of
outbounds]; `throughput_hysteresis_percent` clamped to [0, 500]; negative `throughput_min_dwell`
becomes 0, which `durationOr` already does.

Core layer: `ThroughputOptions` is a new struct in `v2/config/hiddify_option.go`, embedded
anonymously into `HiddifyOptions` next to `FailoverOptions`, so its keys stay flat and
`overridable:"true"` works per key; defaults go into `DefaultHiddifyOptions()`. `builder.go` gains
`OutboundThroughputTag = "fastest"`, adds it to `PredefinedOutboundTags` so a subscription server
named `fastest` cannot collide with the balancer, builds the outbound whenever `len(tags) > 1` with
the same failover options as `lowest` plus the throughput options, and inserts it into `selectorTags`
right after `lowest`. `defaultSelect` stays `lowest`.

App layer: one setting, `auto-mode` (`lowest` or `fastest`, default `lowest`), a
`PreferencesNotifier` in `lib/core/preferences/general_preferences.dart`. It is app-local and not
part of the core options JSON, because the core builds both balancers regardless and only the app
decides which is selected. A small `AutoMode` enum with a `choices` list goes into
`lib/features/connection/model/auto_mode.dart`. Settings → General renders it with the existing
`ChoicePreferenceWidget` pattern (the `logLevel` tile,
`lib/features/settings/overview/sections/general_page.dart:86-93`). Keys
`pages.settings.general.autoMode`, `autoModes.lowest` and `autoModes.fastest` go into
`assets/translations/en.i18n.json` and `ru.i18n.json`; other locales fall back, and generated Dart
translation files are not committed. `_selectLowest()` becomes `_selectAutoMode()`: it reads the
preference and calls `selectOutbound('select', 'lowest' | 'fastest')`, with the retry count (3), the
delay (1 s) and the "never fail the connect" behaviour unchanged. Changing the setting while
connected does not re-select; it applies on the next connect or reconnect, the rule that already
governs a manual server pick, which keeps disabling both automatic modes until the next connect.

Proxy list: only the configured auto entry is shown. With `auto-mode = lowest` the `fastest` row is
filtered out of the `select` group in `lib/features/proxy/` (and `lowest` when the setting is
`fastest`), by tag, the way `§hide§` entries are already dropped. The owner asked for a short list;
the hidden entry stays selectable through the setting, nothing else changes in the page.

## 5. Log lines and diagnostics

Per measurement, at info:

```
throughput: <tag> <MB/s, one decimal> bytes=<n> took=<ms>ms
throughput: <tag> failed reason=<timeout|short|dial_error|http_<code>>
```

No `group=` on these two: only the `fastest` balancer measures, so there is nothing to disambiguate.
Two more lines are decided here, because otherwise silence is unexplainable:

```
throughput: budget exhausted spent_mb=<x> cap_mb=<n>          (once per blocked round)
throughput: <tag> aborted reason=<paused|inactive|rescue|stopped> bytes=<n>
```

An aborted measurement charges its bytes and records no value; it is not a failure and does not
affect ranking. Switch lines keep the stage 2 format and gain one reason, `better_throughput`, in
`reasons.go`.

Format change, listed explicitly as such: `failover:` and `diag:` both gain a leading `group=<tag>`
field so two balancers are distinguishable in one log, and `diag:` gains three throughput fields
between `cpu_s=` and `switches=`:

```
failover: group=<tag> <from> -> <to> reason=<reason> took=<ms>ms
diag: group=<tag> current=<tag> probes_active=<n> probes_rescue=<n> probes_interface=<n> probes_ok=<n> probes_failed=<n> rescues=<n> rescue_exhausted=<n> stalls=<n> stalls_suppressed=<n> rss_mb=<x> cpu_s=<x> tp_probes=<n> tp_bytes_mb=<x> tp_budget_left_mb=<x> switches=<reason>=<n>,...
```

A `lowest` balancer prints `tp_probes=n/a tp_bytes_mb=n/a tp_budget_left_mb=n/a`, the convention
`rss_mb` and `cpu_s` already use, so field positions stay stable for parsers. The stage 2 hand-over
document records both formats and must be updated in the same change.

## 6. Failure handling

| Situation | Behaviour |
|---|---|
| One measurement fails | Value 0, reason logged; the ranker treats the tag as having no value, so latency decides its place among the unmeasured |
| Every measurement of a round fails | Selection unchanged; the round is re-armed after 600 s, doubling per consecutive all-failed round up to 7200 s, reset on the first round with a value |
| The current server's recheck fails | Treated as "current has no valid value", so the next round may switch without hysteresis or dwell. Not reported to the failover controller: a failed download is not proof of a dead server, and the controller has its own probe |
| Budget exhausted | No measurement; last known values keep ranking, latency fills the gaps; one log line per blocked round |
| Pause flips mid-download | The download context is cancelled, bytes charged, `aborted` logged, no value recorded |
| Balancer goes inactive mid-round | Same as pause; the round resumes when the balancer is active again |
| Rescue starts during a measurement | The measurement is cancelled and the round re-armed: rescue traffic and a 3 MB download must not share the uplink, and rescue is the more urgent |
| Core shutdown | The balancer context cancels the scheduler and the in-flight download; `Close` waits for the scheduler goroutine as it waits for the controller |
| Monitoring disabled | No history, so no shortlist and no failover, as for `lowest` today; the warning at `balancer.go:149-153` is extended to name the strategy |

## 7. Interaction with the existing failover controller

The controller is unchanged in behaviour; it only stops being tied to `*LowestDelay`. Dial errors,
stalls and probe failures still go `reportFailure` → `MarkFailed` → `Candidates` → rescue, and
because `Throughput` installs the throughput-first ranker every one of those paths prefers the
fastest known server and falls back to latency for unmeasured ones. `ForceSelect` from a rescue
writes a latency value and does not touch the throughput table; that server may well be slower, which
is why a full round is armed 600 s after any failover switch. The stall tracker, active check,
interface probe and diag loop are wired for both strategies, gated by the idle rule, so the
unselected balancer is silent apart from its diag line every 15 minutes.

## 8. Testing strategy

Unit, `protocol/group/balancer/throughput_test.go`, fake downloader and `fakeClock`:

| Case | Assertion |
|---|---|
| Ranking | Values 1.0 / 4.0 / 2.0 MB/s pick the 4.0 one |
| Hysteresis | Current 4.0, challenger 4.9 (22.5 %) does not switch; 5.0 (25 %) does |
| Min dwell | Challenger 40 % faster at 599 s does not switch; at 600 s it switches, reason `better_throughput` |
| Provisional pick | `Select` returns the latency pick before any round, and a round never blocks `Select` |
| Missing current value | Current unmeasured, challenger 10 % faster, 10 s since the last switch, switches anyway |
| Budget exhaustion | Cap 100 MB, 34 rounds of 3 candidates: measurements stop, last values keep ranking, one budget line per blocked round |
| Pause gating | `IsPaused` true means the downloader is never called; flipping it true mid-round cancels and logs `aborted` |
| Sequential | The fake downloader fails the test if entered concurrently |
| Invalidation | `InterfaceUpdated` clears the table, selection falls back to latency, a full round is armed |
| Failed measurements | `short` (300000 bytes in 8 s), `timeout`, `http_403`, `dial_error` each log their reason and record no value; an all-failed round re-arms with 600 s backoff |
| Idle rule | With `lastDial` older than 180 s the scheduler does nothing; one dial makes it run within a tick |
| Recheck | A halved value arms a full round, a 40 % drop does not |

Scenario, `scenario_test.go`: `TestScenarioThroughputPrefersFastLink`, with `s1` at 80 ms and 1.0 MB/s
against `s2` at 200 ms and 6.0 MB/s. The latency shortlist puts `s1` first, the round measures both,
and the selection ends on `s2` with one `better_throughput` switch. The test prints the same
four-field line as the existing scenarios (`SCENARIO name=throughput_fast_over_low_latency
probes=<downloads> switches=<n> recovery_ms=0`) and `tool/performance/go_scenarios.py` gains it in
`TEST_SCENARIO_NAMES`. The stage 2 manifest keeps its three rows as the observation baseline; the new
row is additive. Refactor safety: `lowest_delay_test.go`, `failover_test.go`, `stall_test.go` and the
three existing scenarios must pass unchanged, which is the check that the `failoverStrategy` and
`ranker` extraction changed no behaviour.

Core builder, `v2/config/failover_test.go`: `fastest` is built with strategy `throughput` and carries
both the failover and the throughput options with their defaults; the throughput keys round-trip from
flat JSON (`{"throughput-shortlist":5}` reaches the field and leaves the other defaults alone) and
marshalling `DefaultHiddifyOptions()` produces top-level `throughput-*` keys with no `Throughput`
nesting; `select` lists `lowest`, `fastest`, then the servers, default `lowest`; a single-server
config builds neither balancer, as today.

App, `test/features/connection/data/connection_repository_test.dart` plus a settings test: the
`auto-mode` preference round-trips and defaults to `lowest`; `connectAutoGroup` and
`reconnectAutoGroup` call `selectOutbound(select, lowest)` by default and
`selectOutbound(select, fastest)` when the setting is `fastest`; the three-attempt retry and the
"connect still succeeds after three failures" cases are repeated for `fastest`. No browser or
Playwright verification anywhere; the app side is verified with `flutter test`, the Go side with
`go test ./protocol/group/balancer/` and `go test ./v2/config/`.

## 9. Rollout

1. `recon-core/hiddify-sing-box` on `recon/main`: the `failoverStrategy` and `ranker` extraction
   first, as its own commit with the existing tests green, then the strategy, downloader, scheduler,
   idle rule, option fields and log-format change.
2. `recon-core`: submodule bump, `ThroughputOptions`, builder changes, tests, tag `v4.1.0-recon.5`;
   the Actions build publishes the AAR as a release asset.
3. `hiddify-app` on `recon/stage2`: `dependencies.properties` `core.version=4.1.0-recon.5`, the
   setting, enum, i18n keys, repository change, tests, and the scenario name in
   `tool/performance/go_scenarios.py`. Generated Dart files and `android/app/libs/` stay out of the
   commits, Makefile compiler flags are unchanged, and the pinned upstream sources stay as they are
   (hiddify-core `c9d6f0f0`, sing-box `0a02b772`, ray2sing `f58be84e`).
4. Docs: `docs/2026-09-12_recon_stage2_core_failover.md` gains the new `failover:` and `diag:` formats
   and the `better_throughput` reason; a stage 3 hand-over section in Russian is written at the end of
   the implementation plan; `tool/performance/README.md` gains the new scenario row.
5. Commits use `type(scope): summary in Russian` with the trailers
   `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
   `Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze`.

Everything ships behind the default `lowest`: `fastest` exists in the config, stays unselected, and
the idle rule keeps it from probing or downloading. The 48 h stage 2 observation baseline is
therefore undisturbed, apart from the added `diag:` fields and the `group=` prefix, which the
analysis scripts must tolerate.

## 10. Open questions and deferred points

1. Download source: one URL ships (`speed.cloudflare.com`), configurable through
   `throughput-test-url`. A per-region list like `connection-test-urls` is deferred until a real
   region shows the host throttled or blocked; a failed measurement already logs the reason, so this
   will be visible in `box.log`.
2. Proxy list: decided in section 4, only the configured auto entry is shown.
3. The measured value is visible nowhere in the UI. Putting it on the proxy tile next to the delay
   needs the gRPC status extension deferred in stage 2 section 5.6; until then the log line is the
   only source.

## 11. Self-review

- Placeholder scan: no TBD, no unnamed default. Every number in sections 3 to 5 is either a binding
  decision or a decision stated here with its reason (30 s tick, 300 s round floor, decimal MB,
  hourly budget ring, all-failed backoff, the abort and budget log lines, `config()`, the `ranker`
  seam, the `AutoMode` file).
- Internal consistency: section 4's table matches every number used in 3.4 to 3.7; section 5's
  formats match the fields section 3 counts; section 8 covers each rule in 3 and each row of 6.
- Scope: one plan, sing-box strategy plus core options plus one app setting. No UI beyond a single
  settings tile, no gRPC change, no change to `lowest` behaviour.
- Ambiguity: section 10 holds the only unresolved points; none blocks implementation and each has a
  stated default to ship with.
