# Recon Stage 3: Throughput Auto Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a second automatic balancer, `fastest`, that picks the server by measured download throughput instead of URL-test latency, selectable from the app and off by default.

**Architecture:** The sing-box fork gains a `throughput` strategy that embeds `LowestDelay` for latency, health and switch bookkeeping, adds a value table filled by an active HTTP download through each candidate outbound, and installs a throughput-first `ranker` so every failover path prefers the fastest known server. A `failoverStrategy` interface lets the stage 2 failover controller serve both strategies unchanged. hiddify-core builds the `fastest` balancer next to `lowest` and keeps `lowest` as the selector default; the app has one setting that decides which auto entry it selects after connect.

**Tech Stack:** Go 1.25 (sing-box fork, hiddify-core), Flutter/Dart (app), GitHub Actions

**Spec:** docs/superpowers/specs/2026-09-12-recon-stage3-throughput-mode-design.md

## Global Constraints

- Repos and branches: sing-box fork `recon-core/hiddify-sing-box` on `recon/main` at `36e826b2`; core `recon-core` on `recon/main` at `66ba248`; app `hiddify-app` on `recon/stage2`.
- Pinned upstream sources stay as they are: hiddify-core `c9d6f0f0`, sing-box `0a02b772`, ray2sing `f58be84e`. Never bump them.
- Makefile compiler flags are unchanged; the Android AAR is built only in GitHub Actions.
- Provider names and subscription URLs never appear in code, tests, docs or commits. Servers are `s1`, `s2`, … everywhere.
- Generated Dart files (`**/*.g.dart`, `**/*.freezed.dart`, `**/*.mapper.dart`, `lib/gen/translations.g.dart`) and `android/app/libs/` are never committed.
- Commit style `type(scope): суть по-русски`, and every commit ends with the two trailers `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze`.
- Windows toolchain: `go build ./...` fails in `protocol/tailscale`, so build and test per package (`go test ./protocol/group/balancer/`, `go vet ./protocol/group/balancer/`). App tests run as `flutter test --concurrency=1`. Run `git checkout -- linux/flutter macos/Flutter windows/flutter` before committing in the app.
- Implementers never push. The controller pushes, tags `v4.1.0-recon.5` and bumps `dependencies.properties`.
- The default auto entry stays `lowest`: `defaultSelect` in the core builder and the `auto-mode` app preference both default to it.
- Prose (docs, comments, commit bodies) follows `~/.claude/skills/unslop/SKILL.md`.
- No Playwright, no browser self-verification. Go is verified with `go test`, the app with `flutter test`.

---

## File map

sing-box fork (`recon-core/hiddify-sing-box`):
- Modify `protocol/group/balancer/strategy.go` — `failoverStrategy` and `ranker` interfaces (Task 1).
- Modify `protocol/group/balancer/lowest_delay.go` — `ranker` seam, `ingest`, `promoteHealthy`, `sinceLastSwitch`, `lock`/`unlock`, `config`, `outboundByTag`, `currentLocked` (Task 1).
- Modify `protocol/group/balancer/failover.go` — interface-typed strategy (Task 1), `group=` prefix, `tp_*` diag fields, activity gate (Task 6).
- Modify `protocol/group/balancer/balancer.go` — generic wiring (Task 1), `StrategyThroughput` constant (Task 2), `lastDial` activity gate and throughput wiring (Task 6).
- Modify `option/balancer.go` — seven `throughput_*` fields (Task 2).
- Modify `protocol/group/balancer/reasons.go` — `reasonBetterThroughput` (Task 2).
- Create `protocol/group/balancer/throughput_options.go` — constants, `throughputConfig`, `normalizeThroughput` (Task 2).
- Create `protocol/group/balancer/downloader.go` — `downloader`, `throughputResult`, `httpDownloader`, `throughputFailure` (Task 3).
- Create `protocol/group/balancer/throughput.go` — the strategy (Task 4), scheduler and budget wiring (Task 5).
- Create `protocol/group/balancer/budget.go` — the 24-bucket rolling ring (Task 5).
- Tests: `ranker_test.go` (Task 1), `throughput_options_test.go` (Task 2), `downloader_test.go` (Task 3), `throughput_test.go` (Tasks 4-6), `budget_test.go` (Task 5), `scenario_test.go` and `failover_test.go` updates (Task 6).

core (`recon-core`):
- Modify `v2/config/hiddify_option.go` — `ThroughputOptions`, embedded anonymously, defaults (Task 7).
- Modify `v2/config/builder.go` — `OutboundThroughputTag`, `PredefinedOutboundTags`, build `fastest` after `lowest` (Task 7).
- Modify `v2/config/failover_test.go` — builder, flat JSON and single-server tests (Task 7).
- Submodule bump `hiddify-sing-box` to the Task 6 commit (Task 7).

app (`hiddify-app`, branch `recon/stage2`):
- Create `lib/features/connection/model/auto_mode.dart` (Task 8).
- Modify `lib/core/preferences/general_preferences.dart`, `lib/features/settings/overview/sections/general_page.dart`, `lib/features/connection/data/connection_repository.dart`, `lib/features/proxy/overview/proxies_overview_notifier.dart`, `assets/translations/en.i18n.json`, `assets/translations/ru.i18n.json` (Task 8).
- Tests `test/features/connection/data/connection_repository_test.dart`, `test/core/preferences/auto_mode_preference_test.dart`, `test/features/proxy/overview/auto_entry_filter_test.dart` (Task 8).
- Modify `tool/performance/go_scenarios.py`, `tool/performance/README.md`; new `docs/performance/<date>-go-scenarios-stage3/`; docs (Task 9).

---

### Task 1: Extract `failoverStrategy` and the `ranker` seam

Pure refactor of the sing-box fork. Behaviour must not change: `lowest_delay_test.go`, `failover_test.go`, `stall_test.go` and the three scenarios pass **unchanged**, which is the proof.

**Files:**
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/strategy.go` (whole file, 9 lines today)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/lowest_delay.go` (struct at `:28-40`, constructor `:44-63`, `Now` `:67-71`, `bestLocked` `:131-144`, `UpdateOutboundsInfo` `:163-210`, `Candidates` `:263-282`)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/failover.go` (`:43` field, `:90-99` constructor)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/balancer.go` (`:40-67` struct, `:132-153` wiring)
- Test: create `recon-core/hiddify-sing-box/protocol/group/balancer/ranker_test.go`

**Interfaces:**
- Produces: `type failoverStrategy interface { Now() string; IsSelected(tag string) bool; Healthy(tag string) bool; Candidates(exclude string) []string; MarkFailed(tag, reason string) (switched bool, hasCandidate bool); ForceSelect(tag, reason string, delay uint16) bool; Events() []switchEvent; config() failoverConfig }`
- Produces: `type ranker interface { best(network, exclude string) (adapter.Outbound, uint16); order(exclude string) []string }` (both called with `LowestDelay.mu` held)
- Produces on `*LowestDelay`: `setRanker(r ranker)`, `lock()`, `unlock()`, `config() failoverConfig`, `outboundByTag(tag string) adapter.Outbound`, `currentLocked() string`, `ingest(history map[string]*adapter.URLTestHistory)`, `promoteHealthy() (changed bool)`, `sinceLastSwitch(now time.Time) time.Duration`, `sinceLastSwitchLocked(now time.Time) time.Duration`, `bestByLatencyLocked(network, exclude string) (adapter.Outbound, uint16)`, `orderByLatency(exclude string) []string`, `orderByLatencyLocked(exclude string) []string`
- Consumes: `newFailover(ctx context.Context, cfg failoverConfig, strategy failoverStrategy, probe prober, logger failoverLogger, onSwitch func()) *failover` (param type change only, call sites unchanged)
- Produces on `*Balancer`: field `foStrategy failoverStrategy`

- [ ] **Step 1: Write the failing seam test**

Create `protocol/group/balancer/ranker_test.go`:

```go
package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

// reverseRanker ranks the latency order backwards. It exists to prove the seam is really
// consulted: no production ranker behaves like this. It ignores the network argument, which is
// safe here because the fake outbounds of these tests support both networks.
type reverseRanker struct{ ld *LowestDelay }

func (r reverseRanker) order(exclude string) []string {
	base := r.ld.orderByLatencyLocked(exclude)
	out := make([]string, 0, len(base))
	for i := len(base) - 1; i >= 0; i-- {
		out = append(out, base[i])
	}
	return out
}

func (r reverseRanker) best(network, exclude string) (adapter.Outbound, uint16) {
	for _, tag := range r.order(exclude) {
		if !r.ld.healthyLocked(tag) {
			continue
		}
		delay, _ := r.ld.measuredLocked(tag)
		return r.ld.byTag[tag], delay
	}
	return nil, 0
}

func TestLowestDelaySatisfiesFailoverStrategy(t *testing.T) {
	var _ failoverStrategy = (*LowestDelay)(nil)
	c := newFakeClock()
	s := newLD(c, "s1", "s2")
	if s.config().minDwell != defaultMinDwell {
		t.Fatalf("config() must expose the normalised failover config, got %v", s.config().minDwell)
	}
}

func TestRankerSeamDecidesOrderAndPromotion(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "s1", "s2", "s3")
	s.setRanker(reverseRanker{s})
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"s1": measured(100, c.Now()), "s2": measured(200, c.Now()), "s3": measured(300, c.Now()),
	})
	if got := s.Candidates(""); len(got) != 3 || got[0] != "s3" {
		t.Fatalf("the installed ranker must decide the candidate order, got %v", got)
	}
	if s.Now() != "s3" {
		t.Fatalf("the installed ranker must decide the promotion, got %q", s.Now())
	}
}

func TestSinceLastSwitchMeasuresFromTheLastMove(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "s1", "s2")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now())})
	c.Advance(90 * time.Second)
	if got := s.sinceLastSwitch(c.Now()); got != 90*time.Second {
		t.Fatalf("sinceLastSwitch = %v, want 1m30s", got)
	}
}

func TestIngestAndPromoteHealthyReproduceUpdate(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "s1", "s2")
	s.ingest(map[string]*adapter.URLTestHistory{"s2": measured(300, c.Now())})
	if !s.promoteHealthy() || s.Now() != "s2" {
		t.Fatalf("ingest + promoteHealthy must replace the provisional pick, now=%q", s.Now())
	}
}
```

- [ ] **Step 2: Run it and see it fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run 'TestLowestDelaySatisfiesFailoverStrategy|TestRankerSeam|TestSinceLastSwitch|TestIngestAndPromote' -count=1
```

Expected: build failure, `undefined: failoverStrategy`, `s.setRanker undefined`, `s.orderByLatencyLocked undefined`, `s.config undefined`, `s.sinceLastSwitch undefined`, `s.ingest undefined`, `s.promoteHealthy undefined`.

- [ ] **Step 3: Add both interfaces to `strategy.go`**

Replace the whole file with:

```go
package balancer

import "github.com/sagernet/sing-box/adapter"

type Strategy interface {
	UpdateOutboundsInfo(outbounds map[string]*adapter.URLTestHistory) (changed bool)
	Select(metadata adapter.InboundContext, network string, touch bool) adapter.Outbound
	Now() string
}

// failoverStrategy is everything the failover controller and the Balancer wiring need from a
// strategy. LowestDelay and Throughput implement it; round-robin, consistent-hashing and
// sticky-sessions do not, which is exactly what keeps them out of the failover path.
//
// The first seven methods are what failover.go already called on *LowestDelay. config() is here
// because Balancer.Start needs the normalised failover config to build the stall tracker and the
// controller, and a type assertion on the concrete strategy is what this interface removes.
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

// ranker decides which candidate is the best one and in what order the rest are tried. It
// replaces the two places where LowestDelay used to hardcode "lowest delay wins". Both methods
// are called with LowestDelay.mu held, so an implementation must not take that lock again.
type ranker interface {
	best(network, exclude string) (adapter.Outbound, uint16)
	order(exclude string) []string
}
```

- [ ] **Step 4: Add the seam and the extracted helpers to `lowest_delay.go`**

Add the `rk` field to the struct (after `events []switchEvent`):

```go
	rk          ranker
	mu          sync.Mutex
```

Rewrite the constructor so the ranker can point back at the strategy:

```go
func NewLowestDelay(outbounds []adapter.Outbound, options option.BalancerOutboundOptions) *LowestDelay {
	couts := convertOutbounds(outbounds)
	byTag := make(map[string]adapter.Outbound, len(outbounds))
	for _, o := range outbounds {
		byTag[o.Tag()] = o
	}
	s := &LowestDelay{
		outbounds: couts,
		byTag:     byTag,
		selected: map[string]adapter.Outbound{
			N.NetworkUDP: couts[N.NetworkUDP][0],
			N.NetworkTCP: couts[N.NetworkTCP][0],
		},
		provisional: true,
		cfg:         normalizeFailover(options),
		now:         time.Now,
		history:     map[string]*adapter.URLTestHistory{},
		failedAt:    map[string]time.Time{},
	}
	s.rk = latencyRanker{s}
	return s
}

// setRanker installs the candidate ordering. Throughput replaces the default latency ranker with
// one that puts measured bandwidth first.
func (s *LowestDelay) setRanker(r ranker) { s.mu.Lock(); s.rk = r; s.mu.Unlock() }

// lock and unlock expose the strategy lock to the throughput value table, which lives in another
// type but must be read by the ranker while this lock is already held. One lock, because two
// would be a lock-order cycle.
func (s *LowestDelay) lock()   { s.mu.Lock() }
func (s *LowestDelay) unlock() { s.mu.Unlock() }

// config returns the normalised failover config. It is immutable after construction.
func (s *LowestDelay) config() failoverConfig { return s.cfg }

func (s *LowestDelay) outboundByTag(tag string) adapter.Outbound {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.byTag[tag]
}

// latencyRanker is the default ranker: the behaviour LowestDelay had before the seam existed.
type latencyRanker struct{ ld *LowestDelay }

func (r latencyRanker) best(network, exclude string) (adapter.Outbound, uint16) {
	return r.ld.bestByLatencyLocked(network, exclude)
}

func (r latencyRanker) order(exclude string) []string {
	return r.ld.orderByLatencyLocked(exclude)
}
```

Split `Now`, and route `bestLocked` and `Candidates` through the ranker:

```go
func (s *LowestDelay) Now() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.currentLocked()
}

// currentLocked is the TCP selection. The caller holds s.mu.
func (s *LowestDelay) currentLocked() string {
	cur := s.selected[N.NetworkTCP]
	if cur == nil {
		return ""
	}
	return cur.Tag()
}

// bestLocked asks the installed ranker for the best candidate.
func (s *LowestDelay) bestLocked(network, exclude string) (adapter.Outbound, uint16) {
	return s.rk.best(network, exclude)
}

// bestByLatencyLocked returns the healthy outbound with the lowest delay for network, excluding
// tag. This is the body bestLocked used to have.
func (s *LowestDelay) bestByLatencyLocked(network, exclude string) (adapter.Outbound, uint16) {
	var best adapter.Outbound
	bestDelay := monitoring.TimeoutDelay
	for _, o := range s.outbounds[network] {
		if o.Tag() == exclude || !s.healthyLocked(o.Tag()) {
			continue
		}
		d, _ := s.measuredLocked(o.Tag())
		if best == nil || d < bestDelay {
			best, bestDelay = o, d
		}
	}
	return best, bestDelay
}

// Candidates lists all tags except exclude in the order the installed ranker decides.
func (s *LowestDelay) Candidates(exclude string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rk.order(exclude)
}

// orderByLatency is Candidates with the latency order forced, whatever ranker is installed. The
// throughput shortlist uses it: measuring only the servers that already have the best values
// would never discover a faster one.
func (s *LowestDelay) orderByLatency(exclude string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.orderByLatencyLocked(exclude)
}

// orderByLatencyLocked lists all tags except exclude: healthy measured first by delay, then
// unknown or failed in configuration order. This is the body Candidates used to have.
func (s *LowestDelay) orderByLatencyLocked(exclude string) []string {
	var measuredTags, unknownTags []string
	delays := map[string]uint16{}
	for _, o := range s.outbounds[N.NetworkTCP] {
		tag := o.Tag()
		if tag == exclude {
			continue
		}
		if d, ok := s.measuredLocked(tag); ok && s.healthyLocked(tag) {
			measuredTags = append(measuredTags, tag)
			delays[tag] = d
		} else {
			unknownTags = append(unknownTags, tag)
		}
	}
	sort.SliceStable(measuredTags, func(i, j int) bool { return delays[measuredTags[i]] < delays[measuredTags[j]] })
	return append(measuredTags, unknownTags...)
}
```

- [ ] **Step 5: Split `UpdateOutboundsInfo` into `ingest`, `promoteHealthy` and the tolerance arm**

Replace `UpdateOutboundsInfo` (`:163-210`) with:

```go
// ingest copies the monitoring history into the strategy.
func (s *LowestDelay) ingest(history map[string]*adapter.URLTestHistory) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ingestLocked(history)
}

func (s *LowestDelay) ingestLocked(history map[string]*adapter.URLTestHistory) {
	for tag, h := range history {
		if h != nil {
			copyH := *h
			s.history[tag] = &copyH
		}
	}
}

// promoteHealthy replaces a provisional or unhealthy selection with the ranker's best candidate,
// for both networks. It is the arm that must run for every strategy: a dead or unmeasured server
// is never kept.
func (s *LowestDelay) promoteHealthy() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.promoteHealthyLocked(s.now(), s.provisional)
}

// promoteHealthyLocked takes wasProvisional as a snapshot: the TCP iteration clears the flag and
// UDP must still see the state the update started from.
func (s *LowestDelay) promoteHealthyLocked(now time.Time, wasProvisional bool) bool {
	changed := false
	for _, network := range []string{N.NetworkTCP, N.NetworkUDP} {
		cur := s.selected[network]
		if cur != nil && !wasProvisional && s.healthyLocked(cur.Tag()) {
			continue
		}
		best, _ := s.bestLocked(network, "")
		if best == nil {
			continue
		}
		if cur == nil || best.Tag() != cur.Tag() {
			reason := reasonProbeFailed
			if wasProvisional {
				reason = reasonInitial
			}
			s.switchLocked(network, best, reason)
			changed = true
		} else if network == N.NetworkTCP {
			// The provisional pick turned out to be the best measured server: it stops
			// being provisional and starts the dwell window from now.
			s.provisional = false
			s.lastSwitch = now
		}
	}
	return changed
}

func (s *LowestDelay) sinceLastSwitch(now time.Time) time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sinceLastSwitchLocked(now)
}

func (s *LowestDelay) sinceLastSwitchLocked(now time.Time) time.Duration {
	return now.Sub(s.lastSwitch)
}

func (s *LowestDelay) UpdateOutboundsInfo(history map[string]*adapter.URLTestHistory) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ingestLocked(history)
	now := s.now()
	// The dwell decision is taken once for the whole update: switchLocked moves lastSwitch on
	// the TCP iteration, and without a snapshot UDP would stay behind for a full dwell.
	dwellOK := s.sinceLastSwitchLocked(now) >= s.cfg.minDwell
	wasProvisional := s.provisional
	changed := s.promoteHealthyLocked(now, wasProvisional)
	if wasProvisional {
		// Every network took the promote arm; the tolerance arm has nothing to add.
		return changed
	}
	for _, network := range []string{N.NetworkTCP, N.NetworkUDP} {
		cur := s.selected[network]
		if cur == nil || !s.healthyLocked(cur.Tag()) {
			// Handled by promoteHealthyLocked, or nothing healthy exists to move to.
			continue
		}
		best, bestDelay := s.bestLocked(network, "")
		if best == nil {
			continue
		}
		curDelay, _ := s.measuredLocked(cur.Tag())
		if uint32(bestDelay)+uint32(s.cfg.tolerance) < uint32(curDelay) && dwellOK {
			s.switchLocked(network, best, reasonBetterLatency)
			changed = true
		}
	}
	return changed
}
```

- [ ] **Step 6: Type the controller and the wiring against the interface**

In `failover.go`, change the field at `:43` and the constructor parameter at `:90`:

```go
	strategy failoverStrategy
