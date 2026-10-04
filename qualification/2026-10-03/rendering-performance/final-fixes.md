# Consolidated rendering fixes

Status: DONE_WITH_CONCERNS. All nine scoped findings have implementations and passing focused checks. Independent scoped review remains pending. The live smooth-navigation outcome remains unqualified.

## Changes and evidence

- O1: batch compatibility and cached-plan identity now include each mesh's resolved local-environment assignment. The native fixture covers local/global and two distinct local probes without changing mesh or camera, compares whole images to an ordered reference, and retains a positive same-probe batch and warm plan reuse. Disabling the environment checks makes `o1-native-red.log` fail. The high-level Dart probe fixture passed even under that mutation (`o1-red.log`), so it is supplemental coverage, not the decisive reproduction.
- O2: scene preparation retains accepted resource identities, snapshots ownership/cache metadata, and defers dynamic geometry/instance copies and uniform writes until all recoverable preparation checks, including cover-binding retention, succeed. Copies submit before their consumers. Rejection restores maps, staging, cache and batches, discards commands, and releases candidate references. Metal regression covers reused and separately owned bases, working-set rejection and injected pipeline-creation failure, exact old pixels/IDs/revision, cleanup and corrected retry of the same native frame revision. Successful dirty uploads remain 152 bytes. The regression fails with the transaction bypassed (`o2-red.log`). The final native29 run includes scene_admission_test.dart, whose impossible-overlap test rejects a candidate and then renders the old scene on the same NativeBackend without reset. NativeRenderer._renderBinary retains its existing encoder.reject(packet) catch path. Dynamic geometry and instance tests supplement version ownership, not pipeline-failure encoder proof. The focused scene_upload_pacing_test.dart run passes four tests, including a direct ScenePacketEncoder.reject followed by re-encode/accept on the same instance without reset. These compose frontend rejection behavior with the new native rollback proof; no end-to-end Dart pipeline-injection test is claimed.
- O3: enabled prefetch has stable speculative decoded/resident quotas, with visible quotas equal to total caps minus speculative shares. Physical requests remain charged to their original lane until drain. Cached content transfers lanes only if both visible quotas fit; unpromoted content cannot enter coverage through refresh. Pinned cover remains retained. Tests cover tight budgets, gated and cancelled I/O, sequential visible replacements, successful promotion, blocked promotion under pinned cover, and default no-prefetch behavior. Replacing the implementation with its pre-fix version fails `o3-red.log`. All 94 tiles tests pass.
- C1: main, transmission and screen-source mesh uniforms have distinct keys. The scaled fixture checks exact full-resolution source images with points/lines, warm skipped writes and retirement. Restoring shared source/capture slots fails `c1-red.log`.
- C2: AO capture coordinates and pixel derivatives scale to source dimensions independently per axis. The fixture compares AO-only receiver differences after subtracting the AO-disabled baseline. Final mean error is 0.003934883 against a 0.005 bound, with signal 0.011132837. Restoring old coordinates fails `c2-strong-red.log`. The initial weaker 0.025 oracle did not fail (`c2-red.log`); both results are preserved. Capture scaling from concurrent `4dc28ec333fc8de822d3921b889748620b17f241` remains supported.
- M1: atmosphere close replaces controller composition without rebuilding prepared tokens that close immediately. Upload-delta checks fail with rebuilding restored (`m1-red.log`), pass with the fix, and retain token/disposal checks. Final focused three tests pass.
- M2: transmission tests establish a reusable single-sample baseline before independently changing format and loaded-depth state. MSAA no longer masks those assertions.
- M3: a compute fixture instruments the production source-filter helper and observes one source load at roughness 0.05 and four at 0.0501. The former BRDF-sensitive image inequality was removed. Existing seeded/redraw image equality remains.
- M4: qualification-local `*.ppm binary` marks all 12 fixtures as non-text and non-diff. `ppm-attributes.json` verifies unchanged bytes against committed originals.

## Budgets and transaction cost

Let P and R be per-tile decoded and logical resident reservations. Speculative decoded quota is `min(maxPrefetchBytes, maxPrefetchRequests*P, max(0,maxDecodedBytes-2*P))`. Speculative resident quota is `min(maxPrefetchRequests*R, max(0,maxResidentBytes-2*R))`. Both are zero when prefetch is disabled, including zero maxPrefetchTiles, or either share cannot fit one tile. Two visible reservations size the partition; they are not a universal spare-headroom guarantee. Enabled prefetch reduces maximum visible cache capacity. Selected prefetched content can wait behind pinned visible cover. These quotas are logical accounting, not measured physical GPU residency.

Changed frames copy map/cache metadata and retain registry references. Immutable uniform byte payloads and batch source/value payloads use Arc storage, avoiding deep copies. A narrowly guarded unchanged, non-temporal, non-admission frame can skip snapshots only with matching accepted frame, live assets, unchanged draw allocation plan, matching batch state, and pipeline preflight. Closing any view or clearing shared cache invalidates the guard. Peer-view churn and warm rejection are exercised. Camera motion remains transactional.

The bounded diagnostic uses 128 meshes, 32 samples at 32x32. Final Rust-suite medians were 1,060,000 ns stationary and 851,209 ns camera-only CPU preparation. A separate same-source run measured 1,166,459/929,833 ns. A controlled bypass only around the benchmark section measured 935,875/974,500 ns; its historical filename is `transaction-cost-bypass-red.log`, but this is a diagnostic comparison, not a correctness RED. Source was restored afterward. Adjacent runs had no thermal/system-load control; neither stationary-versus-moving nor the bypass comparison establishes a speedup. This bounded case did not show a material moving-frame penalty requiring further redesign. Map/handle-copy work and changed-frame temporary ownership remain real costs.

