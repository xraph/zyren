# Native XR

You can use this workstream to follow the ARKit session implementation and the
remaining ARCore and renderer work. The first checkpoint targets iOS 14 or later.
It does not qualify camera presentation, depth occlusion or headset support.

## Source and device audit

- `zyren` keeps its scene, math, resources and plugin contracts independent of
  Flutter. `flutter_zyren` owns the existing native presentation adapters.
- `flutter_zyren/darwin/Classes/ZyrenMetalViews.mm` presents through CAMetalLayer.
  `zyren_native/lib/src/surface.dart` uses runtime/slot/generation identities and
  native lifetime management. Neither API imports an ARKit captured image.
- Existing cameras calculate a projection from their frustum. XR will need an
  explicit calibrated projection, orientation and viewport transform before you
  can align virtual content with a captured camera image.
- Xcode 27.0 is installed. An iPhone 16 Pro and Pixel 9 Pro are connected. The
  iPhone has an active `dev.twinos.planet` console session (PID 82728 at audit),
  owned by native/geospatial qualification. Leave that app running. A paired iPad
  is listed but has not been claimed or qualified for this workstream.
- No existing XR package or adapter was found. ARKit is the first adapter because
  its SDK and compiler are available locally. Device availability does not imply
  permission to replace another owner's running session.

## Decisions

Keep `zyren_xr.dart` as a Dart-only contract and put Flutter method-channel
integration in `flutter.dart`. An iOS Flutter plugin owns a real ARSession.
The first API polls the latest native snapshot. It does not queue camera frames
or move image bytes through the method channel. Each snapshot carries tracking
quality and interruption/failure state; a successful start only means ARKit
accepted the configuration.

Use ARKit's right-handed world coordinates in metres, column-major matrices,
gravity alignment and session-local anchor UUIDs. Resetting tracking removes
anchors. You must rebind your scene after a reset; these UUIDs are not durable
source IDs. Anchor placement requires normal tracking. A session has a bounded
number of app anchors, and plane snapshots report truncation explicitly.

Capability queries do not prompt for camera access. Start validates the host's
camera usage description and asks permission when needed. Unsupported hardware,
denial, an occupied session, interruption and native failure stay distinguishable.
The plugin pauses on backgrounding and requires an explicit start to resume.

## Phases and acceptance

1. ARKit session checkpoint: create/start/pause/dispose, permission cancellation,
   typed capabilities, pose/intrinsics/tracking snapshots, local anchors,
   horizontal/vertical planes and ambient light. Accept after Dart contract and
   channel tests, iOS compiler checks and a reproducible device probe exist.
   Record physical checks separately. Simulator success cannot qualify tracking.
2. Metal camera and calibrated camera adapter: import ARFrame.capturedImage with
   CVMetalTextureCache, retain both image planes through GPU completion, apply
   displayTransform and YCbCr range/color conversion, then render the Zyren scene
   with ARKit's calibrated projection. Reuse native presentation, frame demand,
   scene transforms, diagnostics and resource retirement. Accept after portrait
   and landscape alignment, resize, pause/dispose, zero camera readback and
   bounded in-flight buffers pass on a physical iPhone and iPad.
3. Plane and anchor scene integration: use shared scene IDs for application
   bindings, expose plane geometry and raycasts, and preserve removal/relocalization
   semantics. Accept after placement, tracking loss, reset and re-entry device
   checks, plus deterministic transform tests. Persistent/cloud anchors need a
   separate identity and persistence design.
4. Depth and lighting: gate sceneDepth with supportsFrameSemantics, import depth
   and confidence textures, align timestamps/intrinsics and implement metric
   depth comparison against Zyren's depth convention. Feed ambient estimates and
   later environment probes into existing light/material APIs. Accept only after
   physical occlusion, confidence rejection, stale depth and unsupported-device
   checks. Ambient lux is not an environment map.