```

```go
func newFailover(ctx context.Context, cfg failoverConfig, strategy failoverStrategy, probe prober, logger failoverLogger, onSwitch func()) *failover {
```

In `balancer.go`, add the field to the struct next to `failover`:

```go
	// foStrategy is the strategy behind strategyFn when it can drive the failover controller
	// (lowest-delay and throughput). It is nil for the other strategies.
	foStrategy failoverStrategy
```

Replace the wiring block at `:132-153` with:

```go
	if fs, ok := s.strategyFn.(failoverStrategy); ok {
		s.foStrategy = fs
	}
	// The controller probes through the monitor and the worker reads its history; without a
	// monitor there is nothing to drive either, so neither is built.
	if s.foStrategy != nil && s.monitor != nil {
		cfg := s.foStrategy.config()
		s.stalls = newStallTracker(cfg, time.Now, func(tag string) {
			// reportFailure owns the Stalls counter; do not bump it here.
			s.failover.reportFailure(tag, reasonStall)
		})
		s.failover = newFailover(s.ctx, cfg, s.foStrategy, monitorProber{s.monitor}, s.logger, func() {
			s.interruptGroup.Interrupt(s.interruptExternalConnections)
		})
		s.failover.setResetStalls(s.stalls.reset)
		if pm := service.FromContext[pause.Manager](s.ctx); pm != nil {
			// IsPaused covers both halves: the screen is off / the tunnel is idle, and
			// there is no usable network. Either way an active probe is wasted radio.
			s.failover.setPaused(pm.IsPaused)
			s.failover.setNetworkPaused(pm.IsNetworkPaused)
		}
	}
	if s.foStrategy != nil && s.monitor == nil {
		// Without the monitor there is no prober and no history, so nothing can detect or
		// repair a dead server. Say it once instead of failing silently.
		s.logger.Warn("load balance: failover is disabled for strategy ", s.options.Strategy, ", outbound monitoring is off")
	}
```

- [ ] **Step 7: Run the new test and the whole package**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -count=1
go vet ./protocol/group/balancer/
```

Expected: `ok github.com/sagernet/sing-box/protocol/group/balancer`, every pre-existing test green with no edits to `lowest_delay_test.go`, `failover_test.go`, `stall_test.go` or `scenario_test.go`, and `go vet` silent.

- [ ] **Step 8: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git add protocol/group/balancer/strategy.go protocol/group/balancer/lowest_delay.go protocol/group/balancer/failover.go protocol/group/balancer/balancer.go protocol/group/balancer/ranker_test.go
git commit -m "refactor(balancer): интерфейс failoverStrategy и seam ranker" -m "Контроллер отказов больше не привязан к конкретному *LowestDelay: он работает через интерфейс из восьми методов, а Balancer подключает его любой стратегии, которая этот интерфейс реализует. Выбор лучшего кандидата и порядок кандидатов вынесены в ranker, из UpdateOutboundsInfo выделены ingest, promoteHealthy и sinceLastSwitch. Поведение lowest не меняется: старые тесты пройдены без правок." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

---

### Task 2: Throughput options, normalisation and the new reason

**Files:**
- Modify: `recon-core/hiddify-sing-box/option/balancer.go` (append to `BalancerOutboundOptions`, after `ActiveCheckInterval` at `:21`)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/reasons.go` (const block at `:80-89`)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/balancer.go` (strategy const block at `:33-38`)
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/throughput_options.go`
- Test: create `recon-core/hiddify-sing-box/protocol/group/balancer/throughput_options_test.go`

**Interfaces:**
- Produces: option fields `ThroughputTestURL string`, `ThroughputProbeBytes int64`, `ThroughputRecheckInterval badoption.Duration`, `ThroughputDailyBudgetMB int64`, `ThroughputShortlist int`, `ThroughputHysteresisPercent int`, `ThroughputMinDwell badoption.Duration`
- Produces: `type throughputConfig struct { testURL string; probeBytes int64; recheck time.Duration; budgetBytes int64; disabled bool; shortlist int; hysteresisPct int; minDwell time.Duration }`
- Produces: `normalizeThroughput(o option.BalancerOutboundOptions, outbounds int) throughputConfig`
- Produces: `StrategyThroughput = "throughput"`, `reasonBetterThroughput = "better_throughput"`, and the constants used by Tasks 3-5
- Consumes: `durationOr(v, def time.Duration) time.Duration` from `failover_options.go:35`

- [ ] **Step 1: Write the failing normalisation test**

Create `protocol/group/balancer/throughput_options_test.go`:

```go
package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func TestNormalizeThroughputDefaults(t *testing.T) {
	cfg := normalizeThroughput(option.BalancerOutboundOptions{}, 5)
	if cfg.testURL != defaultThroughputTestURL {
		t.Fatalf("testURL = %q", cfg.testURL)
	}
	if cfg.probeBytes != 3_000_000 || cfg.recheck != 2*time.Hour || cfg.budgetBytes != 100_000_000 ||
		cfg.disabled || cfg.shortlist != 3 || cfg.hysteresisPct != 25 || cfg.minDwell != 10*time.Minute {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
}

func TestNormalizeThroughputClamps(t *testing.T) {
	cfg := normalizeThroughput(option.BalancerOutboundOptions{
		ThroughputProbeBytes:        1000,
		ThroughputShortlist:         99,
		ThroughputHysteresisPercent: 900,
	}, 4)
	if cfg.probeBytes != 524288 {
		t.Fatalf("probe bytes below the failure floor must be clamped up, got %d", cfg.probeBytes)
	}
	if cfg.shortlist != 4 {
		t.Fatalf("the shortlist cannot exceed the number of outbounds, got %d", cfg.shortlist)
	}
	if cfg.hysteresisPct != 500 {
		t.Fatalf("hysteresis = %d, want the 500 clamp", cfg.hysteresisPct)
	}
	if got := normalizeThroughput(option.BalancerOutboundOptions{ThroughputProbeBytes: 200_000_000}, 4).probeBytes; got != 100_000_000 {
		t.Fatalf("probe bytes = %d, want the 100000000 clamp", got)
	}
}

func TestNormalizeThroughputNegativesDisable(t *testing.T) {
	cfg := normalizeThroughput(option.BalancerOutboundOptions{
		ThroughputRecheckInterval:   badoption.Duration(-1),
		ThroughputDailyBudgetMB:     -1,
		ThroughputMinDwell:          badoption.Duration(-1),
		ThroughputHysteresisPercent: -1,
	}, 4)
	if cfg.recheck != 0 {
		t.Fatalf("a negative recheck interval must disable the periodic recheck, got %v", cfg.recheck)
	}
	if !cfg.disabled {
		t.Fatal("a negative daily budget must disable measurement entirely")
	}
	if cfg.minDwell != 0 {
		t.Fatalf("a negative min dwell becomes 0, got %v", cfg.minDwell)
	}
	if cfg.hysteresisPct != 0 {
		t.Fatalf("a negative hysteresis becomes 0, got %d", cfg.hysteresisPct)
	}
}

func TestNormalizeThroughputOverrides(t *testing.T) {
	cfg := normalizeThroughput(option.BalancerOutboundOptions{
		ThroughputTestURL:           "https://example.invalid/down",
		ThroughputProbeBytes:        5_000_000,
		ThroughputRecheckInterval:   badoption.Duration(30 * time.Minute),
		ThroughputDailyBudgetMB:     250,
		ThroughputShortlist:         2,
		ThroughputHysteresisPercent: 10,
		ThroughputMinDwell:          badoption.Duration(90 * time.Second),
	}, 6)
	if cfg.testURL != "https://example.invalid/down" || cfg.probeBytes != 5_000_000 ||
		cfg.recheck != 30*time.Minute || cfg.budgetBytes != 250_000_000 || cfg.shortlist != 2 ||
		cfg.hysteresisPct != 10 || cfg.minDwell != 90*time.Second {
		t.Fatalf("overrides not applied: %+v", cfg)
	}
}

func TestThroughputReasonAndStrategyNames(t *testing.T) {
	if reasonBetterThroughput != "better_throughput" {
		t.Fatalf("reason = %q", reasonBetterThroughput)
	}
	if StrategyThroughput != "throughput" {
		t.Fatalf("strategy = %q", StrategyThroughput)
	}
}
```

- [ ] **Step 2: Run it and see it fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run TestNormalizeThroughput -count=1
```

Expected: build failure, `undefined: normalizeThroughput`, `unknown field ThroughputProbeBytes in struct literal of type option.BalancerOutboundOptions`, `undefined: reasonBetterThroughput`, `undefined: StrategyThroughput`.

- [ ] **Step 3: Add the option fields**

In `option/balancer.go`, after `ActiveCheckInterval`:

```go
	// Recon throughput (throughput strategy only). Zero means default, negative disables where
	// noted. All seven travel with the balancer outbound, so the core sets them per balancer.
	ThroughputTestURL           string             `json:"throughput_test_url,omitempty"`
	ThroughputProbeBytes        int64              `json:"throughput_probe_bytes,omitempty"`
	ThroughputRecheckInterval   badoption.Duration `json:"throughput_recheck_interval,omitempty"` // negative disables
	ThroughputDailyBudgetMB     int64              `json:"throughput_daily_budget_mb,omitempty"`  // negative disables measurement
	ThroughputShortlist         int                `json:"throughput_shortlist,omitempty"`
	ThroughputHysteresisPercent int                `json:"throughput_hysteresis_percent,omitempty"`
	ThroughputMinDwell          badoption.Duration `json:"throughput_min_dwell,omitempty"`
```

- [ ] **Step 4: Add the reason and the strategy name**

In `reasons.go`, extend the doc comment with one line and add the constant:

```go
//	better_throughput a full measurement round found a server faster by more than the hysteresis
```

```go
	reasonBetterThroughput = "better_throughput"
```

In `balancer.go`, extend the strategy const block:

```go
	StrategyLowestDelay       = "lowest-delay"
	StrategyThroughput        = "throughput"
```

- [ ] **Step 5: Create `throughput_options.go`**

```go
package balancer

import (
	"time"

	"github.com/sagernet/sing-box/option"
)

const (
	defaultThroughputTestURL                 = "https://speed.cloudflare.com/__down?bytes=3000000"
	defaultThroughputProbeBytes        int64 = 3_000_000
	defaultThroughputRecheck                 = 2 * time.Hour
	defaultThroughputDailyBudgetMB     int64 = 100
	defaultThroughputShortlist               = 3
	defaultThroughputHysteresisPercent       = 25
	defaultThroughputMinDwell                = 10 * time.Minute

	// minThroughputProbeBytes is the failure floor as well: below it the "fewer than 524288
	// bytes is a failed measurement" rule could never be satisfied.
	minThroughputProbeBytes        int64 = 524_288
	maxThroughputProbeBytes        int64 = 100_000_000
	maxThroughputHysteresisPercent       = 500

	// Measurement shape. MB is decimal, 1,000,000 bytes, the unit link rates and data caps are
	// quoted in; the budget uses the same unit.
	throughputTimeout            = 8 * time.Second
	throughputWarmupBytes  int64 = 262_144
	throughputMinBytes     int64 = 524_288
	throughputReadBuffer         = 32 * 1024
	throughputTick               = 30 * time.Second
	throughputRoundFloor         = 5 * time.Minute
	throughputGateTick           = time.Second
	throughputFailBackoffMin     = 10 * time.Minute
	throughputFailBackoffMax     = 2 * time.Hour
)

type throughputConfig struct {
	testURL       string
	probeBytes    int64
	recheck       time.Duration // 0 = no periodic recheck
	budgetBytes   int64
	disabled      bool // no measurement at all; the strategy ranks by latency
	shortlist     int
	hysteresisPct int
	minDwell      time.Duration
}

// normalizeThroughput follows the convention of normalizeFailover: zero means default, negative
// disables where the option table says so. outbounds is the size of the pool, which caps the
// shortlist.
func normalizeThroughput(o option.BalancerOutboundOptions, outbounds int) throughputConfig {
	cfg := throughputConfig{
		testURL:       o.ThroughputTestURL,
		probeBytes:    o.ThroughputProbeBytes,
		recheck:       durationOr(o.ThroughputRecheckInterval.Build(), defaultThroughputRecheck),
		shortlist:     o.ThroughputShortlist,
		hysteresisPct: o.ThroughputHysteresisPercent,
		minDwell:      durationOr(o.ThroughputMinDwell.Build(), defaultThroughputMinDwell),
	}
	if cfg.testURL == "" {
		cfg.testURL = defaultThroughputTestURL
	}
	if cfg.probeBytes == 0 {
		cfg.probeBytes = defaultThroughputProbeBytes
	}
	if cfg.probeBytes < minThroughputProbeBytes {
		cfg.probeBytes = minThroughputProbeBytes
	}
	if cfg.probeBytes > maxThroughputProbeBytes {
		cfg.probeBytes = maxThroughputProbeBytes
	}
	switch {
	case o.ThroughputDailyBudgetMB < 0:
		cfg.disabled = true
	case o.ThroughputDailyBudgetMB == 0:
		cfg.budgetBytes = defaultThroughputDailyBudgetMB * 1_000_000
	default:
		cfg.budgetBytes = o.ThroughputDailyBudgetMB * 1_000_000
	}
	if cfg.shortlist <= 0 {
		cfg.shortlist = defaultThroughputShortlist
	}
	if outbounds > 0 && cfg.shortlist > outbounds {
		cfg.shortlist = outbounds
	}
	// Zero is "not set" for every option here, so it takes the default; a caller that really
	// wants to switch on any improvement asks for it with a negative value.
	switch {
	case cfg.hysteresisPct == 0:
		cfg.hysteresisPct = defaultThroughputHysteresisPercent
	case cfg.hysteresisPct < 0:
		cfg.hysteresisPct = 0
	case cfg.hysteresisPct > maxThroughputHysteresisPercent:
		cfg.hysteresisPct = maxThroughputHysteresisPercent
	}
	return cfg
}
```

- [ ] **Step 6: Run it and see it pass**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -count=1
go vet ./protocol/group/balancer/ ./option/
```

Expected: `ok`, five new tests green, every pre-existing test still green.

- [ ] **Step 7: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git add option/balancer.go protocol/group/balancer/reasons.go protocol/group/balancer/balancer.go protocol/group/balancer/throughput_options.go protocol/group/balancer/throughput_options_test.go
git commit -m "feat(balancer): опции throughput, нормализация и причина better_throughput" -m "Семь полей throughput_* в BalancerOutboundOptions с дефолтами 3 МБ, 7200 с, 100 МБ/сутки, шорт-лист 3, гистерезис 25 %, dwell 600 с. Ноль означает дефолт, отрицательное значение отключает пересчёт и замеры; probe_bytes зажат в [524288, 100000000], гистерезис в [0, 500], шорт-лист по размеру пула." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

---

### Task 3: The `downloader` seam and the production HTTP downloader

**Files:**
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/downloader.go`
- Test: create `recon-core/hiddify-sing-box/protocol/group/balancer/downloader_test.go`

**Interfaces:**
- Produces: `type downloader interface { Download(ctx context.Context, tag, url string) (throughputResult, error) }`
- Produces: `type throughputResult struct { Bytes int64; Timed int64; Elapsed time.Duration; Status int }` with `func (r throughputResult) mbps() float64`
- Produces: `newHTTPDownloader(lookup func(tag string) adapter.Outbound) *httpDownloader` with tunable fields `timeout`, `warmupBytes`, `minBytes`, `bufSize`
- Produces: `throughputFailure(res throughputResult, err error, minBytes int64) string` returning `""`, `short`, `timeout`, `dial_error` or `http_<code>`
- Produces: `errNoOutbound`
- Consumes: `adapter.Outbound.DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error)`; `M.ParseSocksaddr(address string) M.Socksaddr`; `ntp.TimeFuncFromContext` and `adapter.RootPoolFromContext`, the TLS setup `common/urltest/urltest.go:142-156` already uses
- Consumes: `fakeOutbound` from `fakes_test.go:104-123`, whose `dial` field replaces `DialContext`, and `newFakeOutbound(tag string)` at `:110`

- [ ] **Step 1: Write the failing downloader test**

Create `protocol/group/balancer/downloader_test.go`:

```go
package balancer

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
)

// newTestDownloader wires the production downloader to an httptest server through the package's
// fake outbound: the only thing the downloader needs from an outbound is DialContext, and the
// fake's dial hook returns a real socket to the test server.
func newTestDownloader(t *testing.T, handler http.HandlerFunc) *httpDownloader {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	addr := srv.Listener.Addr().String()
	out := newFakeOutbound("s1")
	out.dial = func(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "tcp", addr)
	}
	d := newHTTPDownloader(func(tag string) adapter.Outbound {
		if tag != "s1" {
			return nil
		}
		return out
	})
	// Small thresholds keep the test in kilobytes and milliseconds; production uses the
	// throughput* constants of throughput_options.go.
	d.timeout = 2 * time.Second
	d.warmupBytes = 4096
	d.minBytes = 8192
	return d
}

func writeBytes(w http.ResponseWriter, n int) {
	chunk := make([]byte, 4096)
	for written := 0; written < n; {
		size := min(len(chunk), n-written)
		c, err := w.Write(chunk[:size])
		if err != nil {
			return
		}
		written += c
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}
}

func TestDownloaderMeasuresACompleteBody(t *testing.T) {
	d := newTestDownloader(t, func(w http.ResponseWriter, r *http.Request) { writeBytes(w, 65536) })
	res, err := d.Download(context.Background(), "s1", "http://test.invalid/down")
	if err != nil {
		t.Fatalf("download failed: %v", err)
	}
	if reason := throughputFailure(res, err, d.minBytes); reason != "" {
		t.Fatalf("a complete body must not be a failure, got %q", reason)
	}
	if res.Bytes != 65536 {
		t.Fatalf("Bytes = %d, want 65536", res.Bytes)
	}
	if res.Timed <= 0 || res.Timed >= res.Bytes {
		t.Fatalf("the warm-up bytes must stay out of Timed: timed=%d bytes=%d", res.Timed, res.Bytes)
	}
	if res.Elapsed <= 0 || res.mbps() <= 0 {
		t.Fatalf("elapsed=%v mbps=%v", res.Elapsed, res.mbps())
	}
}

func TestDownloaderShortBody(t *testing.T) {
	d := newTestDownloader(t, func(w http.ResponseWriter, r *http.Request) { writeBytes(w, 5000) })
	res, err := d.Download(context.Background(), "s1", "http://test.invalid/down")
	if err != nil {
		t.Fatalf("a short but complete body is not a transport error: %v", err)
	}
	if reason := throughputFailure(res, err, d.minBytes); reason != "short" {
		t.Fatalf("reason = %q, want short (bytes=%d)", reason, res.Bytes)
	}
}

func TestDownloaderTimeoutAfterTheFloor(t *testing.T) {
	d := newTestDownloader(t, func(w http.ResponseWriter, r *http.Request) {
		writeBytes(w, 20000)
		<-r.Context().Done()
	})
	d.timeout = 300 * time.Millisecond
	res, err := d.Download(context.Background(), "s1", "http://test.invalid/down")
	if err == nil {
		t.Fatal("a body that never ends must end in an error")
	}
	if res.Bytes < d.minBytes {
		t.Fatalf("Bytes = %d, want at least the floor %d", res.Bytes, d.minBytes)
	}
	if reason := throughputFailure(res, err, d.minBytes); reason != "timeout" {
		t.Fatalf("reason = %q, want timeout", reason)
	}
}

func TestDownloaderHTTPStatus(t *testing.T) {
	d := newTestDownloader(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusForbidden) })
	res, err := d.Download(context.Background(), "s1", "http://test.invalid/down")
	if err != nil {
		t.Fatalf("a 403 is an answer, not a transport error: %v", err)
	}
	if reason := throughputFailure(res, err, d.minBytes); reason != "http_403" {
		t.Fatalf("reason = %q, want http_403", reason)
	}
}

func TestDownloaderDialError(t *testing.T) {
	out := newFakeOutbound("s1")
	out.dial = func(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
		return nil, errors.New("refused")
	}
	d := newHTTPDownloader(func(tag string) adapter.Outbound { return out })
	d.timeout = time.Second
	res, err := d.Download(context.Background(), "s1", "http://test.invalid/down")
	if err == nil {
		t.Fatal("a refused dial must surface as an error")
	}
	if reason := throughputFailure(res, err, d.minBytes); reason != reasonDialError {
		t.Fatalf("reason = %q, want dial_error", reason)
	}
}

func TestDownloaderUnknownTag(t *testing.T) {
	d := newHTTPDownloader(func(tag string) adapter.Outbound { return nil })
	if _, err := d.Download(context.Background(), "s9", "http://test.invalid/down"); !errors.Is(err, errNoOutbound) {
		t.Fatalf("err = %v, want errNoOutbound", err)
	}
}
```

- [ ] **Step 2: Run it and see it fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run TestDownloader -count=1
```

Expected: build failure, `undefined: newHTTPDownloader`, `undefined: throughputFailure`, `undefined: errNoOutbound`, `undefined: httpDownloader`.

- [ ] **Step 3: Create `downloader.go`**

```go
package balancer

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/common/ntp"
)

// downloader measures one server. Production dials through that server's outbound; tests inject
// a fake. One method, because that is all the strategy needs.
type downloader interface {
	Download(ctx context.Context, tag, url string) (throughputResult, error)
}

// throughputResult is one measurement. Bytes is everything that arrived, warm-up included, and is
// what the budget is charged; Timed and Elapsed cover only the part after the warm-up threshold,
// which is what the rate is computed from.
type throughputResult struct {
	Bytes   int64
	Timed   int64
	Elapsed time.Duration
	Status  int // HTTP status, 0 if no response arrived
}

// mbps is decimal megabytes per second: 1 MB is 1,000,000 bytes, the unit link rates and data caps
// are quoted in, and the same unit the budget counts in.
func (r throughputResult) mbps() float64 {
	if r.Elapsed <= 0 || r.Timed <= 0 {
		return 0
	}
	return float64(r.Timed) / 1e6 / r.Elapsed.Seconds()
}

var errNoOutbound = errors.New("outbound not found")

// throughputFailure names the failure of a measurement, or "" when it succeeded. A transfer that
// ends early is short below the byte floor and a timeout above it; a transfer that never got a
// response is a dial error; a non-2xx answer carries its status.
func throughputFailure(res throughputResult, err error, minBytes int64) string {
	switch {
	case res.Status != 0 && (res.Status < 200 || res.Status > 299):
		return "http_" + strconv.Itoa(res.Status)
	case err != nil && res.Status == 0:
		return reasonDialError
	case res.Bytes < minBytes:
		return "short"
	case err != nil:
		return "timeout"
	default:
		return ""
	}
}

// httpDownloader runs one HTTP GET through the candidate outbound. Keep-alives are off and
// redirects are refused, so one call is one connection to one host and nothing is reused between
// candidates. Latency is never derived from this request; it keeps coming from the monitoring
// history.
type httpDownloader struct {
	lookup      func(tag string) adapter.Outbound
	timeout     time.Duration
	warmupBytes int64
	minBytes    int64
	bufSize     int
}

func newHTTPDownloader(lookup func(tag string) adapter.Outbound) *httpDownloader {
	return &httpDownloader{
		lookup:      lookup,
		timeout:     throughputTimeout,
		warmupBytes: throughputWarmupBytes,
		minBytes:    throughputMinBytes,
		bufSize:     throughputReadBuffer,
	}
}

func (d *httpDownloader) Download(ctx context.Context, tag, url string) (throughputResult, error) {
	out := d.lookup(tag)
	if out == nil {
		return throughputResult{}, errNoOutbound
	}
	// One timeout covers connect, TLS and body: a measurement that needs longer than this is
	// not a measurement worth having.
	ctx, cancel := context.WithTimeout(ctx, d.timeout)
	defer cancel()
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return out.DialContext(ctx, network, M.ParseSocksaddr(addr))
			},
			TLSClientConfig: &tls.Config{
				Time:    ntp.TimeFuncFromContext(ctx),
				RootCAs: adapter.RootPoolFromContext(ctx),
			},
			DisableKeepAlives: true,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error { return http.ErrUseLastResponse },
	}
	defer client.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return throughputResult{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return throughputResult{}, err
	}
	defer resp.Body.Close()
	res := throughputResult{Status: resp.StatusCode}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return res, nil
	}
	buf := make([]byte, d.bufSize)
	var started time.Time
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			res.Bytes += int64(n)
			switch {
			case !started.IsZero():
				res.Timed += int64(n)
				res.Elapsed = time.Since(started)
			case res.Bytes >= d.warmupBytes:
				// Timing starts here, so TCP slow start and the handshake stay
				// outside the measured window. The chunk that crossed the
				// threshold is not counted either.
				started = time.Now()
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return res, nil
			}
			return res, readErr
		}
	}
}
```

- [ ] **Step 4: Run it and see it pass**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run TestDownloader -count=1 -v
go test ./protocol/group/balancer/ -count=1
go vet ./protocol/group/balancer/
```

