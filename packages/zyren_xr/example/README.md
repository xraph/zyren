# XR session probe

Run this app on a free physical ARKit iPhone or iPad with iOS 14 or later:

```sh
cd packages/zyren_xr/example
/Users/rexraphael/fvm/versions/3.47.5/bin/flutter run -d <device-id>
```

Tap Start, allow camera access and move the device slowly. You can inspect camera
position, tracking quality, frame age, plane/anchor counts and ambient estimates.
Pause stops tracking. Release closes the session, unregisters its agent provider
and clears the timer. Start again to create a fresh session.

Place anchor uses the shared registry with the host's `xr.place` grant. It places
an anchor half a metre along the sensor camera's forward axis. Undo removes it.
The native camera view draws a 10 cm orange cube. Placement moves it to the latest
anchor. The initial cube sits half a metre along the session origin's negative Z
axis, so it may leave the view as you move.

You can run the physical probe with:

```sh
flutter test --no-pub integration_test/session_test.dart -d <device-id>
```

The probe requires camera permission and normal tracking within 30 seconds. It
checks capability reporting, tracking, shared provider inspection, placement,
undo, pause and release. It does not qualify planes, lighting accuracy, rendered
alignment, depth occlusion, screen raycasts or live MCP. Read the workstream plan
for those remaining checks.

Use `integration_test/presentation_test.dart` for the camera path. It requests
portrait and landscape orientations, renders 30 frames in each, resizes the view,
checks native readback and lease counters, then pauses and releases the session.
You still need a visual alignment check against real surfaces on both iPhone and
iPad. A passing synthetic or build check does not establish that alignment.

For CPU checks, run `flutter test --no-pub test`. These tests use a transport
fixture to check the rendered layout at 320 and 1100 logical pixels; they do not
start an AR session. Keep another workstream's device app running if it owns the
connected phone. Build outputs and logs are not runtime evidence.