Rollback retention initially exposed exact-budget cache reclamation pressure. Same-size obsolete/evicted uniform slots now recycle only after completed use and when registry ownership contains no external owner beyond the explicitly tracked transaction references. Writes stay deferred. Simultaneously required source/transmission/main keys never share a slot. Different-size replacements retain true overlap/rejection. Nine-view return, rejected-candidate original-view pixels and pass-slot separation pass. Zero new allocations in recycled cases reflect actual buffer reuse.

## Validation commands and source scope

Run from the repository unless a package cwd is specified. Rust commands used `CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 CARGO_INCREMENTAL=0`. Dart native commands additionally used `RUN_NATIVE_GPU=1`, FVM Flutter 3.47.5/Dart 3.13.4, package-local hooks and serial execution.

| Command | Result and log |
| --- | --- |
| `cargo test --manifest-path packages/zyren_native/native/Cargo.toml --lib -- --include-ignored --test-threads=1 --nocapture` | 53 passed on real native Metal, final source; rust-qualified.log |
| `cargo test --manifest-path packages/zyren_native/native/Cargo.toml --test draw_preparation -- --include-ignored --test-threads=1` | 9 passed, final source; draw-preparation-qualified.log |
| cwd packages/zyren_native: `fvm dart test --concurrency=1` | 253 passed before the final Arc payload optimization and submission-failure snapshot-release cleanup; native-dart-final.log |
| cwd packages/zyren_native: `fvm dart test --concurrency=1 test/dynamic_geometry_test.dart test/instanced_mesh_test.dart test/scene_admission_test.dart test/opaque_batching_test.dart test/mapped_pbr_batching_test.dart test/reflection_probes_test.dart test/screen_lighting_test.dart test/large_world_screen_lighting_test.dart test/transmission_test.dart test/scene_capture_test.dart` | 29 passed against final source; native-focused-qualified.log |
| cwd packages/zyren_3d_tiles: `fvm dart test --concurrency=1` | 94 passed against final native source; tiles-qualified.log. Subsequent streamer braces-only lint fix has no semantic change. |
| cwd packages/zyren_geospatial: `fvm dart test --concurrency=1 test/atmosphere_cloud_inputs_test.dart` | 3 passed, final artifact; geospatial-focused-qualified.log |
| cwd packages/zyren_3d_tiles: `fvm dart analyze lib/src/streamer.dart test/motion_test.dart` | No issues; tiles-analyze-final.log |
| cwd packages/zyren: `fvm dart test test/scene_upload_pacing_test.dart` | 4 passed, direct same-encoder retry; encoder-retry-qualified.log |
| cwd packages/zyren_geospatial: `fvm dart analyze lib/src/atmosphere/plugin.dart test/atmosphere_cloud_inputs_test.dart` | No issues; geospatial-analyze.log |

Raw outputs, failed intermediate checks, mutation harnesses and artifact/source hashes are retained in final-fix-validation. Source identity is a shared-tree snapshot, not a claim of an isolated artifact. Concurrent graph/mesh work remains outside this commit scope. The one ordinary Planet profile build passed (96.0 MB), with dependency and SPM notices retained in ordinary-planet-build.log. CUA closed the owned prior app and relaunched the rebuilt ordinary bundle; the final screenshot shows Tokyo city, clouds and attribution. ordinary-planet-restoration.json preserves prior/new AOT/native/host hashes. Neither physical gesture nor sustained foreground is qualified.

## Local commits

All commits use temporary isolated indexes, exact positive paths and HEAD compare-and-swap. No branch change, push or merge occurred. Exact path lists are in final-fix-validation/commits.jsonl.

- `38a2d3412262a917e0ae5f2b05e49ade7a102d1e`: M1 atmosphere close and its regression.
- `5ed44f363ff56274326a741780511544d94e5a4f`: M4 qualification PPM attributes.
- `974d102bf118ad57312264d97e63eb0bcf7ebc10`: O3 partitioned tile admission, motion tests and quota documentation.
- `51b146055a07c0ffa3edd614b4ba65bc6b2ff197`: coordinated native O1/O2/C1/C2/M2/M3 and regressions, plus formatting-only cleanup of the owned M1 test.

The evidence commit is reported externally because a commit cannot contain its own hash. The parent owns final review disposition and final scratch cleanup. Nothing here approves that review or authorizes deleting scratch.

## Remaining qualification limits

The failed schema-2 live route is unchanged. Its incomplete stationary sample contains measured scene GPU time (9.959/17.82/34.638 ms p50/p95/p99) and frame intervals (85.245/138.774/146.231 ms). The retained controller reason `timingUnavailable` must not erase those measurements or be reinterpreted as proof that every current GPU sample was missing. No live Auto transition was demonstrated. All 34 accepted sampled frames were tile-budget limited. The route did not complete; counts do not establish complete geometry coverage.

Sustained foreground smoothness, motion grain, physical drag/zoom/rotation/reversal gestures, completed provider route coverage and live adaptive transitions remain unqualified. No matched live FPS baseline, wider-device thermal result, Vulkan/DX12/mobile qualification, physical device-loss/hang recovery or external-renderer parity is established. Missing per-pass GPU costs and physical residency remain null. Earlier unpinned loaded shader images remain unpinned; later artifact hashes do not repair that historical gap. Dependency/SPM/script-output notices remain disclosed follow-ups.

Generic MRT, full source motion-vector parity, temporal SSR, arbitrary mutable PublicationGroup snapshot isolation and unrelated concurrent modules remain outside this wave. Ignored canonical docs and public website publication remain separate from these committed qualification records. Passing focused code checks does not change the failed live outcome.