Expected: six `--- PASS` lines (`TestDownloaderMeasuresACompleteBody`, `ShortBody`, `TimeoutAfterTheFloor`, `HTTPStatus`, `DialError`, `UnknownTag`), then `ok` for the whole package.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git add protocol/group/balancer/downloader.go protocol/group/balancer/downloader_test.go
git commit -m "feat(balancer): загрузчик для замера пропускной способности" -m "Один HTTP GET через outbound кандидата: keep-alive выключен, редиректы отклоняются, тело читается в буфер 32 КиБ и выбрасывается. Отсчёт времени начинается после 262144 прогревочных байт, поэтому медленный старт TCP и рукопожатие в скорость не попадают. Причины отказа: short, timeout, dial_error, http_<код>. Тесты идут через httptest и фейковый outbound." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

---

### Task 4: The `Throughput` strategy core

Value table, throughput-first ranker, `UpdateOutboundsInfo`, a full round driven directly, hysteresis and dwell, `invalidate()`. No scheduler, no budget, no gates: Task 5 adds those and modifies `runRound` and `measure` in place.

**Files:**
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/throughput.go`
- Test: create `recon-core/hiddify-sing-box/protocol/group/balancer/throughput_test.go`

**Interfaces:**
- Produces: `NewThroughput(outbounds []adapter.Outbound, options option.BalancerOutboundOptions, logger failoverLogger) *Throughput`, satisfying both `Strategy` and `failoverStrategy`
- Produces on `*Throughput`: `setClock(now func() time.Time, sleep func(ctx context.Context, d time.Duration) error)`, `setDownloader(d downloader)`, `setNotify(fn func())`, `runRound(ctx context.Context)`, `measure(ctx context.Context, tag string) bool`, `evaluate()`, `invalidate()`, `shortlist() []string`
- Produces: `type tpValue struct { mbps float64; at time.Time; ok bool }`, `type throughputRanker struct{ t *Throughput }`
- Consumes from Task 1: `ld.lock()`, `ld.unlock()`, `ld.ingest`, `ld.promoteHealthy`, `ld.sinceLastSwitchLocked`, `ld.currentLocked`, `ld.bestByLatencyLocked`, `ld.orderByLatency`, `ld.orderByLatencyLocked`, `ld.healthyLocked`, `ld.measuredLocked`, `ld.outboundByTag`, `ld.setRanker`, `ld.config`, `ld.setClock`
- Consumes from Task 2: `normalizeThroughput`, `reasonBetterThroughput`, `throughputMinBytes`
- Consumes from Task 3: `downloader`, `throughputResult`, `throughputFailure`, `newHTTPDownloader`, `errNoOutbound`
- Consumes from existing tests: `fakeClock` and `newFakeClock` (`fakes_test.go:147-156`), `memLogger` with `snapshot()`/`has()` (`failover_test.go:84-118`), `fakeOutbounds` (`fakes_test.go:135`), `measured` (`fakes_test.go:143`)

- [ ] **Step 1: Write the failing strategy tests**

Create `protocol/group/balancer/throughput_test.go`:

```go
package balancer

import (
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
	N "github.com/sagernet/sing/common/network"
)

// tpResult builds a fake measurement whose mbps() is exactly the value asked for: Timed is the
// rate in bytes and Elapsed is one second, so the division is exact and the hysteresis
// comparisons of these tests are not decided by float error.
func tpResult(mbps float64) throughputResult {
	return throughputResult{Bytes: 3_000_000, Timed: int64(mbps * 1e6), Elapsed: time.Second, Status: 200}
}

// fakeDownloader answers from a table and fails the test if it is ever entered twice at once: two
// downloads share the uplink and would measure each other.
type fakeDownloader struct {
	t *testing.T

	mu      sync.Mutex
	results map[string]throughputResult
	errs    map[string]error
	block   map[string]chan struct{}
	calls   []string

	inside atomic.Bool
}

func newFakeDownloader(t *testing.T) *fakeDownloader {
	return &fakeDownloader{
		t:       t,
		results: map[string]throughputResult{},
		errs:    map[string]error{},
		block:   map[string]chan struct{}{},
	}
}

func (d *fakeDownloader) Download(ctx context.Context, tag, url string) (throughputResult, error) {
	if !d.inside.CompareAndSwap(false, true) {
		d.t.Errorf("two downloads at once, the second one for %q", tag)
	}
	defer d.inside.Store(false)
	d.mu.Lock()
	d.calls = append(d.calls, tag)
	gate := d.block[tag]
	d.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			// A cancelled download still received bytes, and they are still charged.
			return throughputResult{Bytes: 100_000}, ctx.Err()
		}
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if err := d.errs[tag]; err != nil {
		return d.results[tag], err
	}
	res, ok := d.results[tag]
	if !ok {
		return throughputResult{}, errNoOutbound
	}
	return res, nil
}

func (d *fakeDownloader) set(tag string, mbps float64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.results[tag] = tpResult(mbps)
	delete(d.errs, tag)
}

func (d *fakeDownloader) fail(tag string, res throughputResult, err error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.results[tag] = res
	if err != nil {
		d.errs[tag] = err
	} else {
		delete(d.errs, tag)
	}
}

func (d *fakeDownloader) blockOn(tag string) chan struct{} {
	gate := make(chan struct{})
	d.mu.Lock()
	d.block[tag] = gate
	d.mu.Unlock()
	return gate
}

func (d *fakeDownloader) callList() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.calls...)
}

// idleSleep is a virtual sleep that does not move the clock. These tests set the clock
// explicitly, and the gate watcher of Task 5 polls once a second: advancing the clock on every
// poll would drift the dwell assertions.
func idleSleep(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Millisecond):
		return nil
	}
}

func newThroughputHarness(t *testing.T, tags ...string) (*Throughput, *fakeDownloader, *memLogger, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	logger := &memLogger{}
	tp := NewThroughput(fakeOutbounds(tags...), option.BalancerOutboundOptions{
		ActiveCheckInterval: badoption.Duration(-1),
	}, logger)
	tp.setClock(clock.Now, idleSleep)
	tp.ld.setClock(clock.Now)
	d := newFakeDownloader(t)
	tp.setDownloader(d)
	return tp, d, logger, clock
}

func countLines(l *memLogger, sub string) int {
	n := 0
	for _, line := range l.snapshot() {
		if strings.Contains(line, sub) {
			n++
		}
	}
	return n
}

func TestThroughputPicksTheFastestValue(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2", "s3")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"s1": measured(100, c.Now()), "s2": measured(150, c.Now()), "s3": measured(120, c.Now()),
	})
	if tp.Now() != "s1" {
		t.Fatalf("before any round the latency pick decides, got %q", tp.Now())
	}
	d.set("s1", 1.0)
	d.set("s2", 4.0)
	d.set("s3", 2.0)
	c.Advance(601 * time.Second)
	tp.runRound(context.Background())
	if tp.Now() != "s2" {
		t.Fatalf("the 4.0 MB/s server must be selected, got %q", tp.Now())
	}
	if got := tp.Candidates(""); len(got) != 3 || got[0] != "s2" || got[1] != "s3" || got[2] != "s1" {
		t.Fatalf("candidates must run by value descending, got %v", got)
	}
}

func TestThroughputHysteresis(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	d.set("s1", 4.0)
	d.set("s2", 4.9) // 22.5 % faster: under the 25 % hysteresis
	c.Advance(601 * time.Second)
	tp.runRound(context.Background())
	if tp.Now() != "s1" {
		t.Fatalf("22.5 percent is under the hysteresis, got %q", tp.Now())
	}
	d.set("s2", 5.0) // exactly 25 %
	c.Advance(601 * time.Second)
	tp.runRound(context.Background())
	if tp.Now() != "s2" {
		t.Fatalf("25 percent must switch, got %q", tp.Now())
	}
}

func TestThroughputMinDwell(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	d.set("s1", 4.0)
	d.set("s2", 5.6) // 40 % faster
	c.Advance(599 * time.Second)
	tp.runRound(context.Background())
	if tp.Now() != "s1" {
		t.Fatalf("599 s is inside the 600 s dwell, got %q", tp.Now())
	}
	c.Advance(time.Second)
	tp.runRound(context.Background())
	if tp.Now() != "s2" {
		t.Fatalf("at 600 s the switch must happen, got %q", tp.Now())
	}
	events := tp.Events()
	if len(events) == 0 || events[0].Reason != reasonBetterThroughput {
		t.Fatalf("events = %+v, want a better_throughput switch", events)
	}
}

func TestThroughputSwitchesWhenCurrentHasNoValue(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	d.fail("s1", throughputResult{Bytes: 300_000, Status: 200}, nil) // short: no value for the current server
	d.set("s2", 1.1)                                                 // only 10 % faster than nothing in particular
	c.Advance(10 * time.Second)                                      // far inside the dwell
	tp.runRound(context.Background())
	if tp.Now() != "s2" {
		t.Fatalf("a missing current value is a failure state, not an optimisation: now=%q", tp.Now())
	}
}

func TestThroughputSelectNeverWaitsForARound(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	if tp.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag() != "s1" {
		t.Fatal("the provisional pick must answer before anything is measured")
	}
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(300, c.Now()), "s2": measured(100, c.Now())})
	if tp.Select(adapter.InboundContext{}, N.NetworkTCP, true).Tag() != "s2" {
		t.Fatal("after the first sweep Select answers with the lowest-delay server")
	}
	gate := d.blockOn("s2")
	d.set("s1", 1.0)
	d.set("s2", 1.0)
	done := make(chan struct{})
	go func() { defer close(done); tp.runRound(context.Background()) }()
	deadline := time.Now().Add(2 * time.Second)
	for len(d.callList()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the round never started")
		}
		time.Sleep(time.Millisecond)
	}
	// The round is now stuck inside a download; Select must still answer.
	if tp.Select(adapter.InboundContext{}, N.NetworkTCP, true) == nil {
		t.Fatal("Select blocked on a running round")
	}
	close(gate)
	<-done
}

func TestThroughputIgnoresLatencyAfterARound(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	d.set("s1", 1.0)
	d.set("s2", 6.0)
	c.Advance(601 * time.Second)
	tp.runRound(context.Background())
	if tp.Now() != "s2" {
		t.Fatalf("now=%q", tp.Now())
	}
	c.Advance(601 * time.Second)
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(20, c.Now()), "s2": measured(400, c.Now())})
	if tp.Now() != "s2" {
		t.Fatalf("a latency difference must never move a throughput selection, got %q", tp.Now())
	}
}

func TestThroughputInvalidateClearsTheTable(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(200, c.Now()), "s2": measured(100, c.Now())})
	d.set("s1", 6.0)
	d.set("s2", 1.0)
	c.Advance(601 * time.Second)
	tp.runRound(context.Background())
	if tp.Now() != "s1" {
		t.Fatalf("now=%q", tp.Now())
	}
	tp.invalidate()
	if got := tp.Candidates(""); len(got) != 2 || got[0] != "s2" {
		t.Fatalf("with an empty table the ranker falls back to latency, got %v", got)
	}
	tp.ld.lock()
	armed, values := tp.roundArmed, len(tp.values)
	tp.ld.unlock()
	if !armed || values != 0 {
		t.Fatalf("invalidate must clear the table and arm a round: armed=%v values=%d", armed, values)
	}
}
```

- [ ] **Step 2: Run it and see it fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run TestThroughput -count=1
```

Expected: build failure, `undefined: NewThroughput`, `undefined: Throughput`, `tp.setDownloader undefined`, `tp.runRound undefined`, `tp.invalidate undefined`.

- [ ] **Step 3: Create `throughput.go`**

```go
package balancer

import (
	"context"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	N "github.com/sagernet/sing/common/network"
)

// tpValue is one measurement of one server. ok=false is a failed measurement: the tag counts as
// having no value, so latency decides its place among the unmeasured.
type tpValue struct {
	mbps float64
	at   time.Time
	ok   bool
}

// Throughput selects by measured download throughput. It embeds LowestDelay and delegates every
// failoverStrategy method to it, so latency, health, failure marks, per-network selection and the
// switch event buffer stay in one place: there is no second URL-test path and no second copy of
// the switch bookkeeping.
type Throughput struct {
	ld     *LowestDelay
	cfg    throughputConfig
	logger failoverLogger

	dlMu sync.Mutex
	dl   downloader

	clockMu sync.Mutex
	now     func() time.Time
	sleepFn func(ctx context.Context, d time.Duration) error

	notifyMu sync.Mutex
	notify   func()

	// values, roundArmed, armedAt, lastRound and failStreak are guarded by ld.mu: the ranker
	// reads the table while holding that lock and the scheduler writes it while calling ld
	// methods, so a second lock would be a lock-order cycle.
	values     map[string]tpValue
	roundArmed bool
	armedAt    time.Time
	lastRound  time.Time
	failStreak int
}

var (
	_ Strategy         = (*Throughput)(nil)
	_ failoverStrategy = (*Throughput)(nil)
)

func NewThroughput(outbounds []adapter.Outbound, options option.BalancerOutboundOptions, logger failoverLogger) *Throughput {
	ld := NewLowestDelay(outbounds, options)
	t := &Throughput{
		ld:      ld,
		cfg:     normalizeThroughput(options, len(outbounds)),
		logger:  logger,
		now:     time.Now,
		sleepFn: sleepCtx,
		values:  map[string]tpValue{},
		// The first activation of the balancer runs a full round.
		roundArmed: true,
	}
	t.dl = newHTTPDownloader(ld.outboundByTag)
	ld.setRanker(throughputRanker{t})
	return t
}

// --- failoverStrategy and Strategy, all delegated ---

func (t *Throughput) Now() string                        { return t.ld.Now() }
func (t *Throughput) IsSelected(tag string) bool         { return t.ld.IsSelected(tag) }
func (t *Throughput) Healthy(tag string) bool            { return t.ld.Healthy(tag) }
func (t *Throughput) Candidates(exclude string) []string { return t.ld.Candidates(exclude) }
func (t *Throughput) Events() []switchEvent              { return t.ld.Events() }
func (t *Throughput) config() failoverConfig             { return t.ld.config() }

func (t *Throughput) MarkFailed(tag, reason string) (bool, bool) { return t.ld.MarkFailed(tag, reason) }

func (t *Throughput) ForceSelect(tag, reason string, delay uint16) bool {
	return t.ld.ForceSelect(tag, reason, delay)
}

func (t *Throughput) Select(metadata adapter.InboundContext, network string, touch bool) adapter.Outbound {
	return t.ld.Select(metadata, network, touch)
}

// UpdateOutboundsInfo keeps latency as a health signal only: a dead or unmeasured server must
// never be selected, but a latency difference never moves a throughput selection. That is why the
// tolerance arm of LowestDelay is not called here.
func (t *Throughput) UpdateOutboundsInfo(history map[string]*adapter.URLTestHistory) bool {
	t.ld.ingest(history)
	return t.ld.promoteHealthy()
}

// --- seams ---

func (t *Throughput) setClock(now func() time.Time, sleep func(ctx context.Context, d time.Duration) error) {
	t.clockMu.Lock()
	defer t.clockMu.Unlock()
	if now != nil {
		t.now = now
	}
	if sleep != nil {
		t.sleepFn = sleep
	}
}

func (t *Throughput) setDownloader(d downloader) {
	t.dlMu.Lock()
	t.dl = d
	t.dlMu.Unlock()
}

// setNotify installs what runs after a switch the strategy made itself: the Balancer drains the
// controller's event buffer, so the failover line is logged and counted at once, and interrupts
// the live connections.
func (t *Throughput) setNotify(fn func()) {
	t.notifyMu.Lock()
	t.notify = fn
	t.notifyMu.Unlock()
}

func (t *Throughput) timeNow() time.Time {
	t.clockMu.Lock()
	defer t.clockMu.Unlock()
	return t.now()
}

func (t *Throughput) sleep(ctx context.Context, d time.Duration) error {
	t.clockMu.Lock()
	sleep := t.sleepFn
	t.clockMu.Unlock()
	return sleep(ctx, d)
}

func (t *Throughput) download(ctx context.Context, tag string) (throughputResult, error) {
	t.dlMu.Lock()
	dl := t.dl
	t.dlMu.Unlock()
	return dl.Download(ctx, tag, t.cfg.testURL)
}

func (t *Throughput) runNotify() {
	t.notifyMu.Lock()
	fn := t.notify
	t.notifyMu.Unlock()
	if fn != nil {
		fn()
	}
}

// --- ranker ---

// throughputRanker puts healthy tags with a known value first, sorted by MB/s descending, then
// healthy tags without a value sorted by delay ascending, then unknown or failed tags in
// configuration order. Every failover path (dial error, stall, network change, rescue) goes
// through it, so all of them prefer the fastest known server and fall back to latency where
// nothing was measured.
type throughputRanker struct{ t *Throughput }

func (r throughputRanker) best(network, exclude string) (adapter.Outbound, uint16) {
	ld := r.t.ld
	var (
		best      adapter.Outbound
		bestValue float64
		bestDelay uint16
	)
	for _, o := range ld.outbounds[network] {
		tag := o.Tag()
		if tag == exclude || !ld.healthyLocked(tag) {
			continue
		}
		v, ok := r.t.values[tag]
		if !ok || !v.ok {
			continue
		}
		if best == nil || v.mbps > bestValue {
			delay, _ := ld.measuredLocked(tag)
			best, bestValue, bestDelay = o, v.mbps, delay
		}
	}
	if best != nil {
		return best, bestDelay
	}
	// Nothing measured on this network yet: latency is the only ordering there is.
	return ld.bestByLatencyLocked(network, exclude)
}

func (r throughputRanker) order(exclude string) []string {
	ld := r.t.ld
	byLatency := ld.orderByLatencyLocked(exclude)
	withValue := make([]string, 0, len(byLatency))
	withoutValue := make([]string, 0, len(byLatency))
	for _, tag := range byLatency {
		if v, ok := r.t.values[tag]; ok && v.ok && ld.healthyLocked(tag) {
			withValue = append(withValue, tag)
			continue
		}
		withoutValue = append(withoutValue, tag)
	}
	sort.SliceStable(withValue, func(i, j int) bool {
		return r.t.values[withValue[i]].mbps > r.t.values[withValue[j]].mbps
	})
	return append(withValue, withoutValue...)
}

// --- rounds ---

// shortlist is the first cfg.shortlist healthy candidates in latency order. Latency order, not
// the installed ranker's order: measuring only the servers that already hold the best values
// would never discover a faster one.
func (t *Throughput) shortlist() []string {
	out := make([]string, 0, t.cfg.shortlist)
	for _, tag := range t.ld.orderByLatency("") {
		if !t.ld.Healthy(tag) {
			continue
		}
		out = append(out, tag)
		if len(out) >= t.cfg.shortlist {
			break
		}
	}
	return out
}

// runRound measures every shortlisted server in order and re-evaluates the selection. It is the
// only writer of the value table and runs on one goroutine, so measurements never overlap: two
// downloads share the uplink and would measure each other.
func (t *Throughput) runRound(ctx context.Context) {
	now := t.timeNow()
	t.ld.lock()
	t.lastRound = now
	t.ld.unlock()
	measured := 0
	for _, tag := range t.shortlist() {
		if t.measure(ctx, tag) {
			measured++
		}
	}
	t.ld.lock()
	if measured > 0 {
		t.roundArmed = false
		t.armedAt = time.Time{}
		t.failStreak = 0
	}
	t.ld.unlock()
	if measured == 0 {
		return
	}
	t.evaluate()
}

// measure runs one download and records its outcome. It reports whether a value was recorded.
func (t *Throughput) measure(ctx context.Context, tag string) bool {
	res, err := t.download(ctx, tag)
	now := t.timeNow()
	if reason := throughputFailure(res, err, throughputMinBytes); reason != "" {
		t.logger.Info("throughput: ", tag, " failed reason=", reason)
		t.ld.lock()
		t.values[tag] = tpValue{at: now}
		t.ld.unlock()
		return false
	}
	mbps := res.mbps()
	t.logger.Info("throughput: ", tag, " ", strconv.FormatFloat(mbps, 'f', 1, 64),
		" bytes=", res.Bytes, " took=", res.Elapsed.Milliseconds(), "ms")
	t.ld.lock()
	t.values[tag] = tpValue{mbps: mbps, at: now, ok: true}
	t.ld.unlock()
	return true
}

// evaluate decides whether the round's numbers justify a switch and performs it. A current
// selection with no valid value is a failure state, not an optimisation, so it moves at once,
// ignoring hysteresis and dwell. The switch carries delay 0: the round measured bandwidth, not
// latency, and the latency history must stay untouched.
func (t *Throughput) evaluate() {
	now := t.timeNow()
	t.ld.lock()
	current := t.ld.currentLocked()
	var (
		bestTag   string
		bestValue float64
	)
	for _, o := range t.ld.outbounds[N.NetworkTCP] {
		tag := o.Tag()
		v, ok := t.values[tag]
		if !ok || !v.ok || !t.ld.healthyLocked(tag) {
			continue
		}
		if bestTag == "" || v.mbps > bestValue {
			bestTag, bestValue = tag, v.mbps
		}
	}
	currentValue, hasCurrent := t.values[current]
	dwell := t.ld.sinceLastSwitchLocked(now)
	t.ld.unlock()

	if bestTag == "" || bestTag == current {
		return
	}
	if hasCurrent && currentValue.ok {
		if bestValue < currentValue.mbps*(1+float64(t.cfg.hysteresisPct)/100) {
			return
		}
		if dwell < t.cfg.minDwell {
			return
		}
	}
	if t.ld.ForceSelect(bestTag, reasonBetterThroughput, 0) {
		t.runNotify()
	}
}

// invalidate drops every measured value and arms a full round. An interface change means the
// numbers were measured on a network that no longer exists; until the new round lands the ranker
// falls back to latency, which is right on a network nothing was measured on. The budget counter
// is not cleared: those bytes were really spent.
func (t *Throughput) invalidate() {
	t.ld.lock()
	t.values = map[string]tpValue{}
	t.roundArmed = true
	t.armedAt = time.Time{}
	t.lastRound = time.Time{}
	t.failStreak = 0
	t.ld.unlock()
}
```

