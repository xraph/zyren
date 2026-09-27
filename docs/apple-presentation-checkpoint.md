# Apple presentation checkpoint

You can now use the CAMetalLayer presenter through the public scene controller.
Select `const SceneRuntime.nativeMetal()` on macOS or iOS. The same core engine
runs your updates, plugins and snapshots; normal presentation carries no frame
pixels through Dart. Physical-device and platform-input qualification remain open.

The earlier experimental texture bridge can render Metal content into a Flutter `Texture`
without sending frame pixels through Dart. It is disabled by default. Flutter's
Core Video texture cache retains old IOSurfaces and blocks the three-buffer
budget after a few frames, so this is an interoperability proof, not a qualified
viewport backend.

## What works

- The core engine and Flutter controller consume `FrameOutput`. Shared output
  carries frame statistics and a surface receipt; explicit capture carries pixels.
  Plugin `afterRender` hooks receive `FrameStats` through the same engine loop.
- Rust allocates an aligned, bounded IOSurface, imports its Metal texture into
  the renderer's device and waits for successful producer completion before
  publication. Normal shared rendering reports zero renderer readback bytes.
- The Apple plugin finds the existing `zyren_runtime` image with `RTLD_NOLOAD`
  and compares runtime tokens before accepting a surface. Flutter texture IDs
  stay separate from native surface identities.
- The macOS and iOS simulator integrations capture the actual texture and check its red center
  pixel. Native counters show Flutter's raster callback consumed the buffer.
  Test screenshot reads are separate from ordinary presentation counters.
- Native tests prove buffer turnover without Flutter, held-consumer backpressure,
  teardown after release and recovery when an epoch changes during GPU work.

The Rust framework has a distinct name because CocoaPods creates a
`flutter_zyren.framework` for the platform plugin. Both still use one native
registry. iOS uses its supported IOSurfaceRef header, and the native helper has
an explicit deployment floor instead of inheriting the installed SDK version.

## The failed gate

The first Flutter test checked a texture widget and one successful frame. A
stronger test required continued publication beyond the three-buffer bound and
zero retained allocations after teardown. That test failed: the producer stopped
after four frames, and three IOSurfaces stayed alive after macOS unregistration.
The iOS 26.0 simulator also hit the live-buffer bound during rendering, but its
texture teardown released all three buffers. Neither result meets continuous
rendering qualification.

A separate Core Video probe reproduced the cause without Flutter: imported
surfaces remained owned after their wrappers were released and after two seconds
of idle time. Explicitly flushing the texture cache released them. The plugin
does not own Flutter's cache and has no public API to flush it.

An experiment that re-notified Flutter about the current completed frame allowed
cache aging to resume allocation, but throughput remained poor and teardown still
retained buffers. It was removed. The implementation never increases the buffer
budget, fabricates consumer completion or reuses storage with an outstanding
owner to make this test pass.

## Reproduce the prototype

For development experiments only, you can enable the bridge explicitly:

```dart
final controller = SceneController(
  runtime: SceneRuntime(
    backendFactory: () => NativeBackend.create(
      experimentalAppleSurfaces: true,
    ),
  ),
);
```

The default backend does not advertise shared textures, and `requireSharedTexture`
continues to report `presentationUnavailable`. The portable examples select
`readbackOnly` explicitly. They still render through native Metal; they do not
use WebGL or a browser.

From `examples/multiple_views`, run:

```sh
flutter test integration_test/apple_presentation_test.dart -d macos
```

This is a characterization test. It checks real pixels, zero producer readback,
runtime mismatch rejection and the known retained-cache behavior. A passing
result does not pass the continued-rendering or cleanup qualification gates.
The [standalone probe](../experiments/apple_presentation/README.md) records the
cache and GPU lifetime behavior independently.

## Native Metal view proof

A separate `zyren/metal-proof` platform view drives a CAMetalLayer through the
existing Rust renderer. You can run it from `examples/multiple_views`:

```sh
flutter run -d macos -t lib/metal_view_demo.dart
flutter test integration_test/metal_view_test.dart -d macos
```

Use your iOS device ID in place of `macos` for the simulator. The proof uses public
AppKitView/UiKitView embedding APIs and the same loaded Rust runtime. It does not
pass rendered pixels through Dart. Metal owns a three-drawable pool; one producer
per view acquires and renders on a serial native queue. Publication runs on the
platform thread after successful GPU completion, where resize, suspension and
close can reject an old frame. A failed submission retains the entire drawable
with the renderer until GPU retirement, so its storage cannot return to the
display pool while work still owns it.

Both macOS and the iOS 26.0 simulator pass independent two-view rendering beyond
the buffer count, exact physical resize, suspension of one view while the other
continues, and 100 create/remove cycles. Every cycle returns to zero live and
retiring renderers, zero native view sessions and zero adapter-held drawables. A rejected scene exposes its
error and releases ownership. Readback diagnostics query the renderer itself;
a native regression verifies that an explicit 512-byte capture changes that
counter instead of accepting a constant zero.

The demo compares a native four-corner scene and gray patch with Flutter widgets,
then applies the same opacity, rotation and rounded clipping to both columns.
Use an OS screenshot for this comparison. Flutter widget raster captures do not
include the native platform view hierarchy. The fixture only has opaque native
materials; Flutter layer opacity does not establish native material-alpha support.

The iPhone 17 Pro simulator screenshot passes
`python3 tool/verify_metal_composition.py artifacts/ios-metal-view-proof.png`
from the repository root (Python with Pillow). The five plain interior samples
match exactly. For the transformed view, 99% of pixels differ from the reference
by at most one channel value, and 0.87% differ by more than two, primarily along
rasterized edges. The comparison permits less than 1% of those edge differences;
it does not claim bit-identical rasterization.

A standalone macOS release smoke run rendered 884 frames across two views, with
zero renderer readback bytes, then closed at zero live/retiring renderers and
zero native view sessions and held drawables. You can reproduce it from `examples/multiple_views`:

```sh
flutter build macos --release -t lib/metal_view_demo.dart --dart-define=METAL_PROOF_SMOKE=true
build/macos/Build/Products/Release/multiple_views.app/Contents/MacOS/multiple_views
```

The smoke mode exits after checking rendering and removal. Omit the Dart define
when running the interactive demo. That proof run used a locked desktop, so its
reference composition still needs a visible macOS comparison.

This fixture isolates ownership and composition. The integrated SceneView path
below now covers updates, render hooks, Flutter pointer routing, visibility and
capability selection. The native-only FFI
functions accept retained Metal objects from the platform plugin; pointers never
cross the Dart channel. The default backend remains unchanged.

## Next implementation

Keep the Apple runtime opt-in until platform input, physical devices and
composition are qualified. Any texture alternative must establish an
explicit consumer lifetime guarantee; private engine selectors are not part of
the library design.

Then qualify native alpha composition, platform input, physical iOS and
visible macOS composition. The proof already covers sustained rendering, 100
create/remove cycles, two views and macOS release runtime identity. Android SurfaceProducer/Vulkan and Windows DXGI remain independent
plan tasks. Three.js feature parity, assets/materials/animation and the full
geospatial port remain later milestones.

## Integrated SceneView runtime

```dart
SceneView.builder(
  runtime: const SceneRuntime.nativeMetal(),
  onCreate: (view) {
    final cube = view.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    view.onUpdate((time) => cube.rotateY(time.deltaSeconds));
  },
)
```

The view owns this controller and closes it on removal. For external controls,
pass a controller to `SceneView(controller: controller)` and dispose it yourself.
A borrowed controller keeps its GPU and geometry cache across view remounts.
Each mounted view gets a new attachment generation, so an old view cannot publish
into or detach its replacement.

The default `requireNative` policy accepts native views or shared textures.
`requireSharedTexture` remains strict and rejects this runtime's native-view
path. The opt-in runtime reports `PresentationPath.nativeView`; it does not
change the default runtime's capabilities.

