# Native OrbitControls

You can orbit, pan and zoom either core camera with `OrbitControls`. This ports
the three-stdlib 2.36.1 implementation used by Drei 10.7.7. It runs in Dart and
uses public core camera/input APIs. No geospatial import or JavaScript runtime
is involved.

`OrbitControlsPlugin` binds the controller to SceneView input and requests frames
while damping or auto-rotation needs them. It releases gesture and key ownership
when detached. Replacing the scene camera creates a fresh controller and reapplies
the configuration callback. The new camera's target becomes the orbit target.

```dart
final orbit = controller.use(OrbitControlsPlugin(
  keyboard: true,
  configure: (controls) {
    controls.enableDamping = true;
    controls.zoomToCursor = true;
    controls.minDistance = 1;
    controls.maxDistance = 100;
  },
));
// After attachment:
orbit.controls?.reset();
```

The standalone controller retains stdlib's default of no damping. The example
enables it, as Drei does. Both damping and auto-rotation advance per update in
this source version. At 120 updates per second, default auto-rotation moves twice
as far in one second as at 60. The port preserves this behavior. Three's newer
addon accepts delta time through the separate [three184 mode](three-orbit.md).

## Reference traces

The generator executes the actual npm OrbitControls module against a small
event surface. The surface only delivers events and viewport dimensions; camera
calculations come from the upstream module. The fixture records package versions
and the module's SHA-256. The native application consumes none of that code.

There are 48 traces and 3,072 checked steps, covering:

- Perspective and orthographic cameras with Y-up and Z-up axes, including
  Earth-scale world positions and combined damping/cursor zoom.
- Primary orbit, secondary pan, Shift-primary pan, middle-button dolly and wheel.
- One-touch orbit/pan and two-touch dolly/pan or dolly/rotate, pointer release and
  cancellation. Wheel input during an active touch orbit stays ignored.
- Damping after release, cursor zoom with screen-plane and ground-plane targets,
  distance/zoom/polar/azimuth limits, reversed orbit and map-style button mappings.
- Viewport resize, arrow keys, save/reset, programmatic angles and dolly/scale.
- Auto-rotation over one second at 30, 60 and 120 updates.

Every step compares position and target within 1e-8 scene units, zoom within
1e-12 and quaternion dot magnitude within 1e-12. Start/change/end events match
exactly. Maximum observed Earth-scale position error is below 1.94e-9 scene
units. The orthographic port retains the source's cached orientation during
damped cursor zoom. Plugin tests also verify that damping settles, idle updates
stop, camera replacement retires the old controls, and disposal releases input.

```sh
npm install --prefix /tmp/geospatial-reference --save-exact --ignore-scripts --no-audit --no-fund \
  typescript@5.9.2 three@0.184.0 tiny-invariant@1.3.3 three-stdlib@2.36.1
node tool/orbit_reference.mjs /tmp/geospatial-reference \
  packages/gpu3d/test/fixtures/stdlib_orbit.json
cd packages/gpu3d
dart test test/orbit_controls_test.dart test/orbit_plugin_test.dart
```

## Native example

From `examples/planet`, run `flutter run -d macos -t lib/orbit_lab.dart`, or use
your iOS/Android device ID. This is an ordinary box scene with no geospatial
plugin. Desktop and narrow layouts share the same compact toolbar and ZeroState.

The integration test checks native rendering, mouse orbit, right-button pan,
cursor wheel zoom, focused arrow keys, orthographic pinch zoom, cursor zoom
while damping remains active, bounds after resize and cleanup. The macOS Metal
run passed with 16 presented frames, eight diagnostic samples and zero readback
bytes. Diagnostic samples are throttled; this is not an FPS measurement. The
native macOS window was also visually inspected, and a native mouse drag changed
the camera view.

| Platform | Result |
| --- | --- |
| macOS 27, Apple Silicon | Metal interaction/layout test passed; zero live renderers, sessions and held drawables after disposal |
| iPhone 17 Pro simulator, iOS 26 | Same test passed; 17 presented frames, eight diagnostic samples, zero readback bytes and zero live native resources after disposal |
| Physical Pixel 9 Pro, Android 17/API 37 | Native Vulkan readback test passed; the final frame contains 66,823 red, 87,504 green and 28,229 blue box pixels |
| Physical iOS and Windows | Not run for this slice |

Android uses this checkout's explicit readback presenter. These pixel counts
verify that the three boxes reached the rendered image; they are not an upstream
image comparison. The full core suite passes 96 tests, and the Flutter host suite
passes 50 tests. Static analysis and the package-boundary guard pass.

```sh
flutter test integration_test/orbit_lab_test.dart -d macos
flutter test integration_test/orbit_lab_test.dart -d YOUR_DEVICE_ID
```

## Differences and remaining work

The public API uses immutable Dart vectors, logical pointer coordinates and
Flutter focus/gesture ownership. Pointer input requires `ViewportInputSource`;
keys require explicit registration. Distance and zoom limits use a positive
floor of 1e-12 to keep the native projection invertible. A camera at its orbit
target, invalid nonfinite configuration and maximum bounds below that floor
throw. Damping stops requesting
frames once angle residuals fall below 1e-12 and pan residual length falls below
1e-12 scene units; the upstream wrapper keeps calling update on every frame.

The [three184 mode](three-orbit.md) provides delta-time auto-rotation, wheel-delta
scaling, cursor target-radius limits, modified-key rotation and different touch
continuation rules. This page covers the default stdlib mode. Native trackpad
pan/zoom gesture events are not wired yet; wheel events are supported. Cameras
follow the existing world-space target/up contract, without parent transforms.
Full upstream story image comparison remains unrun. GlobeControls surface picking, terrain clearance,
near/far globe modes, dynamic clipping and camera transition animation remain
separate work.