- [ ] **Step 4: Run the tests and see them pass**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run TestThroughput -count=1 -v
go test ./protocol/group/balancer/ -count=1
go vet ./protocol/group/balancer/
```

Expected: `--- PASS` for `TestThroughputPicksTheFastestValue`, `TestThroughputHysteresis`, `TestThroughputMinDwell`, `TestThroughputSwitchesWhenCurrentHasNoValue`, `TestThroughputSelectNeverWaitsForARound`, `TestThroughputIgnoresLatencyAfterARound`, `TestThroughputInvalidateClearsTheTable`, plus the Task 2 option tests; `ok` for the package.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git add protocol/group/balancer/throughput.go protocol/group/balancer/throughput_test.go
git commit -m "feat(balancer): стратегия throughput — таблица значений, ранжирование, раунд" -m "Throughput встраивает LowestDelay и делегирует ему все восемь методов интерфейса, добавляя таблицу измеренных скоростей под тем же замком и ranker, который ставит измеренные серверы вперёд по МБ/с, а неизмеренные — по задержке. UpdateOutboundsInfo вызывает только ingest и promoteHealthy: задержка остаётся признаком живости, но выбор не двигает. Полный раунд меряет шорт-лист, отсортированный по задержке, и переключается при запасе 25 % и dwell 600 с; отсутствие значения у текущего сервера переключает сразу." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

---

### Task 5: Scheduler, budget ring, gates, backoff, aborts and log lines

**Files:**
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/budget.go`
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/budget_test.go`
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/throughput.go` (struct, new seams, `start`/`stop`/`loop`/`tick`/`recheck`, budget in `runRound` and `measure`, `stats`)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/throughput_test.go` (append tests)

**Interfaces:**
- Produces: `type budgetRing struct` with `hourOf(t time.Time) int64`, `(*budgetRing).advance(hour int64)`, `charge(hour int64, n int64)`, `spent(hour int64) int64`
- Produces on `*Throughput`: `start(ctx context.Context)`, `stop()`, `tick()`, `recheck(ctx context.Context, tag string, previous float64)`, `reserve() bool`, `charge(n int64)`, `abortReason() string`, `measureCtx(parent context.Context) (context.Context, context.CancelFunc)`, `setPaused(fn func() bool)`, `setActive(fn func() bool)`, `setRescuing(fn func() bool)`, `onFailoverSwitch()`, `armRound(at time.Time)`, `stats() tpStats`
- Produces: `type tpStats struct { probes uint64; bytes int64; budgetLeft int64; ok bool }`, `failBackoff(streak int) time.Duration`, `mbString(bytes int64) string`
- Consumes: `throughputTick` (30 s), `throughputRoundFloor` (300 s), `throughputGateTick` (1 s), `throughputFailBackoffMin` (600 s), `throughputFailBackoffMax` (7200 s) from Task 2
- Consumes from the tests: `waitUntil(t *testing.T, what string, cond func() bool)` at `failover_test.go:440`

Log lines produced here, exactly:

```
throughput: budget exhausted spent_mb=<x> cap_mb=<n>
throughput: <tag> aborted reason=<paused|inactive|rescue|stopped> bytes=<n>
```

- [ ] **Step 1: Write the failing budget-ring test**

Create `protocol/group/balancer/budget_test.go`:

```go
package balancer

import "testing"

func TestBudgetRingHoldsOneDay(t *testing.T) {
	var b budgetRing
	base := int64(1_700_000_000 / 3600)
	b.charge(base, 3_000_000)
	b.charge(base, 3_000_000)
	if got := b.spent(base); got != 6_000_000 {
		t.Fatalf("spent = %d, want 6000000", got)
	}
	if got := b.spent(base + 23); got != 6_000_000 {
		t.Fatalf("still inside the 24 h window: spent = %d", got)
	}
	if got := b.spent(base + 24); got != 0 {
		t.Fatalf("the bucket must roll out after 24 h, spent = %d", got)
	}
}

func TestBudgetRingZeroesSkippedHours(t *testing.T) {
	var b budgetRing
	base := int64(100_000)
	b.charge(base, 1000)
	b.charge(base+3, 2000)
	if got := b.spent(base + 3); got != 3000 {
		t.Fatalf("spent = %d, want 3000", got)
	}
	if got := b.spent(base + 24); got != 2000 {
		t.Fatalf("only the oldest charge rolls out, spent = %d", got)
	}
	if got := b.spent(base + 27); got != 0 {
		t.Fatalf("spent = %d, want 0", got)
	}
}

func TestBudgetRingJumpOfMoreThanADayClears(t *testing.T) {
	var b budgetRing
	base := int64(100_000)
	b.charge(base, 5000)
	if got := b.spent(base + 500); got != 0 {
		t.Fatalf("a jump past the whole ring clears it, spent = %d", got)
	}
	b.charge(base+500, 7000)
	if got := b.spent(base + 500); got != 7000 {
		t.Fatalf("spent = %d, want 7000", got)
	}
}
```

- [ ] **Step 2: Run it and see it fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run TestBudgetRing -count=1
```

Expected: build failure, `undefined: budgetRing`.

- [ ] **Step 3: Create `budget.go`**

```go
package balancer

import "time"

// budgetRing is a rolling 24 h byte counter: 24 hourly buckets plus the index and hour number of
// the newest one. Bounded memory, O(24) to read, and hour granularity is far finer than a
// 100 MB/day cap needs. The counter lives in memory only and resets with the core process, so a
// restart loop can exceed the nominal daily cap; the exposure is bounded, one full round costs at
// most three probes, and persisting it would mean a new on-disk file in the core.
//
// Every method takes the hour number of "now" from the caller, so the ring never reads a clock of
// its own and the tests stay deterministic. The instance inside Throughput is guarded by ld.mu.
type budgetRing struct {
	buckets [24]int64
	idx     int
	hour    int64
	started bool
}

func hourOf(t time.Time) int64 { return t.Unix() / 3600 }

// advance rolls the ring forward to hour, zeroing the buckets of every hour that passed.
func (b *budgetRing) advance(hour int64) {
	if !b.started {
		b.started = true
		b.hour = hour
		b.idx = 0
		b.buckets = [24]int64{}
		return
	}
	if hour <= b.hour {
		return
	}
	steps := hour - b.hour
	if steps >= 24 {
		b.buckets = [24]int64{}
		b.idx = 0
		b.hour = hour
		return
	}
	for i := int64(0); i < steps; i++ {
		b.idx = (b.idx + 1) % 24
		b.buckets[b.idx] = 0
	}
	b.hour = hour
}

func (b *budgetRing) charge(hour int64, n int64) {
	b.advance(hour)
	b.buckets[b.idx] += n
}

func (b *budgetRing) spent(hour int64) int64 {
	b.advance(hour)
	var total int64
	for _, v := range b.buckets {
		total += v
	}
	return total
}
```

- [ ] **Step 4: Run the budget test and see it pass**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run TestBudgetRing -count=1 -v
```

Expected: three `--- PASS` lines.

- [ ] **Step 5: Write the failing scheduler tests**

Append to `protocol/group/balancer/throughput_test.go` (the imports `errors` and `sync/atomic` are already needed by the file; add `errors` if it is not there yet):

```go
func TestThroughputTickIsGated(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	d.set("s1", 1.0)
	d.set("s2", 2.0)

	paused, inactive, rescuing := true, false, false
	tp.setPaused(func() bool { return paused })
	tp.setActive(func() bool { return !inactive })
	tp.setRescuing(func() bool { return rescuing })

	tp.tick()
	if n := len(d.callList()); n != 0 {
		t.Fatalf("a paused balancer must not download, calls=%d", n)
	}
	paused, inactive = false, true
	tp.tick()
	if n := len(d.callList()); n != 0 {
		t.Fatalf("an idle balancer must not download, calls=%d", n)
	}
	inactive, rescuing = false, true
	tp.tick()
	if n := len(d.callList()); n != 0 {
		t.Fatalf("a rescue scan owns the uplink, calls=%d", n)
	}
	rescuing = false
	tp.tick()
	if got := d.callList(); len(got) != 2 {
		t.Fatalf("with every gate open the armed round runs, calls=%v", got)
	}
}

func TestThroughputRoundIsSequential(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2", "s3")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"s1": measured(300, c.Now()), "s2": measured(100, c.Now()), "s3": measured(200, c.Now()),
	})
	d.set("s1", 1.0)
	d.set("s2", 1.0)
	d.set("s3", 1.0)
	tp.runRound(context.Background())
	got := d.callList()
	if len(got) != 3 || got[0] != "s2" || got[1] != "s3" || got[2] != "s1" {
		// The fake downloader fails the test on its own if two calls ever overlap.
		t.Fatalf("the round measures the latency shortlist in order, one at a time: %v", got)
	}
}

func TestThroughputBudgetExhaustion(t *testing.T) {
	tp, d, l, c := newThroughputHarness(t, "s1", "s2", "s3")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"s1": measured(100, c.Now()), "s2": measured(150, c.Now()), "s3": measured(120, c.Now()),
	})
	d.set("s1", 1.0)
	d.set("s2", 4.0)
	d.set("s3", 2.0)
	c.Advance(601 * time.Second)
	// 100 MB cap, 3 MB per measurement, 3 measurements per round: 11 rounds fit (99 MB), the
	// remaining 23 are blocked before they start.
	for i := 0; i < 34; i++ {
		tp.runRound(context.Background())
	}
	if n := len(d.callList()); n != 33 {
		t.Fatalf("measurements = %d, want 33", n)
	}
	if n := countLines(l, "throughput: budget exhausted"); n != 23 {
		t.Fatalf("budget lines = %d, want one per blocked round (23)", n)
	}
	if !l.has("cap_mb=100.0") {
		t.Fatalf("the budget line must carry the cap: %v", l.snapshot())
	}
	if tp.Now() != "s2" {
		t.Fatalf("the last known values keep ranking, now=%q", tp.Now())
	}
}

func TestThroughputDisabledBudgetNeverMeasures(t *testing.T) {
	tp, d, l, c := newThroughputHarness(t, "s1", "s2")
	tp.cfg.disabled = true
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	tp.tick()
	if n := len(d.callList()); n != 0 {
		t.Fatalf("a disabled budget measures nothing, calls=%d", n)
	}
	if n := countLines(l, "budget exhausted"); n != 0 {
		t.Fatal("a disabled budget is not an exhausted one")
	}
}

func TestThroughputAbortsWhenPausedMidDownload(t *testing.T) {
	tp, d, l, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	var paused atomic.Bool
	tp.setPaused(paused.Load)
	gate := d.blockOn("s1")
	d.set("s1", 1.0)
	d.set("s2", 2.0)
	done := make(chan struct{})
	go func() { defer close(done); tp.runRound(context.Background()) }()
	waitUntil(t, "the first download to start", func() bool { return len(d.callList()) > 0 })
	paused.Store(true)
	<-done
	close(gate)
	if !l.has("throughput: s1 aborted reason=paused bytes=100000") {
		t.Fatalf("lines: %v", l.snapshot())
	}
	tp.ld.lock()
	_, has := tp.values["s1"]
	tp.ld.unlock()
	if has {
		t.Fatal("an aborted measurement records no value")
	}
	if got := d.callList(); len(got) != 1 {
		t.Fatalf("the round stops at the abort, calls=%v", got)
	}
}

func TestThroughputFailureReasonsAndBackoff(t *testing.T) {
	tp, d, l, c := newThroughputHarness(t, "s1", "s2", "s3", "s4")
	tp.cfg.shortlist = 4 // measure all four so every failure reason appears once
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"s1": measured(100, c.Now()), "s2": measured(150, c.Now()),
		"s3": measured(200, c.Now()), "s4": measured(250, c.Now()),
	})
	d.fail("s1", throughputResult{Bytes: 300_000, Status: 200}, nil)
	d.fail("s2", throughputResult{Bytes: 600_000, Status: 200}, context.DeadlineExceeded)
	d.fail("s3", throughputResult{Status: 403}, nil)
	d.fail("s4", throughputResult{}, errors.New("refused"))
	tp.runRound(context.Background())
	for _, want := range []string{
		"throughput: s1 failed reason=short",
		"throughput: s2 failed reason=timeout",
		"throughput: s3 failed reason=http_403",
		"throughput: s4 failed reason=dial_error",
	} {
		if !l.has(want) {
			t.Fatalf("missing %q in %v", want, l.snapshot())
		}
	}
	tp.ld.lock()
	armed, at, streak := tp.roundArmed, tp.armedAt, tp.failStreak
	tp.ld.unlock()
	if !armed || streak != 1 || !at.Equal(c.Now().Add(10*time.Minute)) {
		t.Fatalf("an all-failed round re-arms after 600 s: armed=%v streak=%d at=%v", armed, streak, at)
	}
	tp.runRound(context.Background())
	tp.ld.lock()
	at, streak = tp.armedAt, tp.failStreak
	tp.ld.unlock()
	if streak != 2 || !at.Equal(c.Now().Add(20*time.Minute)) {
		t.Fatalf("the backoff doubles: streak=%d at=%v", streak, at)
	}
	d.set("s1", 2.0)
	tp.runRound(context.Background())
	tp.ld.lock()
	armed, streak = tp.roundArmed, tp.failStreak
	tp.ld.unlock()
	if armed || streak != 0 {
		t.Fatalf("a round with a value resets the streak: armed=%v streak=%d", armed, streak)
	}
}

func TestThroughputRecheck(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	d.set("s1", 4.0)
	d.set("s2", 1.0)
	tp.tick() // the armed first round
	if tp.Now() != "s1" {
		t.Fatalf("now=%q", tp.Now())
	}
	c.Advance(2 * time.Hour)
	d.set("s1", 2.4) // a 40 % drop
	tp.tick()
	tp.ld.lock()
	armed := tp.roundArmed
	tp.ld.unlock()
	if armed {
		t.Fatal("a 40 percent drop must not arm a full round")
	}
	if got := d.callList(); got[len(got)-1] != "s1" || len(got) != 3 {
		t.Fatalf("the recheck measures only the current server: %v", got)
	}
	c.Advance(2 * time.Hour)
	d.set("s1", 1.1) // less than half of 2.4
	tp.tick()
	tp.ld.lock()
	armed = tp.roundArmed
	tp.ld.unlock()
	if !armed {
		t.Fatal("a halved value must arm a full round")
	}
}

func TestThroughputFailoverSwitchArmsARoundAfterTheDwell(t *testing.T) {
	tp, _, _, c := newThroughputHarness(t, "s1", "s2")
	tp.ld.lock()
	tp.roundArmed = false
	tp.ld.unlock()
	tp.onFailoverSwitch()
	tp.ld.lock()
	armed, at := tp.roundArmed, tp.armedAt
	tp.ld.unlock()
	if !armed || !at.Equal(c.Now().Add(10*time.Minute)) {
		t.Fatalf("a failover switch arms a round one dwell later: armed=%v at=%v", armed, at)
	}
}

func TestThroughputStartStopIsIdempotent(t *testing.T) {
	tp, _, _, _ := newThroughputHarness(t, "s1", "s2")
	tp.start(context.Background())
	tp.stop()
	tp.stop()
}
```

- [ ] **Step 6: Run them and see them fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run 'TestThroughput(TickIsGated|BudgetExhaustion|Aborts|FailureReasons|Recheck|StartStop|Failover|DisabledBudget|RoundIsSequential)' -count=1
```

Expected: build failure, `tp.setPaused undefined`, `tp.tick undefined`, `tp.start undefined`, `tp.onFailoverSwitch undefined`, `tp.cfg.disabled` assignment fine but `tp.stop undefined`.

- [ ] **Step 7: Extend `throughput.go` with the gates, the budget and the scheduler**

Add to the imports: `"sync/atomic"`. Add to the struct, after `notify`:

```go
	// The gate predicates are installed by the Balancer after construction; the scheduler reads
	// them from its own goroutine. A nil predicate means the gate is open.
	hookMu   sync.Mutex
	paused   func() bool
	active   func() bool
	rescuing func() bool

	ctx      context.Context
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	stopOnce sync.Once

	cProbes atomic.Uint64
	cBytes  atomic.Int64
```

and to the ld.mu-guarded block:

```go
	budget     budgetRing
```

Add the new methods:

