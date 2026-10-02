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
flutter test integration_test/google_tiles_test.dart -d macos --dart-define-from-file=/path/to/private-provider.json
```

It checks native presentation, Manhattan geometry, a stable camera, attribution
at desktop and narrow widths, and cleanup. It needs provider access and a network
connection. For a local synthetic dataset, run `lib/tiles3d_lab.dart` or its
`integration_test/tiles3d_streaming_test.dart` test instead.
