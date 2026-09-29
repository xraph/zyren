# Extend the engine

Use `zyren` for Dart scene and plugin code, or `flutter_zyren` for the Flutter
facade. Add `zyren_geospatial` when you need Earth coordinates or globe controls. The dependency points one way: the
geospatial package imports the core, and the core never imports geospatial.

## Choose an extension point

| Contract | You supply | Ownership |
| --- | --- | --- |
| `ScenePlugin` | Controls, scene updates, domain services or asynchronous setup | One instance per engine; attach and detach belong to the engine |
| `RenderBackend` | Native submission with typed capabilities and output | A fresh instance from `SceneRuntime.backendFactory`; closed by the controller |
| `FramePresenter` | Conversion from RGBA output to a Flutter display | A fresh instance from `presenterFactory`; disposed by the viewport |
| `PresentedFrame` | A widget and resources for one displayed frame | Retired by the viewport after the replacement paints |
| `BufferGeometry` / `Object3D` | Custom mesh geometry and scene composition | Your scene owns these Dart objects; applied views retain native geometry until removal or close |

These contracts are implemented and tested. They do not yet expose native shader
registration, render passes or texture handles. Those require a resource API and
render graph in the core. Replacing the presenter alone cannot remove the current
GPU readback. The new backend output contract separates readback from presented
frames; shared texture presentation still needs native platform synchronization.

## Write a plugin

Extend `ScenePlugin`. Keep the ID, dependencies and required features stable for
the lifetime of the instance. You can mutate scene objects through the context.

```dart
class SpinPlugin extends ScenePlugin {
  final Object3D object;
  double angle = 0;
  Registration? demand;
  SpinPlugin(this.object);

  @override
  String get id => 'example.spin';

  @override
  void attach(PluginContext context) => demand = context.acquireFrameDemand();

  @override
  void detach(PluginContext context) => demand?.dispose();

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    angle += frame.delta.inMicroseconds / 1000000;
    object.quaternion = Quat.axisAngle(const Vec3(0, 1, 0), angle);
  }
}

final spin = SpinPlugin(cube);
final viewport = SceneView.scene(
  scene: scene, camera: camera, plugins: [spin],
  options: const EngineOptions(presentation: PresentationPolicy.readbackOnly),
);
```

Register plugins once in `SceneView.builder`'s `onCreate`, or on a borrowed
controller before its first attachment. Rebuilds preserve that configuration.
Change `sceneKey` for a managed replacement; use `controller.retry()` or the
error builder's retry callback after a failure. Retry retains CPU scene state and
does not replay setup. A plugin instance belongs to one engine at a time.

## Share a typed service

Export one `ServiceKey<T>` alongside your service interface. The provider calls
`context.provide(key, service)` during `attach`. Consumers declare the provider's
plugin ID in `dependencies` and call `context.service(key)`.

The engine sorts dependencies before it creates a renderer. Missing dependencies,
duplicate IDs and cycles fail initialization. Once the renderer exists, all
`requiredFeatures` are checked before any plugin attaches. Services are scoped to
one engine. Duplicate providers and registration outside `attach` are errors.

Attach hooks may be asynchronous. They finish before rendering starts. A failed
attach triggers reverse cleanup, including the plugin that failed, so `detach`
must tolerate partial initialization. Dependencies remain available while their
consumers detach. Cleanup continues if a plugin throws, releases the renderer and
reports all cleanup failures.

## Frame lifecycle

For each frame, the controller calls its registered `onUpdate` callbacks, then the
engine runs `beforeRender` hooks in dependency order. The renderer produces a
frame output. The engine passes its `FrameStats` to `afterRender` hooks in the
same order, and the presenter displays the image or shared texture in Flutter.

Only one frame can be in flight. `FrameInfo.delta` starts at zero and is capped
at 100 milliseconds to avoid large jumps after a pause. A reset elapsed clock
also produces a zero delta. Frame hooks may be asynchronous, but slow hooks delay
the frame. Hooks receive statistics without forcing pixel readback.
Do not wait for engine disposal from inside a frame hook: disposal waits for that
frame to finish.

The viewport continues rendering while a window is visible but unfocused. It
stops when the application is hidden, paused or detached. Flutter calls visible
unfocused windows `inactive`; see its [lifecycle contract](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html).

