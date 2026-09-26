# Extend the engine

Use `flutter_gpu3d` for general 3D work. Add `flutter_geospatial` when you need
Earth coordinates or globe controls. The dependency points one way: the
geospatial package imports the core, and the core never imports geospatial.

## Choose an extension point

| Contract | You supply | Ownership |
| --- | --- | --- |
| `ScenePlugin` | Controls, scene updates, domain services or asynchronous setup | One instance per engine; attach and detach belong to the engine |
| `SceneRenderer` | A native renderer with explicit capabilities and RGBA output | A fresh instance from `rendererFactory`; disposed by the engine |
| `FramePresenter` | Conversion from RGBA output to a Flutter display | A fresh instance from `presenterFactory`; disposed by the viewport |
| `PresentedFrame` | A widget and resources for one displayed frame | Retired by the viewport after the replacement paints |
| `BufferGeometry` / `Object3D` | Custom mesh geometry and scene composition | Your scene owns these Dart objects; the native renderer caches visible geometry |

These contracts are implemented and tested. They do not yet expose native shader
registration, render passes or texture handles. Those require a resource API and
render graph in the core. Replacing the presenter alone cannot remove the current
GPU readback. Shared texture presentation also needs a backend output contract and
platform synchronization.

## Write a plugin

Extend `ScenePlugin`. Keep the ID, dependencies and required features stable for
the lifetime of the instance. You can mutate scene objects through the context.

```dart
class SpinPlugin extends ScenePlugin {
  final Object3D object;
  double angle = 0;
  SpinPlugin(this.object);

  @override
  String get id => 'example.spin';

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    angle += frame.delta.inMicroseconds / 1000000;
    object.quaternion.setAxisAngle(Vector3(0, 1, 0), angle);
  }
}

final spin = SpinPlugin(cube);
final viewport = SceneView(scene: scene, camera: camera, plugins: [spin]);
```

Create plugins and factory functions outside `build`. Rebuilding a list with the
same plugin instances is safe. Changing a plugin instance, factory, scene or
camera waits for pending work, disposes the old session, then creates a new one.
Change `restartToken` to retry the same configuration after a failure. Reuse a
plugin only after its previous engine has finished disposal. Simultaneous use in
two engines is rejected.

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

For each frame, the viewport calls its optional `onFrame` callback, then the
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
await `dispose` from an offscreen workflow. The default backend is always native
wgpu. No browser runtime or fallback is installed.

## Install geospatial

```dart
final geo = GeospatialPlugin();
final orbit = GlobeOrbitPlugin();
final scene = Scene()
  ..add(Mesh(geo.reference.globeGeometry(), MeshMaterial()));
final camera = PerspectiveCamera(near: 100000, far: 200000000);

final viewport = SceneView(
  scene: scene,
  camera: camera,
  plugins: [geo, orbit],
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
