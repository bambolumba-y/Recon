# Recon Stage 2 — core failover and source-built core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Recon-built hiddify-core whose `lowest-delay` balancer keeps the current server while it works, switches on failure within seconds, probes the full pool rarely, and reports every switch in one log line.

**Architecture:** All failover logic lives in the sing-box fork's `protocol/group/balancer` package: a rewritten `LowestDelay` strategy (hysteresis, health, candidates), a `failover` controller (failure reports, rescue scan, active check, interface change), and a stall watchdog around balancer connections. `common/monitoring` gains a synchronous probe entry point, a disable switch for the periodic sweep, and counters. hiddify-core passes new options from `HiddifyOptions` into the `lowest` balancer and builds the AAR in GitHub Actions of the fork; the app downloads that AAR, selects `lowest` in auto mode and defaults the sweep to 30 min.

**Tech Stack:** Go 1.25.6 (sing-box module `go 1.24.7`), gomobile v0.1.11, NDK r28, Java 17, GitHub Actions; Flutter 3.38.5 / Dart 3.10.4 on the app side.

**Spec:** `docs/superpowers/specs/2026-09-12-hiddify-multi-sub-failover-design.md`, section 5 (failover) and section 1 (targets). Measurement plan: `docs/superpowers/plans/2026-09-12-recon-stage2-performance.md`. Provenance: `docs/2026-09-12_recon_core_provenance.md`.

## Global Constraints

- Pinned sources: hiddify-core `c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0` (tag v4.1.0), its sing-box submodule `0a02b7729f6a211436bb8bdcd8696c283eb27767`, ray2sing `f58be84e30d946915a1de437fbcc3d3ffca18a23`. Never bump them in this plan.
- Workspaces: core fork checkout `C:\Users\bambolumba\Desktop\Recon\recon-core` (nested sing-box at `recon-core\hiddify-sing-box`); app at `C:\Users\bambolumba\Desktop\Recon\hiddify-app`. Do not touch the owner's sibling checkouts `Recon\hiddify-core` and `Recon\hiddify-sing-box`.
- Go tests run locally on Windows from `recon-core\hiddify-sing-box` with `go test ./protocol/group/balancer/ ./common/monitoring/`. `go vet` of those packages passes today; keep it passing.
- Android AAR is built only in GitHub Actions (license condition 2 and the Makefile refuses Windows). Keep the upstream Makefile `android` target and its flags (`-gcflags "all=-N -l"`) unchanged in this plan; the compiler-flags experiment is a separate later candidate.
- Balancer option defaults (spec 5.1): `tolerance` 150 ms, `min_dwell` 60 s, `stall_timeout` 8 s, `stall_threshold` 3, `stall_window` 30 s, `rescue_batch` 6, `rescue_timeout` 5 s, `active_check_interval` 3 min, sweep 30 min. Every value is an option; nothing is hard-coded twice.
- Failover log line, exactly: `failover: <from> -> <to> reason=<reason> took=<ms>ms` with reason in `dial_error`, `stall`, `network_change`, `probe_failed`, `better_latency`, `manual`, `rescue_exhausted`.
- Servers with no successful measurement are never selected on their own; they are candidates for rescue probing only.
- No new wakeup alarms, wakelocks or continuous logging. Periodic work: active check (current server only), stall tick (1 s, only while the balancer has tracked connections), sweep (monitoring, 30 min default, pause-aware as today).
- Subscription URLs and server addresses never appear in docs or commits. Log lines may contain outbound tags (upstream already logs them).
- Commit messages: `type(scope): по-русски`, each commit ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze`.
- Prose (docs, comments, commit bodies) follows `~/.claude/skills/unslop/SKILL.md`.
- GitHub account `bambolumba-y`; forks are public (license condition 1).

---

## File map

sing-box fork (`recon-core/hiddify-sing-box`):
- Modify `option/balancer.go` — new failover fields.
- Modify `option/monitoring.go` — `DisableInterfaceSweep`.
- Create `protocol/group/balancer/failover_options.go` — defaults, `failoverConfig`, `normalizeFailover`.
- Rewrite `protocol/group/balancer/lowest_delay.go` — hysteresis, health, candidates, forced select.
- Create `protocol/group/balancer/failover.go` — controller: failure reports, rescue scan, active check, interface change, counters, `diag:` line.
- Create `protocol/group/balancer/stall.go` — connection wrapper and stall tracker.
- Modify `protocol/group/balancer/balancer.go` — wiring.
- Modify `common/monitoring/outbound_monitoring.go` — `TestAndWait`, negative interval disables sweep, `DisableInterfaceSweep`, `Stats`.
- Tests: `protocol/group/balancer/{failover_options,lowest_delay,failover,stall,scenario}_test.go`, `protocol/group/balancer/fakes_test.go`, `common/monitoring/options_test.go`.

hiddify-core fork (`recon-core`):
- Modify `.gitmodules` — sing-box submodule URL → fork.
- Create `.github/workflows/recon-core-android.yml` — AAR build + release.
- Modify `v2/config/hiddify_option.go` — `FailoverOptions`, defaults.
- Modify `v2/config/builder.go` — pass options into the `lowest` balancer and monitoring.
- Create `v2/config/failover_test.go`.

app (`hiddify-app`, branch `recon/stage2` cut from `recon/stage2-baseline`):
- Modify `.github/workflows/recon-android.yml`, `dependencies.properties` — download the fork AAR.
- Create `tool/core/fetch_core.sh` — same download for local builds.
- Modify `lib/features/connection/data/connection_repository.dart` — select `lowest` after auto connect.
- Modify `lib/features/settings/data/config_option_repository.dart` — sweep default 30 min.
- Create `tool/performance/go_scenarios.py`, `docs/performance/2026-09-XX-go-scenarios/summary.csv`.
- Docs: `docs/2026-09-XX_recon_stage2_core_failover.md`, plan/spec status lines.

---

### Task 1: Forks and pinned branches

**Files:**
- Modify: `recon-core/.gitmodules`
- Git: new GitHub repos `bambolumba-y/recon-core`, `bambolumba-y/recon-sing-box`; branches `recon/main` in both.

**Interfaces:**
- Produces: remote `recon` in both workspaces; branch `recon/main` in `recon-core` at `c9d6f0f0` + one commit; branch `recon/main` in `recon-core/hiddify-sing-box` at `0a02b772`.

- [ ] **Step 1: Fork both upstream repositories (no clone)**

```bash
gh repo fork hiddify/hiddify-sing-box --fork-name recon-sing-box --clone=false
gh repo fork hiddify/hiddify-core --fork-name recon-core --clone=false
gh repo view bambolumba-y/recon-sing-box --json isFork,defaultBranchRef
gh repo view bambolumba-y/recon-core --json isFork,defaultBranchRef
```

Expected: both views print `"isFork": true`.

- [ ] **Step 2: Push the pinned sing-box commit as `recon/main`**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core/hiddify-sing-box
git remote add recon https://github.com/bambolumba-y/recon-sing-box.git
git checkout -b recon/main 0a02b7729f6a211436bb8bdcd8696c283eb27767
git push -u recon recon/main
```

- [ ] **Step 3: Point the core submodule at the fork and push `recon/main`**

In `recon-core/.gitmodules` change the `hiddify-sing-box` entry URL to `https://github.com/bambolumba-y/recon-sing-box.git` and the `ray2sing` URL from the `git@github.com:` form to `https://github.com/hiddify/ray2sing.git`. Leave the recorded submodule commits unchanged (`git submodule status --recursive` must still print `0a02b772…` and `f58be84e…`).

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core
git remote add recon https://github.com/bambolumba-y/recon-core.git
git checkout -b recon/main
git submodule sync
git add .gitmodules
git commit -m "chore(recon): подмодуль sing-box указывает на форк recon-sing-box" -m "Закреплённые коммиты подмодулей не меняются: sing-box 0a02b772, ray2sing f58be84e. URL ray2sing переведён с SSH на HTTPS, чтобы рекурсивный checkout работал в GitHub Actions без ключей." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
git push -u recon recon/main
```

- [ ] **Step 4: Verify a fresh recursive clone resolves**

```bash
cd "$TMP" && git clone --recursive --branch recon/main https://github.com/bambolumba-y/recon-core.git verify-clone && git -C verify-clone submodule status --recursive && rm -rf verify-clone
```

Expected: two lines with `0a02b7729f6a211436bb8bdcd8696c283eb27767 hiddify-sing-box` and `f58be84e30d946915a1de437fbcc3d3ffca18a23 ray2sing`, no `-` prefix.

---

### Task 2: Reference AAR build in the fork's GitHub Actions

**Files:**
- Create: `recon-core/.github/workflows/recon-core-android.yml`

**Interfaces:**
- Produces: workflow "Recon Core Android"; release tag pattern `v4.1.0-recon.N` with asset `hiddify-lib-android.tar.gz` (same archive layout as upstream: `hiddify-core.aar` inside).

- [ ] **Step 1: Write the workflow**

```yaml
name: Recon Core Android

on:
  push:
    branches: [recon/main]
    tags: ['v*-recon.*']
  workflow_dispatch:

permissions:
  contents: write

jobs:
  android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          submodules: recursive
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          check-latest: false
      - uses: actions/setup-java@v5
        with:
          distribution: zulu
          java-version: '17'
      - id: ndk
        uses: nttld/setup-ndk@v1
        with:
          ndk-version: r28
      - name: Record toolchain
        run: |
          go version
          echo "ndk=${{ steps.ndk.outputs.ndk-path }}"
          git submodule status --recursive
      - name: Build AAR
        run: make android
        env:
          ANDROID_NDK_HOME: ${{ steps.ndk.outputs.ndk-path }}
          CODE_VERSION: "-X github.com/hiddify/hiddify-core/v2/hcommon/constants.Version=${{ github.ref_name }}"
      - name: Package
        working-directory: bin
        run: |
          tar -czvf hiddify-lib-android.tar.gz hiddify-core.aar
          sha256sum hiddify-lib-android.tar.gz hiddify-core.aar | tee SHA256SUMS
      - uses: actions/upload-artifact@v4
        with:
          name: hiddify-lib-android
          path: |
            bin/hiddify-lib-android.tar.gz
            bin/SHA256SUMS
      - name: Release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: |
            bin/hiddify-lib-android.tar.gz
            bin/SHA256SUMS
          generate_release_notes: false