`SceneEngine` also works without a viewport. You can create it, call `render` and
await `dispose` from an offscreen workflow. In the Dart core you supply
`rendererFactory` explicitly. The Flutter facade keeps `NativeRenderer.create`
as its default. Both use the same plugin host and ownership rules.

## Install geospatial

```dart
final geo = GeospatialPlugin();
final orbit = GlobeOrbitPlugin();
final scene = Scene()
  ..add(Mesh(geo.reference.globeGeometry(), DiffuseMaterial()));
final camera = PerspectiveCamera(near: 100000, far: 200000000);

final viewport = SceneView.scene(
  scene: scene,
  camera: camera,
  plugins: [geo, orbit],
  options: const EngineOptions(presentation: PresentationPolicy.readbackOnly),
);

// Application commands can also control the orbit.
orbit.focus(Geodetic.degrees(3.3792, 6.5244));
orbit.rotateBy(10, 5);
orbit.zoom(1.1);
```

`GeospatialPlugin` registers a `GeospatialReference` under `geospatialReference`.
That service holds the ellipsoid and creates coordinates, local frames and globe
geometry from the same world model. You can supply another ellipsoid for another
planet. Pure coordinate functions remain usable without starting a renderer.

`GlobeOrbitPlugin` depends on the geospatial plugin. It owns a Z-up, centre-facing
camera while attached and restores the previous position, target and up vector
when detached. The plugin registers pinch and scroll interests through the Flutter input
adapter. You can also call its control methods from keyboard commands or a
different host. Focusing is safe
before initialization finishes. Latitude stops at 85 degrees to keep this initial
orbit controller away from a singular pole view. Set camera clipping planes to
cover your world model and zoom range; the orbit plugin leaves them unchanged.
Its distance limits are 1.05 to 20 times the largest ellipsoid radius.

The planet example uses both plugins. An ordinary model viewer can use the core
with an empty plugin list.

## Captured backend submissions

Use the advanced import when you need a backend without a Flutter view:

```dart
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

final backend = await NativeBackend.create();
try {
  final scene = Scene()..add(Mesh(BoxGeometry(), DiffuseMaterial()));
  final submission = FrameSubmission.capture(
    scene: scene,
    camera: PerspectiveCamera(),
    size: PhysicalSize(256, 256),
  );
  final output = await backend.render(submission);
  switch (output) {
    case ReadbackOutput(:final image):
      print('${image.size.width} x ${image.size.height}, ${image.rowStride} bytes per row');
    case PresentedOutput():
      throw StateError('The current native backend only implements readback.');
  }
} finally {
  await backend.close();
}
```

Capture freezes the scene and camera before asynchronous work. Subsequent scene
changes affect later submissions. Binary scene packets carry geometry recipes
and changed mesh records. Geometry residency belongs to the native device;
`NativeBackend.createView()` shares it across independent readback views.
See [GPU resources](design/gpu-resources.md) for ownership and packet details.

The current output is top-down RGBA8 in sRGB space with straight alpha and an
explicit row stride. Readback transfers pixel ownership to `ImageData`; consumers
receive a read-only view. Unsupported output formats and surface presentation
produce typed `SceneException` issues. They cannot select a readback fallback
implicitly. Readback frame statistics report uploaded and resident resource
payload bytes. Frame targets, driver padding and transfer staging are outside
those counters, so they do not measure total GPU residency. GPU timing remains
unavailable.

Run the headless example with `fvm dart run example/offscreen.dart` from
`packages/zyren_native`. It requires a native Metal, Vulkan or DX12 device.

## Scene value migration

Assign immutable values when you edit a transform:

```dart
final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
scene.batch(() {
  mesh.position = const Vec3(1, 2, 3);
  mesh.rotateY(Angle.degrees(90));
  mesh.material = UnlitMaterial(color: Color3.hex(0xf2bd65));
});
```

`Scene.changes` coalesces synchronous edits. A failed batch keeps its changes and
publishes the final revision. `Vec3`, `Quat` and `Mat4` expose read-only values;
`toVectorMath()` returns a separate copy for interoperability. Camera field of
view now takes radians, so use `Angle.degrees(42)` for the old 42-degree view.
Geodetic methods return `Vec3` and still preserve double precision in metres.

`FrameScheduler` is available from `package:zyren/rendering.dart`. Call `tick`
with a monotonic time only when you can submit a frame. It returns null while
idle or hidden. A request remains pending across the FPS limit; a removable
demand registration produces continuous frames. The Flutter controller uses this clock. `onUpdate` acquires continuous demand
until you dispose its registration. Plugins use `context.invalidate()` for one
frame and `context.acquireFrameDemand()` while animating or damping.

