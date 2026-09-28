# Planet labs

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