```go
// tpStats is the throughput half of the diag line. ok=false makes the fields print n/a, the
// convention rss_mb and cpu_s already use, so field positions stay stable for parsers.
type tpStats struct {
	probes     uint64
	bytes      int64
	budgetLeft int64
	ok         bool
}

func (t *Throughput) setPaused(fn func() bool)   { t.hookMu.Lock(); t.paused = fn; t.hookMu.Unlock() }
func (t *Throughput) setActive(fn func() bool)   { t.hookMu.Lock(); t.active = fn; t.hookMu.Unlock() }
func (t *Throughput) setRescuing(fn func() bool) { t.hookMu.Lock(); t.rescuing = fn; t.hookMu.Unlock() }

func (t *Throughput) isPaused() bool {
	t.hookMu.Lock()
	fn := t.paused
	t.hookMu.Unlock()
	return fn != nil && fn()
}

func (t *Throughput) isActive() bool {
	t.hookMu.Lock()
	fn := t.active
	t.hookMu.Unlock()
	return fn == nil || fn()
}

func (t *Throughput) isRescuing() bool {
	t.hookMu.Lock()
	fn := t.rescuing
	t.hookMu.Unlock()
	return fn != nil && fn()
}

// needsWatch reports whether any gate can close under a running download. Without a gate there is
// nothing to watch and no watcher goroutine is started.
func (t *Throughput) needsWatch() bool {
	t.hookMu.Lock()
	defer t.hookMu.Unlock()
	return t.paused != nil || t.active != nil || t.rescuing != nil
}

// abortReason names the gate that closed under a measurement, or "" while all of them are open.
// An aborted measurement charges its bytes and records no value; it is not a failure and does not
// affect ranking.
func (t *Throughput) abortReason() string {
	if t.ctx != nil && t.ctx.Err() != nil {
		return "stopped"
	}
	if t.isPaused() {
		return "paused"
	}
	if t.isRescuing() {
		// Rescue traffic and a 3 MB download must not share the uplink, and rescue is the
		// more urgent of the two.
		return "rescue"
	}
	if !t.isActive() {
		return "inactive"
	}
	return ""
}

func (t *Throughput) rootCtx() context.Context {
	if t.ctx != nil {
		return t.ctx
	}
	return context.Background()
}

// start launches the scheduler on the balancer context. A negative daily budget disables
// measurement entirely: say so once and behave as a latency balancer with an empty table.
func (t *Throughput) start(ctx context.Context) {
	t.ctx, t.cancel = context.WithCancel(ctx)
	if t.cfg.disabled {
		t.logger.Warn("throughput: measurement is disabled by a negative daily budget, ranking falls back to latency")
		return
	}
	t.wg.Add(1)
	go func() {
		defer t.wg.Done()
		t.loop()
	}()
}

// stop cancels the scheduler and the download in flight and waits for the goroutine, the way the
// failover controller's stop does.
func (t *Throughput) stop() {
	t.stopOnce.Do(func() {
		if t.cancel != nil {
			t.cancel()
		}
		t.wg.Wait()
	})
}

// loop wakes on one 30 s tick instead of several timers: 30 s is 0.4 % of the 7200 s recheck
// interval, so the scheduling error is irrelevant.
func (t *Throughput) loop() {
	for {
		if err := t.sleep(t.ctx, throughputTick); err != nil {
			return
		}
		t.tick()
	}
}

// tick is one scheduler wakeup: the gates first, then an armed full round, then the periodic
// recheck of the current server.
func (t *Throughput) tick() {
	if t.cfg.disabled || t.isPaused() || t.isRescuing() || !t.isActive() {
		return
	}
	now := t.timeNow()
	t.ld.lock()
	armed := t.roundArmed
	due := !now.Before(t.armedAt)
	floorOK := t.lastRound.IsZero() || now.Sub(t.lastRound) >= throughputRoundFloor
	current := t.ld.currentLocked()
	value, hasValue := t.values[current]
	t.ld.unlock()

	switch {
	case armed && due && floorOK:
		t.runRound(t.rootCtx())
	case !armed && t.cfg.recheck > 0 && hasValue && value.ok && now.Sub(value.at) >= t.cfg.recheck:
		t.recheck(t.rootCtx(), current, value.mbps)
	}
}

// recheck re-measures only the current server. A value that halved says the link changed under
// us, which is worth the three measurements of a full round; a smaller drop is not.
func (t *Throughput) recheck(ctx context.Context, tag string, previous float64) {
	if !t.reserve() {
		return
	}
	if !t.measure(ctx, tag) {
		// A failed recheck leaves the current server without a valid value, which the next
		// round treats as a failure state and may act on without hysteresis or dwell. It is
		// not reported to the failover controller: a failed download is not proof of a dead
		// server, and the controller has its own probe.
		return
	}
	now := t.timeNow()
	t.ld.lock()
	if v := t.values[tag]; v.ok && v.mbps < previous/2 {
		t.roundArmed = true
		t.armedAt = now
	}
	t.ld.unlock()
}

// reserve reports whether the budget has room for one measurement. A blocked round says so once
// and keeps ranking with the values it has; where a candidate has no value, latency fills in.
func (t *Throughput) reserve() bool {
	if t.cfg.disabled {
		return false
	}
	now := t.timeNow()
	t.ld.lock()
	spent := t.budget.spent(hourOf(now))
	t.ld.unlock()
	if spent+t.cfg.probeBytes <= t.cfg.budgetBytes {
		return true
	}
	t.logger.Info("throughput: budget exhausted spent_mb=", mbString(spent), " cap_mb=", mbString(t.cfg.budgetBytes))
	return false
}

// charge books every byte that actually arrived: warm-up bytes and the partial bytes of a failed
// or aborted measurement included.
func (t *Throughput) charge(n int64) {
	if n <= 0 {
		return
	}
	now := t.timeNow()
	t.ld.lock()
	t.budget.charge(hourOf(now), n)
	t.ld.unlock()
	t.cBytes.Add(n)
}

// measureCtx cancels the download when a gate closes under it. Without an installed gate there is
// nothing to poll, so no goroutine is started.
func (t *Throughput) measureCtx(parent context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(parent)
	if !t.needsWatch() {
		return ctx, cancel
	}
	go func() {
		for {
			if err := t.sleep(ctx, throughputGateTick); err != nil {
				return
			}
			if t.abortReason() != "" {
				cancel()
				return
			}
		}
	}()
	return ctx, cancel
}

// onFailoverSwitch arms a full round one min-dwell after a switch the controller made, so the
// round measures a settled selection. A rescue writes a latency value and never touches the
// throughput table, and that server may well be slower, which is why the round is armed at all.
func (t *Throughput) onFailoverSwitch() {
	t.armRound(t.timeNow().Add(t.cfg.minDwell))
}

func (t *Throughput) armRound(at time.Time) {
	t.ld.lock()
	t.roundArmed = true
	t.armedAt = at
	t.ld.unlock()
}

func (t *Throughput) stats() tpStats {
	now := t.timeNow()
	t.ld.lock()
	spent := t.budget.spent(hourOf(now))
	t.ld.unlock()
	left := t.cfg.budgetBytes - spent
	if left < 0 || t.cfg.disabled {
		left = 0
	}
	return tpStats{probes: t.cProbes.Load(), bytes: t.cBytes.Load(), budgetLeft: left, ok: true}
}

// failBackoff doubles from 600 s per consecutive all-failed round, capped at 7200 s.
func failBackoff(streak int) time.Duration {
	if streak < 1 {
		streak = 1
	}
	d := throughputFailBackoffMin
	for i := 1; i < streak; i++ {
		d *= 2
		if d >= throughputFailBackoffMax {
			return throughputFailBackoffMax
		}
	}
	return d
}

func mbString(bytes int64) string { return strconv.FormatFloat(float64(bytes)/1e6, 'f', 1, 64) }
```

- [ ] **Step 8: Put the budget and the aborts into `runRound` and `measure`**

Replace `runRound` and `measure` from Task 4 with:

```go
func (t *Throughput) runRound(ctx context.Context) {
	now := t.timeNow()
	t.ld.lock()
	// A blocked round still records the attempt, so the 300 s floor spaces the retries and the
	// budget line is not printed once per tick.
	t.lastRound = now
	t.ld.unlock()
	if !t.reserve() {
		return
	}
	measured := 0
	for _, tag := range t.shortlist() {
		if t.abortReason() != "" {
			// The round is left armed and resumes when the gate opens again.
			return
		}
		if !t.reserve() {
			break
		}
		if t.measure(ctx, tag) {
			measured++
		}
	}
	t.ld.lock()
	if measured > 0 {
		t.roundArmed = false
		t.armedAt = time.Time{}
		t.failStreak = 0
	} else {
		t.failStreak++
		t.roundArmed = true
		t.armedAt = now.Add(failBackoff(t.failStreak))
	}
	t.ld.unlock()
	if measured > 0 {
		t.evaluate()
	}
}

// measure runs one download and records its outcome. It reports whether a value was recorded.
func (t *Throughput) measure(ctx context.Context, tag string) bool {
	t.cProbes.Add(1)
	mctx, cancel := t.measureCtx(ctx)
	res, err := t.download(mctx, tag)
	cancel()
	t.charge(res.Bytes)
	if reason := t.abortReason(); reason != "" && err != nil {
		t.logger.Info("throughput: ", tag, " aborted reason=", reason, " bytes=", res.Bytes)
		return false
	}
	now := t.timeNow()
	if reason := throughputFailure(res, err, throughputMinBytes); reason != "" {
		t.logger.Info("throughput: ", tag, " failed reason=", reason)
		t.ld.lock()
		t.values[tag] = tpValue{at: now}
		t.ld.unlock()
		return false
	}
	mbps := res.mbps()
	t.logger.Info("throughput: ", tag, " ", strconv.FormatFloat(mbps, 'f', 1, 64),
		" bytes=", res.Bytes, " took=", res.Elapsed.Milliseconds(), "ms")
	t.ld.lock()
	t.values[tag] = tpValue{mbps: mbps, at: now, ok: true}
	t.ld.unlock()
	return true
}
```

- [ ] **Step 9: Run the whole package and see it pass**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -count=1 -v 2>&1 | tail -60
go test ./protocol/group/balancer/ -count=1 -race
go vet ./protocol/group/balancer/
```

Expected: every test green, including the Task 4 tests unchanged, and `-race` clean (the value table, the budget and the counters are the only shared state and all of them sit under `ld.mu` or an atomic).

- [ ] **Step 10: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git add protocol/group/balancer/budget.go protocol/group/balancer/budget_test.go protocol/group/balancer/throughput.go protocol/group/balancer/throughput_test.go
git commit -m "feat(balancer): планировщик замеров, суточный бюджет и отмены" -m "Тик раз в 30 с: сначала ворота (пауза, простой, идущий rescue, бюджет), затем взведённый полный раунд не чаще раза в 300 с, иначе перезамер текущего сервера раз в 7200 с. Бюджет — кольцо из 24 часовых корзин, 100 МБ на скользящие сутки, списываются все полученные байты. Раунд, где все замеры провалились, взводится заново через 600 с с удвоением до 7200 с. Закрывшиеся во время загрузки ворота отменяют её: байты списываются, значение не записывается, в лог идёт строка aborted." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

---

### Task 6: Balancer wiring, the idle rule and the log-format change

**Files:**
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/failover.go` (struct `:39-88`, `newFailover` `:90-112`, `activeCheckLoop` `:237-256`, `runRescue` `:392-427`, `logSwitchLine` `:569-571`, `logDiag` `:581-614`)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/balancer.go` (struct `:40-67`, `NewLoadBalance` `:80-100`, `Start` `:106-156`, `PostStart` `:158-166`, `InterfaceUpdated` `:208-213`, `Close` `:215-227`, the five select paths `:240-331`)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/failover_test.go` (`newHarness` `:130-146`, assertions at `:157`, `:185`, `:286`, `:653`, `:675`, `:684`)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/scenario_test.go` (append the fourth scenario)
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/throughput_test.go` (append the idle-rule test)

**Interfaces:**
- Produces: `newFailover(ctx context.Context, cfg failoverConfig, group string, strategy failoverStrategy, probe prober, logger failoverLogger, onSwitch func()) *failover` — `group` is new and second-to-last before the strategy
- Produces on `*failover`: `setActive(fn func() bool)`, `isActive() bool`, `setThroughputStats(fn func() tpStats)`, `rescuing() bool`
- Produces on `*Balancer`: `touch()`, `active() bool`, fields `tp *Throughput`, `lastDial atomic.Int64`, `nowFn func() time.Time`, `activeWindow time.Duration`
- Consumes: `Throughput.start(ctx)`, `stop()`, `invalidate()`, `stats()`, `setActive`, `setPaused`, `setRescuing`, `setNotify`, `onFailoverSwitch` (Tasks 4-5)

Log formats after this task, exactly:

```
failover: group=<tag> <from> -> <to> reason=<reason> took=<ms>ms
diag: group=<tag> current=<tag> probes_active=<n> probes_rescue=<n> probes_interface=<n> probes_ok=<n> probes_failed=<n> rescues=<n> rescue_exhausted=<n> stalls=<n> stalls_suppressed=<n> rss_mb=<x> cpu_s=<x> tp_probes=<n> tp_bytes_mb=<x> tp_budget_left_mb=<x> switches=<reason>=<n>,...
```

A `lowest` balancer prints `tp_probes=n/a tp_bytes_mb=n/a tp_budget_left_mb=n/a`, so field positions stay stable for parsers.

- [ ] **Step 1: Update the existing tests to the new format (they must fail first)**

In `failover_test.go`, pass the group tag from the harness:

```go
	f := newFailover(ctx, strategy.cfg, "lowest", strategy, p, l, func() {})
```

and update the six assertions:

- `:157` → `if !l.has("failover: group=lowest a -> b reason=dial_error took=0ms") {`
- `:185` → `if !l.has("failover: group=lowest a -> d reason=stall") {`
- `:286` → `if !l.has("diag: group=lowest current=a probes_active=0") || l.has("http") {`
- `:653` → `if !l.has("failover: group=lowest a -> b reason=stall") {`
- `:675` → `if !l.has(" rss_mb=100.0 cpu_s=12.5 tp_probes=n/a tp_bytes_mb=n/a tp_budget_left_mb=n/a switches=") {`
- `:684` → `if !l.has(" rss_mb=n/a cpu_s=n/a tp_probes=n/a tp_bytes_mb=n/a tp_budget_left_mb=n/a switches=") {`

Add two tests to `failover_test.go`:

```go
func TestActiveCheckSkipsAnIdleBalancer(t *testing.T) {
	f, s, p, _, c := newHarness(t, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now()), "b": measured(200, c.Now())})
	idle := true
	f.setActive(func() bool { return !idle })
	// The loop body without the loop: sleep, gates, probe.
	if f.isActive() {
		t.Fatal("the gate must report the balancer idle")
	}
	idle = false
	if !f.isActive() {
		t.Fatal("the gate must reopen once the balancer is active")
	}
	if len(p.callList()) != 0 {
		t.Fatalf("no probe may have run yet: %v", p.callList())
	}
}

func TestDiagLineCarriesThroughputFields(t *testing.T) {
	f, _, _, l, _ := newHarness(t, "a", "b")
	f.setThroughputStats(func() tpStats {
		return tpStats{probes: 7, bytes: 21_000_000, budgetLeft: 79_000_000, ok: true}
	})
	f.logDiag()
	if !l.has(" tp_probes=7 tp_bytes_mb=21.0 tp_budget_left_mb=79.0 switches=") {
		t.Fatalf("lines: %v", l.snapshot())
	}
}
```

- [ ] **Step 2: Run them and see them fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -count=1
```

Expected: build failure, `too many arguments in call to newFailover`, `f.setActive undefined`, `f.setThroughputStats undefined`.

- [ ] **Step 3: Add the group, the activity gate and the throughput stats to `failover.go`**

Add to the struct, next to `onSwitch`:

```go
	// group is the balancer tag. It prefixes every failover: and diag: line, so two balancers
	// in one log are distinguishable.
	group string
```

next to `readStats`:

```go
	// readThroughput is the throughput half of the diag line. The default reports ok=false, so
	// a lowest-delay balancer prints n/a in those three fields.
	readThroughput func() tpStats
```

and next to `resetStalls` under `hookMu`:

```go
	activeFn func() bool
```

Constructor:

```go
func newFailover(ctx context.Context, cfg failoverConfig, group string, strategy failoverStrategy, probe prober, logger failoverLogger, onSwitch func()) *failover {
	ctx, cancel := context.WithCancel(ctx)
	if onSwitch == nil {
		onSwitch = func() {}
	}
	return &failover{
		ctx:             ctx,
		cancel:          cancel,
		cfg:             cfg,
		group:           group,
		strategy:        strategy,
		probe:           probe,
		logger:          logger,
		onSwitch:        onSwitch,
		readStats:       readProcStats,
		readThroughput:  func() tpStats { return tpStats{} },
		paused:          func() bool { return false },
		networkPaused:   func() bool { return false },
		activeFn:        func() bool { return true },
		resetStalls:     func() {},
		now:             time.Now,
		sleepFn:         sleepCtx,
		switches:        map[string]uint64{},
		confirmingStall: map[string]struct{}{},
	}
}
```

New methods, next to `setPaused`:

```go
// setActive installs the idle-balancer gate. With two balancers in the config only one is
// selected, and the unselected one must not probe, rescue or measure.
func (f *failover) setActive(active func() bool) {
	if active == nil {
		return
	}
	f.hookMu.Lock()
	f.activeFn = active
	f.hookMu.Unlock()
}

func (f *failover) isActive() bool {
	f.hookMu.Lock()
	active := f.activeFn
	f.hookMu.Unlock()
	return active()
}

// setThroughputStats installs the source of the tp_* diag fields.
func (f *failover) setThroughputStats(read func() tpStats) {
	if read == nil {
		return
	}
	f.hookMu.Lock()
	f.readThroughput = read
	f.hookMu.Unlock()
}

func (f *failover) readThroughputStats() tpStats {
	f.hookMu.Lock()
	read := f.readThroughput
	f.hookMu.Unlock()
	return read()
}

// rescuing reports whether a rescue scan is in flight. The throughput scheduler waits for it:
// rescue traffic and a 3 MB download must not share the uplink.
func (f *failover) rescuing() bool { return f.rescueRunning.Load() }
```

Gate the active check, next to its `isPaused` check in `activeCheckLoop`:

```go
		if f.isPaused() || !f.isActive() {
			continue
		}
```

Gate the rescue backoff in `runRescue`, inside the loop before the network-pause arm:

```go
		if attempt > 0 && !f.isActive() {
			// No traffic has gone through this balancer for a whole active-check window,
			// so nobody is waiting for the rescue. Park the way the scan parks on a
			// network pause: sleep the short backoff and look again without spending an
			// attempt. The first attempt is never gated: it reacts to real traffic.
			if err := f.sleep(f.ctx, rescueBackoff[0]); err != nil {
				return
			}
			continue
		}
```

Both log lines:

```go
func (f *failover) logSwitchLine(from, to, reason string, tookMS int64) {
	f.logger.Info("failover: group=", f.group, " ", from, " -> ", to, " reason=", reason, " took=", tookMS, "ms")
}
```

and in `logDiag`, after the `rssMB, cpuS` block:

```go
	// tp_* are n/a on a lowest-delay balancer, the convention rss_mb and cpu_s already use, so
	// field positions stay stable for parsers.
	tpProbes, tpBytes, tpLeft := "n/a", "n/a", "n/a"
	if ts := f.readThroughputStats(); ts.ok {
		tpProbes = strconv.FormatUint(ts.probes, 10)
		tpBytes = mbString(ts.bytes)
		tpLeft = mbString(ts.budgetLeft)
	}
	f.logger.Info(
		"diag: group=", f.group,
		" current=", f.strategy.Now(),
		" probes_active=", c.ProbesActive,
		" probes_rescue=", c.ProbesRescue,
		" probes_interface=", c.ProbesInterface,
		" probes_ok=", c.ProbesOK,
		" probes_failed=", c.ProbesFailed,
		" rescues=", c.Rescues,
		" rescue_exhausted=", c.RescueExhausted,
		" stalls=", c.Stalls,
		" stalls_suppressed=", c.StallsSuppressed,
		" rss_mb=", rssMB,
		" cpu_s=", cpuS,
		" tp_probes=", tpProbes,
		" tp_bytes_mb=", tpBytes,
		" tp_budget_left_mb=", tpLeft,
		" switches=", strings.Join(parts, ","),
	)
```

- [ ] **Step 4: Run the controller tests and see them pass**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run 'TestFailure|TestRescue|TestStall|TestDiag|TestActiveCheck|TestMirrored|TestListenPacket' -count=1
```

Expected: all green, including the two new tests.

- [ ] **Step 5: Write the failing Balancer-wiring tests**

Append to `throughput_test.go`:

```go
func TestBalancerActivityGate(t *testing.T) {
	c := newFakeClock()
	b := &Balancer{nowFn: c.Now, activeWindow: 3 * time.Minute}
	if b.active() {
		t.Fatal("a balancer that never dialled is inactive")
	}
	b.touch()
	if !b.active() {
		t.Fatal("one dial makes the balancer active")
	}
	c.Advance(179 * time.Second)
	if !b.active() {
		t.Fatal("inside the active-check window the balancer is still active")
	}
	c.Advance(2 * time.Second)
	if b.active() {
		t.Fatal("no dial for longer than the window means inactive")
	}
}

func TestThroughputSchedulerObeysTheIdleRule(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(100, c.Now()), "s2": measured(150, c.Now())})
	d.set("s1", 1.0)
	d.set("s2", 2.0)
	b := &Balancer{nowFn: c.Now, activeWindow: 3 * time.Minute}
	tp.setActive(b.active)
	tp.tick()
	if n := len(d.callList()); n != 0 {
		t.Fatalf("a balancer with no dial in the window measures nothing, calls=%d", n)
	}
	b.touch()
	tp.tick()
	if n := len(d.callList()); n != 2 {
		t.Fatalf("one dial makes the round run within a tick, calls=%d", n)
	}
}
```

Append to `scenario_test.go`:

```go
// TestScenarioThroughputPrefersFastLink is the stage 3 scenario: the latency shortlist puts the
// nearer server first, the round measures both, and the selection ends on the faster link.
func TestScenarioThroughputPrefersFastLink(t *testing.T) {
	tp, d, _, c := newThroughputHarness(t, "s1", "s2")
	tp.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"s1": measured(80, c.Now()), "s2": measured(200, c.Now())})
	if tp.Now() != "s1" {
		t.Fatalf("the latency pick must be s1, got %q", tp.Now())
	}
	d.set("s1", 1.0)
	d.set("s2", 6.0)
	c.Advance(601 * time.Second) // past the min dwell of the initial promotion
	tp.runRound(context.Background())
	if tp.Now() != "s2" {
		t.Fatalf("the faster link must win over the lower latency, got %q", tp.Now())
	}
	switches := 0
	for _, ev := range tp.Events() {
		if ev.Network == N.NetworkTCP && ev.Reason == reasonBetterThroughput {
			switches++
		}
	}
	if switches != 1 {
		t.Fatalf("one better_throughput switch expected, got %d", switches)
	}
	t.Logf("SCENARIO name=throughput_fast_over_low_latency probes=%d switches=%d recovery_ms=0", len(d.callList()), switches)
}
```

`scenario_test.go` needs `context` and `N "github.com/sagernet/sing/common/network"` in its imports.