## Managed and borrowed views

Use one import for ordinary Flutter scenes:

```dart
import 'package:flutter_zyren/flutter_zyren.dart';

final viewport = SceneView.builder(
  sceneKey: 'preview',
  options: const EngineOptions(presentation: PresentationPolicy.readbackOnly),
  onCreate: (view) {
    final cube = view.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    view.onUpdate((time) => cube.rotateY(time.deltaSeconds));
  },
);
```

Use a borrowed controller when other widgets need access to the scene. It can
mount on one view at a time. `ready` settles after backend and plugin setup;
`firstFrame` settles after presentation. `dispose()` rejects new work immediately,
and `whenDisposed` waits for pending work and native cleanup. Readiness fails with
`disposed` if removal wins backend creation. Cleanup failures remain observable.

The default presentation policy requires a shared texture. That adapter is not
implemented yet. Select `readbackOnly` or `allowReadback` explicitly for the current
native renderer. This affects presentation to Flutter; 3D rendering remains on
the native GPU. `ready` reports the selected path through `RendererInfo`.

## Typed input and diagnostics

`SceneView(onPointer: ...)` reports logical `ViewportPoint` values. Render scale
and device pixel ratio do not change those coordinates. Use `point.toNdc` with
the logical viewport size when you need normalized coordinates.

Plugins can listen to `context.input?.events` and register `SceneGesture.tap`,
`scale` or `scroll`. Own each returned registration with `context.scope.keep(...)`. Interests
participate in Flutter's gesture arena; an overlay button receives its own tap,
and a scroll view keeps wheel input unless a scene control registers for it.
The geospatial orbit plugin uses this path by default.

`RenderFeature` requirements are typed. Unsupported plugins report a
`SceneException` with a stable code, plugin ID, missing features and device limits.
Adapter and driver names remain null when the backend cannot report them.
`SceneStatus` changes for lifecycle events; `frameStats` samples diagnostics at
most five times per second. A static view stops its Flutter ticker too.
`RecoveryPolicy.automaticOnce` retries one typed device loss, then exposes any
further failure for manual recovery.

## Scoped work and cancellation

Plugin contexts own an `AttachmentScope`. Keep registrations in that scope so
cancellation stops input and frame callbacks before plugin resources detach:

```dart
final input = context.input;
if (input != null) {
  context.scope.keep(input.registerGesture(SceneGesture.tap));
  context.scope.listen(input.events, (event) {
    if (event.phase == ScenePointerPhase.tap) context.invalidate();
  });
}
```

`scope.close()` is synchronous and idempotent. It disposes registrations in
reverse order, attempts every cleanup and reports synchronous failures with
`ScopeCleanupException`. Await `scope.whenClosed` to include asynchronous stream
cancellation and its errors. Engine teardown awaits this before plugin detach. Late registrations are disposed immediately and rejected. An engine
accepts an optional `lifetime: AttachmentScope()`. Closing it cancels pending
attachment or stops a running engine and starts disposal. Await `engine.dispose()`
for completion and cleanup errors. The Flutter controller supplies this lifetime
automatically. Plugin `attach` methods must
finish their own asynchronous work, including after cancellation, for teardown
to finish. Use the scope for any registrations created after an await.

`controller.onUpdate` registrations belong to the controller. Dispose one to stop
that animation early, or let controller disposal release it. Borrowed unmounting
suspends rendering without disposing the controller's work.

`controller.assets` is an `AssetScope`. Its `keep(LoadTask<T>)` method tracks a
loader's result, retains the resulting CPU asset and cancels pending work when
the scope closes. `release(asset)` drops the scope's retained reference.
`LoadTask<T>` exposes `result`, `progress` and idempotent `cancel()`. Cancellation
wins until the result is published and fails it with `LoadCancelled`. Format
loaders, source resolution and `assets.load(...)` are still plan 03 work.

Run the managed, borrowed and shared-scene examples in `examples/multiple_views`.
Their widget tests import the example libraries, so their public API usage is
checked by both the analyzer and the test runner.

The current `PerspectiveCamera` uses world-space `position`, `target` and `up`.
Its inherited quaternion and parent transforms do not affect the view matrix in
this milestone. Use those three camera properties for navigation until camera
hierarchy support lands with plan 03.
