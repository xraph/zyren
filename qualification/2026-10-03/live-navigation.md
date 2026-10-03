# Live Google Tiles navigation

The live runs exposed three problems we could fix without changing scene detail:

- Image decoders reject a third concurrent decode as busy. Asset loading treated
  that temporary response as a permanent tile failure. We now retry admission
  with bounded backoff, retain the downloaded source, and stop on cancellation.
  The Mac and iPad then settled with zero failed tiles.
- With moonlight enabled, observer movement changes lunar irradiance slightly.
  An exact comparison discarded cloud history on 546 of 549 moving frames in
  the diagnostic Mac route. History now tolerates irradiance changes below
  0.1%, while retaining checks for moon direction, light edits and camera cuts.
  Lighting becomes part of the last successfully presented frame's history.
- Scene traversal copied every node's child list on every read. The first Mac
  CPU capture included this getter in 855 of 7,585 samples. We now cache each
  immutable snapshot until children are added, removed or reparented. Existing
  snapshots still retain their membership, and callers cannot mutate them.

You should not read this as completed qualification on all devices. The final
foreground comparison remains pending, and an intermittent upload failure can
still stop navigation. The fixes are local commits `184bf65d`, `8cb7f563` and
`7e72b088`; nothing was pushed.

## Device evidence

These runs used Flutter 3.47.5 profile builds, live Tokyo tiles through Cesium
Ion, animated clouds, default cloud quality, shadows on and zero sparsity.
Each requested phase lasts 12 seconds. FPS counts accepted native presentations,
not physical display scanout. Inputs follow the same globe controls as the app.

| Device | Observed result | Qualification limit |
| --- | --- | --- |
| MacBook Pro, M3 Max, 128 GB | 21.5 stationary FPS, 59.2 ms p95 interval, 1600 × 792 render target | Stationary phase only. Rotation stopped on the scene upload budget. |
| iPad Pro 13-inch, M4 | 30.0 stationary FPS, 35.0 ms p95 interval, 1880 × 1115 render target | Stationary phase only. Rotation hit the same upload failure. |
| Pixel 9 Pro, Mali-G715 | 7.6 stationary FPS, 153.8 ms p95 interval, 960 × 963 render target | Decoder fix included. Rotation stopped after four frames on the upload budget. |
| iPhone 16 Pro, A18 Pro | 40.0 and 11.5 stationary FPS on two foreground runs, 1206 × 798 render target | Both runs stopped during rotation on the upload budget. Final fixes included. |

All stationary results include the decoder retry fix. The Mac, iPad and Pixel
builds precede the child snapshot and lunar history fixes; the iPhone includes
both. GPU timing was unavailable in these samples. Readback was zero. All
stationary frames reported tile-budget pressure, so these measurements do not
describe unrestricted detail. The Mac and iPad reported resumed lifecycle at
their start and failure boundaries but preceded continuous foreground checking.

### Pixel follow-up

Once the XR run had ended, we relaunched the installed Planet profile build.
Its APK hash matched the saved build. This kept the run independent of the
renderer and collector edits underway in the shared checkout.

The stationary phase presented 91 frames at 7.6 FPS with 143 visible tiles.
Rotation stopped on the upload budget after four frames, with visibility
falling as low as one tile. Three of those four frames reset cloud history for
lighting, consistent with this build predating the lunar history fix. There
were no tile decode failures or readbacks. The short rotation sample cannot
qualify navigation FPS.

Android reported Planet as the resumed activity and thermal status 0 at all six
external checks, roughly five seconds apart. The app also reported resumed
lifecycle at both boundaries. These checks do not establish constant GPU
clocks or continuous foreground coverage. CPU profile retrieval failed with an
RPC error, and GPU timing was unavailable.

After collection, the installed Planet app was relaunched with no benchmark
running. Tokyo geometry and refined clouds were visible. A retry left six tiles
unavailable with zero active requests; the cause was not captured. That later
restoration is separate from the measured run, which reported no tile failures.

### iPhone follow-up

The iPhone was later unlocked and available while the iPad remained reserved for
Scientific Lab. Both iPhone runs used the same installed profile binary, all three
fixes, Medium clouds at 768 × 508, shadows enabled and zero sparsity. Foreground
checks remained satisfied throughout each attempt.

Both stationary phases held 146 visible tiles, 167 draw calls and 291,753
triangles. Yet stationary FPS fell from 40.0 to 11.5 on the repeat, with p95 frame
intervals of 26.6 and 94.5 ms. We have not isolated the cause of that variance.
Thermal state and resource behavior after renderer recovery need measurements;
neither is established as the cause here.