- [ ] **Step 6: Run them and see them fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -run 'TestBalancerActivityGate|TestThroughputSchedulerObeys|TestScenarioThroughput' -count=1
```

Expected: build failure, `unknown field nowFn in struct literal of type Balancer`, `b.touch undefined`, `b.active undefined`.

- [ ] **Step 7: Wire the Balancer**

Add `"sync/atomic"` to the imports. Add to the struct, after `stalls`:

```go
	// tp is the throughput strategy when that is what the balancer runs; nil otherwise.
	tp *Throughput

	// lastDial is the unix-nano timestamp of the last Select on any path. The idle rule reads
	// it: with lowest and fastest both in the config only one is selected, and the unselected
	// one must not probe, rescue or measure.
	lastDial     atomic.Int64
	nowFn        func() time.Time
	activeWindow time.Duration
```

In `NewLoadBalance`, add `nowFn: time.Now,` to the literal.

Add the two helpers next to `Now()`:

```go
// touch records that traffic went through this balancer.
func (s *Balancer) touch() {
	now := s.nowFn
	if now == nil {
		now = time.Now
	}
	s.lastDial.Store(now().UnixNano())
}

// active reports whether a dial happened inside the active-check window. At start lastDial is 0,
// the balancer is inactive and runs nothing; the first dial uses the provisional or already
// promoted selection without waiting and makes the balancer active in the same call.
func (s *Balancer) active() bool {
	last := s.lastDial.Load()
	if last == 0 {
		return false
	}
	now := s.nowFn
	if now == nil {
		now = time.Now
	}
	window := s.activeWindow
	if window <= 0 {
		window = defaultActiveCheckInterval
	}
	return now().Sub(time.Unix(0, last)) <= window
}
```

Add `s.touch()` as the first statement of `DialContext`, `ListenPacket`, `NewConnectionEx`, `NewPacketConnectionEx` and `NewDirectRouteConnection`, before the `metadata` handling and the `Select` call.

In `Start`, register the new strategy:

```go
	case StrategyLowestDelay:
		s.strategyFn = NewLowestDelay(outbounds, s.options)
	case StrategyThroughput:
		tp := NewThroughput(outbounds, s.options, s.logger)
		s.tp = tp
		s.strategyFn = tp
```

and replace the wiring block written in Task 1 with:

```go
	if fs, ok := s.strategyFn.(failoverStrategy); ok {
		s.foStrategy = fs
	}
	// The controller probes through the monitor and the worker reads its history; without a
	// monitor there is nothing to drive either, so neither is built.
	if s.foStrategy != nil && s.monitor != nil {
		cfg := s.foStrategy.config()
		s.activeWindow = cfg.activeCheckInterval
		pm := service.FromContext[pause.Manager](s.ctx)
		s.stalls = newStallTracker(cfg, time.Now, func(tag string) {
			// reportFailure owns the Stalls counter; do not bump it here.
			s.failover.reportFailure(tag, reasonStall)
		})
		s.failover = newFailover(s.ctx, cfg, s.Tag(), s.foStrategy, monitorProber{s.monitor}, s.logger, func() {
			s.interruptGroup.Interrupt(s.interruptExternalConnections)
			if s.tp != nil {
				// A rescue or a failure switch may have landed on a slower server, so
				// measure the settled selection one dwell later.
				s.tp.onFailoverSwitch()
			}
		})
		s.failover.setResetStalls(s.stalls.reset)
		s.failover.setActive(s.active)
		if pm != nil {
			// IsPaused covers both halves: the screen is off / the tunnel is idle, and
			// there is no usable network. Either way an active probe is wasted radio.
			s.failover.setPaused(pm.IsPaused)
			s.failover.setNetworkPaused(pm.IsNetworkPaused)
		}
		if s.tp != nil {
			s.tp.setActive(s.active)
			s.tp.setRescuing(s.failover.rescuing)
			if pm != nil {
				s.tp.setPaused(pm.IsPaused)
			}
			// A switch the strategy made itself is not a failover event: drain it at once
			// so the failover line is logged and counted without waiting for a sweep.
			s.tp.setNotify(func() {
				s.failover.drainEvents()
				s.interruptGroup.Interrupt(s.interruptExternalConnections)
			})
			s.failover.setThroughputStats(s.tp.stats)
		}
	}
	if s.foStrategy != nil && s.monitor == nil {
		// Without the monitor there is no prober and no history, so nothing can detect or
		// repair a dead server. Say it once instead of failing silently.
		s.logger.Warn("load balance: failover is disabled for strategy ", s.options.Strategy, ", outbound monitoring is off")
	}
```

`PostStart`, `InterfaceUpdated` and `Close`:

```go
func (s *Balancer) PostStart() error {
	go s.worker()
	if s.failover != nil {
		s.failover.start()
		go s.stallLoop()
	}
	if s.tp != nil {
		s.tp.start(s.ctx)
	}
	return nil
}

// InterfaceUpdated implements [adapter.InterfaceUpdateListener].
func (s *Balancer) InterfaceUpdated() {
	if s.failover != nil {
		s.failover.onInterfaceChange()
	}
	if s.tp != nil {
		// The values were measured on a network that no longer exists.
		s.tp.invalidate()
	}
}

func (s *Balancer) Close() error {
	s.closeOnce.Do(func() {
		// Close the channel first so worker and stallLoop leave, then stop the controller
		// and the scheduler: both wait for their own goroutines, including a rescue scan or
		// a download in flight.
		if s.close != nil {
			close(s.close)
		}
		if s.failover != nil {
			s.failover.stop()
		}
		if s.tp != nil {
			s.tp.stop()
		}
	})
	return nil
}
```

- [ ] **Step 8: Run the whole package, the race detector and the scenarios**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
go test ./protocol/group/balancer/ -count=1
go test ./protocol/group/balancer/ -count=1 -race
go test ./protocol/group/balancer/ -run TestScenario -v -count=1 | grep SCENARIO
go vet ./protocol/group/balancer/
go test ./common/monitoring/ -count=1
```

Expected: everything green, and four `SCENARIO` lines: `dial_error_with_candidates`, `rescue_unknown_pool`, `latency_jitter_24h`, `throughput_fast_over_low_latency probes=2 switches=1 recovery_ms=0`.

- [ ] **Step 9: Commit and report the commit hash**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git add protocol/group/balancer/balancer.go protocol/group/balancer/failover.go protocol/group/balancer/failover_test.go protocol/group/balancer/throughput_test.go protocol/group/balancer/scenario_test.go
git commit -m "feat(balancer): подключение стратегии throughput и правило простаивающего балансировщика" -m "Balancer собирает стратегию по имени throughput, отдаёт ей ворота паузы, простоя и идущего rescue и обнуляет таблицу значений при смене интерфейса. lastDial обновляется на всех пяти путях выбора; активная проверка и планировщик замеров молчат, пока через балансировщик не прошёл трафик, а откат rescue паркуется, не тратя попытку. Строки failover: и diag: получили префикс group=<tag>, в diag: добавлены tp_probes, tp_bytes_mb и tp_budget_left_mb — у lowest они n/a." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
git rev-parse HEAD
```

Report that hash to the controller: Task 7 records it as the submodule commit.

---

### Task 7: Core options, the `fastest` balancer and the submodule bump

**Files:**
- Modify: `recon-core/v2/config/hiddify_option.go` (`HiddifyOptions` embed list `:33-38`, new struct next to `FailoverOptions` `:71-80`, defaults `:149-158`)
- Modify: `recon-core/v2/config/builder.go` (tag consts `:42-44`, `PredefinedOutboundTags` `:60`, the `urlTest` outbound `:269-296`, the selector block `:298-316`)
- Modify: `recon-core/v2/config/failover_test.go` (append four tests)
- Modify: `recon-core` submodule pointer for `hiddify-sing-box`

**Interfaces:**
- Produces: `type ThroughputOptions struct` with flat JSON keys `throughput-test-url`, `throughput-probe-bytes`, `throughput-recheck-interval`, `throughput-daily-budget-mb`, `throughput-shortlist`, `throughput-hysteresis-percent`, `throughput-min-dwell`, each `overridable:"true"`
- Produces: `OutboundThroughputTag = "fastest"`, added to `PredefinedOutboundTags`
- Consumes: `option.BalancerOutboundOptions` fields from Task 2; the sing-box strategy name `"throughput"` from Task 2
- Consumes: the sing-box commit produced by Task 6. Write it as `<SINGBOX_COMMIT>` in the commit body below only for the hash itself; **the controller fills it in** after Task 6 reports it.

- [ ] **Step 1: Write the failing core tests**

Append to `recon-core/v2/config/failover_test.go`:

```go
func TestDefaultThroughputOptions(t *testing.T) {
	o := DefaultHiddifyOptions()
	if o.ThroughputTestURL != "https://speed.cloudflare.com/__down?bytes=3000000" {
		t.Fatalf("test url = %q", o.ThroughputTestURL)
	}
	if o.ThroughputProbeBytes != 3000000 || o.ThroughputRecheckInterval != 7200 ||
		o.ThroughputDailyBudgetMB != 100 || o.ThroughputShortlist != 3 ||
		o.ThroughputHysteresisPercent != 25 || o.ThroughputMinDwell != 600 {
		t.Fatalf("defaults: %+v", o.ThroughputOptions)
	}
}

func TestThroughputOptionsUnmarshalFromFlatJSON(t *testing.T) {
	o := DefaultHiddifyOptions()
	if err := json.Unmarshal([]byte(`{"throughput-shortlist":5}`), o); err != nil {
		t.Fatal(err)
	}
	if o.ThroughputShortlist != 5 {
		t.Fatalf("ThroughputShortlist: got %d, want 5", o.ThroughputShortlist)
	}
	if o.ThroughputDailyBudgetMB != 100 || o.ThroughputHysteresisPercent != 25 {
		t.Fatalf("the other throughput defaults must survive: %+v", o.ThroughputOptions)
	}
	b, err := json.Marshal(DefaultHiddifyOptions())
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["throughput-shortlist"]; !ok {
		t.Fatalf("marshaled JSON must carry top-level key throughput-shortlist: %s", b)
	}
	if _, ok := raw["Throughput"]; ok {
		t.Fatalf("marshaled JSON must not nest throughput fields under Throughput: %s", b)
	}
}

func TestFastestBalancerCarriesThroughputOptions(t *testing.T) {
	opt := DefaultHiddifyOptions()
	input := option.Options{Outbounds: []option.Outbound{
		{Type: C.TypeDirect, Tag: "s1", Options: &option.DirectOutboundOptions{}},
		{Type: C.TypeDirect, Tag: "s2", Options: &option.DirectOutboundOptions{}},
	}}
	out, err := BuildConfig(context.Background(), opt, &ReadOptions{Options: &input})
	if err != nil {
		t.Fatal(err)
	}
	var fastest *option.BalancerOutboundOptions
	for _, ob := range out.Outbounds {
		if ob.Tag == OutboundThroughputTag {
			fastest = ob.Options.(*option.BalancerOutboundOptions)
		}
	}
	if fastest == nil {
		t.Fatal("fastest balancer missing")
	}
	if fastest.Strategy != "throughput" {
		t.Fatalf("strategy = %q, want throughput", fastest.Strategy)
	}
	// The failover options are the same as on lowest.
	if fastest.Tolerance != 150 || fastest.MinDwell.Build().Seconds() != 60 ||
		fastest.RescueBatch != 6 || fastest.ActiveCheckInterval.Build().Minutes() != 3 {
		t.Fatalf("failover options: %+v", fastest)
	}
	if fastest.ThroughputProbeBytes != 3000000 || fastest.ThroughputShortlist != 3 ||
		fastest.ThroughputHysteresisPercent != 25 ||
		fastest.ThroughputRecheckInterval.Build() != 7200*time.Second ||
		fastest.ThroughputMinDwell.Build() != 600*time.Second ||
		fastest.ThroughputDailyBudgetMB != 100 || fastest.ThroughputTestURL == "" {
		t.Fatalf("throughput options: %+v", fastest)
	}
}

func TestSelectorListsLowestThenFastest(t *testing.T) {
	opt := DefaultHiddifyOptions()
	input := option.Options{Outbounds: []option.Outbound{
		{Type: C.TypeDirect, Tag: "s1", Options: &option.DirectOutboundOptions{}},
		{Type: C.TypeDirect, Tag: "s2", Options: &option.DirectOutboundOptions{}},
	}}
	out, err := BuildConfig(context.Background(), opt, &ReadOptions{Options: &input})
	if err != nil {
		t.Fatal(err)
	}
	var selector *option.SelectorOutboundOptions
	for _, ob := range out.Outbounds {
		if ob.Tag == OutboundSelectTag {
			selector = ob.Options.(*option.SelectorOutboundOptions)
		}
	}
	if selector == nil {
		t.Fatal("selector missing")
	}
	want := []string{OutboundURLTestTag, OutboundThroughputTag, "s1", "s2"}
	if len(selector.Outbounds) != len(want) {
		t.Fatalf("select = %v, want %v", selector.Outbounds, want)
	}
	for i, tag := range want {
		if selector.Outbounds[i] != tag {
			t.Fatalf("select = %v, want %v", selector.Outbounds, want)
		}
	}
	if selector.Default != OutboundURLTestTag {
		t.Fatalf("the default auto entry stays lowest, got %q", selector.Default)
	}
	if !contains(PredefinedOutboundTags, OutboundThroughputTag) {
		t.Fatal("fastest must be a predefined tag so a subscription server cannot collide with it")
	}
}

func TestSingleServerBuildsNoBalancer(t *testing.T) {
	opt := DefaultHiddifyOptions()
	input := option.Options{Outbounds: []option.Outbound{
		{Type: C.TypeDirect, Tag: "s1", Options: &option.DirectOutboundOptions{}},
	}}
	out, err := BuildConfig(context.Background(), opt, &ReadOptions{Options: &input})
	if err != nil {
		t.Fatal(err)
	}
	for _, ob := range out.Outbounds {
		if ob.Tag == OutboundThroughputTag || ob.Tag == OutboundURLTestTag {
			t.Fatalf("a single-server config builds no balancer, found %q", ob.Tag)
		}
	}
}
```

Add `"time"` to the imports of `failover_test.go`.

- [ ] **Step 2: Run them and see them fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core
go test ./v2/config/ -count=1
```

Expected: build failure, `o.ThroughputTestURL undefined`, `undefined: OutboundThroughputTag`, `fastest.ThroughputProbeBytes undefined` (the last one only until the submodule bump of Step 6; run the step in order).

- [ ] **Step 3: Add `ThroughputOptions` to `hiddify_option.go`**

After `FailoverOptions` in the struct list:

```go
	URLTestOptions
	FailoverOptions
	ThroughputOptions
```

After the `FailoverOptions` type:

```go
// ThroughputOptions travel with the fastest balancer. Embedded anonymously into HiddifyOptions,
// so the keys stay flat in the options JSON and overridable works per key. Seconds for the two
// durations, decimal megabytes for the budget.
type ThroughputOptions struct {
	ThroughputTestURL           string `json:"throughput-test-url,omitempty" overridable:"true"`
	ThroughputProbeBytes        int64  `json:"throughput-probe-bytes,omitempty" overridable:"true"`
	ThroughputRecheckInterval   int    `json:"throughput-recheck-interval,omitempty" overridable:"true"`
	ThroughputDailyBudgetMB     int64  `json:"throughput-daily-budget-mb,omitempty" overridable:"true"`
	ThroughputShortlist         int    `json:"throughput-shortlist,omitempty" overridable:"true"`
	ThroughputHysteresisPercent int    `json:"throughput-hysteresis-percent,omitempty" overridable:"true"`
	ThroughputMinDwell          int    `json:"throughput-min-dwell,omitempty" overridable:"true"`
}
```

In `DefaultHiddifyOptions()`, after the `FailoverOptions` literal:

```go
		ThroughputOptions: ThroughputOptions{
			ThroughputTestURL:           "https://speed.cloudflare.com/__down?bytes=3000000",
			ThroughputProbeBytes:        3000000,
			ThroughputRecheckInterval:   7200,
			ThroughputDailyBudgetMB:     100,
			ThroughputShortlist:         3,
			ThroughputHysteresisPercent: 25,
			ThroughputMinDwell:          600,
		},
```

- [ ] **Step 4: Build the `fastest` balancer in `builder.go`**

Add the tag next to `OutboundURLTestTag`:

```go
	OutboundURLTestTag        = "lowest"
	OutboundThroughputTag     = "fastest"
	OutboundRoundRobinTag     = "balance"
```

Add it to `PredefinedOutboundTags`, so a subscription server called `fastest` cannot collide with the balancer:

```go
	PredefinedOutboundTags   = []string{OutboundDirectTag, OutboundBypassTag, OutboundSelectTag, OutboundURLTestTag, OutboundThroughputTag, OutboundDNSTag, OutboundDirectFragmentTag, WARPConfigTag}
```

After the `urlTest` outbound literal, add the second balancer:

```go
	// The same pool and the same failover options as lowest, plus the throughput ones. Both
	// balancers exist in every multi-server config; the app decides which one is selected, and
	// the idle rule keeps the unselected one from probing or downloading.
	throughput := option.Outbound{
		Type: C.TypeBalancer,
		Tag:  OutboundThroughputTag,
		Options: &option.BalancerOutboundOptions{
			Outbounds:                   tags,
			Strategy:                    "throughput",
			DelayAcceptableRatio:        2,
			Tolerance:                   opt.Tolerance,
			MinDwell:                    badoption.Duration(time.Duration(opt.MinDwell) * time.Second),
			StallTimeout:                badoption.Duration(time.Duration(opt.StallTimeout) * time.Second),
			StallThreshold:              opt.StallThreshold,
			StallWindow:                 badoption.Duration(time.Duration(opt.StallWindow) * time.Second),
			RescueBatch:                 opt.RescueBatch,
			RescueTimeout:               badoption.Duration(time.Duration(opt.RescueTimeout) * time.Second),
			ActiveCheckInterval:         badoption.Duration(time.Duration(opt.ActiveCheckInterval) * time.Second),
			InterruptExistConnections:   true,
			ThroughputTestURL:           opt.ThroughputTestURL,
			ThroughputProbeBytes:        opt.ThroughputProbeBytes,
			ThroughputRecheckInterval:   badoption.Duration(time.Duration(opt.ThroughputRecheckInterval) * time.Second),
			ThroughputDailyBudgetMB:     opt.ThroughputDailyBudgetMB,
			ThroughputShortlist:         opt.ThroughputShortlist,
			ThroughputHysteresisPercent: opt.ThroughputHysteresisPercent,
			ThroughputMinDwell:          badoption.Duration(time.Duration(opt.ThroughputMinDwell) * time.Second),
		},
	}
```

Replace the `if len(tags) > 1` block with the two-balancer version (keep the existing `if OutboundMainDetour == WARPConfigTag { ... } else { ... }` structure exactly as it is and replace only the body of each arm with the lines below, so the two arms stay identical and the conditional shape is untouched):

```go
	selectorTags := tags
	if len(tags) > 1 {
		// lowest first and the selector default, fastest right after it: the proxy list shows
		// the two auto entries and the servers, and a fresh profile starts on lowest.
		outbounds = append([]option.Outbound{urlTest, throughput}, outbounds...)
		selectorTags = append([]string{urlTest.Tag, throughput.Tag}, selectorTags...)
		defaultSelect = urlTest.Tag
	}
```

- [ ] **Step 5: Run the core tests**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core
go test ./v2/config/ -count=1 -v -run 'Throughput|Failover|Selector|SingleServer'
go test ./v2/config/ -count=1
go vet ./v2/config/
```

Expected: `TestDefaultThroughputOptions`, `TestThroughputOptionsUnmarshalFromFlatJSON`, `TestFastestBalancerCarriesThroughputOptions`, `TestSelectorListsLowestThenFastest`, `TestSingleServerBuildsNoBalancer` pass, and the four stage 2 tests still pass. If the build cannot see the `Throughput*` fields on `option.BalancerOutboundOptions`, the submodule still points at the old sing-box commit: do Step 6 first and rerun.

- [ ] **Step 6: Bump the sing-box submodule**

`<SINGBOX_COMMIT>` is the hash Task 6 printed. The controller supplies it; do not invent one.

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git rev-parse HEAD
cd /c/Users/bambolumba/Desktop/Recon/recon-core
git submodule status
git add hiddify-sing-box
git status --short
```

Expected: `git rev-parse HEAD` prints `<SINGBOX_COMMIT>`; `git status --short` lists `M hiddify-sing-box` plus the three modified files. `git submodule status` must still print `f58be84e30d946915a1de437fbcc3d3ffca18a23 ray2sing`.

- [ ] **Step 7: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core
git add v2/config/hiddify_option.go v2/config/builder.go v2/config/failover_test.go hiddify-sing-box
git commit -m "feat(config): второй балансировщик fastest со стратегией throughput" -m "ThroughputOptions встроены в HiddifyOptions анонимно, поэтому ключи throughput-* остаются плоскими и переопределяются по одному. Билдер собирает fastest рядом с lowest с теми же опциями отказа плюс параметры замера и ставит его в select сразу после lowest; по умолчанию выбирается по-прежнему lowest. Тег fastest добавлен в PredefinedOutboundTags, чтобы сервер подписки с таким именем не подменил балансировщик. Подмодуль sing-box поднят до <SINGBOX_COMMIT>." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

---

