# Native planet example

From this directory, run `fvm flutter run -d macos`, or select your connected
native device. You can drag to orbit, scroll or pinch to zoom and choose a city
marker. See the [workspace README](../../README.md) for setup and verification.
# Camera pose lab

Run `flutter run -d macos -t lib/camera_lab.dart` to use the ported PointOfView
with the shared native Metal SceneView. The [camera lab notes](https://xraph.com/docs/zyren/reference/parity/native-camera-lab)
cover device commands, runtime checks and remaining limits. This is a numerical
port fixture with local calibration geometry; city streaming, atmosphere and
clouds remain in the [full parity matrix](https://xraph.com/docs/zyren/reference/parity/matrix).

# Terrain streaming lab

Run `flutter run -d macos -t lib/terrain_lab.dart` to explore a deterministic
terrain patch with checker imagery. The camera presets change detail as you
move. Scroll or pinch to zoom, or drag to orbit.

At a detail camera, enable **Offline test** to fail child loads while the parent
stays visible. **Reconnect and retry** restores finer terrain. The footer shows
loading requests, cached CPU bytes and visible GPU payload bytes.

The [terrain notes](https://xraph.com/docs/zyren/reference/parity/terrain-streaming) cover source contracts,
native verification and limits. This fixture needs no provider credentials.

# Google Maps lab

Run the Google Maps lab with your own Maps Tile API key or a Cesium Ion token
that can access Google's asset 2275207. Put one of these fields in a private JSON
file outside the repository: `ZYREN_GOOGLE_MAPS_KEY` or `ZYREN_CESIUM_ION_TOKEN`.
The lab uses the Google key when both are supplied.

```sh
flutter run -d macos -t lib/google_tiles_lab.dart --dart-define-from-file=/path/to/private-provider.json
```

Use your connected device ID instead of `macos` for Android or iOS. The lab
requires native presentation. It opens Manhattan, provides a Fuji preset and
uses the shared globe controls for surface navigation and orbital zoom.

Credits follow the visible tiles. You can open Data sources for the full text
on a narrow screen. Provider content stays in memory, and the scene releases
its requests and resources when you close it. The tile resource budget is
32 MiB, leaving room within the native store for replacement uploads.

The live integration test uses the same private configuration:

```sh
flutter drive -d macos --driver=test_driver/integration_test.dart --target=integration_test/google_tiles_test.dart --dart-define-from-file=/path/to/private-provider.json
```

It checks native presentation, Manhattan and Fuji geometry, a stable camera, attribution
at desktop and narrow widths, and cleanup. It needs provider access and a network
connection. For a local synthetic dataset, run `lib/tiles3d_lab.dart` or its
`integration_test/tiles3d_streaming_test.dart` test instead.

# Source story qualification

Add `--dart-define=ZYREN_LAB_CLOUDS=true` to open Tokyo, Fuji and London with
the pinned cloud maps and blue noise. Use the Clouds selector to choose Auto,
Low, Medium, High or Ultra. Auto starts phones at Medium and tablets/desktops at
High. You can change the setting while the scene is running.

Switch **Cloud shadows** off to skip the shadow maps and light shafts while
keeping the clouds visible. The **Shadows** selector sets Low, Medium, High or
Ultra independently of cloud quality. Auto follows the Clouds selector. Turning
shadows off keeps your chosen shadow quality for the next time you enable them.

Phones allow 48 MiB of visible tile payloads; tablets and desktops allow 64 MiB.
Both scene types use four concurrent tile requests. The screen-error target is eight
render pixels, so finer tiles can replace the broad parent imagery sooner.

| Device | Scene edge / total pixels | Auto cloud edge | Ultra cloud edge |
| --- | --- | --- | --- |
| Phone | 1600 / 1,572,864 | 512 | 640 |
| Tablet | 1920 / 2,097,152 | 640 | 640 |
| Desktop | 1920 / 2,097,152 | 640 | 768 |

Android and iOS views with a shortest display side of at least 600 logical pixels
use the tablet profile. Orientation does not change the classification. Desktop
windows keep the desktop profile at narrow widths.

Larger displays use a bounded render target; waiting longer does not lift that
limit. The rounded area cap leaves room for old and replacement effect textures
during a resize. Cloud quality changes restart refinement, and a failed change
keeps the current setting available with a retry action.

You can run one city and save its inputs and checks from the workspace root:

```sh
python3 tool/qualification/geospatial_stories.py run --preset london --device macos --provider-config /path/to/private-provider.json --output /tmp/zyren-london-metal
python3 tool/qualification/geospatial_stories.py report --output /tmp/zyren-story-report.json /tmp/zyren-london-metal/evidence.json
```

Use a fresh output directory for each run. Pass `--flutter` when Flutter is not
on your PATH, and `--ios` with an iPhone device ID. The runner keeps phone apps
installed so you don't have to repeat developer trust after every test. After a
device test, launch a normal app build before checking touch or gestures. Flutter's
integration-test binding can discard physical input in the retained test app.
See the [qualification runner guide](../../tool/qualification/README.md) for
normal-app restoration and launch commands.

The report retains all 74 pinned source stories. Five city scenes are registered
so far. A passing native run records the camera, date, viewport, backend, central
pick, attribution and cleanup. It does not certify image parity. Full source
image comparisons are still pending, and unregistered scenes stay visible in
the report. Each run includes file hashes before and after execution; changed
source or incomplete checks cannot produce a qualified result.

The fixture also hashes each atmosphere table and cloud map it loads. Those
bytes must match the upstream Git LFS hashes in
`assets/qualification/source_assets.json`: four atmosphere tables and, for cloud
scenes, five weather, shape and noise maps. Provider tile content stays outside
this asset manifest. You still need live provider access for the city geometry.

For the offline cloud, lens and SMAA regression, run:

```sh
flutter drive -d macos --driver=test_driver/integration_test.dart --target=integration_test/cloud_effects_test.dart
```

That fixture needs no provider credentials. It checks native presentation,
temporal history, resizing and resource disposal.
