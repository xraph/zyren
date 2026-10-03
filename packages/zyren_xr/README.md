# zyren_xr

You can request scene-depth occlusion with
`XrConfiguration(requireDepthOcclusion: true)` on a supported ARKit or ARCore device.
ARKit imports depth and confidence textures directly. ARCore stages depth and
confidence in native memory and reports those upload bytes separately. Missing
depth or a retained frame older than 250 ms fails with a retryable error; low-confidence pixels leave virtual geometry
unoccluded. This uses standard projected depth with a single sample. Screen
effects, temporal rendering, MSAA and transmission capture are not supported by
the supplied-depth path. Physical occlusion remains unqualified.

Use `XrSceneBindings` to attach your scene objects to native anchor IDs. Keep
your application source ID on the binding. Updates validate the native snapshot's
session ID and origin epoch. Camera or individual anchor tracking loss hides content until tracking recovers. An origin reset
or observed anchor removal detaches it without disposing your mesh resources.

Use `zyren_xr` to run a native ARKit or ARCore world-tracking session and inspect
its camera pose, tracking quality, local anchors, planes and ambient light.
ARKit needs a physical supported device and iOS 14 or later. ARCore needs Android
API 27 or later and a compatible Vulkan device. Read the
[Android setup and qualification notes](android/README.md) before using that
adapter. Camera alignment and the full lifecycle still need physical qualification
on iPhone, iPad and Pixel.

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

On iOS, add `NSCameraUsageDescription` to your host's Info.plist before starting. Capability
queries do not prompt. `start` requests permission when needed and reports denial,
restriction and missing configuration as separate `XrException.code` values.
Only one Zyren XR session can own the camera across Flutter engines.

The Dart-only `zyren_xr.dart` entry point imports no Flutter libraries. You can
test your session behavior with an `XrTransport` fixture while the iOS plugin
uses a real `ARSession` and Android uses ARCore with Vulkan hardware-buffer camera
import. The fixture does not establish native tracking.

## Session data

`snapshot()` reads the latest frame without retaining a queue of camera images.
Inspect session state, tracking quality and frame age before using its pose.
`nativeTimestamp` and frame `timestamp` use the same adapter clock in seconds.
On ARCore, each new sensor frame receives its first host observation time. Repeated
reads of the same sensor frame keep that time, so they cannot make it fresh again.
The optional `sensorTimestamp` preserves the raw sensor timebase. Host observation
age does not measure camera exposure latency. Native depth matching still compares
the raw camera and depth timestamps before accepting them.
Paused, interrupted and failed sessions return no usable frame. Failed ARKit
sessions need disposal and recreation. Backgrounding pauses the session; call
`start` when you're ready to resume.

Matrices are column-major, right-handed rigid transforms in metres. Camera poses
follow the image sensor orientation. Intrinsics describe the captured image;
they are not a calibrated projection for your Flutter viewport.

`addAnchor` accepts a rigid session-space pose when tracking is normal and fresh.
You can own at most 128 app anchors. Plane snapshots include at most 128 planes
and report `omittedPlanes` when more planes exist. IDs are local native anchor identities. Bind
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
  native reset clears obsolete undo history after snapshot reconciliation. An
  independently removed anchor makes that undo stale.

Set `allowPlacement: true` only when your application permits it, and grant the
scope in the host registry. Mutations also require an idempotency key so a retry
does not create another anchor. Cancellation stops work before native submission;
once the native session accepts an anchor, use its returned ID or the undo command to remove it.

The host supplies `XrViewBinding`, including scene/document/viewport IDs, camera
identity, logical rectangle, DPR, scene revision and the scene-from-session rigid
transform. Supply presented frame metadata only when you know it. XR sensor
frames do not prove which pixels your user saw. When you supply the presenter's
`raycast` callback and current calibration, `screen_raycast` returns bounded native
plane hits. `place_hit` accepts a returned token and uses the same scoped command
and undo history. A native presenter/epoch guard rejects placement after resize or
reattachment, including changes while a call is pending. Source IDs for native
planes remain unknown; a plane estimate does not prove pixel visibility.

Call `commands.synchronize(snapshot)` from your host's snapshot loop to discard
undo history after a native origin reset. Commands and inspection also reconcile
the epoch. The first inspection after a reset can return `stale` because that
reconciliation changes the provider revision; repeat inspection for fresh state.

Unregister the provider before calling its `dispose`. Then dispose the session
when its owner closes. The provider does not own the camera session and never
opens an MCP listener; the shared devtools transport belongs to the host.

## Camera presentation

Create an `XrPresentationController` after starting the session, then mount its
`XrCameraView`. Request frames when your UI needs them. Only one frame can be in
flight, so skip a request while `isRendering` is true.

