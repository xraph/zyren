# Rendering qualification, October 3 plan

Use this record with [the owned commit manifest](owned-commits.json) and
[chronological decisions and costs](decisions.md). Verification continued on
October 4. The implementation includes native profiling, queued resource work,
bounded scene admission, retained cover and picking, conservative horizon/prefetch
policies, cloud history/adaptation, draw caching/batching, compensated PBR,
transmission reuse, local probes and optional forward screen lighting.

The combined change is not full source-story or platform parity. Final independent
whole-change review is still required. The canonical local capability, parity and
public rendering sources were updated.
The repository intentionally ignores `docs/`, so [reviewed snapshots](documentation/sources.json)
preserve their exact content and source hashes here. Website import/build/deployment,
push and merge were not performed.

## Current combined checks

| Scope | Command, from the named package | Result |
| --- | --- | --- |
| `zyren_native/native` | `cargo test --lib -- --include-ignored --test-threads=1` | 49 passed, 0 ignored; library tests including native shader fixtures, not every Cargo integration target |
| `zyren_native` | `RUN_NATIVE_GPU=1 fvm dart test --concurrency=1` | 248 passed |
| `zyren` | `fvm dart test` | 796 passed |
| `zyren_3d_tiles` | `RUN_NATIVE_GPU=1 fvm dart test --concurrency=1` | 91 passed |
| `zyren_geospatial` | `RUN_NATIVE_GPU=1 ZYREN_SOURCE_CLOUDS=<verified local assets> fvm dart test --concurrency=1` | 359 passed, 19 skipped |
| `flutter_zyren` | `fvm flutter test` | 174 passed |
| Planet benchmark | `fvm flutter test test/navigation_benchmark_route_test.dart test/navigation_benchmark_stats_test.dart` | 15 passed after the post-route fix, including capture lifecycle |
| Affected packages and final edited files | `fvm dart analyze` with the recorded exact scopes | No issues |

Native builds used `CARGO_PROFILE_DEV_DEBUG=0`, `CARGO_PROFILE_TEST_DEBUG=0` and
`CARGO_INCREMENTAL=0`. FVM uses Flutter 3.47.5 and Dart 3.13.4. Package-local
native hooks and observed library hashes are recorded with the commands in
[evidence/task-9-validation](evidence/task-9-validation). No raw toolchain remote
or authenticated VM address belongs in this record.

The earlier pinned-source runs separately passed 2 cloud, 8 binary atmosphere and
4 EXR atmosphere native checks, with no skips in those selected runs. Their asset
hashes match pinned LFS content and inventory Git blobs. The current geospatial
suite's 19 skips remain skips; they are not converted into passes by that earlier
selected evidence.

The combined suites exposed stale expectations and one lifecycle regression.
Initial raw failures remain alongside the corrected runs. The updates preserve
existing pixel tolerances and exact publication identities:

- Native profile round trips now expect six additive nullable screen-lighting
  fields. Timestamp storage has fourteen named passes plus one overall slot,
  so its two buffers total 480 bytes, replacing the older thirteen-slot 416-byte
  assertion. The test checks absent/incomplete reads and the source pass by name.
- A cold PBR frame has two total draws, one mesh and one `energyLut` draw. Its warm
  frame has one mesh draw and identical pixels. Geometry tests use mesh counters.
- glTF pixel references now use the existing independent 65,536-sample VNDF energy
  integral, with linear factors, sRGB conversion and the original two-byte
  tolerance. No renderer shader or tolerance was changed to match an observed byte.
- Codec fixtures await both quiet requests and displayed publication within their
  original 200-frame bound. Decoding can finish while an empty frame submits.
- A borrowed Flutter view can restore a ready existing session after remount.
  Pending plugin attachment keeps input disabled; failed/closed/recovering sessions
  cannot become ready through visibility changes. The visible-host simulation
  clock remains independent of readiness.
- The loaded-model click fixture explicitly uses unlit diagnostic materials because
  its fake backend lacks Standard material support. It now requires `SceneReady`.
  Native Standard glTF/PBR coverage remains in the separate renderer suite.

## Native image evidence

The new large-world fixture compares a scene at `(6378137, -4194304, 2097152)`
with its equivalent local scene at 96 by 96 pixels. AO and reflections each change
pixels when enabled. All six complete RGBA comparisons are exact: stationary and
two opposite camera offsets with the candidate still staged. Screen scratch and
registered payload return to zero after cleanup. This is real Metal shader evidence,
not foreground FPS, physical residency or every large-coordinate configuration.