```

`make android` runs `lib_install` → `prepare` (`go mod tidy`) first, as upstream does. Upstream's `zip` step deletes stray headers; ours packages only the AAR.

- [ ] **Step 2: Commit, push, run**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core
git add .github/workflows/recon-core-android.yml
git commit -m "chore(ci): сборка Android AAR ядра в GitHub Actions форка" -m "Эталонная сборка из неизменённых исходников v4.1.0. Флаги Makefile сохранены, включая -gcflags all=-N -l." -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -m "Claude-Session: https://claude.ai/code/session_01DUfv9GrgTW19uExaYWYDze"
git push recon recon/main
gh run list -R bambolumba-y/recon-core -w "Recon Core Android" -L 1
gh run watch -R bambolumba-y/recon-core --exit-status $(gh run list -R bambolumba-y/recon-core -w "Recon Core Android" -L 1 --json databaseId --jq '.[0].databaseId')
```

Expected: green. Budget 25–40 min (gomobile builds four ABIs). If `gomobile bind` fails on NDK discovery, set `ANDROID_HOME` to `$ANDROID_SDK_ROOT` in the Build step and retry once; report anything else.

- [ ] **Step 3: Tag the reference release**

```bash
git tag -a v4.1.0-recon.0 -m "Эталон: неизменённые исходники v4.1.0, сборка в Actions форка"
git push recon v4.1.0-recon.0
gh release view v4.1.0-recon.0 -R bambolumba-y/recon-core --json assets --jq '.assets[].name'
```

Expected: `hiddify-lib-android.tar.gz` and `SHA256SUMS`. Record the archive SHA-256 in the task report; it will differ from the official `6c4841f7…` (dirty upstream tree, different runner), which is expected and must be stated, not hidden.

---

### Task 3: Balancer failover options and defaults

