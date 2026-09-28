# Native planet example

From this directory, run `fvm flutter run -d macos`, or select your connected
native device. You can drag to orbit, scroll or pinch to zoom and choose a city
marker. See the [workspace README](../../README.md) for setup and verification.
# Camera pose lab

Run `flutter run -d macos -t lib/camera_lab.dart` to use the ported PointOfView
with the shared native Metal SceneView. The [camera lab notes](../../docs/parity/native-camera-lab.md)
cover device commands, runtime checks and remaining limits. This is a numerical
port fixture with local calibration geometry; city streaming, atmosphere and
clouds remain in the [full parity matrix](../../docs/parity/matrix.md).

# Terrain streaming lab

Run `flutter run -d macos -t lib/terrain_lab.dart` to explore a deterministic
terrain patch with checker imagery. The camera presets change detail as you
move. Scroll or pinch to zoom, or drag to orbit.

At a detail camera, enable **Offline test** to fail child loads while the parent
stays visible. **Reconnect and retry** restores finer terrain. The footer shows
loading requests, cached CPU bytes and visible GPU payload bytes.

The [terrain notes](../../docs/parity/terrain-streaming.md) cover source contracts,
native verification and limits. This fixture needs no provider credentials.