Earlier raw results include six stable-cover transition comparisons; phased cloud
reconstruction ramps and 29 staged frame comparisons; final in-flight cloud and
atmosphere replacement cases; opaque batching stationary/motion profiles; mapped
PBR/HDR reference images; transmission reuse images; probe ownership/alpha checks;
and forward AO/SSR images and presenter diagnostics. The inventory identifies
original paths, hashes, compression and any sanitization. Earlier failed attempts
are retained as failed attempts. Final task logs and fix2 cloud results supersede
their named initial/fix1 checkpoints.

Task 6's matched small synthetic benchmark encoded 4,096 mesh draws as 128 batches.
Its stationary CPU preparation plus encoding changed from 59.663 to 20.061 ms;
the moving-camera sample changed from 102.131 to 50.109 ms, while preparation alone
increased from 14.273 to 44.292 ms and had no plan hits. All 30 motion images matched.
These were development Metal/readback diagnostics on a shared M3 Max with changing
host load, not controlled presentation FPS. Four owned benchmark executables were
removed after disk exhaustion; their identity hashes and raw results remain.

## Live route and limits

The final benchmark has five twelve-second phases: stationary, orbit, drag, zoom
and a linear orbit reversal at six seconds. Auto, shadows-off and sparse variants
use adaptive device defaults; named presets are fixed. Reports record requested
and applied adaptation, effective controller diagnostics, commanded motion and
accepted camera positions, native timings, upload backlog, selected/visible/
displayed/prefetched tiles, cloud history, logical payload and render dimensions.
A dimension change invalidates the phase. Counts do not prove geometric coverage.

The post-route schema 3 correction requires accepted presentation through the
12-second boundary and rejects receipt gaps above one second. Applied reversal
commands and actual camera motion must be matched to accepted frame sources on
both sides. Full measurement duration includes initial and terminal stalls. These
rules are stricter than the schema 2 harness used by the preserved failed live
attempts; no new live run has qualified the amended harness.

The live outcome and its artifact identity are recorded in `live-navigation.md`.
Earlier Planet reports used unmatched settings/content and some auto runs disabled
adaptation. No before/after speedup is claimed. SSR/AO is off by default and its
cost cannot be attributed to the ordinary Planet route.

Physical allocation failure, physical device loss and a real completion-timeout
fault remain unverified. Budget rejection, forced test timeouts, worker aborts and
mock recovery prove separate paths. Vulkan/DX12 and mobile qualification of this
combined change remain open. Earlier platform evidence does not transfer to the
new combined artifact.

The previous Shader Lab presenters passed native assertions at desktop/narrow
sizes, including MSAA and resource retirement, but reported foreground failure.
They also emitted dependency, Swift Package Manager and script-output warnings.
The screen-lighting Dart artifact was observed after those tests and cannot prove
its earlier loaded binary identity. The linked presenter framework was captured.

The [consolidated final fixes](final-fixes.md) isolate Task 8a's format/depth guards
and directly instrument Task 8c's one/four source-load boundary. They also address
probe batching, rejected dynamic frames, prefetch byte priority, capture scaling,
atmosphere close churn and PPM attributes. Final-source checks passed Rust 53,
draw preparation 9, focused native Dart 29 and atmosphere 3; the tiles suite passed
94. The earlier full native 253 run preceded the final Arc/cleanup changes.
Independent scoped review remains pending. Generic MRT, full source motion-vector
parity and temporal SSR remain outside the forward stateless screen effects.

## Evidence and history handling

`68e4744f` contains 27 rendering paths and 89 concurrently staged paths from other
work. Preserve that history and use only its positive `ownedPaths` filter for
rendering review. All Task 9 commits used isolated temporary indexes and exact
owned paths; no shared staged entries or other work were discarded.

Task 1's initial parallel native suite exposed process-global renderer-count races;
its serial run passed. Serial execution is the qualification contract here.

Root-run Dart tests previously consumed a stale native hook artifact. Package-local
execution rebuilt the current shader. That finding is distinct from the unexplained
native `backendUnavailable` startup incidents in Tasks 7 and 8c, whose initial
failures and later passes remain in the evidence. No startup-cause claim is made.

This folder contains selected logs, source/settings/identity JSON and test images.
RGBA output is losslessly gzip-compressed. It contains no native executables,
third-party source textures, provider configuration or ignored build tree. The
ignored working reports are retained separately for independent review.

The ordinary Planet profile app was rebuilt once and restored through CUA after
the fixes. Tokyo city, clouds and attribution were visible. Prior/new artifact
identities are retained in [final restoration evidence](evidence/final-fix-validation/ordinary-planet-restoration.json).
This does not qualify foreground navigation. The owned manifest includes 46
commits through `51b14605`; this evidence update is identified externally.
