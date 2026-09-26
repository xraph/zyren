# Extend the engine

Use `gpu3d` for Dart scene and plugin code, or `flutter_gpu3d` for the Flutter
facade. Add `flutter_geospatial` when you need Earth coordinates or globe controls. The dependency points one way: the
geospatial package imports the core, and the core never imports geospatial.

## Choose an extension point

| Contract | You supply | Ownership |
| --- | --- | --- |
| `ScenePlugin` | Controls, scene updates, domain services or asynchronous setup | One instance per engine; attach and detach belong to the engine |
| `RenderBackend` | Native submission with typed capabilities and output | A fresh instance from `SceneRuntime.backendFactory`; closed by the controller |
| `FramePresenter` | Conversion from RGBA output to a Flutter display | A fresh instance from `presenterFactory`; disposed by the viewport |
| `PresentedFrame` | A widget and resources for one displayed frame | Retired by the viewport after the replacement paints |
| `BufferGeometry` / `Object3D` | Custom mesh geometry and scene composition | Your scene owns these Dart objects; the native renderer caches visible geometry |

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
frame. The engine runs `afterRender` hooks in the same order, and the presenter
converts the output for Flutter.

Only one frame can be in flight. `FrameInfo.delta` starts at zero and is capped
at 100 milliseconds to avoid large jumps after a pause. A reset elapsed clock
also produces a zero delta. Frame hooks may be asynchronous, but slow hooks delay
the frame. Treat the returned pixel buffer as read-only in observation hooks.
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

// Wire these to Flutter input handlers.
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
when detached. Drag, pinch and scroll handling stay in Flutter, so the plugin
also works with keyboard input or a different gesture adapter. Focusing is safe
before initialization finishes. Latitude stops at 85 degrees to keep this initial
orbit controller away from a singular pole view. Set camera clipping planes to
cover your world model and zoom range; the orbit plugin leaves them unchanged.
Its distance limits are 1.05 to 20 times the largest ellipsoid radius.

The planet example uses both plugins. An ordinary model viewer can use the core
with an empty plugin list.

## Captured backend submissions

Use the advanced import when you need a backend without a Flutter view:

```dart
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';

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
changes affect later submissions. Geometry upload caching still belongs to each
native renderer. The temporary encoder uses ABI v1; binary resources remain a
later milestone.

The current output is top-down RGBA8 in sRGB space with straight alpha and an
explicit row stride. Readback transfers pixel ownership to `ImageData`; consumers
receive a read-only view. Unsupported output formats and surface presentation
produce typed `SceneException` issues. They cannot select a readback fallback
implicitly. Total GPU residency and GPU timing remain null until native counters
exist; upload statistics count logical geometry bytes, not serialized JSON size.

Run the headless example with `fvm dart run example/offscreen.dart` from
`packages/gpu3d_native`. It requires a native Metal, Vulkan or DX12 device.

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

`FrameScheduler` is available from `package:gpu3d/rendering.dart`. Call `tick`
with a monotonic time only when you can submit a frame. It returns null while
idle or hidden. A request remains pending across the FPS limit; a removable
demand registration produces continuous frames. The Flutter controller uses this clock. `onUpdate` acquires continuous demand
until you dispose its registration. Plugins use `context.invalidate()` for one
frame and `context.acquireFrameDemand()` while animating or damping.

## Managed and borrowed views

Use one import for ordinary Flutter scenes:

```dart
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

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