**Files:**
- Modify: `recon-core/hiddify-sing-box/option/balancer.go`
- Modify: `recon-core/hiddify-sing-box/option/monitoring.go`
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/failover_options.go`
- Test: `recon-core/hiddify-sing-box/protocol/group/balancer/failover_options_test.go`

**Interfaces:**
- Produces: `option.BalancerOutboundOptions` fields `MinDwell, StallTimeout, StallThreshold, StallWindow, RescueBatch, RescueTimeout, ActiveCheckInterval`; `option.MonitoringOptions.DisableInterfaceSweep bool`; `balancer.failoverConfig` and `balancer.normalizeFailover(option.BalancerOutboundOptions) failoverConfig`.

- [ ] **Step 1: Failing test**

```go
package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func TestNormalizeFailoverDefaults(t *testing.T) {
	cfg := normalizeFailover(option.BalancerOutboundOptions{})
	if cfg.tolerance != 150 || cfg.minDwell != 60*time.Second || cfg.stallTimeout != 8*time.Second ||
		cfg.stallThreshold != 3 || cfg.stallWindow != 30*time.Second || cfg.rescueBatch != 6 ||
		cfg.rescueTimeout != 5*time.Second || cfg.activeCheckInterval != 3*time.Minute {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
}

func TestNormalizeFailoverOverrides(t *testing.T) {
	cfg := normalizeFailover(option.BalancerOutboundOptions{
		Tolerance:           40,
		MinDwell:            badoption.Duration(5 * time.Second),
		StallTimeout:        badoption.Duration(2 * time.Second),
		StallThreshold:      1,
		StallWindow:         badoption.Duration(10 * time.Second),
		RescueBatch:         2,
		RescueTimeout:       badoption.Duration(time.Second),
		ActiveCheckInterval: badoption.Duration(-1),
	})
	if cfg.tolerance != 40 || cfg.minDwell != 5*time.Second || cfg.stallThreshold != 1 || cfg.rescueBatch != 2 {
		t.Fatalf("overrides not applied: %+v", cfg)
	}
	if cfg.activeCheckInterval != 0 {
		t.Fatalf("negative active_check_interval must disable the check, got %v", cfg.activeCheckInterval)
	}
}
```

Run: `cd recon-core/hiddify-sing-box && go test ./protocol/group/balancer/ -run TestNormalizeFailover -v` → FAIL (undefined `normalizeFailover`).

- [ ] **Step 2: Options**

`option/balancer.go`:

```go
type BalancerOutboundOptions struct {
	Outbounds                 []string           `json:"outbounds"`
	Tolerance                 uint16             `json:"tolerance,omitempty"`
	InterruptExistConnections bool               `json:"interrupt_exist_connections,omitempty"`
	Strategy                  string             `json:"strategy,omitempty"`
	DelayAcceptableRatio      float64            `json:"delay_acceptable_ratio,omitempty"`
	TTL                       badoption.Duration `json:"ttl,omitempty"`
	MaxRetry                  int                `json:"max_retry,omitempty"` //not implemented yet

	// Recon failover (lowest-delay strategy only). Zero means default, negative disables where noted.
	MinDwell            badoption.Duration `json:"min_dwell,omitempty"`
	StallTimeout        badoption.Duration `json:"stall_timeout,omitempty"`
	StallThreshold      int                `json:"stall_threshold,omitempty"`
	StallWindow         badoption.Duration `json:"stall_window,omitempty"`
	RescueBatch         int                `json:"rescue_batch,omitempty"`
	RescueTimeout       badoption.Duration `json:"rescue_timeout,omitempty"`
	ActiveCheckInterval badoption.Duration `json:"active_check_interval,omitempty"` // negative disables
}
```

`option/monitoring.go`: add `DisableInterfaceSweep bool `json:"disable_interface_sweep,omitempty"`` with a comment: when true, a network change no longer starts a full monitoring cycle; the balancer probes only its current server.

- [ ] **Step 3: `failover_options.go`**

```go
package balancer

import (
	"time"

	"github.com/sagernet/sing-box/option"
)

const (
	defaultTolerance           uint16 = 150
	defaultMinDwell                   = 60 * time.Second
	defaultStallTimeout               = 8 * time.Second
	defaultStallThreshold             = 3
	defaultStallWindow                = 30 * time.Second
	defaultRescueBatch                = 6
	defaultRescueTimeout              = 5 * time.Second
	defaultActiveCheckInterval        = 3 * time.Minute
	stallTick                         = time.Second
	diagInterval                      = 15 * time.Minute
)

var rescueBackoff = []time.Duration{10 * time.Second, 30 * time.Second, 60 * time.Second, 120 * time.Second}

type failoverConfig struct {
	tolerance           uint16
	minDwell            time.Duration
	stallTimeout        time.Duration
	stallThreshold      int
	stallWindow         time.Duration
	rescueBatch         int
	rescueTimeout       time.Duration
	activeCheckInterval time.Duration // 0 = disabled
}

func durationOr(v time.Duration, def time.Duration) time.Duration {
	if v == 0 {
		return def
	}
	if v < 0 {
		return 0
	}
	return v
}

func normalizeFailover(o option.BalancerOutboundOptions) failoverConfig {
	cfg := failoverConfig{
		tolerance:           o.Tolerance,
		minDwell:            durationOr(o.MinDwell.Build(), defaultMinDwell),
		stallTimeout:        durationOr(o.StallTimeout.Build(), defaultStallTimeout),
		stallThreshold:      o.StallThreshold,
		stallWindow:         durationOr(o.StallWindow.Build(), defaultStallWindow),
		rescueBatch:         o.RescueBatch,
		rescueTimeout:       durationOr(o.RescueTimeout.Build(), defaultRescueTimeout),
		activeCheckInterval: durationOr(o.ActiveCheckInterval.Build(), defaultActiveCheckInterval),
	}
	if cfg.tolerance == 0 {
		cfg.tolerance = defaultTolerance
	}
	if cfg.stallThreshold <= 0 {
		cfg.stallThreshold = defaultStallThreshold
	}
	if cfg.rescueBatch <= 0 {
		cfg.rescueBatch = defaultRescueBatch
	}
	return cfg
}
```

Note: upstream hiddify-core sets `Tolerance: 1` on both balancers today; Task 9 changes the `lowest` balancer to pass the configured value. A tolerance of 1 ms in the field would mean switching on noise, so Task 9 is not optional.

- [ ] **Step 4: Run tests, vet, commit**

```bash
go test ./protocol/group/balancer/ -run TestNormalizeFailover -v && go vet ./option/ ./protocol/group/balancer/
git add option/balancer.go option/monitoring.go protocol/group/balancer/failover_options.go protocol/group/balancer/failover_options_test.go
git commit -m "feat(balancer): опции отказоустойчивости и их значения по умолчанию"
```

(Trailers as in Global Constraints on every commit; omitted below for brevity.)

---

### Task 4: LowestDelay with hysteresis and health

**Files:**
- Rewrite: `recon-core/hiddify-sing-box/protocol/group/balancer/lowest_delay.go`
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/fakes_test.go`
- Test: `recon-core/hiddify-sing-box/protocol/group/balancer/lowest_delay_test.go`

**Interfaces:**
- Consumes: `failoverConfig` (Task 3), `adapter.URLTestHistory`, `monitoring.TimeoutDelay`.
- Produces:

```go
type switchEvent struct{ Network, From, To, Reason string }

func NewLowestDelay(outbounds []adapter.Outbound, options option.BalancerOutboundOptions) *LowestDelay
func (s *LowestDelay) Now() string                                   // TCP selection tag
func (s *LowestDelay) Select(metadata adapter.InboundContext, network string, touch bool) adapter.Outbound
func (s *LowestDelay) UpdateOutboundsInfo(history map[string]*adapter.URLTestHistory) bool // Strategy iface
func (s *LowestDelay) MarkFailed(tag, reason string) (switched bool, hasCandidate bool) // non-current tag: (false, true); current with no healthy candidate: (false, false)
func (s *LowestDelay) ForceSelect(tag, reason string, delay uint16) bool // delay>0 records a synthetic measured history so the tag counts as healthy
func (s *LowestDelay) Healthy(tag string) bool
func (s *LowestDelay) Candidates(exclude string) []string           // measured-first by delay, unknown last
func (s *LowestDelay) Events() []switchEvent                        // drained by caller (Task 6/8)
// test seams
func (s *LowestDelay) setClock(now func() time.Time)
```

Rules (spec 5.2): a tag is *measured* when its latest history has `0 < Delay < TimeoutDelay` and `!IsFromCache`; *healthy* = measured and not marked failed after that history's `Time`. Current stays while healthy. Failure → immediate switch to best healthy candidate (dwell ignored). Latency switch only if `best.delay + tolerance < current.delay` and `now - lastSwitch >= minDwell`. Unknown (unmeasured or cached) never selected by `UpdateOutboundsInfo`; the initial selection before any measurement is the first outbound (as upstream) and is marked provisional so the first successful measurement of any server replaces it without dwell.

- [ ] **Step 1: Fakes**

```go
package balancer

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type fakeOutbound struct {
	outbound.Adapter
	mu   sync.Mutex
	dial func(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error)
}

func newFakeOutbound(tag string) *fakeOutbound {
	return &fakeOutbound{Adapter: outbound.NewAdapter("fake", tag, []string{N.NetworkTCP, N.NetworkUDP}, nil)}
}

func (f *fakeOutbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	f.mu.Lock()
	dial := f.dial
	f.mu.Unlock()
	if dial == nil {
		c, _ := net.Pipe()
		return c, nil
	}
	return dial(ctx, network, destination)
}

func (f *fakeOutbound) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	return nil, net.ErrClosed
}

func fakeOutbounds(tags ...string) []adapter.Outbound {
	res := make([]adapter.Outbound, 0, len(tags))
	for _, tag := range tags {
		res = append(res, newFakeOutbound(tag))
	}
	return res
}

func measured(delay uint16, at time.Time) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{Time: at, Delay: delay}
}

func failedHistory(at time.Time) *adapter.URLTestHistory {
	return &adapter.URLTestHistory{Time: at, Delay: 65535}
}

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock { return &fakeClock{now: time.Unix(1_700_000_000, 0)} }
func (c *fakeClock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *fakeClock) Advance(d time.Duration) { c.mu.Lock(); c.now = c.now.Add(d); c.mu.Unlock() }
```

- [ ] **Step 2: Failing tests**

```go
package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
)

func newLD(clock *fakeClock, tags ...string) *LowestDelay {
	s := NewLowestDelay(fakeOutbounds(tags...), option.BalancerOutboundOptions{})
	s.setClock(clock.Now)
	return s
}

func TestInitialSelectionIsProvisionalUntilMeasured(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b")
	if s.Now() != "a" {
		t.Fatalf("initial = %q", s.Now())
	}
	// only b measured: switch without dwell
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"b": measured(300, c.Now())})
	if s.Now() != "b" {
		t.Fatalf("provisional selection must yield to the first measured server, got %q", s.Now())
	}
}

func TestNoSwitchUnderTolerance(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(200, c.Now()), "b": measured(400, c.Now())})
	c.Advance(10 * time.Minute)
	changed := s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(200, c.Now()), "b": measured(100, c.Now())})
	if changed || s.Now() != "a" {
		t.Fatalf("100 ms gain is under tolerance 150: changed=%v now=%q", changed, s.Now())
	}
}

func TestNoLatencySwitchInsideDwell(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(200, c.Now())}) // provisional -> a (lastSwitch = now)
	c.Advance(30 * time.Second)
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(500, c.Now()), "b": measured(50, c.Now())})
	if s.Now() != "a" {
		t.Fatalf("dwell 60s not elapsed, got %q", s.Now())
	}
	c.Advance(31 * time.Second)
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(500, c.Now()), "b": measured(50, c.Now())})
	if s.Now() != "b" {
		t.Fatalf("after dwell the better server must be selected, got %q", s.Now())
	}
	ev := s.Events()
	if len(ev) == 0 || ev[len(ev)-1].Reason != "better_latency" {
		t.Fatalf("events = %+v", ev)
	}
}

func TestFailureSwitchIgnoresDwell(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now()), "b": measured(900, c.Now())})
	switched, has := s.MarkFailed("a", "dial_error")
	if !switched || !has || s.Now() != "b" {
		t.Fatalf("switched=%v has=%v now=%q", switched, has, s.Now())
	}
	if s.Healthy("a") {
		t.Fatal("a must be unhealthy after MarkFailed")
	}
}

func TestUnknownNeverSelectedBlind(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b", "c")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now())})
	switched, has := s.MarkFailed("a", "stall")
	if switched || has || s.Now() != "a" {
		t.Fatalf("no measured candidate: must stay on a and report no candidate; switched=%v has=%v now=%q", switched, has, s.Now())
	}
	got := s.Candidates("a")
	if len(got) != 2 {
		t.Fatalf("candidates = %v", got)
	}
}

func TestCandidatesOrderMeasuredFirst(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b", "c", "d")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{
		"a": measured(100, c.Now()), "b": measured(50, c.Now()), "c": {Time: c.Now(), Delay: 10, IsFromCache: true},
	})
	got := s.Candidates("a")
	if len(got) != 3 || got[0] != "b" || (got[1] != "c" && got[2] != "c") {
		t.Fatalf("order = %v (measured b first, cached/unknown c,d last)", got)
	}
}

func TestSuccessfulProbeClearsFailure(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now()), "b": measured(200, c.Now())})
	s.MarkFailed("a", "dial_error")
	c.Advance(time.Second)
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(90, c.Now()), "b": measured(200, c.Now())})
	if !s.Healthy("a") {
		t.Fatal("a probe newer than the failure mark must make a healthy again")
	}
}

func TestForceSelect(t *testing.T) {
	c := newFakeClock()
	s := newLD(c, "a", "b")
	if !s.ForceSelect("b", "rescue", 120) || s.Now() != "b" || !s.Healthy("b") {
		t.Fatalf("force select failed, now=%q", s.Now())
	}
	if s.ForceSelect("zzz", "rescue", 120) {
		t.Fatal("unknown tag must be rejected")
	}
}
```

Run: `go test ./protocol/group/balancer/ -run 'TestInitial|TestNoSwitch|TestNoLatency|TestFailure|TestUnknown|TestCandidates|TestSuccessful|TestForce' -v` → FAIL (missing methods).

- [ ] **Step 3: Implementation**

```go
package balancer

import (
	"sort"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/monitoring"
	"github.com/sagernet/sing-box/option"
	N "github.com/sagernet/sing/common/network"
)

type switchEvent struct {
	Network, From, To, Reason string
}

type LowestDelay struct {
	outbounds   map[string][]adapter.Outbound
	byTag       map[string]adapter.Outbound
	selected    map[string]adapter.Outbound
	provisional bool
	cfg         failoverConfig
	now         func() time.Time
	lastSwitch  time.Time
	history     map[string]*adapter.URLTestHistory
	failedAt    map[string]time.Time
	events      []switchEvent
	mu          sync.Mutex
}

var _ Strategy = (*LowestDelay)(nil)

func NewLowestDelay(outbounds []adapter.Outbound, options option.BalancerOutboundOptions) *LowestDelay {
	couts := convertOutbounds(outbounds)
	byTag := make(map[string]adapter.Outbound, len(outbounds))
	for _, o := range outbounds {
		byTag[o.Tag()] = o
	}
	return &LowestDelay{
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
}

func (s *LowestDelay) setClock(now func() time.Time) { s.mu.Lock(); s.now = now; s.mu.Unlock() }

func (s *LowestDelay) Now() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.selected[N.NetworkTCP].Tag()
}

func (s *LowestDelay) Select(metadata adapter.InboundContext, network string, touch bool) adapter.Outbound {
	s.mu.Lock()
	defer s.mu.Unlock()
	if network != N.NetworkTCP && network != N.NetworkUDP {
		network = N.NetworkTCP
	}
	return s.selected[network]
}

func (s *LowestDelay) Events() []switchEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	ev := s.events
	s.events = nil
	return ev
}

// measuredLocked: latest probe succeeded and is not a cache entry.
func (s *LowestDelay) measuredLocked(tag string) (uint16, bool) {
	h := s.history[tag]
	if h == nil || h.IsFromCache || h.Delay == 0 || h.Delay >= monitoring.TimeoutDelay {
		return 0, false
	}
	return h.Delay, true
}

func (s *LowestDelay) healthyLocked(tag string) bool {
	d, ok := s.measuredLocked(tag)
	if !ok || d == 0 {
		return false
	}
	if at, failed := s.failedAt[tag]; failed && !s.history[tag].Time.After(at) {
		return false
	}
	return true
}

func (s *LowestDelay) Healthy(tag string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.healthyLocked(tag)
}

// bestLocked returns the healthy outbound with the lowest delay for network, excluding tag.
func (s *LowestDelay) bestLocked(network, exclude string) (adapter.Outbound, uint16) {
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

func (s *LowestDelay) switchLocked(network string, to adapter.Outbound, reason string) {
	from := s.selected[network]
	if from != nil && from.Tag() == to.Tag() {
		return
	}
	s.selected[network] = to
	fromTag := ""
	if from != nil {
		fromTag = from.Tag()
	}
	s.events = append(s.events, switchEvent{Network: network, From: fromTag, To: to.Tag(), Reason: reason})
	if network == N.NetworkTCP {
		s.lastSwitch = s.now()
		s.provisional = false
	}
}

func (s *LowestDelay) UpdateOutboundsInfo(history map[string]*adapter.URLTestHistory) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for tag, h := range history {
		if h != nil {
			copyH := *h
			s.history[tag] = &copyH
		}
	}
	changed := false
	now := s.now()
	for _, network := range []string{N.NetworkTCP, N.NetworkUDP} {
		cur := s.selected[network]
		best, bestDelay := s.bestLocked(network, "")
		if best == nil {
			continue
		}
		switch {
		case s.provisional || !s.healthyLocked(cur.Tag()):
			if best.Tag() != cur.Tag() {
				s.switchLocked(network, best, "probe_failed")
				changed = true
			}
		default:
			curDelay, _ := s.measuredLocked(cur.Tag())
			if uint32(bestDelay)+uint32(s.cfg.tolerance) < uint32(curDelay) && now.Sub(s.lastSwitch) >= s.cfg.minDwell {
				s.switchLocked(network, best, "better_latency")
				changed = true
			}
		}
	}
	return changed
}

// MarkFailed records a failure signal for tag. If tag is the current selection, it switches to the best
// healthy candidate right away. hasCandidate=false tells the caller to start a rescue scan.
func (s *LowestDelay) MarkFailed(tag, reason string) (switched bool, hasCandidate bool) // non-current tag: (false, true); current with no healthy candidate: (false, false) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failedAt[tag] = s.now()
	for _, network := range []string{N.NetworkTCP, N.NetworkUDP} {
		cur := s.selected[network]
		if cur == nil || cur.Tag() != tag {
			continue
		}
		best, _ := s.bestLocked(network, tag)
		if best == nil {
			continue
		}
		hasCandidate = true
		s.switchLocked(network, best, reason)
		switched = true
	}
	return switched, hasCandidate
}

// ForceSelect selects tag for both networks (rescue result or manual pick). The tag is treated as alive.
func (s *LowestDelay) ForceSelect(tag, reason string, delay uint16) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	o, ok := s.byTag[tag]
	if !ok {
		return false
	}
	delete(s.failedAt, tag)
	for _, network := range []string{N.NetworkTCP, N.NetworkUDP} {
		s.switchLocked(network, o, reason)
	}
	return true
}

// Candidates lists all tags except exclude: healthy measured first by delay, then unknown/failed in
// configuration order.
func (s *LowestDelay) Candidates(exclude string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
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

Keep the exported method set exactly as listed in Interfaces.

- [ ] **Step 4: Run all balancer tests, vet, commit**

```bash
go test ./protocol/group/balancer/ -v && go vet ./protocol/group/balancer/
git add protocol/group/balancer/lowest_delay.go protocol/group/balancer/fakes_test.go protocol/group/balancer/lowest_delay_test.go
git commit -m "feat(balancer): гистерезис и признак здоровья в стратегии lowest-delay"
```

---

### Task 5: Monitoring — synchronous probe, sweep switches, counters

**Files:**
- Modify: `recon-core/hiddify-sing-box/common/monitoring/outbound_monitoring.go`
- Test: `recon-core/hiddify-sing-box/common/monitoring/options_test.go`

**Interfaces:**
- Produces:

```go
// TestAndWait probes one outbound now, bypassing the queues, stores the result like a queued test and
// returns it. It is the prober used by the balancer's active check and rescue scan.
func (m *OutboundMonitoring) TestAndWait(ctx context.Context, tag string, timeout time.Duration) (adapter.URLTestHistory, error)

type Stats struct {
	CyclesStarted, CyclesSkipped                       uint64
	ProbesQueued, ProbesDirect, ProbesOK, ProbesFailed uint64
}
func (m *OutboundMonitoring) Stats() Stats
func (m *OutboundMonitoring) SweepEnabled() bool
```

Behaviour changes:
1. `options.Interval < 0` → sweep disabled: `startTimerWorkers` does not create a ticker or schedule loop; `Touch` still records activity; `SweepEnabled()` false. `Interval == 0` keeps the 5 min default (upstream `omitempty` compatibility).
2. `InterfaceUpdated`: if `options.DisableInterfaceSweep` → do nothing (count `CyclesSkipped`), else current behaviour.
3. Counters: `startCycleOnce` increments `CyclesStarted` on success and `CyclesSkipped` when the CAS fails; `executeTask` increments `ProbesQueued`; `TestAndWait` increments `ProbesDirect`; `applyResult` increments `ProbesOK`/`ProbesFailed` by `outcome.err`.
4. `TestAndWait` implementation: look up state; `ctx, cancel := context.WithTimeout(ctx, timeout)`; call `m.tester(ctx, tag)` (it already applies its own `urlTestTimeout` on top; the shorter wins); build `testOutcome{outboundTag: tag, history: his, err: err, priority: true}`; `m.applyResult(outcome)`; return. Do not touch `state.testing` (the queue path owns it) but do skip when `state == nil` with `errors.New("outbound not registered")`.

- [ ] **Step 1: Failing tests** (`options_test.go`, package `monitoring`)

```go
package monitoring

import (
	"context"
	"testing"
	"time"

	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func newTestMonitor(t *testing.T, opts option.MonitoringOptions) *OutboundMonitoring {
	t.Helper()
	m, err := NewOutboundMonitoring(context.Background(), log.NewNOPFactory().NewLogger("test"), opts)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestNegativeIntervalDisablesSweep(t *testing.T) {
	m := newTestMonitor(t, option.MonitoringOptions{Interval: badoption.Duration(-1)})
	if m.SweepEnabled() {
		t.Fatal("negative interval must disable the sweep")
	}
	m.started = true
	m.Touch() // must not panic and must not start a ticker
	if m.mainTicker != nil {
		t.Fatal("ticker must not start when the sweep is disabled")
	}
}

func TestZeroIntervalKeepsDefault(t *testing.T) {
	m := newTestMonitor(t, option.MonitoringOptions{})
	if !m.SweepEnabled() || m.mainInterval != 5*time.Minute {
		t.Fatalf("enabled=%v interval=%v", m.SweepEnabled(), m.mainInterval)
	}
}

func TestInterfaceSweepCanBeDisabled(t *testing.T) {
	m := newTestMonitor(t, option.MonitoringOptions{DisableInterfaceSweep: true})
	m.InterfaceUpdated()
	if s := m.Stats(); s.CyclesStarted != 0 || s.CyclesSkipped != 1 {
		t.Fatalf("stats = %+v", s)
	}
}

func TestTestAndWaitUnknownTag(t *testing.T) {
	m := newTestMonitor(t, option.MonitoringOptions{})
	if _, err := m.TestAndWait(context.Background(), "nope", time.Second); err == nil {
		t.Fatal("unknown tag must return an error")
	}
}
```

`NewOutboundMonitoring` reads services from ctx with `service.FromContext`, which returns zero values for a bare context; the constructor does not dereference them. If it panics in the test, add nil guards where the test hits them (constructor only), never in hot paths. Run → FAIL (`SweepEnabled`, `Stats`, `TestAndWait` undefined).

- [ ] **Step 2: Implement** the four behaviour changes above. `Stats` uses `atomic.Uint64` fields on the struct. In `startTimerWorkers`, return early when `m.mainInterval <= 0` (store `mainInterval = -1` when the option is negative; keep `SweepEnabled() { return m.mainInterval > 0 }`). In `scheduleLoop` nothing changes because it is never started.

- [ ] **Step 3: Run, vet, commit**

```bash
go test ./common/monitoring/ -v && go vet ./common/monitoring/
git add common/monitoring/outbound_monitoring.go common/monitoring/options_test.go
git commit -m "feat(monitoring): прямая проверка сервера, отключаемый обход и счётчики"
```

---

### Task 6: Failover controller — failures, rescue scan, active check, interface change

**Files:**
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/failover.go`
- Test: `recon-core/hiddify-sing-box/protocol/group/balancer/failover_test.go`

**Interfaces:**
- Consumes: `*LowestDelay` (Task 4), `failoverConfig` (Task 3).
- Produces:

```go
type prober interface {
	Probe(ctx context.Context, tag string, timeout time.Duration) (delay uint16, err error)
}

type failoverLogger interface {
	Info(args ...any)
	Warn(args ...any)
}

type failoverCounters struct {
	ProbesActive, ProbesRescue, ProbesInterface uint64 // started
	ProbesOK, ProbesFailed                     uint64
	Rescues, RescueExhausted                   uint64
	Switches                                   map[string]uint64 // by reason
	Stalls                                     uint64
}

type failover struct { /* private */ }

func newFailover(ctx context.Context, cfg failoverConfig, strategy *LowestDelay, probe prober, logger failoverLogger, onSwitch func()) *failover
func (f *failover) start()                                  // active check loop + diag loop
func (f *failover) stop()
func (f *failover) reportFailure(tag, reason string)        // from dial error, stall, active check
func (f *failover) onInterfaceChange()                      // light probe of current, reset stalls
func (f *failover) drainEvents()                            // logs strategy events as failover lines
func (f *failover) counters() failoverCounters
// test seams
func (f *failover) setClock(now func() time.Time, sleep func(ctx context.Context, d time.Duration) error)
func (f *failover) waitIdle(timeout time.Duration) bool     // true when no rescue is running
```

Behaviour:
- `reportFailure(tag, reason)`: if `tag != strategy.Now()` → record nothing but still return (the monitoring invalidation is done by the caller). Else `switched, has := strategy.MarkFailed(tag, reason)`; if `switched` → `drainEvents()` (logs `failover:` line with `took=0ms`), `onSwitch()`; if `!has` → `startRescue(reason)`.
- `startRescue(reason)`: single flight (`atomic.Bool`); goroutine: `started := now()`; for attempt 0..∞: `from := strategy.Now()`; if `strategy.Healthy(from)` → stop (a sweep revived it). `cands := strategy.Candidates(from)`; for each batch of `cfg.rescueBatch`: probe all in parallel with `cfg.rescueTimeout` (each probe: `ProbesRescue++`, outcome counters); the first success (lowest delay among the batch's successes) → `strategy.ForceSelect(tag, reason, delay)`; log `failover: <from> -> <tag> reason=<reason> took=<ms since started>ms`; `onSwitch()`; `Rescues++`; return. If all batches fail: `RescueExhausted++`; log `failover: <from> -> <from> reason=rescue_exhausted took=<ms>ms`; `sleep(backoff[min(attempt, len-1)])`; on ctx error return.
- Active check: only when `cfg.activeCheckInterval > 0`; loop: `sleep(interval)`; if paused (see below) → continue; `tag := strategy.Now()`; probe with `cfg.rescueTimeout` (`ProbesActive++`); on error → `reportFailure(tag, "probe_failed")`. Pause: `newFailover` receives nothing about pause; the Balancer (Task 8) passes `paused func() bool` through a setter `setPaused(func() bool)`; default `func() bool { return false }`.
- `onInterfaceChange()`: `stalls.reset()` (Task 7 provides; here call a `resetStalls func()` hook set by Task 8, default no-op); probe current once in a goroutine (`ProbesInterface++`); on error → `reportFailure(tag, "network_change")`.
- Diag loop: every `diagInterval` while running, and once in `stop()`: `logger.Info("diag: current=", tag, " probes_active=", …, " probes_rescue=", …, " probes_ok=", …, " probes_failed=", …, " rescues=", …, " rescue_exhausted=", …, " stalls=", …, " switches=", <reason=count comma-joined sorted>)`. Counts only; no addresses.
- `drainEvents()`: for each `strategy.Events()` entry with network TCP: `logger.Info("failover: ", ev.From, " -> ", ev.To, " reason=", ev.Reason, " took=0ms")`; `Switches[ev.Reason]++`. UDP events are counted but not logged (they mirror TCP).

- [ ] **Step 1: Failing tests**

```go
package balancer

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

type scriptedProber struct {
	mu     sync.Mutex
	delays map[string]uint16 // missing or 0 => error
	calls  []string
	block  map[string]chan struct{} // optional: probe waits until channel closed
}

func (p *scriptedProber) Probe(ctx context.Context, tag string, timeout time.Duration) (uint16, error) {
	p.mu.Lock()
	p.calls = append(p.calls, tag)
	d := p.delays[tag]
	b := p.block[tag]
	p.mu.Unlock()
	if b != nil {
		select {
		case <-b:
		case <-ctx.Done():
			return 0, ctx.Err()
		}
	}
	if d == 0 {
		return 0, errors.New("probe failed")
	}
	return d, nil
}

func (p *scriptedProber) set(tag string, delay uint16) { p.mu.Lock(); p.delays[tag] = delay; p.mu.Unlock() }
func (p *scriptedProber) count(tag string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	n := 0
	for _, c := range p.calls {
		if c == tag {
			n++
		}
	}
	return n
}

type memLogger struct {
	mu    sync.Mutex
	lines []string
}

func (l *memLogger) Info(args ...any) { l.add(args...) }
func (l *memLogger) Warn(args ...any) { l.add(args...) }
func (l *memLogger) add(args ...any) {
	var b strings.Builder
	for _, a := range args {
		b.WriteString(strings.TrimSpace(strings.Trim(fmtAny(a), "\n")))
	}
	l.mu.Lock()
	l.lines = append(l.lines, b.String())
	l.mu.Unlock()
}
func (l *memLogger) has(sub string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, ln := range l.lines {
		if strings.Contains(ln, sub) {
			return true
		}
	}
	return false
}

func fmtAny(a any) string { return strings.TrimSpace(fmt.Sprint(a)) }

func newHarness(t *testing.T, tags ...string) (*failover, *LowestDelay, *scriptedProber, *memLogger, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	strategy := NewLowestDelay(fakeOutbounds(tags...), option.BalancerOutboundOptions{
		RescueBatch: 2, RescueTimeout: badoption.Duration(50 * time.Millisecond), ActiveCheckInterval: badoption.Duration(-1),
	})
	strategy.setClock(clock.Now)
	p := &scriptedProber{delays: map[string]uint16{}, block: map[string]chan struct{}{}}
	l := &memLogger{}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	f := newFailover(ctx, strategy.cfg, strategy, p, l, func() {})
	f.setClock(clock.Now, func(ctx context.Context, d time.Duration) error { // virtual sleep: advance and yield
		clock.Advance(d)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Millisecond):
			return nil
		}
	})
	return f, strategy, p, l, clock
}

func TestFailureWithCandidateSwitchesWithoutProbe(t *testing.T) {
	f, s, p, l, c := newHarness(t, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now()), "b": measured(200, c.Now())})
	f.reportFailure("a", "dial_error")
	if s.Now() != "b" || len(p.calls) != 0 {
		t.Fatalf("now=%q probes=%v", s.Now(), p.calls)
	}
	if !l.has("failover: a -> b reason=dial_error took=0ms") {
		t.Fatalf("log lines: %v", l.lines)
	}
}

func TestFailureForNonCurrentIsIgnored(t *testing.T) {
	f, s, _, _, c := newHarness(t, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now()), "b": measured(200, c.Now())})
	f.reportFailure("b", "dial_error")
	if s.Now() != "a" || !s.Healthy("a") {
		t.Fatal("a failure of a non-selected server must not move the selection")
	}
}

func TestRescuePicksFirstResponderInBatches(t *testing.T) {
	f, s, p, l, c := newHarness(t, "a", "b", "c", "d", "e")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now())})
	p.set("d", 300) // only d answers; batches: [b c] then [d e]
	f.reportFailure("a", "stall")
	if !f.waitIdle(2 * time.Second) {
		t.Fatal("rescue did not finish")
	}
	if s.Now() != "d" {
		t.Fatalf("now=%q calls=%v", s.Now(), p.calls)
	}
	if p.count("e") > 1 || p.count("b") != 1 || p.count("c") != 1 {
		t.Fatalf("batching wrong: %v", p.calls)
	}
	if !l.has("failover: a -> d reason=stall") {
		t.Fatalf("lines: %v", l.lines)
	}
	if got := f.counters(); got.Rescues != 1 || got.ProbesRescue < 3 {
		t.Fatalf("counters = %+v", got)
	}
}

func TestRescueExhaustedBacksOffThenRecovers(t *testing.T) {
	f, s, p, l, c := newHarness(t, "a", "b", "c")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now())})
	f.reportFailure("a", "dial_error")
	deadline := time.Now().Add(2 * time.Second)
	for p.count("b") < 2 && time.Now().Before(deadline) { // second attempt reached => backoff slept once
		time.Sleep(5 * time.Millisecond)
	}
	if !l.has("reason=rescue_exhausted") {
		t.Fatalf("lines: %v", l.lines)
	}
	p.set("c", 250)
	if !f.waitIdle(2 * time.Second) || s.Now() != "c" {
		t.Fatalf("now=%q lines=%v", s.Now(), l.lines)
	}
	if f.counters().RescueExhausted == 0 {
		t.Fatal("exhausted attempts must be counted")
	}
}

func TestRescueIsSingleFlight(t *testing.T) {
	f, s, p, _, c := newHarness(t, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now())})
	gate := make(chan struct{})
	p.block["b"] = gate
	f.reportFailure("a", "dial_error")
	f.reportFailure("a", "stall")
	f.reportFailure("a", "probe_failed")
	time.Sleep(20 * time.Millisecond)
	if p.count("b") != 1 {
		t.Fatalf("concurrent failure reports must not start parallel rescues: %v", p.calls)
	}
	p.set("b", 120)
	close(gate)
	if !f.waitIdle(2*time.Second) || s.Now() != "b" {
		t.Fatalf("now=%q", s.Now())
	}
}

func TestRescueStopsWhenCurrentRevives(t *testing.T) {
	f, s, p, _, c := newHarness(t, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now())})
	f.reportFailure("a", "dial_error") // b unknown and failing -> exhausted, backoff
	time.Sleep(20 * time.Millisecond)
	c.Advance(time.Second)
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(90, c.Now())}) // sweep says a is fine
	if !f.waitIdle(3 * time.Second) {
		t.Fatal("rescue must stop once the current server is healthy again")
	}
	_ = p
}

func TestActiveCheckFailureTriggersSwitch(t *testing.T) {
	clock := newFakeClock()
	strategy := NewLowestDelay(fakeOutbounds("a", "b"), option.BalancerOutboundOptions{
		ActiveCheckInterval: badoption.Duration(time.Minute), RescueTimeout: badoption.Duration(50 * time.Millisecond),
	})
	strategy.setClock(clock.Now)
	strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, clock.Now()), "b": measured(200, clock.Now())})
	p := &scriptedProber{delays: map[string]uint16{"b": 200}, block: map[string]chan struct{}{}}
	l := &memLogger{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := newFailover(ctx, strategy.cfg, strategy, p, l, func() {})
	f.setClock(clock.Now, func(ctx context.Context, d time.Duration) error {
		clock.Advance(d)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Millisecond):
			return nil
		}
	})
	f.start()
	defer f.stop()
	deadline := time.Now().Add(2 * time.Second)
	for strategy.Now() != "b" && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if strategy.Now() != "b" || p.count("a") == 0 {
		t.Fatalf("now=%q calls=%v", strategy.Now(), p.calls)
	}
	if !l.has("reason=probe_failed") {
		t.Fatalf("lines: %v", l.lines)
	}
}

func TestInterfaceChangeProbesOnlyCurrent(t *testing.T) {
	f, s, p, _, c := newHarness(t, "a", "b", "c")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now()), "b": measured(150, c.Now())})
	p.set("a", 110)
	f.onInterfaceChange()
	time.Sleep(20 * time.Millisecond)
	if p.count("a") != 1 || p.count("b") != 0 || p.count("c") != 0 || s.Now() != "a" {
		t.Fatalf("calls=%v now=%q", p.calls, s.Now())
	}
}

func TestDiagLineHasCountsOnly(t *testing.T) {
	f, _, _, l, _ := newHarness(t, "a", "b")
	f.logDiag()
	if !l.has("diag: current=a probes_active=0") || l.has("http") {
		t.Fatalf("lines: %v", l.lines)
	}
}
```

Add `"fmt"` to the imports. Run → FAIL (undefined `newFailover`).

- [ ] **Step 2: Implement `failover.go`** following the Behaviour list. Skeleton:

```go
package balancer

import (
	"context"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type prober interface {
	Probe(ctx context.Context, tag string, timeout time.Duration) (uint16, error)
}

type failoverLogger interface {
	Info(args ...any)
	Warn(args ...any)
}

type failoverCounters struct {
	ProbesActive, ProbesRescue, ProbesInterface uint64
	ProbesOK, ProbesFailed                     uint64
	Rescues, RescueExhausted                   uint64
	Switches                                   map[string]uint64
	Stalls                                     uint64
}

type failover struct {
	ctx      context.Context
	cancel   context.CancelFunc
	cfg      failoverConfig
	strategy *LowestDelay
	probe    prober
	logger   failoverLogger
	onSwitch func()
	paused   func() bool
	resetStalls func()

	now   func() time.Time
	sleep func(ctx context.Context, d time.Duration) error

	rescueRunning atomic.Bool
	rescueDone    chan struct{} // closed when the current rescue exits; replaced per rescue
	rescueMu      sync.Mutex

	wg sync.WaitGroup

	cProbesActive, cProbesRescue, cProbesInterface, cProbesOK, cProbesFailed atomic.Uint64
	cRescues, cRescueExhausted, cStalls                                       atomic.Uint64
	switchMu sync.Mutex
	switches map[string]uint64
}

func newFailover(ctx context.Context, cfg failoverConfig, strategy *LowestDelay, probe prober, logger failoverLogger, onSwitch func()) *failover {
	ctx, cancel := context.WithCancel(ctx)
	return &failover{
		ctx: ctx, cancel: cancel, cfg: cfg, strategy: strategy, probe: probe, logger: logger,
		onSwitch: onSwitch, paused: func() bool { return false }, resetStalls: func() {},
		now: time.Now, sleep: sleepCtx, switches: map[string]uint64{},
	}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
```

Then `start` (active check goroutine when interval > 0, diag goroutine), `stop` (cancel, `wg.Wait`, final `logDiag`), `reportFailure`, `startRescue`/`runRescue`, `probeOnce(tag, counter *atomic.Uint64) (uint16, error)` that also bumps OK/Failed, `onInterfaceChange`, `drainEvents`, `logDiag`, `counters`, `waitIdle` (waits on `rescueDone` or returns true when no rescue runs), `setClock`, `setPaused`, `setResetStalls`. Log the failover line with `strconv`/`fmt` free string building via `logger.Info("failover: ", from, " -> ", to, " reason=", reason, " took=", ms, "ms")` — the `memLogger` in tests concatenates `fmt.Sprint` of each arg, so an int64 `ms` prints as digits.

Rescue batch probing runs each probe in its own goroutine with a shared `context.WithTimeout(f.ctx, cfg.rescueTimeout)`; collect results; success = `err == nil`; choose the lowest delay among successes.

- [ ] **Step 3: Run with the race detector, vet, commit**

```bash
go test ./protocol/group/balancer/ -race -count=3 && go vet ./protocol/group/balancer/
git add protocol/group/balancer/failover.go protocol/group/balancer/failover_test.go
git commit -m "feat(balancer): контроллер отказов: спасательный скан, активная проверка, смена сети"
```

`-race` needs cgo on Windows; if it is unavailable, run without `-race` and state that in the report.

---

### Task 7: Stall watchdog

**Files:**
- Create: `recon-core/hiddify-sing-box/protocol/group/balancer/stall.go`
- Test: `recon-core/hiddify-sing-box/protocol/group/balancer/stall_test.go`

**Interfaces:**
- Produces:

```go
type stallTracker struct { /* private */ }
func newStallTracker(cfg failoverConfig, now func() time.Time, onStall func(tag string)) *stallTracker
func (t *stallTracker) wrap(conn net.Conn, tag string) net.Conn   // tracked connection; removes itself on Close
func (t *stallTracker) tick(currentTag string)                    // evaluate once; called every stallTick by the balancer while len(conns) > 0
func (t *stallTracker) reset()                                    // clear the stall window (interface change)
func (t *stallTracker) size() int
```

Rules: a tracked conn is *stalled* when it has written at least one byte, has read zero bytes since that write, and `now - lastWrite >= stallTimeout`. Each conn contributes at most one stall until it reads again. Stall timestamps are kept in a slice trimmed to `stallWindow`; when `len >= stallThreshold` → `onStall(currentTag)` once and the window is cleared. Only conns whose tag equals `currentTag` count. A successful read on any conn of the current tag clears the window (the server is alive).

- [ ] **Step 1: Failing tests**

```go
package balancer

import (
	"net"
	"testing"
	"time"
)

type scriptConn struct {
	net.Conn
	readCh chan []byte
}

func newScriptConn() (*scriptConn, net.Conn) {
	a, b := net.Pipe()
	return &scriptConn{Conn: a}, b
}

func newTracker(clock *fakeClock) (*stallTracker, *[]string) {
	var fired []string
	cfg := normalizeFailover(optionWith(8*time.Second, 3, 30*time.Second))
	return newStallTracker(cfg, clock.Now, func(tag string) { fired = append(fired, tag) }), &fired
}

func TestStallCountsOnlyWrittenUnreadConns(t *testing.T) {
	clock := newFakeClock()
	tr, fired := newTracker(clock)
	conns := make([]net.Conn, 0, 3)
	peers := make([]net.Conn, 0, 3)
	for i := 0; i < 3; i++ {
		c, peer := net.Pipe()
		conns = append(conns, tr.wrap(c, "a"))
		peers = append(peers, peer)
	}
	for _, c := range conns {
		go c.Write([]byte("x"))
	}
	for _, p := range peers {
		buf := make([]byte, 1)
		p.Read(buf) // peer consumes the write so Write returns; nothing is ever written back
	}
	time.Sleep(10 * time.Millisecond)
	clock.Advance(7 * time.Second)
	tr.tick("a")
	if len(*fired) != 0 {
		t.Fatal("under stall_timeout nothing may fire")
	}
	clock.Advance(2 * time.Second)
	tr.tick("a")
	if len(*fired) != 1 || (*fired)[0] != "a" {
		t.Fatalf("three stalled conns >= threshold 3 must fire once, got %v", *fired)
	}
	tr.tick("a")
	if len(*fired) != 1 {
		t.Fatal("a conn contributes one stall until it reads again")
	}
}

func TestReadClearsWindow(t *testing.T) {
	clock := newFakeClock()
	tr, fired := newTracker(clock)
	c1, p1 := net.Pipe()
	c2, p2 := net.Pipe()
	w1, w2 := tr.wrap(c1, "a"), tr.wrap(c2, "a")
	go w1.Write([]byte("x"))
	go w2.Write([]byte("x"))
	p1.Read(make([]byte, 1))
	p2.Read(make([]byte, 1))
	time.Sleep(10 * time.Millisecond)
	clock.Advance(9 * time.Second)
	tr.tick("a") // two stalls recorded, below threshold
	go p1.Write([]byte("y"))
	w1.Read(make([]byte, 1)) // server answered
	tr.tick("a")
	c3, p3 := net.Pipe()
	w3 := tr.wrap(c3, "a")
	go w3.Write([]byte("x"))
	p3.Read(make([]byte, 1))
	time.Sleep(10 * time.Millisecond)
	clock.Advance(9 * time.Second)
	tr.tick("a")
	if len(*fired) != 0 {
		t.Fatalf("a read must clear the window; fired=%v", *fired)
	}
}

func TestOtherTagAndClosedConnsIgnored(t *testing.T) {
	clock := newFakeClock()
	tr, fired := newTracker(clock)
	c1, p1 := net.Pipe()
	w := tr.wrap(c1, "b")
	go w.Write([]byte("x"))
	p1.Read(make([]byte, 1))
	clock.Advance(20 * time.Second)
	tr.tick("a")
	if len(*fired) != 0 || tr.size() != 1 {
		t.Fatalf("fired=%v size=%d", *fired, tr.size())
	}
	w.Close()
	if tr.size() != 0 {
		t.Fatal("closed conns must be untracked")
	}
}

func optionWith(timeout time.Duration, threshold int, window time.Duration) option.BalancerOutboundOptions {
	return option.BalancerOutboundOptions{
		StallTimeout: badoption.Duration(timeout), StallThreshold: threshold, StallWindow: badoption.Duration(window),
	}
}
```

Add imports `github.com/sagernet/sing-box/option` and `github.com/sagernet/sing/common/json/badoption`. Run → FAIL.

- [ ] **Step 2: Implement `stall.go`**

```go
package balancer

import (
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type stallTracker struct {
	cfg     failoverConfig
	now     func() time.Time
	onStall func(tag string)

	mu     sync.Mutex
	conns  map[*stallConn]struct{}
	stalls []time.Time
	readSeen atomic.Bool
}

type stallConn struct {
	net.Conn
	tracker       *stallTracker
	tag           string
	lastWriteNano atomic.Int64
	readSinceWrite atomic.Int64
	counted       atomic.Bool
	closeOnce     sync.Once
}

func newStallTracker(cfg failoverConfig, now func() time.Time, onStall func(tag string)) *stallTracker {
	return &stallTracker{cfg: cfg, now: now, onStall: onStall, conns: map[*stallConn]struct{}{}}
}

func (t *stallTracker) wrap(conn net.Conn, tag string) net.Conn {
	c := &stallConn{Conn: conn, tracker: t, tag: tag}
	t.mu.Lock()
	t.conns[c] = struct{}{}
	t.mu.Unlock()
	return c
}

func (t *stallTracker) size() int { t.mu.Lock(); defer t.mu.Unlock(); return len(t.conns) }

func (t *stallTracker) reset() {
	t.mu.Lock()
	t.stalls = nil
	for c := range t.conns {
		c.counted.Store(false)
	}
	t.mu.Unlock()
}

func (t *stallTracker) tick(currentTag string) {
	now := t.now()
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.readSeen.Swap(false) {
		t.stalls = nil
	}
	for c := range t.conns {
		if c.tag != currentTag {
			continue
		}
		lw := c.lastWriteNano.Load()
		if lw == 0 || c.readSinceWrite.Load() > 0 || c.counted.Load() {
			continue
		}
		if now.Sub(time.Unix(0, lw)) < t.cfg.stallTimeout {
			continue
		}
		c.counted.Store(true)
		t.stalls = append(t.stalls, now)
	}
	// trim window
	kept := t.stalls[:0]
	for _, at := range t.stalls {
		if now.Sub(at) <= t.cfg.stallWindow {
			kept = append(kept, at)
		}
	}
	t.stalls = kept
	if len(t.stalls) >= t.cfg.stallThreshold {
		t.stalls = nil
		go t.onStall(currentTag)
	}
}

func (c *stallConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	if n > 0 {
		c.lastWriteNano.Store(c.tracker.now().UnixNano())
		c.readSinceWrite.Store(0)
		c.counted.Store(false)
	}
	return n, err
}

func (c *stallConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.readSinceWrite.Add(int64(n))
		c.tracker.readSeen.Store(true)
	}
	return n, err
}

func (c *stallConn) Close() error {
	c.closeOnce.Do(func() {
		c.tracker.mu.Lock()
		delete(c.tracker.conns, c)
		c.tracker.mu.Unlock()
	})
	return c.Conn.Close()
}

func (c *stallConn) Upstream() any { return c.Conn }
```

The `Write` path resets `counted` so a conn that keeps writing while the server is silent can stall again after a fresh `stallTimeout`. In `TestStallCountsOnlyWrittenUnreadConns` there are no further writes, so the second tick fires nothing, as asserted. `onStall` is called on a goroutine so the balancer's `reportFailure` may take locks freely.

- [ ] **Step 3: Run, vet, commit**

```bash
go test ./protocol/group/balancer/ -run 'TestStall|TestRead|TestOther' -v && go vet ./protocol/group/balancer/
git add protocol/group/balancer/stall.go protocol/group/balancer/stall_test.go
git commit -m "feat(balancer): детектор зависших соединений"
```

---

### Task 8: Wire failover into the Balancer

**Files:**
- Modify: `recon-core/hiddify-sing-box/protocol/group/balancer/balancer.go`
- Test: `recon-core/hiddify-sing-box/protocol/group/balancer/scenario_test.go`

**Interfaces:**
- Consumes: Tasks 4–7; `monitoring.OutboundMonitoring.TestAndWait` (Task 5); `pause.Manager` from ctx.
- Produces: `Balancer` implements `adapter.InterfaceUpdateListener`; `Balancer.Close()` is idempotent.

Changes to `balancer.go`:
1. Fields: `failover *failover`, `stalls *stallTracker`, `stallStop chan struct{}`, `closeOnce sync.Once`; `close` channel is created in `NewLoadBalance` (`close: make(chan struct{})`) — today it is nil and `Close()` never closes it.
2. `Start()`: after building `strategyFn`, if strategy is `StrategyLowestDelay`: `ld := s.strategyFn.(*LowestDelay)`; `s.stalls = newStallTracker(ld.cfg, time.Now, func(tag string) { s.failover.cStalls.Add(1); s.failover.reportFailure(tag, "stall") })`; `s.failover = newFailover(s.ctx, ld.cfg, ld, monitorProber{s.monitor}, s.logger, func() { s.interruptGroup.Interrupt(s.interruptExternalConnections) })`; `s.failover.setResetStalls(s.stalls.reset)`; if `pm := service.FromContext[pause.Manager](s.ctx); pm != nil { s.failover.setPaused(pm.IsDevicePaused) }`.
3. `monitorProber` adapter:

```go
type monitorProber struct{ m *monitoring.OutboundMonitoring }

func (p monitorProber) Probe(ctx context.Context, tag string, timeout time.Duration) (uint16, error) {
	his, err := p.m.TestAndWait(ctx, tag, timeout)
	if err != nil {
		return 0, err
	}
	return his.Delay, nil
}
```

4. `PostStart()`: `go s.worker()`; if `s.failover != nil { s.failover.start(); go s.stallLoop() }`.
5. `stallLoop()`: ticker `stallTick`; on each tick, if `s.stalls.size() > 0 { s.stalls.tick(s.strategyFn.Now()) }`; exits on `s.close`/ctx. (A ticker with a size check costs one goroutine wake per second only while connections exist; when idle the loop still wakes but does no work — acceptable for this stage; the diagnostics will show if it matters.)
6. `worker()`: after `UpdateOutboundsInfo` returns changed, call `s.failover.drainEvents()` (nil-safe) before interrupting.
7. `DialContext`: on error, keep `InvalidateTest`, then `if s.failover != nil { s.failover.reportFailure(outbound.Tag(), "dial_error") }`. On success, wrap: `if s.stalls != nil { conn = s.stalls.wrap(conn, outbound.Tag()) }` before `interruptGroup.NewConn`.
8. `InterfaceUpdated()`: `if s.failover != nil { s.failover.onInterfaceChange() }`.
9. `Close()`: `s.closeOnce.Do(func(){ close(s.close); if s.failover != nil { s.failover.stop() } })`.

- [ ] **Step 1: Scenario test at controller level** (`scenario_test.go`): these are the reproducible PC scenarios the measurement plan asks for. Each logs one machine-readable line `SCENARIO name=<n> probes=<count> switches=<count> recovery_ms=<virtual ms>` via `t.Logf`, parsed by Task 11.

```go
package balancer

import (
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
)

func TestScenarioDialErrorRecovery(t *testing.T) {
	f, s, p, _, c := newHarness(t, "a", "b", "c")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now()), "b": measured(150, c.Now()), "c": measured(120, c.Now())})
	start := c.Now()
	f.reportFailure("a", "dial_error")
	if s.Now() != "c" {
		t.Fatalf("expected c (lowest healthy), got %q", s.Now())
	}
	t.Logf("SCENARIO name=dial_error_with_candidates probes=%d switches=%d recovery_ms=%d", len(p.calls), f.counters().Switches["dial_error"], c.Now().Sub(start).Milliseconds())
}

func TestScenarioAllUnknownRescue(t *testing.T) {
	f, s, p, _, c := newHarness(t, "a", "b", "c", "d", "e", "f", "g")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(100, c.Now())})
	p.set("f", 400)
	start := c.Now()
	f.reportFailure("a", "stall")
	if !f.waitIdle(3 * time.Second) || s.Now() != "f" {
		t.Fatalf("now=%q", s.Now())
	}
	t.Logf("SCENARIO name=rescue_unknown_pool probes=%d switches=%d recovery_ms=%d", len(p.calls), f.counters().Rescues, c.Now().Sub(start).Milliseconds())
}

func TestScenarioLatencyFlapDoesNotSwitch(t *testing.T) {
	f, s, _, _, c := newHarness(t, "a", "b")
	s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(200, c.Now()), "b": measured(210, c.Now())})
	for i := 0; i < 48; i++ { // 24 virtual hours of half-hourly sweeps with +-100 ms jitter
		c.Advance(30 * time.Minute)
		da, db := uint16(200), uint16(210)
		if i%2 == 0 {
			da, db = 300, 190
		}
		s.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a": measured(da, c.Now()), "b": measured(db, c.Now())})
	}
	f.drainEvents()
	if s.Now() != "a" {
		t.Fatalf("jitter under tolerance must not switch, got %q", s.Now())
	}
	t.Logf("SCENARIO name=latency_jitter_24h probes=0 switches=%d recovery_ms=0", f.counters().Switches["better_latency"])
}
```

- [ ] **Step 2: Apply the wiring, then**

```bash
go build ./... 2>&1 | tail -5     # whole module must still compile (box.go etc.)
go test ./protocol/group/balancer/ ./common/monitoring/ -count=1 && go vet ./protocol/group/balancer/ ./common/monitoring/
```

`go build ./...` may take several minutes the first time; it must end with no output.

- [ ] **Step 3: Commit**

```bash
git add protocol/group/balancer/balancer.go protocol/group/balancer/scenario_test.go
git commit -m "feat(balancer): подключение контроллера отказов, детектора зависаний и строки failover"
git push recon recon/main
```

---

### Task 9: hiddify-core passes failover options and Recon defaults

**Files:**
- Modify: `recon-core/v2/config/hiddify_option.go`
- Modify: `recon-core/v2/config/builder.go` (the `urlTest` balancer literal and the `Monitoring` literal)
- Test: `recon-core/v2/config/failover_test.go`
- Git: bump the `hiddify-sing-box` submodule pointer to the Task 8 commit.

**Interfaces:**
- Produces: `HiddifyOptions.FailoverOptions` with JSON keys `failover-tolerance` (ms), `failover-min-dwell` (s), `failover-stall-timeout` (s), `failover-stall-threshold`, `failover-stall-window` (s), `failover-rescue-batch`, `failover-rescue-timeout` (s), `failover-active-check-interval` (s), `disable-interface-sweep` (bool). Defaults: 150, 60, 8, 3, 30, 6, 5, 180, true. `URLTestInterval` default becomes `DurationInSeconds(1800)`.

- [ ] **Step 1: Failing test**

```go
package config

import (
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestDefaultFailoverOptions(t *testing.T) {
	o := DefaultHiddifyOptions()
	if o.Failover.Tolerance != 150 || o.Failover.MinDwell != 60 || o.Failover.StallTimeout != 8 || o.Failover.StallThreshold != 3 ||
		o.Failover.StallWindow != 30 || o.Failover.RescueBatch != 6 || o.Failover.RescueTimeout != 5 || o.Failover.ActiveCheckInterval != 180 {
		t.Fatalf("defaults: %+v", o.Failover)
	}
	if !o.DisableInterfaceSweep || o.URLTestInterval != DurationInSeconds(1800) {
		t.Fatalf("sweep defaults: disable=%v interval=%v", o.DisableInterfaceSweep, o.URLTestInterval)
	}
}

func TestLowestBalancerCarriesFailoverOptions(t *testing.T) {
	opt := DefaultHiddifyOptions()
	input := option.Options{Outbounds: []option.Outbound{
		{Type: C.TypeDirect, Tag: "s1", Options: &option.DirectOutboundOptions{}},
		{Type: C.TypeDirect, Tag: "s2", Options: &option.DirectOutboundOptions{}},
	}}
	out, err := BuildConfig(*opt, input)
	if err != nil {
		t.Fatal(err)
	}
	var lowest *option.BalancerOutboundOptions
	for _, ob := range out.Outbounds {
		if ob.Tag == OutboundURLTestTag {
			lowest = ob.Options.(*option.BalancerOutboundOptions)
		}
	}
	if lowest == nil {
		t.Fatal("lowest balancer missing")
	}
	if lowest.Tolerance != 150 || lowest.MinDwell.Build().Seconds() != 60 || lowest.RescueBatch != 6 || lowest.ActiveCheckInterval.Build().Minutes() != 3 {
		t.Fatalf("lowest options: %+v", lowest)
	}
	if out.Experimental == nil || out.Experimental.Monitoring == nil || !out.Experimental.Monitoring.DisableInterfaceSweep {
		t.Fatal("monitoring must carry disable_interface_sweep")
	}
}
```

The exact constructor names (`DefaultHiddifyOptions`, `BuildConfig`) must be read from `v2/config/hiddify_option.go` and `builder.go` before writing the test; adjust the test to the real names and signatures, keep the assertions. Run from `recon-core`: `go test ./v2/config/ -run 'TestDefaultFailover|TestLowestBalancer' -v` → FAIL.

- [ ] **Step 2: Implement**

`hiddify_option.go`:

```go
type FailoverOptions struct {
	Tolerance           uint16 `json:"failover-tolerance,omitempty" overridable:"true"`
	MinDwell            int    `json:"failover-min-dwell,omitempty" overridable:"true"`
	StallTimeout        int    `json:"failover-stall-timeout,omitempty" overridable:"true"`
	StallThreshold      int    `json:"failover-stall-threshold,omitempty" overridable:"true"`
	StallWindow         int    `json:"failover-stall-window,omitempty" overridable:"true"`
	RescueBatch         int    `json:"failover-rescue-batch,omitempty" overridable:"true"`
	RescueTimeout       int    `json:"failover-rescue-timeout,omitempty" overridable:"true"`
	ActiveCheckInterval int    `json:"failover-active-check-interval,omitempty" overridable:"true"`
}
```

Add `Failover FailoverOptions `json:",inline"`` next to `URLTestOptions` (follow how `URLTestOptions` is embedded) and `DisableInterfaceSweep bool `json:"disable-interface-sweep,omitempty" overridable:"true"``. Set the defaults listed above in the defaults function; change `URLTestInterval: DurationInSeconds(1800)`.

`builder.go`, the `urlTest` literal:

```go
Options: &option.BalancerOutboundOptions{
	Outbounds:                 tags,
	Strategy:                  "lowest-delay",
	DelayAcceptableRatio:      2,
	Tolerance:                 opt.Failover.Tolerance,
	MinDwell:                  badoption.Duration(time.Duration(opt.Failover.MinDwell) * time.Second),
	StallTimeout:              badoption.Duration(time.Duration(opt.Failover.StallTimeout) * time.Second),
	StallThreshold:            opt.Failover.StallThreshold,
	StallWindow:               badoption.Duration(time.Duration(opt.Failover.StallWindow) * time.Second),
	RescueBatch:               opt.Failover.RescueBatch,
	RescueTimeout:             badoption.Duration(time.Duration(opt.Failover.RescueTimeout) * time.Second),
	ActiveCheckInterval:       badoption.Duration(time.Duration(opt.Failover.ActiveCheckInterval) * time.Second),
	InterruptExistConnections: true,
},
```

Monitoring literal: add `DisableInterfaceSweep: hopt.DisableInterfaceSweep,`. Leave the `balance` (round-robin) balancer untouched.

- [ ] **Step 3: Bump the submodule, test, commit, push, tag**

```bash
cd /c/Users/bambolumba/Desktop/Recon/recon-core
git add hiddify-sing-box v2/config/hiddify_option.go v2/config/builder.go v2/config/failover_test.go
go test ./v2/config/ -count=1
git commit -m "feat(config): опции отказоустойчивости и обход раз в 30 минут по умолчанию"
git push recon recon/main
git tag -a v4.1.0-recon.1 -m "Ядро Recon: failover в lowest-delay, обход раз в 30 минут"
git push recon v4.1.0-recon.1
gh run watch -R bambolumba-y/recon-core --exit-status $(gh run list -R bambolumba-y/recon-core -w "Recon Core Android" -L 1 --json databaseId --jq '.[0].databaseId')
gh release view v4.1.0-recon.1 -R bambolumba-y/recon-core --json assets --jq '.assets[].name'
```

Expected: release with `hiddify-lib-android.tar.gz`. Record its SHA-256.

---

### Task 10: App uses the Recon core, selects `lowest` in auto mode, sweeps every 30 min

**Files:**
- Modify: `hiddify-app/.github/workflows/recon-android.yml:32-34`
- Modify: `hiddify-app/dependencies.properties`
- Create: `hiddify-app/tool/core/fetch_core.sh`
- Modify: `hiddify-app/lib/features/connection/data/connection_repository.dart:106-120`
- Modify: `hiddify-app/lib/features/settings/data/config_option_repository.dart:156-161`
- Test: `hiddify-app/test/features/connection/data/connection_repository_test.dart` (create if absent; the Stage 1 suite has 64 tests under `test/`)

Branch: `git checkout -b recon/stage2 recon/stage2-baseline` in `hiddify-app`.

- [ ] **Step 1: Core source**

`dependencies.properties`: `core.version=4.1.0-recon.1` (keep the file's single line, no trailing newline change). Workflow step:

```yaml
      - name: Download Recon core
        run: |
          mkdir -p android/app/libs
          CORE_VERSION=$(tr -d '\r' < dependencies.properties | sed -n 's/^core.version=//p')
          curl -fL "https://github.com/bambolumba-y/recon-core/releases/download/v${CORE_VERSION}/hiddify-lib-android.tar.gz" | tar xz -C android/app/libs/
          ls -la android/app/libs
```

`tool/core/fetch_core.sh` does the same for local builds (`set -euo pipefail`, run from `hiddify-app`), and the top of `docs/README` note in `tool/core/` is one paragraph: what it downloads and that `android/app/libs/` is git-ignored.

- [ ] **Step 2: Failing test for the auto connect selection**

Read `connection_repository.dart` and the `SingboxService` interface used there. Add a test with a fake `SingboxService` that records calls: after `connectAutoGroup(false)` succeeds, the calls must be `start(...)` then `selectOutbound('select', 'lowest')`; the same after `reconnectAutoGroup(false)`. If Stage 1 tests already have a fake singbox service (look in `test/features/connection/`), extend it rather than writing a second one.

- [ ] **Step 3: Implement**

```dart
  @override
  TaskEither<ConnectionFailure, Unit> connectAutoGroup(bool disableMemoryLimit) => setup().flatMap(
        (_) => autoGroup.buildConfig().mapLeft(ConnectionFailure.fromAutoGroup),
      ).flatMap(
        (build) => singbox.start(build.configPath, AutoGroupRepository.displayName, disableMemoryLimit),
      ).flatMap((_) => _selectLowest());

  /// Auto mode must run on the core's lowest-delay balancer, not on the selector's default (`balance`).
  TaskEither<ConnectionFailure, Unit> _selectLowest() =>
      singbox.selectOutbound('select', 'lowest').mapLeft(ConnectionFailure.unexpected);
```

Match the existing chain shape and failure constructors in the file (the snippet shows intent; keep the file's real names). Apply the same `_selectLowest()` after `restart` in `reconnectAutoGroup`.

`config_option_repository.dart:158`: `const Duration(minutes: 30)`.

- [ ] **Step 4: Run tests, restore plugin registrants, commit**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
/c/src/flutter/bin/flutter test 2>&1 | tail -3
git checkout -- linux macos windows
git add .github/workflows/recon-android.yml dependencies.properties tool/core lib/features/connection/data/connection_repository.dart lib/features/settings/data/config_option_repository.dart test
git commit -m "feat(core): приложение собирается с ядром Recon и выбирает lowest в авторежиме"
git push recon recon/stage2
gh run watch -R bambolumba-y/Recon --exit-status $(gh run list -R bambolumba-y/Recon -w "Recon Android" -b recon/stage2 -L 1 --json databaseId --jq '.[0].databaseId')
```

Expected: 65+ tests pass, "Recon Android" green on `recon/stage2`, artifact `recon-apk`. If the workflow only triggers on `recon/main`, add `recon/stage2` to its `branches` list in the same commit.

---

### Task 11: Go scenario runner and results table

**Files:**
- Create: `hiddify-app/tool/performance/go_scenarios.py`
- Create: `hiddify-app/docs/performance/<YYYY-MM-DD>-go-scenarios/summary.csv` and `manifest.json`
- Modify: `hiddify-app/tool/performance/README.md` (one section)

- [ ] **Step 1: Script**

`go_scenarios.py` (Python 3.12, stdlib only): runs `go test ./protocol/group/balancer/ -run 'TestScenario' -v -count=1 -json` in the sing-box workspace (path argument, default `../recon-core/hiddify-sing-box`), parses `Output` lines containing `SCENARIO `, writes `summary.csv` with columns `scenario,probes,switches,recovery_ms,status` and `manifest.json` with `{go_version, singbox_commit, core_commit, timestamp_utc, command}` from `go version` and `git rev-parse HEAD` in both repos. Exit non-zero if any scenario test failed. Output directory: `docs/performance/<date>-go-scenarios/`; refuse to overwrite an existing directory.

- [ ] **Step 2: Run it, commit results**

```bash
cd /c/Users/bambolumba/Desktop/Recon/hiddify-app
python tool/performance/go_scenarios.py
git add tool/performance/go_scenarios.py tool/performance/README.md docs/performance/*-go-scenarios
git commit -m "test(perf): прогон Go-сценариев отказоустойчивости и таблица результатов"
```

---

### Task 12: Documentation and hand-over

**Files:**
- Create: `hiddify-app/docs/<YYYY-MM-DD>_recon_stage2_core_failover.md`
- Modify: `hiddify-app/docs/superpowers/plans/2026-09-12-recon-stage2-performance.md` (implementation log entry)
- Modify: `hiddify-app/docs/superpowers/specs/2026-09-12-hiddify-multi-sub-failover-design.md` (section 5.6: status stream deferred; the log line is the delivered interface)
- Mirror the three files to `C:\Users\bambolumba\Desktop\Recon\docs\...` (root copy is a convenience mirror).

- [ ] **Step 1: Write the report**: what changed in each repo with commit ids and tags, the option table with defaults and JSON keys at each layer (sing-box option → HiddifyOptions key → app), the failover and diag log formats, how to read them from the app's log export, the reference vs. Recon AAR hashes, what remains (device acceptance with two subscriptions, 48 h observation, compiler-flags candidate, status stream in the app). Under 150 lines. No provider hostnames.

- [ ] **Step 2: Commit and push**

```bash
git add docs
git commit -m "docs(stage2): ядро Recon с отказоустойчивостью: что сделано и как проверять"
git push recon recon/stage2
```

---

## Self-review notes

- Spec 5.1 options: all eight plus sweep covered (Tasks 3, 5, 9). Sweep `0 disables` is delivered as `interval < 0` at the sing-box layer because `0` is indistinguishable from "unset" under `omitempty`; documented in Task 5 and Task 12.
- Spec 5.2 selection rule: Task 4. Spec 5.3 signals: dial error and stall (Tasks 7, 8), network change (Task 6/8). Spec 5.4 rescue: Task 6. Spec 5.5 sweep/light checks: Tasks 5, 6, 9. Spec 5.6: log line delivered; the gRPC status extension needs protoc and Dart regeneration and is deferred (Task 12 records it). Spec 5.7: Tasks 1, 2, 9, 10. Spec 5.8 unit tests: Tasks 4, 6, 7, 8.
- Names used across tasks: `normalizeFailover`, `failoverConfig`, `LowestDelay.{MarkFailed,ForceSelect,Healthy,Candidates,Events,setClock}`, `failover.{start,stop,reportFailure,onInterfaceChange,drainEvents,counters,setClock,setPaused,setResetStalls,waitIdle,logDiag}`, `stallTracker.{wrap,tick,reset,size}`, `OutboundMonitoring.{TestAndWait,Stats,SweepEnabled}` — consistent in every task that mentions them.
