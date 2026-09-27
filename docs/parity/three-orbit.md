# Three r184 orbit controls

Select `OrbitBehavior.three184` when you need the OrbitControls behavior from
Three.js 0.184.0. The default remains `stdlib236`, which matches the version used
by Drei in the pinned geospatial source.

```dart
controller.use(OrbitControlsPlugin(
  behavior: OrbitBehavior.three184,
  keyboard: true,
  configure: (controls) {
    controls.enableDamping = true;
    controls.zoomToCursor = true;
    controls.cursor = const Vec3(0, 1, 0);
    controls.maxTargetRadius = 20;
  },
));
```

Both modes use the same native camera and viewport APIs. You don't need the
geospatial package, JavaScript or a browser. To try r184, run
`flutter run -d macos -t lib/three_orbit_lab.dart` from `examples/planet`.
Use `lib/orbit_lab.dart` for stdlib.

## Behavior

| Operation | stdlib236 | three184 |
| --- | --- | --- |
| Auto-rotation | Fixed angle per update | `update(deltaTime)` uses seconds; omitted time retains the source's fixed step |
| Wheel and middle drag | Fixed zoom step based on direction | Step scales with the absolute pixel delta |
| Wheel during mouse orbit | Accepted | Ignored until the gesture ends |
| Modified arrow keys | Pan | Control, Meta or Shift rotates; plain arrows pan |
| Pinch cursor zoom | Pinch changes scale | Pinch also updates the cursor ray at the fingers' midpoint |
| Pinch finger release | Ends the active state | Remaining finger resumes the configured single-touch action |
| Target constraint | No cursor radius | `cursor`, `minTargetRadius` and `maxTargetRadius` bound the target |

The plugin supplies frame delta to r184 auto-rotation. Tests render one second
at 30, 60 and 120 Hz and compare the final pose. Damping still decays once per
update in both upstream versions. The core frame clock caps large time gaps at
100 ms, so resuming a suspended view does not replay every missed rotation step.

You can call `pan(deltaX, deltaY)`, `rotateLeft(angle)` and `rotateUp(angle)`
directly. Pan uses logical pixels and angles use radians. These methods also
work in stdlib mode as native convenience methods. They apply immediately and
request a frame. Keep the compatibility mode fixed for a controller's lifetime.

## Reference checks

The reference generator imports the actual r184 addon from the pinned npm
package. It records the source SHA-256 and captures position, target, zoom,
quaternion and start/change/end events after each action. The native replay
checks 128 traces containing 11,144 steps. The stdlib fixture remains unchanged
at 48 traces and 3,072 steps.

The r184 traces cover both projections, Y-up, Z-up, tilted and inverted up axes,
Earth-scale positions, cursor zoom with damping, distance and target limits,
disabled actions, modified keys, programmatic movement, pointer cancellation
and touch continuation. Position and target tolerance is 1e-8 scene units. Zoom
tolerance is 1e-12; event sequences match exactly. Quaternion comparisons
normalize both rotations before comparing their dot product, with a tolerance
of 1e-12. Near an Earth-scale orbit pole (within 2e-6 radians), the tolerance
is 1e-9: nanometer position rounding gets amplified into roll when the view
and up vectors nearly coincide. The largest measured dot error there is
6.4e-10, about 0.0041 degrees. Maximum Earth-scale position error is below
9.54e-9 scene units. This pole precision limit remains part of the native
world-coordinate camera contract.

Eight steps record an upstream exception: with rotation disabled, r184 retains
its pinch state after one finger lifts and the next move reads a missing second
pointer. The native controller cancels that state, preserves the pose and stays
usable. The replay records the exception and checks the native cancellation.

The addon also passes the horizontal pointer coordinate as both coordinates
when middle-button dolly starts. The compatibility mode retains this source
quirk for cursor zoom. Quaternion rotation preserves Three's arithmetic order
to avoid a spurious event difference at a distance clamp.

```sh
node tool/orbit_reference.mjs /tmp/geospatial-reference \
  packages/gpu3d/test/fixtures/three_orbit.json three184
cd packages/gpu3d
dart test test/orbit_controls_test.dart test/orbit_plugin_test.dart
```

Use the pinned development dependencies listed in [the stdlib setup](native-orbit.md).
The generator also accepts `stdlib236`, its default.

## Native verification

The integration test runs both modes at desktop and narrow viewport sizes. It
checks mouse orbit, pan, proportional wheel zoom, focused keys, modified-key
rotation, orthographic pinch zoom, single-touch continuation, damping and native
resource cleanup.

| Platform | Result |
| --- | --- |
| macOS 27, Apple Silicon | Both modes passed; 16 presented frames per mode, zero readback bytes and zero live native resources after each teardown |
| iPhone 17 Pro simulator, iOS 26 | Both modes passed; 17 stdlib and 19 r184 presented frames, zero readback bytes and zero live native resources after each teardown |
| Physical iPhone, iOS 27 | Signed build passed. Installation was rejected because all three free-development app slots were occupied. No hardware test result yet |
| Physical Pixel 9 Pro, Android 17/API 37 | Both modes passed through native Vulkan readback, including rendered pixel checks; nine stdlib and eight r184 diagnostic samples |
| Windows | Not run for this change |

Each mode produced eight throttled diagnostic samples on macOS and the
simulator. These counts are not frame-rate measurements. The macOS r184 app was
also inspected visually, and a native mouse drag changed its rendered view.

The Pixel's final stdlib frame contains 66,823 red, 87,504 green and 28,229 blue
box pixels. The r184 frame contains 55,437 red, 61,686 green and 13,366 blue box
pixels. Android uses this checkout's explicit readback presenter; this run does
not qualify a zero-copy Android presentation path.

The full core suite passes 226 tests; the Flutter host suite passes 50. Static
analysis, formatting, fixture regeneration and the package-boundary guard pass.

```sh
flutter test integration_test/orbit_lab_test.dart -d macos
flutter test integration_test/orbit_lab_test.dart -d YOUR_SIMULATOR_ID
```

For a wireless iOS device, use the driver runner. This Flutter SDK's test command
rejects wireless devices and does not expose its suggested `--publish-port` flag.

```sh
flutter drive --driver test_driver/integration_test.dart \
  --target integration_test/orbit_lab_test.dart -d YOUR_DEVICE_ID --publish-port
```

The physical iPhone retry used Flutter 3.47.5 with Xcode 27. The device installer
reported the free-development app limit before Flutter fell back to Xcode,
whose automation failed with `Failed to find project Runner: Error: Can't get
object.` A verbose retry with the command-scoped `FLUTTER_LLDB_DEBUGGING=true`
setting exposed the installation error. If you hit this limit, free a development
app slot before retrying. Removing an app also removes its local data. No existing
iPhone apps were removed for this check.

## Native input boundary

The native host supplies logical pixel scroll deltas. The reference replay
converts browser line units by 16, page units by 100 and synthetic Ctrl-wheel
pinch deltas by 10 before sending them to the native controller. These are
browser event conversions, not native key modifiers. Holding Control on a real
keyboard does not multiply native wheel input.

Native trackpad pan/zoom events, parented cameras and full story image comparison
remain unverified or unsupported as listed in [the parity matrix](matrix.md).
EnvironmentControls, GlobeControls and camera transition animation remain
separate work. Neither orbit mode performs terrain picking or height correction.