```dart
import 'package:zyren/zyren.dart';
import 'package:zyren_xr/flutter.dart';

final presenter = await XrPresentationController.create(session: session);
final scene = Scene()
  ..background = null
  ..backgroundOpacity = 0
  ..add(Mesh(BoxGeometry(width: .1, height: .1, depth: .1), UnlitMaterial())
    ..position = const Vec3(0, 0, -.5));
// Mount XrCameraView(controller: presenter) in your Flutter layout first.
final calibration = await presenter.render(scene);
print('${calibration.frameId}: ${calibration.pixelWidth} x ${calibration.pixelHeight}');
// When the view closes, await presenter.close() before session.dispose().
```

The controller acquires a native camera frame and its viewport projection together. Its
camera uses the view's interface orientation, crop and pixel dimensions. Supply
`sceneFromSession` when your scene has another rigid origin; scale and shear are
rejected because native positions and the clipping range use metres.

`presentedCalibration` updates after native rendering and presentation succeed.
It includes the frame ID, timestamp, session revision, viewport epoch, projection,
camera pose, display transform, logical dimensions and DPR. You can use it to
correlate your view metadata with the presented image. `diagnostics` reports the
native renderer's readback counter and the camera lease limits. These values are
null before the first successful presentation. You can also use `gpu` for scoped
resources, shader compilation and native GPU inspection.

The iOS adapter imports the captured Y and CbCr planes through CVMetalTextureCache,
converts full or video range with the image's YCbCr matrix, and applies ARKit's
inverse display transform. It retains the ARFrame and both texture wrappers until
GPU work finishes. Camera pixels stay native. The scene renders into an sRGB Metal
texture on the existing Zyren runtime's device, then the compositor blends the
virtual color with the camera. Resource commands and rendering share one serial
queue. Pause, resize, interruption and disposal reject obsolete leases.

Both CocoaPods and Swift Package Manager use the same Swift sources. The SPM
manifest links the FlutterFramework dependency supplied by the Flutter tool.

## Plane geometry and lighting

Call `presenter.raycast(x, y)` with viewport-local logical coordinates after a
successful presentation. The result carries the presented frame, viewport epoch,
native session revision, sensor timestamp and bounded plane intersections. Stale
frames and changed viewports fail explicitly. `session.planeGeometry` returns a
bounded mesh in plane-local coordinates; apply its pose and your scene origin.
`toGeometry()` creates an ordinary Zyren `BufferGeometry`.

Add `XrAmbientLighting.light` to your scene and update the adapter with each fresh
snapshot. You choose `neutralIntensityLux`, which maps the camera's neutral
estimate to your scene's diffuse light level. ARKit reports an estimated lumen
value with 1000 as neutral. ARCore reports gamma-space relative intensity and RGB
correction, without a measured color temperature. The adapter preserves that
boundary, converts ARCore correction to linear color and disables its light for
missing, stale or invalid input. It does not create specular reflections or an
environment map. Blackbody color is an approximation using the analytic CIE fit
from [Wyman, Sloan and Shirley](https://jcgt.org/published/0002/02/01/).
See [Apple's intensity definition](https://developer.apple.com/documentation/arkit/arlightestimate/ambientintensity)
and [ARCore's light-estimate contract](https://developers.google.com/ar/reference/java/com/google/ar/core/LightEstimate)
for the source units and color space.

The example has tap placement, anchor scene bindings, depth selection and origin
reset. Start it with `--dart-define=XR_DEVTOOLS=true` to enable the shared devtools
loopback listener. Its endpoint and temporary token are printed to the local debug
log. Set `XR_DEVTOOLS_TOKEN` and run `example/tool/mcp.dart` against that endpoint
to use the shared MCP stdio bridge. Android hosts can forward port 8796 with adb.
This host registers XR agent tools; a separate scene inspector is not attached.
Close the probe session to close its listener and revoke its token.

## Current limits

On iOS, `cameraPresentation` reports ARKit support; `depthOcclusion` and
`sceneDepthHardware` report scene-depth hardware support. On Android, camera and
depth renderer capabilities become available only after the presenter probes the
actual Vulkan device. `availability` retains ARCore's exact runtime state, including
missing or outdated Play Services. You must request depth
when starting the session; missing depth frames fail explicitly. Use transparent scenes without
screen effects. The iOS color path supports 8-bit bi-planar SDR images and rejects
unsupported image formats or YCbCr matrices. Android validates its hardware buffer
format and external YCbCr sampling capabilities. HDR camera transfer and wide-gamut
color qualification remain outside this implementation.

Read the [qualification record](qualification/2026-10-03.md) for checked commands,
review fixes and the remaining physical acceptance matrix.

The CPU tests verify camera transforms and controller failure handling. A synthetic
Metal test checks YCbCr range and alpha composition on macOS. Neither establishes
physical camera alignment, iPhone/iPad lifecycle behavior, or visual quality.
Run `example/integration_test/presentation_test.dart` on each device, then check
portrait and landscape alignment against real surfaces. The existing session probe
covers tracking and agent commands. The iPhone session probe has passed normal tracking, registered-provider placement
and undo, pause and disposal. Camera alignment, physical depth occlusion, rich
native hits over live MCP and the Android path still need device qualification.

See the [workstream plan](../../plans/zyren-plugins/xr.md) for remaining device
checks and renderer dependencies. This package is not published.
