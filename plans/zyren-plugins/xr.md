# Native XR

You can use this workstream to track native XR implementation and qualification.
The package remains unpublished until its required device checks pass.

## Current status, 2026-10-03

The mobile implementation and OpenXR design are committed. Required physical
acceptance is still incomplete, so the package remains unpublished.

| Phase | Implementation and checked behavior | Verification still required |
| --- | --- | --- |
| 1. ARKit session | Lifecycle, tracking, anchors, planes and light are implemented. iPhone session/provider placement, undo, pause/disposal and retained-frame background/restart probes passed. | Physical denial/retry, permission cancellation, interruption and engine teardown. |
| 2. Camera | Metal import, calibrated scene rendering and zero-readback diagnostics are implemented. iPhone and Pixel portrait/landscape presentation, viewport dimensions, resize, bounded leases and pause/disposal passed. | Visual alignment; all iPad checks, blocked by its free-profile app limit. |
| 3. Scene integration | Bounded geometry, calibrated raycasts, scene/source bindings and scoped hit placement are implemented. iPhone live MCP discovery, inspection and mutation denial passed. | Both phones detected no plane within the native-hit window. Rich hit placement, tracking loss, reset and re-entry remain pending. |
| 4. Depth and light | Native ARKit depth/confidence and ambient adapters are implemented. Four real Metal renderer tests and 24 depth shader comparisons passed. | Physical occlusion, stale/unsupported depth and device lighting behavior. Pixel returned depthUnavailable. Environment probes remain a later integration. |
| 5. ARCore | Vulkan camera/raw depth, lifecycle and shared agents are implemented. Pixel camera/resize, fresh permission grant, deny/retry and retained-frame background/restart passed. | Native placement/depth, AR service installation flow, Activity/engine teardown, GPU failure retirement and sustained performance. |
| 6. OpenXR | Separate lifecycle/device/swapchain design is committed in `1e5f280`. | No headset adapter or runtime qualification is claimed by this design milestone. |

The native agent probe traverses the shared MCP codec and authenticated loopback
HTTP transport. Its discovery/inspect/denial stage now passes on iPhone. That
phone remained at limited tracking with zero planes, and the Pixel native-hit
run also found no plane. Neither run establishes permitted native hit placement.
The host-side stdio bridge uses the same devtools implementation.

The resumed device runs exposed Android ELF alignment, permission-dialog pause
handling and rotation extent bugs. Commits `28b4f9c`, `ee3e266` and `12615b5`
correct them. The camera probe now waits for real Flutter/native viewport
convergence and checks every steady frame. Commit `0e384aa` adds a retained-frame
lifecycle probe and keeps the host examples awake. Independent reviews passed.

Checks: 56 package/example tests, clean Dart analysis, package boundaries, signed
iOS profile builds, 12 Kotlin tests, eight C++ extent assertions and NDK arm64
linkage. All eight arm64 APK libraries pass 16 KB ELF alignment and APK zip
alignment, but the available Pixel runs with 4 KB pages. No 16 KB device runtime
qualification is claimed.

The iPad installation failed because Physics Lab, Planet and the TwinOS app
already occupy the three free-profile slots. No app was removed. Both phones
need a usable tracked scene for remaining placement and depth checks. The Pixel
had no raw depth/confidence in the depth probe, which returned the required typed
error without establishing occlusion.

See the [qualification record](../../packages/zyren_xr/qualification/2026-10-03.md)
for logs and the full acceptance matrix. The source/device audit below records
the initial starting point, not current implementation or device ownership.

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
   checks. An ambient estimate is not an environment map.
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
   The [OpenXR design](../../packages/zyren_xr/docs/openxr.md) now defines this
   boundary, including runtime-selected device adoption, frame timing, swapchain
   ownership, reference spaces and agent correlation. It is a design deliverable.
   No headset backend or runtime/device qualification is claimed.

## Shared dependencies and requests

- Android review request, 2026-10-03: query and optionally enable Vulkan
  swapchain maintenance and its instance dependencies in vendored wgpu-hal
  `vulkan/adapter.rs` and `vulkan/instance.rs`. Chain the queried YCbCr and
  maintenance features into device creation. Expose the enabled capability in
  `interop/android.rs`; only XR presentation requires it. Present fences and
  per-image semaphores must prove display retirement before surface destruction.
  These exact shared paths were clean and had no competing plan request.