Native work runs on a serial queue. A rendered drawable stays owned until the
presenter publishes it after the core render hooks. Resize, suspension and
removal revoke pending receipts. Async cleanup retains the session by value
until renderer destruction completes. Capturing through a backend
`ReadbackTarget` returns RGBA8 sRGB pixels and updates the measured readback
counter; the controller-level capture convenience API remains planned.

From `examples/multiple_views`, run:

```sh
flutter run -d macos -t lib/native_scene_demo.dart
flutter test integration_test/native_scene_test.dart -d macos
flutter build macos --release -t lib/native_scene_demo.dart --dart-define=METAL_SCENE_SMOKE=true
build/macos/Build/Products/Release/multiple_views.app/Contents/MacOS/multiple_views
```

The interactive example shares one scene across two controllers. Its buttons edit
the shared mesh, move each camera and close or reopen one view. Use an iOS
simulator ID instead of `macos` for the first two commands.

The integration suite checks updates and plugin hooks, an idle scene waking
after edits, two cameras, borrowed remount without re-upload, physical resize,
TickerMode suspension, 100 managed create/remove cycles and explicit pixel
capture. Injected Flutter taps test routing within Flutter; they do not establish
OS mouse, touch or keyboard delivery.

You can run `integration_test/native_scene_race_test.dart` to check cancellation
while renderer creation, view attachment or frame completion is pending. It also
delays an old attachment across a borrowed-controller remount. All four scenarios
pass on macOS and the iOS simulator, returning native ownership counters to zero
and preventing stale publication. The completion gate pauses the native reply
after GPU work finishes; the Rust timeout fixture separately blocks a GPU queue.
These gates compile only into Debug builds. The macOS release binary contains
none of their channel method names.

## Earlier proof checks

The checkpoint passes 50 core/geospatial tests, 46 Flutter and executable-example
tests, 11 native Dart tests, and 21 Rust tests with real GPU cases enabled.
Analyzer, Clippy, formatting and the package/header boundary check pass.
The existing macOS two-view integration passes through explicit readback.
The experimental texture characterization passes on macOS and iPhone 17 Pro
simulator with iOS 26.0, including rejection of a mismatched runtime token.

The macOS release app and iOS simulator debug app build. Rust checks pass for
Android ARM64 and the iOS ARM64 simulator. These builds do not prove release
shared-runtime identity, physical iOS behavior or Android presentation.

## Packaging limits

The shared Darwin plugin currently uses CocoaPods. Flutter 3.47.5 accepts this
and warns that Swift Package Manager support will become mandatory in a future
release. Add that packaging path before distribution. A build on the simulator
or a source-level Android check does not qualify physical-device presentation.

## Integrated runtime checks

The five SceneView integrations pass on macOS and the iPhone 17 Pro simulator
with iOS 26.0. Each platform presents 142 frames with zero readback, including
100 managed view cycles that return to zero sessions, renderers, retirements and
held drawables. The separate capture returns the expected red RGBA pixel and
adds exactly 11,844 bytes to the readback counter.

The integration caught a teardown crash in the native close helper: an async
block captured a C++ reference parameter whose owner had already returned.
Retaining the session by value fixes the reproduced crash and passes both full
lifecycle suites. Core/geospatial tests pass 50 cases; Flutter and executable
examples pass 51. Analyzer, formatting and package/header boundaries pass.

The standalone macOS release smoke presents 937 frames across two controllers
with zero readback. Removal returns all ownership counters to zero. This run
uses the public SceneView adapter and the loaded Rust asset's runtime identity.

The interactive release demo was also inspected on the macOS desktop. Both
native views render, the mesh button changes their geometry, and closing and
reopening the left view leaves the right view active. The iOS simulator capture
shows the same scene in the narrow layout. These checks establish the simple
demo's visible output; transformed composition and viewport pointer gestures
still need their own macOS qualification.
