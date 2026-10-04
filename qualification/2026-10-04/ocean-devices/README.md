# Ocean device checks and release installation

The unified Planet app contains 16 launcher entries, including six saved ocean
scenes and the NOAA Monterey Bay region. The final app uses `lib/main.dart` and
bundle ID `dev.twinos.planet`. Test harnesses are replaced by that launcher after
qualification.

## Installed releases

All three devices now have the [fog-enabled release](../ocean-fog/README.md)
from `40760039`, version `0.1.0+1`. The [earlier installation receipt](installation.json)
and table below retain the pre-fog `6c0d3979` run and its launch limits.

| Device | Release installed | Latest foreground check |
| --- | --- | --- |
| Pixel 9 Pro | Yes; installed APK hash matches the built APK | Launch command succeeds; secure lock screen prevents visible verification |
| iPhone 16 Pro | Yes; signed release bundle installed | Passcode required; launch attempt also reports a CoreDevice connection failure |
| iPad Pro 13-inch M4 | Yes; signed release bundle installed | Launch explicitly denied because the device is locked |

Both release bundles contain byte-identical NOAA grids and the pinned manifest.
Xcode produced the signed iOS app in `Release-iphoneos`; Flutter's wrapper expected
`iphoneos` and returned a missing-product error. The actual bundle passed strict
code-signature verification and installed successfully on both Apple devices.

## What the checks establish

- All 131 ocean CPU/native tests pass on macOS Metal, including the 100-cycle
  quality/resource test. Twelve native physics bridge tests pass after the
  combined-current accuracy fix.
- Sixteen app tests cover saved definitions, native rendering/cleanup, 72 physical
  query samples, fresh-process NOAA offline access, the horizon artifact and real
  vessel wake injection. Thirty responsive Flutter checks pass, including narrow
  layouts, landscape and 200% text.
- The macOS seven-scene native application run passes scene switching, pause,
  independent layers, stable canvas bounds and awaited controller disposal. The
  [post-review run](macos-reviewed-native.json) also verifies vessel wake admission
  at the same code revision as the installed releases.
- The iPad M4 seven-scene profile run passes at `a263e5a0`, including Monterey,
  native presentation and disposal. The iPad locked before its post-review repeat,
  so the new wake-admission assertion is verified on macOS, not this device.
- Earlier iPhone and iPad six-scene runs pass after the canvas pixel cap. Their
  receipts retain the exact scene revision, framebuffer dimensions and tick count.
  The earlier Pixel result is in [its receipt](../ocean-scenes-2/pixel-native.json).
- Final mobile repeats require user unlock. Pixel's weather dream and then
  secure lock screen covered the app; the interrupted profile is not accepted as
  foreground performance evidence. iPhone reports `passcodeRequired: true`.
  The iPad subsequently reported the same locked state.

The mobile canvas stays below 921,600 pixels; desktop stays below 2,073,600.
Flutter UI keeps its normal display density. All accepted native runs report zero
presentation pixel readback. This is distinct from the deliberate GPU readback in
image regression tests.

## Short presentation samples

The custom balanced profile has a 32-point visual grid, one band and a 192-patch
cap. Canonical waves remain at 128 and physics uses a 60 Hz owner. These are not
stock Medium/High profiles. Each scene excludes 15 warmup presentations and then
records 120 intervals. This is a short sample on development devices, not a
sustained target qualification or a measurement of physical display scanout.

| Scene | Mac p50 ms | Mac p95 ms | iPad p50 ms | iPad p95 ms |
| --- | ---: | ---: | ---: | ---: |
| Calm | 33.392 | 35.583 | 50.120 | 51.780 |
| Storm | 33.590 | 37.961 | 50.079 | 52.418 |
| Coast | 65.684 | 73.580 | 82.433 | 85.136 |
| Vessel | 191.159 | 280.702 | 183.591 | 209.224 |
| Underwater | 58.033 | 65.889 | 66.656 | 70.634 |
| Orbit | 31.885 | 36.345 | 40.393 | 43.005 |
| Monterey | 45.981 | 51.323 | 117.020 | 162.716 |

The [Mac report](macos-profile.json) uses 1600x1200 on M3 Max at `eb7de2aa`.
The [iPad report](ipad-profile.json) uses 1137x810 on M4 at `a263e5a0`.
Both precede the wake-admission fix. Their JSON includes p99, CPU build/submit
measurements, render-submission GPU timing, wave host timing and logical payload.
The main render GPU timing excludes separate wave/interaction submissions.
Whole-frame GPU time, isolated water CPU/GPU cost and physical residency remain
null. No planned frame-rate target passes from these results.

The [canonical preparation probe](canonical-preparation.json) compares AOT
six-chart preparation before and after removing temporary per-mode lists. All six
final mode hashes match. Its modest timing change is not a frame-rate result.

## Review fixes

The final source review found two integration defects. Both regressions failed
before their fixes and passed afterward:

1. Vessel wakes used a 1.4 m radius where the grid required at least 1.89 m. Events
   were rejected while spray still appeared. Wake radius now spans at least two
   cells, spray follows accepted admission, and Scene info exposes rejection.
   A native test verifies accepted admission and nonzero ripple displacement.
2. The physics bridge added current uncertainty after admitting the wave query.
   It now checks the combined velocity error against the bridge policy before
   publishing a force batch. A stricter policy rejects an over-limit current even
   when the body solver's tolerance is looser; the within-limit control still runs.

The review covered owned ocean, physics, application and scene-input consumers.
It did not establish sustained performance, art acceptance, global survey accuracy,
Windows/Linux qualification or correctness of unrelated concurrent renderer work.
Planar reflections remain explicitly unsupported pending a native secondary-view
lease. No extra fluid model or geographic coverage is implied by these checks.

## Reproduce

From `examples/planet`, with Flutter 3.47.5:

```sh
ZYREN_QUALIFICATION_OUTPUT=/tmp/ocean-profile.json fvm flutter drive --profile \
  --driver=test_driver/qualification.dart --target=integration_test/ocean_lab_test.dart \
  --dart-define=OCEAN_PROFILE_FRAMES=120 -d macos
```

Use the physical device ID for mobile; add `--publish-port` for wireless iOS.
Set `OCEAN_PROFILE_FRAMES=0` for the functional check without timing collection.
Keep the device unlocked and the app in front. A completed build or a background
native frame does not prove visible scene output.

## Open gates

Sustained stock-profile desktop 1080p/60 and mobile 720p/30 targets remain unmet
or unqualified. Final professional art acceptance remains open. Windows DX12 and
Linux Vulkan hardware were not available. Monterey provides a bounded offline
region, not global coastlines or navigation charts. Traffic navigation, flight
and orbital dynamics remain later platform work.