### Task 8: App setting, enum, i18n, auto-mode selection and the proxy-list filter

Everything here is in `hiddify-app` on branch `recon/stage2`.

**Files:**
- Create: `hiddify-app/lib/features/connection/model/auto_mode.dart`
- Modify: `hiddify-app/lib/core/preferences/general_preferences.dart` (the `Preferences` class, after `autoGroupEnabled` at `:107`)
- Modify: `hiddify-app/assets/translations/en.i18n.json` (`pages.settings.general`, before `"logLevel"` at `:239`)
- Modify: `hiddify-app/assets/translations/ru.i18n.json` (same place, before `"logLevel"` at `:242`)
- Modify: `hiddify-app/lib/features/settings/overview/sections/general_page.dart` (before the `logLevel` `ChoicePreferenceWidget` at `:86-93`)
- Modify: `hiddify-app/lib/features/connection/data/connection_repository.dart` (`_selectLowest` and its two call sites at `:113-124`, the retry block at `:126-165`)
- Modify: `hiddify-app/lib/features/proxy/overview/proxies_overview_notifier.dart` (`build` `:60-95`, `_sortOutbounds` `:140-178`)
- Test: modify `hiddify-app/test/features/connection/data/connection_repository_test.dart`; create `hiddify-app/test/core/preferences/auto_mode_preference_test.dart` and `hiddify-app/test/features/proxy/overview/auto_entry_filter_test.dart`

**Interfaces:**
- Produces: `enum AutoMode { lowest, fastest }` with `String get outboundTag`, `String get hiddenOutboundTag`, `static const String groupTag = 'select'`, `static List<AutoMode> get choices`, `String present(TranslationsEn t)`
- Produces: `Preferences.autoMode`, a `StateNotifierProvider<PreferencesNotifier<AutoMode, String>, AutoMode>` on key `auto-mode`, default `AutoMode.lowest`
- Produces: `filterAutoEntries(List<OutboundInfo> items, AutoMode mode) -> List<OutboundInfo>` in `proxies_overview_notifier.dart`
- Produces: i18n keys `pages.settings.general.autoMode`, `pages.settings.general.autoModes.lowest`, `pages.settings.general.autoModes.fastest`
- Consumes: `PreferencesNotifier.create<T, P>(key, defaultValue, {mapFrom, mapTo, ...})` (`lib/core/utils/preferences_utils.dart:96`), `ChoicePreferenceWidget<T>({selected, preferences, choices, title, icon, presentChoice})` (`lib/features/settings/widget/preference_tile.dart:66-89`), `HiddifyCoreService.selectOutbound(String groupTag, String outboundTag)`, `OutboundInfo` (`lib/hiddifycore/generated/v2/hcore/hcore.pb.dart:619`)
- Note: the core builds both balancers regardless; this setting is app-local and is not part of the core options JSON.

- [ ] **Step 1: Write the failing app tests**

Create `test/core/preferences/auto_mode_preference_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/model/auto_mode.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> containerWith(Map<String, Object> initial) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) async => prefs)]);
  await container.read(sharedPreferencesProvider.future);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('auto-mode defaults to lowest', () async {
    final container = await containerWith({});
    addTearDown(container.dispose);

    expect(container.read(Preferences.autoMode), AutoMode.lowest);
  });

  test('auto-mode round-trips through shared preferences', () async {
    final container = await containerWith({});
    addTearDown(container.dispose);

    await container.read(Preferences.autoMode.notifier).update(AutoMode.fastest);
    expect(container.read(Preferences.autoMode), AutoMode.fastest);

    final reloaded = await containerWith({'auto-mode': 'fastest'});
    addTearDown(reloaded.dispose);
    expect(reloaded.read(Preferences.autoMode), AutoMode.fastest);
  });

  test('an unknown stored value falls back to lowest', () async {
    final container = await containerWith({'auto-mode': 'nonsense'});
    addTearDown(container.dispose);

    expect(container.read(Preferences.autoMode), AutoMode.lowest);
  });

  test('each mode names the outbound it selects and the one it hides', () {
    expect(AutoMode.lowest.outboundTag, 'lowest');
    expect(AutoMode.lowest.hiddenOutboundTag, 'fastest');
    expect(AutoMode.fastest.outboundTag, 'fastest');
    expect(AutoMode.fastest.hiddenOutboundTag, 'lowest');
    expect(AutoMode.groupTag, 'select');
  });
}
```

Create `test/features/proxy/overview/auto_entry_filter_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/model/auto_mode.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

void main() {
  final items = [
    OutboundInfo(tag: 'lowest', isGroup: true),
    OutboundInfo(tag: 'fastest', isGroup: true),
    OutboundInfo(tag: 's1'),
    OutboundInfo(tag: 's2'),
  ];

  test('auto-mode lowest hides the fastest row', () {
    expect(filterAutoEntries(items, AutoMode.lowest).map((e) => e.tag), ['lowest', 's1', 's2']);
  });

  test('auto-mode fastest hides the lowest row', () {
    expect(filterAutoEntries(items, AutoMode.fastest).map((e) => e.tag), ['fastest', 's1', 's2']);
  });
}
```

In `test/features/connection/data/connection_repository_test.dart`, rename the retry-delay references and add the `fastest` cases. Replace the two `selectLowestRetryDelay` lines (`:89`, `:93`, `:142`) with `selectAutoModeRetryDelay`, and append these tests before the closing brace of `main`:

```dart
  test('connectAutoGroup selects the fastest balancer when the setting says so', () async {
    await container.read(Preferences.autoMode.notifier).update(AutoMode.fastest);

    final result = await repo.connectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls[singbox.calls.length - 2], 'start');
    expect(singbox.calls.last, 'selectOutbound(select, fastest)');
  });

  test('reconnectAutoGroup selects the fastest balancer when the setting says so', () async {
    await container.read(Preferences.autoMode.notifier).update(AutoMode.fastest);

    final result = await repo.reconnectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls[singbox.calls.length - 2], 'restart');
    expect(singbox.calls.last, 'selectOutbound(select, fastest)');
  });

  test('the three-attempt retry is the same for fastest', () async {
    await container.read(Preferences.autoMode.notifier).update(AutoMode.fastest);
    singbox.selectOutboundThrowsRemaining = -1;

    final result = await repo.connectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls.where((c) => c == 'selectOutbound(select, fastest)').length, 3);
  });

  test('connectAutoGroup still completes when selecting fastest always returns Left', () async {
    await container.read(Preferences.autoMode.notifier).update(AutoMode.fastest);
    singbox.selectOutboundReturnsLeft = true;

    final result = await repo.connectAutoGroup(false).run();

    expect(result.isRight(), isTrue, reason: result.getLeft().toNullable()?.toString());
    expect(singbox.calls.where((c) => c == 'selectOutbound(select, fastest)').length, 3);
  });
```

Add these imports to that test file:

```dart
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/model/auto_mode.dart';
```

- [ ] **Step 2: Run them and see them fail**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
flutter test --concurrency=1 test/core/preferences/auto_mode_preference_test.dart test/features/proxy/overview/auto_entry_filter_test.dart test/features/connection/data/connection_repository_test.dart
```

Expected: compile errors, `Target of URI doesn't exist: 'package:hiddify/features/connection/model/auto_mode.dart'`, `The getter 'autoMode' isn't defined for the class 'Preferences'`, `Undefined name 'filterAutoEntries'`, `The setter 'selectAutoModeRetryDelay' isn't defined`.

- [ ] **Step 3: Create the enum**

`lib/features/connection/model/auto_mode.dart`:

```dart
import 'package:hiddify/core/localization/translations.dart';

/// Which automatic balancer the app selects in the core's `select` group after connect.
///
/// `lowest` picks the server by URL-test latency, `fastest` by measured download throughput. The
/// core builds both balancers in every multi-server config; only one of them is ever selected,
/// and the unselected one costs nothing because it never sees a dial. Changing this setting while
/// connected does not re-select: it applies on the next connect or reconnect, the rule that
/// already governs a manual server pick.
enum AutoMode {
  lowest,
  fastest;

  /// The group the auto entries live in.
  static const String groupTag = 'select';

  /// Tag of the core outbound this mode selects.
  String get outboundTag => name;

  /// Tag of the auto entry the proxy list hides while this mode is set.
  String get hiddenOutboundTag => this == AutoMode.lowest ? AutoMode.fastest.name : AutoMode.lowest.name;

  static List<AutoMode> get choices => values;

  String present(TranslationsEn t) => switch (this) {
    AutoMode.lowest => t.pages.settings.general.autoModes.lowest,
    AutoMode.fastest => t.pages.settings.general.autoModes.fastest,
  };
}
```

- [ ] **Step 4: Add the preference**

In `lib/core/preferences/general_preferences.dart`, add the import

```dart
import 'package:hiddify/features/connection/model/auto_mode.dart';
```

and the entry after `autoGroupEnabled`:

```dart
  /// Which auto entry the app selects after an auto-group connect. App-local: the core builds
  /// both balancers regardless, and only the app decides which one is selected.
  static final autoMode = PreferencesNotifier.create<AutoMode, String>(
    "auto-mode",
    AutoMode.lowest,
    mapFrom: AutoMode.values.byName,
    mapTo: (value) => value.name,
  );
```

- [ ] **Step 5: Add the i18n keys**

In `assets/translations/en.i18n.json`, inside `pages.settings.general`, before `"logLevel"`:

```json
        "autoMode": "Auto mode",
        "autoModes": {
          "lowest": "Lowest latency",
          "fastest": "Fastest download"
        },
```

In `assets/translations/ru.i18n.json`, same place:

```json
        "autoMode": "Авто-режим",
        "autoModes": {
          "lowest": "Наименьшая задержка",
          "fastest": "Максимальная скорость"
        },
```

Regenerate the translations (the generated file is gitignored and never committed):

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
dart run slang
```

- [ ] **Step 6: Add the settings tile**

In `lib/features/settings/overview/sections/general_page.dart`, add the import

```dart
import 'package:hiddify/features/connection/model/auto_mode.dart';
```

and the tile immediately before the `logLevel` `ChoicePreferenceWidget`:

```dart
          ChoicePreferenceWidget(
            selected: ref.watch(Preferences.autoMode),
            preferences: ref.watch(Preferences.autoMode.notifier),
            choices: AutoMode.choices,
            title: t.pages.settings.general.autoMode,
            icon: Icons.auto_awesome_rounded,
            presentChoice: (value) => value.present(t),
          ),
```

- [ ] **Step 7: Select the configured auto mode after connect**

In `lib/features/connection/data/connection_repository.dart`, add the imports

```dart
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/model/auto_mode.dart';
```

change both call sites from `.flatMap((_) => _selectLowest())` to `.flatMap((_) => _selectAutoMode())`, and replace the doc comment and the retry block with:

```dart
  /// Auto mode must run on one of the core's balancers, not on the selector's default.
  /// `HiddifyCoreService.selectOutbound` rethrows any `GrpcError` from the core (the 1 s call
  /// deadline during a core restart, `UNAVAILABLE` while the core is restarting, "outbound not
  /// found in selector" for a single-server group) instead of always returning a `Left`, so each
  /// attempt is wrapped in `TaskEither.tryCatch` to catch both outcomes and retried up to
  /// [_selectAutoModeMaxAttempts] times, [selectAutoModeRetryDelay] apart. A selection failure
  /// must not fail the composed connect: `start`/`restart` already succeeded and the tunnel is up
  /// (on the selector's default outbound), so failing here would show a spurious connect error and
  /// disable the boot auto-restart. Log a warning after the last attempt and complete with success
  /// instead.
  ///
  /// The mode is read once per connect, so changing the setting while connected applies on the
  /// next connect or reconnect.
  static const _selectAutoModeMaxAttempts = 3;

  @visibleForTesting
  static Duration selectAutoModeRetryDelay = const Duration(seconds: 1);

  TaskEither<ConnectionFailure, Unit> _selectAutoMode() => _selectAutoModeAttempt(ref.read(Preferences.autoMode), 1);

  TaskEither<ConnectionFailure, Unit> _selectAutoModeAttempt(AutoMode mode, int attempt) =>
      TaskEither<ConnectionFailure, Either<String, Unit>>.tryCatch(
        () => singbox.selectOutbound(AutoMode.groupTag, mode.outboundTag).run(),
        (error, stackTrace) => ConnectionFailure.unexpected(error, stackTrace),
      ).flatMap((either) => TaskEither.fromEither(either).mapLeft(ConnectionFailure.unexpected)).orElse((failure) {
        if (attempt >= _selectAutoModeMaxAttempts) {
          loggy.warning('failed to select the ${mode.name} balancer after auto connect', failure);
          return TaskEither.of(unit);
        }
        return TaskEither(() async {
          await Future<void>.delayed(selectAutoModeRetryDelay);
          return _selectAutoModeAttempt(mode, attempt + 1).run();
        });
      });
```

- [ ] **Step 8: Hide the unselected auto entry in the proxy list**

In `lib/features/proxy/overview/proxies_overview_notifier.dart`, add the imports

```dart
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/model/auto_mode.dart';
import 'package:meta/meta.dart';
```

add the filter above `ProxiesOverviewNotifier`:

```dart
/// Drops the auto entry the `auto-mode` setting does not select. The core always builds both
/// balancers; showing both would put two auto rows in a list the owner wants short, and the
/// hidden one stays reachable through the setting.
@visibleForTesting
List<OutboundInfo> filterAutoEntries(List<OutboundInfo> items, AutoMode mode) =>
    items.where((item) => item.tag != mode.hiddenOutboundTag).toList();
```

read the setting in `build`:

```dart
    final sortBy = ref.watch(proxiesSortNotifierProvider);
    final autoMode = ref.watch(Preferences.autoMode);
```

pass it through the last line of `build`:

```dart
        .asyncMap((proxies) async => await _sortOutbounds(proxies, sortBy, autoMode));