Rotation failed within its first second on both attempts. The collector retained
12 and 14 frames, including roughly 38.5 and 34.9 MiB of uploads before failure.
Most of those frames had only one coarse fallback tile visible, compared with
146 while stationary. This records the loss of detail during movement, but the
short rotation intervals cannot qualify navigation FPS.

Cloud history did not reset in either rotation attempt and continued accumulating.
No tile decode failures were reported. Those observations support the fixes on a
live phone, without establishing sustained navigation performance. Source and
compiled-bundle hashes are saved with the evidence; concurrent source changes
were not hot-reloaded into the installed AOT binary.

A second Mac route completed before the final two fixes, but the app reported
an inactive lifecycle. It is diagnostic evidence only:

| Phase | Presentation FPS | p95 interval | Frames over 100 ms | Uploaded payload |
| --- | ---: | ---: | ---: | ---: |
| Stationary | 21.4 | 57.5 ms | 0 | 0 |
| Rotate | 16.8 | 200.1 ms | 25 | 144.1 MiB |
| Drag | 13.4 | 97.1 ms | 8 | 169.9 MiB |
| Zoom | 15.3 | 87.9 ms | 2 | 62.6 MiB |

The older collector marked that route passed because its scene checks passed.
The evidence wrapper explicitly excludes it from foreground qualification.
The collector now rejects loss of foreground focus, preserves interrupted phase
samples, and records renderer failure metadata without provider URLs. The final
Mac build was rejected by that foreground check twice. Focus attempts did not
change its reported lifecycle. Later mobile runs also need exclusive access to
the devices currently used by XR work.

## Remaining navigation failure

The Mac, iPad, iPhone and Pixel reached `Scene resource upload exceeds the frame budget`
when rotating. The encoder rejects a submission above 64 MiB of uploaded
payload, one million new vertices or three million new indices. These limits
are separate from the scene's residency allowance. A large visibility or LOD
change can exceed a submission limit even when the resident scene fits.

The recorded exception does not identify which limit was exceeded. We have not
raised the limits or treated this as fixed. The next renderer change needs
bounded resource upload staging, with complete tile coverage retained until a
replacement can be published. Test camera reversals, large turns and repeated
location changes under that policy, then repeat the same live route.

macOS also reproduced the pinned Flutter accessibility bridge crash during UI
inspection. Its existing example compatibility hook did not prevent that crash.
That is separate from the upload failure and remains unresolved.

## Checks and rerun

Targeted checks passed: 22 asset admission/budget tests, 21 tile streaming tests,
19 scene/raycast/frustum tests, 10 cloud history/control/Metal temporal tests,
and two benchmark statistics tests. Changed source analysis passed.
The full Planet suite also passed all 20 tests with `RUN_NATIVE_GPU=1`. Its first
attempt without that flag failed to start the native atmosphere test backend.

The new native moonlight regression failed before the fix: 18 renders retained
only one history frame. It passed afterward with all 18 retained. Tests also
cover actual light changes, unpresented frames, cancellation, permanent decode
errors, bounded retries and child snapshot behavior.

[Structured evidence](live-navigation.json) includes run settings, incomplete
attempts, failure classifications and compressed raw frame traces. CPU profiles
remain under `/tmp/planet-navigation-20261003`; they cover loading and settling
as well as measurement, so their percentages are not per-phase CPU timings.
The checkout and devices were shared with other work. Thermal state was not
held constant, and no matched Takram browser run was captured.

Use the [navigation collector instructions](../../tool/qualification/README.md#live-navigation-timing)
for the rerun. Check exclusive device availability, keep the iPhone unlocked,
and keep Planet foregrounded on the Mac. Repeat Auto after each Low, shadows-off or 75% sparsity
experiment. Those comparisons are still pending; this report makes no measured
FPS improvement claim for the final fixes.

The normal Mac cloud lab was restored with all three fixes. Its first launch
hit the same upload limit; a second launch showed live Tokyo geometry, 340
visible tiles and refined clouds. This confirms the normal app is rendering
again, not that the intermittent failure is resolved. The Pixel and iPad were
left to their other device checks.

After the iPhone follow-up, rebuilding the normal target failed in the Rust
renderer while concurrent renderer edits were in progress. The installed Planet
benchmark build was relaunched successfully instead. It uses the normal Flutter
input binding and starts without running a benchmark. Physical gestures and a
completed scene were not rechecked after that relaunch.
