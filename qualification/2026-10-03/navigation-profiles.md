# Live navigation profiles

Navigation is still too slow. Bounded upload staging let the iPhone finish four
complete routes and the Pixel finish rotation without the earlier upload-limit
failure. Both devices still stalled during movement. This is progress on a
failure mode, not completed performance qualification.

You can inspect the [structured results](navigation-profiles.json) and the
compressed frame traces in [navigation-profiles](navigation-profiles/). Earlier
all-device failures remain in [the first report](live-navigation.md).

## Completed measurements

All runs used Flutter 3.47.5 profile builds and live Google Tokyo tiles through
Cesium Ion. Each phase requested 12 seconds of stationary rendering, rotation,
surface drag or wheel zoom. FPS counts accepted native presentations. It does
not measure physical display scanout or touch latency.

| Device and run | Phase | FPS | p95 frame interval | Result |
| --- | --- | ---: | ---: | --- |
| iPhone 16 Pro, Low, fixed weather | Stationary | 40.8 | 27.4 ms | Complete |
| Same iPhone route | Rotate | 27.0 | 66.6 ms | Complete |
| Same iPhone route | Drag | 15.2 | 128.7 ms | Complete |
| Same iPhone route | Zoom | 18.6 | 89.7 ms | Complete |
| Pixel 9 Pro, Low, fixed weather | Stationary | 7.3 | 159.4 ms | Complete |
| Same Pixel route | Rotate | 4.0 | 888.1 ms | Complete; maximum stall 1.98 s |
| iPad Pro M4, High, fixed weather | Stationary | 30.8 | 38.5 ms | Complete; later lost foreground |
| MacBook Pro M3 Max | None | Unknown | Unknown | Inactive lifecycle; rejected |

The iPhone used renderer `0fcf1691` with the saved harness patch. All four phases
completed without tile failures, readback or cloud-history resets. Rotation
still fell to one coarse visible tile, and drag contained 26 intervals over
100 ms. Full route completion does not establish continuous detailed coverage.

The Pixel used `54110571`, which includes subsequent upload-staging corrections
and resource-write batching. Its first attempt could not settle with 16
`sourceFailed` tiles. A fresh process completed stationary and rotation, then
failed to settle for drag with 14 source failures. HTTP status was unavailable.
Android reported thermal status 1 at all 35 external checks in the second run.
These conditions prevent a clean speedup comparison with the earlier build.

The iPad used `f99814c1` and an on-device export because both DDS and direct VM
connections failed. The stationary phase passed continuous foreground checks,
but its geometry still changed during measurement. It lost foreground before
the next phase. We did not determine whether that came from auto-lock or another
interaction. No VM CPU profile is available for this run.

## Changes and measured costs

- Planet phone Auto now starts with Low clouds (`d29796b4`). Explicit quality
  choices remain available. In fixed-weather iPhone runs, Low presented 40.8
  stationary FPS with 10.8 ms median GPU time. Medium repeats presented 15.7
  and 23.2 FPS, with 46.2 and 21.9 ms GPU time. These are observations from
  separate runs, not a guaranteed multiplier. Apple thermal state was not
  measured, and fixed weather did not eliminate timing variance.
- The existing Sparsity control reduces cloud occurrence. An earlier iPhone
  run at 75% sparsity reached 29.8 stationary FPS, but the surrounding default
  runs varied from 15.7 to 34.1 FPS. That does not establish an isolated sparsity
  speedup. Reducing cloud quality or coverage changes the image.
- The iPhone CPU capture included repeated local-transform construction during
  scene capture and picking. `93ff5f36` caches immutable local transforms while
  preserving parent movement and computed transform getters. An isolated AOT
  probe reduced two million unchanged reads from a median 405.8 ms to 16.1 ms.
  The [probe source](navigation-profiles/local-transform-probe.dart) and
  [measurements](navigation-profiles/local-transform-probe.json) are retained.
  This is not an end-to-end FPS result. The cache is in the iPad build, not the
  recorded iPhone or Pixel builds.
- Reporting now survives tile-error serialization and missing CPU diagnostics
  (`67e74207`). The collector saves frame results before requesting CPU samples.
  `54110571` adds explicit weather modes, settings-change rejection, bounded VM
  requests and upload-admission checks. `f99814c1` adds the device export used on
  iPad. Missing diagnostics remain unavailable.

Pixel stationary GPU time was 24.9 ms, including 19.6 ms in effects and 5.3 ms
in the scene pass, while median presentation intervals were 135.7 ms. GPU scene
cost alone therefore does not explain its pacing. Resource graphs and native
presentation need separate investigation. CPU completion waits overlap GPU
execution and must not be added to GPU time.

## Verification and remaining work

Checks passed: 10 reporting, statistics and device-default tests; 30 scene,
picking and packet tests; four export and capture tests; and changed-source
analysis. The transform reuse tests failed before the change and passed after
it. Android, macOS and iOS profile builds succeeded. Device export and host
import were exercised on the iPad. Trace hashes are verified after decompression.

The build hashes and source groups in the manifest keep concurrent renderer
changes separate. The first staged iPhone binary hash was not captured before
the iPad build replaced that output, so its hash is explicitly unavailable.
Its source revision and harness patch are retained. CPU sample windows can
include settling as well as movement; inclusive function ticks overlap.

Remaining work includes foreground Mac and full iPad routes, Pixel tile-source
failures and long stalls, continuous tile detail during turns, and matched
before/after runs for later renderer changes. Windows and Linux devices were
not available. No matched Takram browser run was captured. Use the
[collector instructions](../../tool/qualification/README.md#live-navigation-timing)
to repeat the route with those limits recorded.

The ordinary cloud lab was restored from `f99814c1` on Pixel, iPad and iPhone,
with no benchmark autorun. Pixel and iPad launched successfully. The iPhone
installation succeeded, but launch was blocked because the phone was locked.
Physical gestures were not requalified. The Mac benchmark window remains open
for a foreground retry.
