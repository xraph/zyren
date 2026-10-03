# Navigation upload pacing

Tile uploads now have a per-frame target: 2 MiB on phones and 4 MiB on tablets
and desktops. Camera updates continue against the last complete tile set while
new resources upload. One asset larger than the target can upload alone, within
the existing hard limits, so a large texture cannot block progress forever.

Upload pacing is committed in `03c11a51`. The Android packet-buffer fix is in
`35b23ebc`. Smooth navigation is not yet qualified.
You can inspect the [run manifest](navigation-upload-pacing.json), including
failed attempts, source revisions, build hashes and compressed frame traces.

## Pixel results before the packet-buffer fix

The paced build completed a live Tokyo route with Low clouds, shadows enabled,
fixed weather and a 960 x 963 render target. Each movement lasted 12 seconds.
FPS counts accepted native presentations, not display scanout or touch latency.

| Movement | FPS | p95 interval | Longest interval |
| --- | ---: | ---: | ---: |
| Stationary | 7.7 | 154.7 ms | 157.5 ms |
| Rotate | 8.3 | 179.5 ms | 260.4 ms |
| Drag | 5.3 | 231.8 ms | 304.9 ms |
| Zoom | 5.8 | 215.1 ms | 222.2 ms |

Uploads stayed below 2 MiB per frame. The earlier Pixel trace reached a 1.98 s
rotation interval with 31.19 MB uploaded in that frame. These runs differ in
source and viewport, so the shorter stall is an observation, not a controlled
speedup measurement. Three fresh baseline attempts produced no usable phases:
one lost foreground to the screensaver, and two encountered tile-source errors.

The paced route had no tile failures, pixel readback or cloud-history resets.
Detailed coverage still dropped to one visible tile during rotation. Only 46 of
101 rotation frames had the next tile set ready; the camera kept moving while
the remaining frames displayed the previous set. Smoother uploads do not prove
continuous detailed coverage.

Turning shadows off reached 8.9 stationary FPS, then failed to settle after
rotation with source errors. A later draw-cache build (`1c0991c8`) created zero
draw buffers and bind groups in steady stationary frames. Median native encoding
fell from 8.9 ms to 2.9 ms, but stationary FPS remained 7.8 in the instrumented
run. Neither change resolves the remaining delay.

## Remaining frame cost

Temporary Android probes separated platform-call duration from native command
duration. Across 24 complete 60-frame windows, median native graph execution
totalled 32.2 ms per frame, and the frame-profile request took another 11.3 ms.
These windows include settling and motion. They are diagnostic aggregates, not
phase-specific GPU measurements. Instrumentation patches and complete log rows
are retained; truncated rows are counted in the manifest.

App-scoped Android simpleperf captured 19,470 samples without loss during
settling. The JNI library accounted for 14.9% of sampled CPU time, with byte
construction and destruction among its hottest functions. The generated C++
profile compile command had no optimization flag. The earlier attempt to sample
as the shell user was denied; sampling as the debuggable app succeeded without
changing security settings.

`35b23ebc` replaces resizable packet vectors with fixed, zero-initialized byte
arrays. The existing capacity checks and error payload limit remain. The bridge
copies only the written response prefix into Java. This removes per-byte
construction and resize destruction even in unoptimized builds.

In the first steady 60-frame window after that change, native graph calls took
4.0 ms per frame and profile retrieval took 0.3 ms. The clean follow-up run
captured 41 complete windows, with medians of 5.2 ms and 0.4 ms respectively.
These windows include loading and settling, so they describe command costs,
not phase-specific GPU time.

## Pixel results after the packet-buffer fix

The clean follow-up (`jni-auto-3`) measured stationary and rotation phases at
960 x 963, with Low clouds at 510 x 512 and shadows enabled. Its build contains
`1c0991c8`, the JNI buffer fix and temporary call-timing probes. The exact patch
and APK hash are in the manifest.

| Movement | FPS | p95 interval | Longest interval |
| --- | ---: | ---: | ---: |
| Stationary | 12.3 | 98.1 ms | 112.6 ms |
| Rotate | 13.4 | 110.9 ms | 185.0 ms |
| Drag | Unmeasured | Unmeasured | Unmeasured |
| Zoom | Unmeasured | Unmeasured | Unmeasured |

The earlier draw-cache run (`rpc-auto-1`) measured 7.8 stationary FPS and 8.0
rotation FPS. The newer result is encouraging, but it is not a controlled
speedup ratio: instrumentation and thermal conditions differ, and streaming
changes the tile set during movement. These rates remain below smooth navigation.

Planet stayed in front throughout the clean run. Both measured phases had no
tile failures, readback or cloud-history resets. Rotation uploads remained below
2 MiB per frame, but detailed coverage again fell to one visible tile. The next
tile set was ready in 94 of 162 rotation frames. The run then timed out while
settling for drag, with 16 tile-source failures and no HTTP status available.
Drag and zoom after the JNI fix remain unqualified.

Two earlier JNI attempts are also retained. The first lost foreground before
measurement, and a later activity check found Photos in front. The second reused
that app session and stopped before measurement with 75 tile-source failures.
The clean run above started a fresh process.

An intermediate experiment deferred diagnostics construction for ordinary graph
commands. It passed six native GPU/protocol checks, but did not show a clear live
gain. That experiment was reverted and is retained only as qualification evidence.

## Device and verification limits

Mac profile builds succeeded, but both paced runs were rejected because Flutter
reported an inactive lifecycle. The iPad M4 export was also rejected as inactive.
The iPhone build and installation succeeded; launch was blocked by its lock
screen. Windows and Linux hardware were unavailable. No matched Takram browser
run was captured. Earlier Android runs reported thermal status 1; the clean JNI
follow-up reported status 0 throughout its environment samples. Apple thermal
state was not measured.

The upload fix passed 786 core tests, 166 Flutter package tests and 50 default
native package tests. The native suite skipped 174 GPU tests by default. A
separate Metal pixel test passed with native GPU execution enabled: it verified
that the previous tile set remains visible and follows the camera until the
replacement is complete. Changed Dart source analysis passed. The JNI change
built successfully for Android profile targets, passed seven Android backend
tests, and rendered live Google tiles and clouds through the changed bridge.

The ordinary cloud lab was rebuilt from `1c0991c8` without benchmark autorun,
with the additional JNI patch on Android. Pixel and Mac launch succeeded.
iPad launch succeeded. iPhone installation succeeded, but launch remained
blocked by the lock screen. Physical gestures have not been requalified.
