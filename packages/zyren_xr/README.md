# zyren_xr

Use `zyren_xr` to run an ARKit world-tracking session and inspect its camera pose,
tracking quality, local anchors, planes and ambient light. You'll need a physical
ARKit device and iOS 14 or later. This checkpoint compiles for iOS; physical XR
behavior still needs qualification.

```dart
import 'package:zyren_xr/flutter.dart';

const transport = MethodChannelXrTransport();
final capabilities = await XrSession.capabilities(transport);
final session = await XrSession.create(transport);
try {
  await session.start();
  final snapshot = await session.snapshot();
  // A successful start can still have no frame or limited tracking.
  print(snapshot.frame?.tracking);
} finally {
  await session.dispose();
}
```

Add `NSCameraUsageDescription` to your host's Info.plist before starting. Capability
queries do not prompt. `start` requests permission when needed and reports denial,
restriction and missing configuration as separate `XrException.code` values.
Only one Zyren XR session can own the camera across Flutter engines.

The Dart-only `zyren_xr.dart` entry point imports no Flutter libraries. You can
test your session behavior with an `XrTransport` fixture while the iOS plugin
uses a real `ARSession`. The fixture does not establish native tracking.

## Session data

`snapshot()` reads the latest frame without retaining a queue of camera images.
Inspect session state, tracking quality and frame age before using its pose.
`nativeTimestamp` and frame timestamps use the native monotonic clock in seconds.
Paused, interrupted and failed sessions return no usable frame. Failed ARKit
sessions need disposal and recreation. Backgrounding pauses the session; call
`start` when you're ready to resume.

Matrices are column-major, right-handed rigid transforms in metres. Camera poses
follow the image sensor orientation. Intrinsics describe the captured image;
they are not a calibrated projection for your Flutter viewport.

`addAnchor` accepts a rigid session-space pose when tracking is normal and fresh.
You can own at most 128 app anchors. Plane snapshots include at most 128 planes
and report `omittedPlanes` when ARKit has more. IDs are local ARKit UUIDs. Bind
your scene's source IDs separately, and rebuild those bindings after
`start(resetTracking: true)` removes the previous origin's anchors.

Use `expectedRevision` and `expectedFrameTimestamp` for placement from a prior
inspection. Native checks reject a changed session or a frame older than 500 ms.
Ambient intensity and color temperature are ARKit estimates, not calibrated
photometric measurements or an environment map.

## Runtime agents

Import `package:zyren_xr/agents.dart` and register an `XrAgentProvider` with the
host's `AgentRegistry`. The package-local example shows the full setup.

- `inspect` returns tracking, camera/anchor/plane state, capabilities and the
  host's view identity. Use `anchorOffset`, `planeOffset` and `limit` (1 to 32)
  to page through the bounded snapshot.
- `place_anchor` uses `XrPlacementCommands`, requires host scope `xr.place`, and
  checks the expected provider, scene and native session revisions. Pass a
  session-space `transform`, `frameTimestamp` and `viewportId` from inspection.
- `undo_placement` removes the last anchor placed through those commands. A
  native reset or an independently removed anchor makes that undo stale.

Set `allowPlacement: true` only when your application permits it, and grant the
scope in the host registry. Mutations also require an idempotency key so a retry
does not create another anchor. Cancellation stops work before native submission;
once ARKit accepts an anchor, use its returned ID or the undo command to remove it.

The host supplies `XrViewBinding`, including scene/document/viewport IDs, camera
identity, logical rectangle, DPR, scene revision and the scene-from-session rigid
transform. Supply presented frame metadata only when you know it. XR sensor
frames do not prove which pixels your user saw, and this checkpoint reports
screen-to-XR raycasting as unsupported. It does not synthesize source IDs for
planes or anchors.

Unregister the provider before calling its `dispose`. Then dispose the session
when its owner closes. The provider does not own the camera session and never
opens an MCP listener; the shared devtools transport belongs to the host.

## Current limits

Camera presentation and depth occlusion report false. Requesting either as a
required feature fails explicitly. `sceneDepthHardware` only reports hardware
support; this plugin does not deliver depth buffers yet.

Camera compositing needs Metal image-plane import, YCbCr conversion, calibrated
projection and GPU lifetime synchronization. Depth needs an aligned depth and
confidence pass. ARCore's Vulkan adapter and OpenXR remain planned. Native
rendering stays Metal, Vulkan or DX12.

Run the diagnostic app in `example` when a physical iPhone is free. See the
[workstream plan](../../plans/zyren-plugins/xr.md) for device checks, renderer
dependencies and the complete backlog. This package is not published.
