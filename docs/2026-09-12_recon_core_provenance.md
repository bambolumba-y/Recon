# Stage 2 — Android core provenance established

Date: 2026-09-12. Scope: source/artifact identification only. The owner will continue
diagnostics implementation and testing in Claude. No core compilation, performance
tests, APK installation or application configuration change was performed here.

## Conclusion

The app's declared core version `4.1.0`, its core submodule reference, the official
release tag and the revision embedded in the Android binary all agree on
`c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0`.

The local AAR is byte-for-byte identical to the current official release asset's AAR.
The core libraries in the four existing local debug APKs match that AAR after the
NDK's `llvm-strip --strip-unneeded` transformation. These are local build artifacts;
the APK installed on the owner's phone was not inspected. No local release APK was
found in `build/app/outputs/flutter-apk` during this inspection.

**Important optimisation candidate:** all four ABI libraries in the official Android
AAR contain `-gcflags="all=-N -l"`. The release Makefile explicitly supplies these
flags. Go compiler help defines `-N` as disabling optimisations and `-l` as disabling
inlining. This is a property of the distributed native core, not an inference from
the surrounding Flutter APK's debug/release label. A Flutter release build does not
recompile a prebuilt AAR with different Go flags.

Removing these flags is a candidate for a controlled experiment, not an already
validated fix or a quantified battery saving. Preserve current flags for the first
source-built reference and change only them in a separate candidate before mixing
in scheduler changes or diagnostics. Functional compatibility still needs testing.

## Pinned source chain

| Component | Exact source |
|---|---|
| hiddify-core `v4.1.0` | `c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0` |
| Its hiddify-sing-box submodule | `0a02b7729f6a211436bb8bdcd8696c283eb27767` |
| Its ray2sing submodule | `f58be84e30d946915a1de437fbcc3d3ffca18a23` |

Verified using the local Git object database plus the current GitHub tag ref API.
The app's `hiddify-core` gitlink equals the release core commit. The separate sibling
directories at `db74dfc…` / `8d94f44…` are later source checkouts and should not be
used as a substitute for this chain.

Primary references:

- [Official release](https://github.com/hiddify/hiddify-core/releases/tag/v4.1.0).
- [Release core tree](https://github.com/hiddify/hiddify-core/tree/c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0).
- [Release sing-box tree](https://github.com/hiddify/hiddify-sing-box/tree/0a02b7729f6a211436bb8bdcd8696c283eb27767).
- [Core Makefile](https://github.com/hiddify/hiddify-core/blob/c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0/Makefile), `android` target.
- [Release build workflow](https://github.com/hiddify/hiddify-core/blob/c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0/.github/workflows/build.yml).
- [Successful release run](https://github.com/hiddify/hiddify-core/actions/runs/22719909723), Android job `65879054994`.

## Binary evidence

The official asset is `hiddify-lib-android.tar.gz`, release ID `293501270`, asset ID
`367533137`, size 105,829,904 bytes. Downloaded into ignored
`build/core-provenance/v4.1.0/`; no binaries are committed.

| Artifact | SHA-256 |
|---|---|
| Official archive; matches GitHub asset digest | `6c4841f7aab23eb1fb17831349ecdfc3ca9c31553b8cbe5effd820cb12607f56` |
| Official and local `hiddify-core.aar`, 106,806,367 bytes | `8bc1ce38bca2dd3e13022a4457336602490f2e7d063626a0192d89209a49d07e` |

All native ABI hashes, APK hashes, direct comparisons and stripping comparisons are
saved in [provenance.json](performance/2026-09-12-core-provenance/provenance.json).
Direct AAR/APK native hashes differ because APK libraries have been stripped. Using
the installed NDK `28.2.13676358` reproduces the APK hashes exactly for armeabi-v7a,
arm64-v8a and x86_64. The universal debug APK contains those same three hashes.
The AAR also contains x86, which is absent from the inspected APKs.

Read-only `go version -m` inspection of all four official native libraries found:

- Go `go1.25.6`, `GOOS=android`, expected per-ABI architecture.
- `vcs.revision=c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0`.
- `vcs.modified=true`, module version ending in `c9d6f0f00b2e+dirty`.
- `-gcflags="all=-N -l"`, `-buildmode=c-shared`, `CGO_ENABLED=1`.
- Local sing-box replacement `=> ./hiddify-sing-box (devel)`.

Full representative [arm64 build information](performance/2026-09-12-core-provenance/arm64-go-buildinfo.txt)
is preserved, including dependency versions and build tags (local path replaced by
the archive entry name; trailing whitespace normalised). Per-ABI settings are in
the JSON. Build metadata for local replacements does not encode their Git SHAs;
the submodule commits above come from the parent Git tree and release workflow.

## Limits of the source attribution

The official binary identifies a **dirty** build tree. The release workflow checks
out recursive submodules and runs `make android`; the preparation target runs
`go mod tidy`, and gomobile generates build material. Those are possible contributors
to a dirty tree, but the exact dirty diff has not been recovered. The Android job log
endpoint returns HTTP 410, so the original command log is unavailable.

Consequently the archive/local-AAR/APK artifact chain is established, and the intended
source revision is established, but a byte-identical rebuild from a clean source tree
is **not** established. Do not replace that distinction with a claim that every byte
of effective source/dependency configuration has been independently reproduced.

For future comparisons retain both the official binary reference and an unmodified
source-built reference, recording any `go.mod`/`go.sum` changes and full build flags.
Unexpected performance differences between them need explanation before attributing
an improvement solely to a code change.

## Corrections to the initial source inspection

The monitoring file inspected in the first handoff is in fact unchanged between the
release sing-box commit and the sibling checkout: both
`common/monitoring/outbound_monitoring.go` objects have Git blob ID
`75ed26807838874c2df3b1594a66e9be39c809b7`. A diff of `common/monitoring` and
`protocol/group/balancer` between those commits was also empty. The findings about
defaults, URL tests, conditional IP information requests and cycle coalescing therefore
apply to the release source too. Effective runtime settings still require measurement.

The core `grpc_server.go` differs between revisions; the release version was inspected
separately and also gates localhost pprof startup on `params.Debug`.

## Exact continuation point for Claude

1. Read this report and the existing stage 2 plan. Preserve the current app baseline
   and official artifact hashes. No branch or version upgrade is needed to identify
   the reference anymore.
2. Prepare a **new complete** core checkout at the pinned release commit, with nested
   submodules at recorded commits. Do not reset the owner's sibling checkouts or use
   `git submodule update --remote`. Example in a new Linux/WSL workspace:

   ```bash
   git clone --branch v4.1.0 https://github.com/hiddify/hiddify-core.git recon-core-v4.1.0
   cd recon-core-v4.1.0
   git checkout --detach c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0
   git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
   git submodule status --recursive
   ```

   These preparation commands were documented, not executed. Check the source pins
   after checkout and before building. The per-command URL rewrite handles ray2sing's
   SSH URL without changing global Git configuration.
3. Reproduce the reference build settings first: Go 1.25.6, gomobile/gobind v0.1.11,
   Java 17, workflow NDK r28, Android API 21, release build tags/ldflags and current
   `all=-N -l`. Record the exact NDK/tool versions used; do not assume the installed
   NDK r28c used for APK stripping is the upstream build's exact r28 toolchain.
   Do not compare an optimised desktop core with an unoptimised Android core as if
   compilation settings were equal.
4. Make the compiler-flags experiment a separate candidate from diagnostics and
   scheduler changes. Compare functionally equivalent builds and verify recovery,
   cancellation and lifecycle correctness. No promised size of CPU/battery benefit.
5. Implement/test bounded diagnostics and proceed with the owner's 48-hour observation
   according to the stage 2 plan. All tests and diagnosis implementation are deferred
   to Claude by the owner's latest instruction.

This session changed documentation/evidence only. Existing Go checkouts, application
code, build flags and release downloads used by CI remain unchanged. The manifest is
an audit pin; CI does not yet enforce its digest. Any later workflow hardening should
be an explicit separate change.