5. ARCore: implement install/availability and Activity permission lifecycle,
   tracking, anchors, planes and light estimates behind the same contract. Use
   AR_TEXTURE_UPDATE_MODE_EXPOSE_HARDWARE_BUFFER and Vulkan AHardwareBuffer import,
   with fence ownership and camera/depth alignment. Never initialize an OpenGL
   camera texture. Qualify on Pixel Vulkan, including Play Services install and
   denial/retry paths, before claiming Android support.
6. Headset milestone: separately design OpenXR instance/system/session lifecycle,
   swapchain ownership, per-eye views, predicted display time, reference spaces,
   actions and device loss. Metal/Vulkan/DX12 support depends on the runtime and
   extension set. Mobile AR does not establish headset support.

## Shared dependencies and requests

- `pubspec.yaml`: add `packages/zyren_xr` and its package-local example under the
  shared lock after re-reading other owners' entries. Resolve dependencies under
  the same lock. No core import or public API changes are needed for phase 1.
- Proposed later shared APIs, not edited here: external image leases and GPU
  completion in `packages/zyren_native`, calibrated projection/view input in
  `packages/zyren`, camera background/depth passes and presentation synchronization
  in `packages/flutter_zyren`. Check active ownership before each shared change.
- Reuse shared resource identity, disposal and render scheduling. Do not add
  geospatial dependencies, credentials or application policy to the renderer.
- Official references: [ARKit configuration capabilities](https://developer.apple.com/documentation/arkit/configuration-objects),
  [ARKit scene depth](https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth),
  [ARCore Vulkan camera buffers](https://developers.google.com/ar/develop/c/vulkan).

## Required runtime agent access

The shared contract is `zyren_agents`. `zyren_xr/agents.dart` supplies
`XrAgentProvider` with `inspect`, `place_anchor` and `undo_placement` tools. The
registry owns discovery, schema validation, scopes, cancellation and retry keys.
The provider uses the ordinary `XrPlacementCommands` API, which an application
can also call directly. The host must enable placement and grant `xr.place`.

Inspection returns bounded anchors/planes, tracking quality and reason, native
frame age, camera transform/intrinsics, ambient light and hardware/renderer
capabilities. Host-supplied scene/document/viewport identity, logical rectangle,
DPR, scene revision and scene-from-session transform accompany the sensor data.
Presented frame and presented scene revision stay null when unknown. Plane
estimates and session UUIDs do not establish persistent source identity or
rendered pixels. Screen-to-XR raycasting remains explicitly unsupported.

Placement checks the provider revision, host view identity and scene revision,
then native session revision and a frame no older than 500 ms. ARKit checks
normal tracking again when it receives the command. Reset, interruption and
anchor mutations change the native revision. Undo removes the last anchor from
the shared command history. After native submission, cancellation cannot undo an
accepted placement; its returned ID remains the recovery target.

Current acceptance: shared registry discovery and schema checks, real provider
query/action code exercised against deterministic transport fixtures, scope
denial, stale origin/frame/view, idempotent retry, undo and cancellation. Required
remaining acceptance: a physical session through this provider, actual MCP
transport, calibrated view correlation and a native rich hit followed by a
permitted placement. This plugin is incomplete until those checks pass.

## Checkpoint evidence

All 17 package tests pass, including Flutter method-channel behavior. The
example widget tests pass at 320 and 1100 logical pixels. The physical integration
probe is written but has not run. Xcode 27 compiles the ARKit Swift adapter to an
arm64 iOS 14 object against Flutter 3.47.5. The full example also builds with
`flutter build ios --debug --no-codesign --no-pub`, including plugin registration
and CocoaPods linkage. This verifies compilation, not native runtime behavior.
Swift Package Manager packaging remains open; the build uses CocoaPods.

An initial Flutter channel test was blocked by
`ENOSPC` while copying its test binary. The retry passed after disk pressure
eased; no other workstream cache was deleted. The shell's default Flutter uses Dart 3.9.2,
so checks must use `/Users/rexraphael/fvm/versions/3.47.5/bin/flutter` or its Dart.

No physical XR check has run. Camera
presentation, calibrated Zyren rendering, depth occlusion, ARCore and OpenXR remain
unimplemented. The package will remain unpublished (`publish_to: none`).