- Phase 5 request, 2026-10-02: add generic Vulkan context and external-image
  rendering entry points in `zyren_native/native/src/interop/android.rs`.
  The camera compositor borrows the renderer's Vulkan device and renders the
  scene into a caller-owned RGBA8 sRGB image with synchronous completion. Enable
  Android hardware-buffer, foreign queue and sampler YCbCr conversion support in
  the vendored Vulkan adapter only after checking the device's extensions and
  features. Validate device identity, image format, dimensions, ownership and
  failure retirement. ARCore and camera conversion stay in the XR Android plugin.
  The new external-image entry point also accepts an optional initialized D32Float
  image for metric depth occlusion. Existing Android and Metal entry points stay
  compatible. Depth and confidence retain their own timestamps and diagnostics;
  any native staging must be reported separately from camera import/readback.
  Add one renderer helper to release retained failed external targets only after
  Android proves queue idle or device loss. Other wait failures retain those
  targets through renderer retirement.

- Phase 4 request, 2026-10-02: add a compatible native Metal entry point in
  `packages/zyren_native/native/src/interop/metal.rs` for a caller-owned color
  texture and initialized Depth32Float texture. Pass the depth load choice through
  `src/renderer.rs`, `src/renderer/composition.rs` and `src/renderer/effects.rs`.
  Existing callers keep clearing their own depth. The new path validates device,
  dimensions and layout, retains both textures through completion, and rejects
  render modes that replace the supplied depth target. Native GPU tests belong in
  `tests/metal_target.rs`. These paths have no pending edits or overlapping
  requests in the other plugin plans at this audit. ARKit data stays in this plugin.

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
rendered pixels. Calibrated raycasting is available when the host supplies the presenter's raycast
callback and current calibration. Hit tokens retain presented camera identity,
viewport epoch, session revision and timestamp. Native placement checks the
presenter and epoch immediately before mutation.

Placement checks the provider revision, host view identity and scene revision,
then native session revision and a frame no older than 500 ms. ARKit checks
normal tracking again when it receives the command. Reset, interruption and
anchor mutations change the native revision. Undo removes the last anchor from
the shared command history. After native submission, cancellation cannot undo an
accepted placement; its returned ID remains the recovery target.

Current acceptance: shared registry discovery and schema checks, real provider
query/action code exercised against deterministic transport fixtures, scope
denial, stale origin/frame/view, idempotent retry, undo and cancellation. The
physical iPhone session/provider probe and live MCP discovery/inspect/denial stage
have passed. Calibrated visual correlation and a native rich hit followed by a
permitted placement remain pending. This plugin is incomplete until those checks pass.

## Historical checkpoint evidence before camera implementation

The following records the initial session-only checkpoint. Use the current status
above for implementation and device evidence.

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

### Local checkpoint, 2026-10-02

Implementation commit: `7b91fc383fa18c371aa53efb17914446b76d4b17`
(`feat(xr): add ARKit sessions and scoped agent placement`). It contains only
this package, example, plan and the two XR workspace entries. Other owners'
workspace additions and source changes stayed outside the commit.

Verified commands, using the repository's Flutter 3.47.5 SDK:

- `dart analyze packages/zyren_xr`: no issues, including the device probe source.
- `dart format --output=none --set-exit-if-changed` on the package and example
  Dart sources: 14 files, no changes.
- From `packages/zyren_xr`, `flutter test --no-pub test --reporter expanded`:
  17 tests passed. These use deterministic transport fixtures, including the
  shared agent registry. They do not execute ARKit.
- From `packages/zyren_xr/example`, `flutter test --no-pub test --reporter expanded`:
  two widget tests passed at 320 and 1100 logical pixels.
- `xcrun swiftc -emit-object -swift-version 5 -target arm64-apple-ios14.0` against
  the iPhoneOS 27 SDK and Flutter 3.47.5 framework: passed. Object output is
  `/tmp/zyren-xr-checks/ZyrenXrPlugin.o`.
- From the example, `flutter build ios --debug --no-codesign --no-pub`: passed.
  The unsigned app is `packages/zyren_xr/example/build/ios/iphoneos/Runner.app`.
  Build and test logs are under `/tmp/zyren-xr-checks`.
- Scoped staged diff check passed before the implementation commit. A broad
  checkout diff check found whitespace in another owner's boundary script;
  that file was left untouched.

Physical evidence remains absent. At the final read-only device check, the
earlier planet console process had ended and the process listing did not show
that app. No XR app was installed or launched. Free disk space had fallen to
159 MiB, and no other workstream cache was removed. Use a coordinated device
window and enough build space for the signed integration probe.

The next required checks are camera allow/deny/retry, permission cancellation,
normal/limited tracking, interruption/background resume, plane updates/removal,
anchor add/remove/reset and engine teardown on a physical device. Then exercise
the registered provider over the shared live MCP transport. Camera textures,
calibrated rendering, rich screen hits, depth occlusion, ARCore, SPM packaging
and separately qualified OpenXR remain in the phases above.