```

and use it in `_sortOutbounds`:

```dart
  Future<OutboundGroup?> _sortOutbounds(OutboundGroup? proxies, ProxiesSort sortBy, AutoMode autoMode) async {
```

```dart
    final items = filterAutoEntries(sortedItems, autoMode);
    proxies.items.clear();
    proxies.items.addAll(items);
    return proxies;
```

(the `for (final item in sortedItems)` loop that only re-added every item goes away with it).

- [ ] **Step 9: Run the app tests and the analyzer**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
dart run slang
flutter test --concurrency=1 test/core/preferences/auto_mode_preference_test.dart test/features/proxy/overview/auto_entry_filter_test.dart test/features/connection/data/connection_repository_test.dart
flutter test --concurrency=1
flutter analyze lib/features/connection lib/features/proxy lib/core/preferences lib/features/settings
```

Expected: `All tests passed!` for the three files (the connection repository file now has 12 tests) and for the whole suite; the analyzer reports no new issues in the touched directories.

- [ ] **Step 10: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
git checkout -- linux/flutter macos/Flutter windows/flutter
git add lib/features/connection/model/auto_mode.dart lib/core/preferences/general_preferences.dart lib/features/settings/overview/sections/general_page.dart lib/features/connection/data/connection_repository.dart lib/features/proxy/overview/proxies_overview_notifier.dart assets/translations/en.i18n.json assets/translations/ru.i18n.json test/core/preferences/auto_mode_preference_test.dart test/features/proxy/overview/auto_entry_filter_test.dart test/features/connection/data/connection_repository_test.dart
git status --short
git commit -m "feat(settings): выбор авто-режима lowest или fastest" -m "Настройка auto-mode в разделе «Общие» решает, какой балансировщик приложение выбирает в группе select после подключения авто-группы; по умолчанию lowest. Число попыток (3), пауза между ними (1 с) и правило «сбой выбора не валит подключение» не изменились. В списке прокси видна только настроенная авто-запись, вторая скрывается по тегу. Ключи автоперевода добавлены в en и ru, сгенерированные файлы не коммитятся." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

`git status --short` must not list `lib/gen/translations.g.dart`, any `*.g.dart`, `*.mapper.dart`, `*.freezed.dart`, `android/app/libs/` or the platform `flutter`/`Flutter` directories.

---

### Task 9: Scenario harness row, re-run, and the documentation

This task has no new production code. It teaches the performance harness about the stage 3 scenario,
records a fresh run, and writes the documentation the owner reads. Everything is in `hiddify-app` on
branch `recon/stage2`, except the mirror copy under `C:\Users\bambolumba\Desktop\Recon\docs\`, which
is outside every git repository and is copied, never committed.

**Files:**
- Modify: `hiddify-app/tool/performance/go_scenarios.py` (`TEST_SCENARIO_NAMES`, `:18-22`)
- Modify: `hiddify-app/tool/performance/README.md` (the "Go balancer scenario runner" section, from `## Go balancer scenario runner` to the end of file)
- Create: `hiddify-app/docs/performance/2026-09-12-go-scenarios-stage3/summary.csv` and `manifest.json` (written by the script, committed as evidence)
- Modify: `hiddify-app/docs/2026-09-12_recon_stage2_core_failover.md` (the `## Формат строк лога` section, `:113-146`)
- Create: `hiddify-app/docs/2026-09-12_recon_stage3_throughput_mode.md`
- Copy (not committed): `C:\Users\bambolumba\Desktop\Recon\docs\2026-09-12_recon_stage3_throughput_mode.md` and the refreshed `2026-09-12_recon_stage2_core_failover.md`
- Test: `hiddify-app/tool/performance/go_scenarios.py` is verified by running it; there is no unit test for it in the repo and this task does not add one

**Interfaces:**
- Consumes: `TestScenarioThroughputPrefersFastLink` in `recon-core/hiddify-sing-box/protocol/group/balancer/scenario_test.go` (added in Task 6), which prints `SCENARIO name=throughput_fast_over_low_latency probes=2 switches=1 recovery_ms=0`
- Consumes: `SCENARIO_LINE` regex and `GO_TEST_ARGS = ["test", "./protocol/group/balancer/", "-run", "TestScenario", "-v", "-count=1", "-json"]` in `go_scenarios.py` — both already match the new test, because it is named `TestScenario…` and prints the same four fields; only the fallback name map needs the entry
- Produces: `docs/performance/2026-09-12-go-scenarios-stage3/summary.csv` with four rows
- Note: Tasks 1-8 must be committed before this task runs, because the scenario test and the app changes must exist. The submodule in `recon-core` must point at the Task 6 commit (done in Task 7) so `core_commit` in the manifest is meaningful.

- [ ] **Step 1: Add the scenario to the harness fallback map**

In `tool/performance/go_scenarios.py`, the comment above `TEST_SCENARIO_NAMES` says "three
controller-level scenario tests"; there are four now. Replace the comment and the dict:

```python
# The four controller-level scenario tests in protocol/group/balancer/scenario_test.go,
# in source order. Used to name a scenario whose test failed before it could print its
# SCENARIO line (see the README section on this script).
TEST_SCENARIO_NAMES = {
    "TestScenarioDialErrorRecovery": "dial_error_with_candidates",
    "TestScenarioAllUnknownRescue": "rescue_unknown_pool",
    "TestScenarioLatencyFlapDoesNotSwitch": "latency_jitter_24h",
    "TestScenarioThroughputPrefersFastLink": "throughput_fast_over_low_latency",
}
```

Nothing else in the script changes. `GO_TEST_ARGS` already selects every `TestScenario*` test and
`SCENARIO_LINE` already parses the four fields the new test prints.

Check the source order matches by reading the test names in the fork:

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
grep -n "^func TestScenario" protocol/group/balancer/scenario_test.go
```

Expected: four lines, `TestScenarioDialErrorRecovery`, `TestScenarioAllUnknownRescue`,
`TestScenarioLatencyFlapDoesNotSwitch`, `TestScenarioThroughputPrefersFastLink`, in that order. If
Task 6 put the new test somewhere else in the file, reorder the dict to match the file, because the
map is documented as being in source order.

- [ ] **Step 2: Run the harness into the stage 3 results directory**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
python tool/performance/go_scenarios.py --out docs/performance/2026-09-12-go-scenarios-stage3
```

Expected stdout, four rows and a zero exit code:

```
dial_error_with_candidates   pass
rescue_unknown_pool          pass
latency_jitter_24h           pass
throughput_fast_over_low_latency pass
Results: ...\docs\performance\2026-09-12-go-scenarios-stage3
```

The script refuses to overwrite an existing directory, so if it has to be re-run, delete the
directory first (`rm -rf docs/performance/2026-09-12-go-scenarios-stage3`). Do not touch
`docs/performance/2026-09-12-go-scenarios/`: that is the stage 2 observation baseline and it keeps
its three rows.

Check the two output files:

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
cat docs/performance/2026-09-12-go-scenarios-stage3/summary.csv
cat docs/performance/2026-09-12-go-scenarios-stage3/manifest.json
```

Expected: `summary.csv` has the header plus four rows, the fourth being
`throughput_fast_over_low_latency,2,1,0,pass`; `manifest.json` records `go_version`,
`singbox_commit` (the Task 6 commit), `core_commit` (the Task 7 commit), `timestamp_utc` and the
`command`. If `singbox_commit` is not the Task 6 commit, the working tree is out of date; commit
Tasks 1-7 first and re-run.

- [ ] **Step 3: Document the new scenario in the harness README**

In `tool/performance/README.md`, in the "Go balancer scenario runner" section, change "the three
controller-level scenario tests" to "the four controller-level scenario tests", and append one entry
to the "Known semantics" list at the end of the file:

```markdown
- `throughput_fast_over_low_latency` reports `probes=2` because `probes` counts
  downloads, not URL-test probes: the throughput strategy measures each of the two
  candidates once. `recovery_ms=0` for the same reason as
  `dial_error_with_candidates`: the switch happens on the round that produced the
  values, so there is nothing to time. `switches=1` is the single
  `better_throughput` switch from the low-latency server to the fast one.
```

Also add, right after the `manifest.json` bullet, a note on which results directory is the baseline:

```markdown
`docs/performance/2026-09-12-go-scenarios/` is the stage 2 baseline and keeps its
three rows. Stage 3 results are in
`docs/performance/2026-09-12-go-scenarios-stage3/` with the fourth row added; use
`--out` to keep each run in its own directory rather than replacing a recorded one.
```

- [ ] **Step 4: Update the log-format section of the stage 2 document**

`docs/2026-09-12_recon_stage2_core_failover.md` documents the log lines the owner greps for, and
Task 6 changed both of them. In the `## Формат строк лога` section, replace the first code block

```
failover: <откуда> -> <куда> reason=<причина> took=<мс>ms
```

with

```
failover: group=<тег группы> <откуда> -> <куда> reason=<причина> took=<мс>ms
```

and extend the sentence about reasons so it reads:

```markdown
Причины на стороне контроллера отказов: `dial_error`, `stall`, `network_change`,
`probe_failed`, `rescue_exhausted`. Причины на стороне стратегии: `initial`
(временный первый выбор заменён первым измеренным лучшим сервером),
`better_latency` (`lowest_delay.go`) и `better_throughput` (`throughput.go`, только
в группе `fastest`). `manual` из раздела 5.2 дизайн-документа зарезервирован под
ручной выбор через группу `select`; сегодня контроллер отказов его не эмитирует.

Поле `group=` появилось на этапе 3 сразу после `failover:` и `diag:`:
балансировщиков теперь два (`lowest` и `fastest`), они пишут в один и тот же
`box.log`, и без него их строки было бы не различить. Скрипты разбора логов
этапа 2 ищут строку по началу `failover:` и по-прежнему её находят, но первое
поле после двоеточия у них сдвинулось на одно.
```

Replace the `diag:` code block with

```
diag: group=<тег группы> current=<tag> probes_active=<n> probes_rescue=<n> probes_interface=<n> probes_ok=<n> probes_failed=<n> rescues=<n> rescue_exhausted=<n> stalls=<n> stalls_suppressed=<n> rss_mb=<МБ> cpu_s=<с> tp_probes=<n> tp_bytes_mb=<МБ> tp_budget_left_mb=<МБ> switches=<reason>=<n>,<reason>=<n>,...
```

and append to the paragraph that explains the counters:

```markdown
Три поля `tp_*` добавлены на этапе 3 и заполняются только в группе `fastest`: в
группе `lowest` в каждом из них стоит `n/a`. `tp_probes` — число завершённых
загрузок с запуска ядра (успешных и неуспешных), `tp_bytes_mb` — суммарно
скачанные ими мегабайты, `tp_budget_left_mb` — остаток суточного бюджета на
момент сводки по скользящему окну в 24 часа. `tp_probes` растёт, а `tp_bytes_mb`
почти нет — значит замеры падают, причину покажет строка
`throughput: <tag> failed reason=...`.
```

Finally, in the `## Что осталось` section, mark the throughput mode as delivered by adding one line
at the end of the list:

```markdown
- Этап 3 (режим `fastest`) реализован, см. `docs/2026-09-12_recon_stage3_throughput_mode.md`.
```

- [ ] **Step 5: Write the stage 3 hand-over document**

Create `docs/2026-09-12_recon_stage3_throughput_mode.md`. Fill the commit hashes, the tag and the
artifact hashes from the actual work; the placeholders below are marked and must not survive.

```markdown
# Recon этап 3 — авто-режим `fastest`: что сделано и как проверять

Второй автоматический балансировщик выбирает сервер по измеренной скорости
скачивания, а не по задержке URL-теста. Он собирается в каждом конфиге с двумя и
более серверами, но по умолчанию не выбран: в группе `select` по-прежнему стоит
`lowest`, и пока `fastest` не выбран, он не делает ни проб, ни загрузок.

## Итог

- В форке sing-box появилась стратегия `throughput`: она встраивает `LowestDelay`
  (задержки, здоровье, учёт переключений остаются его) и добавляет таблицу
  значений МБ/с, которую заполняет активная HTTP-загрузка через сам кандидатский
  outbound.
- Контроллер отказов этапа 2 работает с обеими стратегиями без изменений: под ним
  теперь интерфейс `failoverStrategy`, а порядок кандидатов даёт сменный `ranker`.
- Ядро строит балансировщик `fastest` рядом с `lowest`, обе записи попадают в
  группу `select`, значение по умолчанию не изменилось.
- В приложении одна настройка «Авто-режим» в разделе «Общие» решает, какую из двух
  записей выбрать после подключения авто-группы. Невыбранная запись в списке
  прокси скрыта.
- Суточный бюджет трафика на замеры — 100 МБ по скользящему окну в 24 часа.

## Карта коммитов

### recon-sing-box, ветка `recon/main`, база `36e826b2`

| Коммит | Что |
|---|---|
| `<T1>` | Интерфейсы `failoverStrategy` и `ranker`, обобщённая обвязка балансировщика |
| `<T2>` | Семь опций `throughput_*`, нормализация, причина `better_throughput` |
| `<T3>` | Интерфейс `downloader` и HTTP-загрузчик через outbound |
| `<T4>` | Ядро стратегии `throughput`: таблица значений, гистерезис, dwell |
| `<T5>` | Планировщик, кольцевой суточный бюджет, гейты, бэкофф, отмены, строки лога |
| `<T6>` | Обвязка, правило простоя по `lastDial`, префикс `group=` и поля `tp_*` |

### recon-core, ветка `recon/main`

| Коммит | Что |
|---|---|
| `<T7>` | Подъём подмодуля, `ThroughputOptions`, сборка `fastest`, тесты |

Тег `v4.1.0-recon.5` ставит владелец после мержа; сборка Actions публикует AAR
как ассет релиза.

### hiddify-app, ветка `recon/stage2`

| Коммит | Что |
|---|---|
| `<T8>` | Настройка «Авто-режим», enum, ключи локализации, выбор записи, фильтр списка |
| `<T9>` | Сценарий в харнессе производительности, прогон, документация |
| (после тега) | `dependencies.properties`: `core.version=4.1.0-recon.5`, ставит владелец |

## Как это работает

Раз в 30 секунд планировщик стратегии просыпается и решает, нужен ли раунд
замеров. Раунд нужен, если таблица значений пуста, если с прошлого полного круга
прошло больше 300 секунд и появились неизмеренные кандидаты, или если значение
текущего сервера старше 7200 секунд. Раунд не запускается, если группа не выбрана
и по ней 180 секунд не было ни одного дозвона, если контроллер отказов на паузе,
если он тянет спасательную процедуру, или если исчерпан суточный бюджет.

Кандидатов берёт шорт-лист: три сервера с наименьшей задержкой по данным
`LowestDelay`. Он специально строится по задержке, а не по уже измеренной
скорости: иначе новый сервер никогда не попал бы в замер. Каждый кандидат
измеряется по очереди, никогда параллельно — иначе замеры мешали бы друг другу и
трафику пользователя.

Один замер — это HTTP GET через сам кандидатский outbound. Первые 262144 байта
считаются прогревом и во времени не участвуют, дальше считается время до
3 МБ (по умолчанию). Меньше 524288 байт — это провал с причиной `short`; прочие
причины: `timeout`, `dial_error`, `http_<код>`. Провал не записывает значение и не
трогает текущий выбор.

Переключение требует одновременно: разницы не меньше 25 % и не меньше 600 секунд
с прошлого переключения. Исключение — когда у текущего сервера значения нет
вообще; тогда любой измеренный кандидат лучше неизвестного. Причина в логе —
`better_throughput`.

Смена сети (`InterfaceUpdated`) очищает всю таблицу: значения, измеренные по
Wi-Fi, к мобильной сети отношения не имеют.

## Опции

Семь полей в `BalancerOutboundOptions`, все со значениями по умолчанию; ноль
означает «взять умолчание», отрицательное значение отключает.

| Ключ (плоский JSON ядра) | Умолчание | Смысл |
|---|---|---|
| `throughput-test-url` | `https://speed.cloudflare.com/__down?bytes=3000000` | Откуда качать |
| `throughput-probe-bytes` | `3000000` | Сколько байт на один замер, зажато в [524288, 100000000] |
| `throughput-recheck-interval` | `7200s` | Как часто перепроверять текущий сервер; отрицательное значение отключает |
| `throughput-daily-budget-mb` | `100` | Суточный бюджет замеров; отрицательное значение отключает замеры |
| `throughput-shortlist` | `3` | Сколько кандидатов в раунде |
| `throughput-hysteresis-percent` | `25` | На сколько процентов кандидат должен быть быстрее |
| `throughput-min-dwell` | `600s` | Минимум между переключениями по скорости |

## Формат строк лога

Обе строки этапа 2 получили поле `group=<тег>` сразу после `failover:` и `diag:`,
потому что балансировщиков теперь два и они пишут в один файл. Полные форматы — в
`docs/2026-09-12_recon_stage2_core_failover.md`.

Новое в `diag:` — три поля, заполняемые только в группе `fastest`:
`tp_probes` (число завершённых загрузок), `tp_bytes_mb` (сколько они скачали),
`tp_budget_left_mb` (остаток суточного бюджета). В группе `lowest` во всех трёх
стоит `n/a`.

Отдельные строки стратегии, уровень `info`. Поля `group=` на них нет: измеряет
только `fastest`, различать нечего.

```
throughput: <tag> <МБ/с, один знак> bytes=<n> took=<мс>ms
throughput: <tag> failed reason=<short|timeout|dial_error|http_403>
throughput: <tag> aborted reason=<paused|inactive|rescue|stopped> bytes=<n>
throughput: budget exhausted spent_mb=<МБ> cap_mb=<МБ>
```

Прерванный замер (`aborted`) списывает свои байты в бюджет, но значения не
записывает: это не провал, на ранжирование он не влияет.

Что смотреть в сутках лога: сколько раз встретилось `budget exhausted` (если
каждый день — бюджет мал для этого пула), какие `reason=` у провалов (сплошные
`http_403` означают, что хост замера режет провайдера), и сколько было
`better_throughput` переключений (десятки в сутки означают, что 25 % гистерезиса
мало для этих серверов).

## Проверка

Форк sing-box (на Windows `go build ./...` падает в `protocol/tailscale`, поэтому
только по пакетам):

```powershell
cd C:\Users\bambolumba\Desktop\Recon\recon-core\hiddify-sing-box
go test ./protocol/group/balancer/ -count=1
go vet ./protocol/group/balancer/
```

Ядро:

```powershell
cd C:\Users\bambolumba\Desktop\Recon\recon-core
go test ./v2/config/ -count=1
```

Приложение:

```powershell
cd C:\Users\bambolumba\Desktop\Recon\hiddify-app
flutter test --concurrency=1
```

Сценарии балансировщика (четвёртая строка — новая):

```powershell
cd C:\Users\bambolumba\Desktop\Recon\hiddify-app
python tool/performance/go_scenarios.py --out docs/performance/2026-09-12-go-scenarios-stage3
```

Результаты прогона: `docs/performance/2026-09-12-go-scenarios-stage3/summary.csv`
и `manifest.json`.

## Проверка на устройстве

1. Собрать APK из тега `v4.1.0-recon.5` (сборку и тег ставит владелец).
2. В настройках поставить уровень логов `info`, авто-режим оставить `lowest`.
   Подключиться, подождать 20 минут, открыть лог ядра: строк `throughput:` быть
   не должно ни одной — правило простоя держит невыбранный балансировщик
   выключенным.
3. Переключить авто-режим на `fastest`, переподключиться. В течение 30 секунд
   должен пойти первый раунд: до трёх строк `throughput: <tag> <МБ/с> bytes=...`.
   В списке прокси видна запись `fastest` и не видна `lowest`.
4. Оставить на сутки. В сводке `diag:` смотреть `tp_bytes_mb`: за сутки он не
   должен превысить 100 МБ бюджета более чем на один незавершённый замер.

## Что осталось

- Измеренная скорость нигде не показана в интерфейсе. Плитка сервера могла бы
  показывать МБ/с рядом с задержкой, но для этого нужно расширение gRPC-статуса,
  отложенное в разделе 5.6 этапа 2.
- Один URL для замера на все регионы. Список по регионам, как
  `connection-test-urls`, отложен до первого случая, когда лог покажет
  систематические `http_<код>` или `timeout`.
- Наблюдение 48 часов по этапу 2 продолжается на умолчании `lowest`; режим
  `fastest` в него не входит.
```

Replace every `<T1>`…`<T9>` with the real short hashes before committing. Placeholders in the
committed file are a defect.

- [ ] **Step 6: Verify the docs and the harness**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
grep -n "<T[0-9]" docs/2026-09-12_recon_stage3_throughput_mode.md
grep -n "group=" docs/2026-09-12_recon_stage2_core_failover.md
grep -c "" docs/performance/2026-09-12-go-scenarios-stage3/summary.csv
python -c "import ast,pathlib; ast.parse(pathlib.Path('tool/performance/go_scenarios.py').read_text(encoding='utf-8')); print('go_scenarios.py parses')"
```

Expected: the first grep prints nothing (exit code 1, no placeholders left); the second prints the
two updated format lines plus the paragraph that explains the prefix; `summary.csv` has 5 lines
(header plus four scenarios); the parse check prints `go_scenarios.py parses`.

- [ ] **Step 7: Mirror the two documents to the root docs directory**

`C:\Users\bambolumba\Desktop\Recon\docs\` is not a git repository; it holds the owner's reading copy
of the same files. Copy, do not symlink:

```bash
cp /c/Users/bambolumba/Desktop/Recon/hiddify-app/docs/2026-09-12_recon_stage3_throughput_mode.md /c/Users/bambolumba/Desktop/Recon/docs/
cp /c/Users/bambolumba/Desktop/Recon/hiddify-app/docs/2026-09-12_recon_stage2_core_failover.md /c/Users/bambolumba/Desktop/Recon/docs/
diff /c/Users/bambolumba/Desktop/Recon/docs/2026-09-12_recon_stage3_throughput_mode.md /c/Users/bambolumba/Desktop/Recon/hiddify-app/docs/2026-09-12_recon_stage3_throughput_mode.md && echo mirrored
diff /c/Users/bambolumba/Desktop/Recon/docs/2026-09-12_recon_stage2_core_failover.md /c/Users/bambolumba/Desktop/Recon/hiddify-app/docs/2026-09-12_recon_stage2_core_failover.md && echo mirrored
```

Expected: two `mirrored` lines and no diff output.

- [ ] **Step 8: Commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
git checkout -- linux/flutter macos/Flutter windows/flutter
git add tool/performance/go_scenarios.py tool/performance/README.md docs/performance/2026-09-12-go-scenarios-stage3/summary.csv docs/performance/2026-09-12-go-scenarios-stage3/manifest.json docs/2026-09-12_recon_stage2_core_failover.md docs/2026-09-12_recon_stage3_throughput_mode.md
git status --short
git commit -m "docs(recon): этап 3, сценарий скорости в харнессе и документация" -m "Четвёртый сценарий throughput_fast_over_low_latency добавлен в карту имён go_scenarios.py и в README; прогон записан в docs/performance/2026-09-12-go-scenarios-stage3, базовый прогон этапа 2 не тронут. В документе этапа 2 обновлены форматы строк failover: и diag: (префикс group=, поля tp_probes, tp_bytes_mb, tp_budget_left_mb) и добавлена причина better_throughput. Новый документ по этапу 3 описывает алгоритм, опции, строки лога, проверку и проверку на устройстве." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
```

`git status --short` must not list `docs/performance/2026-09-12-go-scenarios/` (the stage 2
baseline), any generated Dart file, or `android/app/libs/`.

- [ ] **Step 9: Hand back to the controller**

Do not push and do not tag. Report to the controller:
- the six sing-box commits, the core commit and the two app commits, with their short hashes;
- that `recon-core` is ready to tag `v4.1.0-recon.5`;
- that after the tag and the Actions build, `dependencies.properties` in the app needs
  `core.version=4.1.0-recon.5` and the release AAR's SHA-256 belongs in the hash table of
  `docs/2026-09-12_recon_stage2_core_failover.md`, which this task left untouched because the
  artifact does not exist yet.

---

## Self-review

### Spec coverage

| Spec section | Task |
|---|---|
| 1. Goal and non-goals | Goal statement; non-goals enforced by Task 7 (default stays `lowest`) and Task 8 (setting is app-local) |
| 2. Context: what exists today | File map; Task 1 preserves the stage 2 behaviour |
| 3.1 Components | Task 1 (`failoverStrategy`, `ranker`), Task 3 (`downloader`), Task 4 (`Throughput`), Task 5 (scheduler, budget) |
| 3.2 `failoverStrategy` | Task 1, steps 3-6 |
| 3.3 Reuse of `LowestDelay` | Task 1, steps 4-5 (`ingest`, `promoteHealthy`, `sinceLastSwitch`, `lock`/`unlock`, `config`, `outboundByTag`, `currentLocked`, `orderByLatency`) |
| 3.4 Measurement | Task 3 (warm-up, probe bytes, failure floor, decimal MB, failure classes) |
| 3.5 Selection algorithm | Task 4 (ranker, hysteresis, dwell, missing-value rule, `better_throughput`) |
| 3.6 Schedule | Task 5, steps 5-7 (30 s tick, 300 s round floor, 7200 s recheck, all-failed backoff) |
| 3.7 Budget | Task 5, steps 3-4 (`budget.go`, 24-bucket ring, `budget exhausted` line) |
| 3.8 Idle-balancer rule | Task 6, steps 3-5 (`Balancer.lastDial`, `active()`, the three gated call sites) |
| 3.9 Network change | Task 4, step 7 (`InterfaceUpdated` clears the table and arms a round) |
| 4. Options and defaults | Task 2 (sing-box side), Task 7 (core side, flat JSON keys, `overridable`) |
| 5. Log lines and diagnostics | Task 5, step 8 (the five `throughput:` lines), Task 6, steps 6-7 (`group=` prefix, `tp_*` diag fields) |
| 6. Failure handling | Task 3 (classification), Task 5, step 7 (backoff, abort reasons including `rescue`) |
| 7. Interaction with the failover controller | Task 1 (interface), Task 6 (wiring, `setNotify`) |
| 8. Testing strategy | Test steps of Tasks 1-8; scenario test in Task 6, step 8; harness row in Task 9 |
| 9. Rollout | Task order 1-9; Global Constraints (no pushes, controller tags `v4.1.0-recon.5`) |
| 10. Open questions | Recorded in the "Что осталось" section written by Task 9, step 5 |

Every spec section maps to at least one task, and every task maps to at least one spec section.

### Placeholder scan

No `TBD`, no "similar to Task N", no "add validation here", no unwritten code blocks. The only
intentional placeholders are `<T1>`…`<T9>` in the hand-over document of Task 9, step 5; step 5 says
to replace them and step 6 greps for them as a check.

### Type and name consistency across tasks

- `failoverStrategy` (Task 1) is the type of `failover.strategy` (Task 1) and the parameter of
  `newFailover` (Tasks 1, 6). `Throughput` (Task 4) and `*LowestDelay` (Task 1) both satisfy it.
- `ranker` with `best(...)`/`order(...)` is defined in Task 1, installed by `Throughput` in Task 4,
  and called with `ld.mu` held everywhere, which is why `Throughput` uses `ld.mu` and adds no lock.
- `throughputConfig` and `normalizeThroughput` (Task 2) are consumed by Tasks 4, 5 and 6 with the
  same field names; `StrategyThroughput = "throughput"` (Task 2) is the string the core writes in
  Task 7.
- `downloader`, `throughputResult{Bytes, Elapsed}` and `throughputFailure` (Task 3) are used with
  the same shapes in Tasks 4 and 5, and the `fakeDownloader` of Task 4 implements the Task 3
  interface exactly.
- `reasonBetterThroughput = "better_throughput"` (Task 2) is the reason string asserted in Tasks 4,
  6 and documented in Task 9.
- `Balancer.lastDial` and `active()` (Task 6) are the same names the Task 5 scheduler gate expects
  through the `isActive func() bool` passed into the strategy.
- `AutoMode.groupTag = "select"` (Task 8) equals `OutboundSelectTag` in the core builder (Task 7),
  and `AutoMode.fastest.outboundTag == "fastest"` equals `OutboundThroughputTag` (Task 7).
- Go test fakes are the existing ones by their real names: `fakeClock`/`newFakeClock`/`Advance`,
  `fakeOutbound`/`newFakeOutbound`/`fakeOutbounds`/`measured`, `scriptedProber`, `memLogger` with
  `has`/`snapshot`, `virtualSleep`, `newHarness`, `waitUntil`.

### Per-task step agreement

Each task's failing-test step names the same file the implementation step edits; each "run and see
it fail" command names the same `-run` filter as the "run and pass" command; each commit step's
`git add` lists exactly the files the task's **Files** section declares, and no more. Tasks 1-6 are
in the sing-box fork, Task 7 in the core, Tasks 8-9 in the app, so no task's commit crosses a
repository boundary.
