# Flutter Zyren

Build native 3D scenes with widgets from your existing import:

```dart
import 'package:flutter_zyren/flutter_zyren.dart';

SceneCanvas(
  runtime: const SceneRuntime.nativeMetal(),
  orbitControls: true,
  children: [
    MeshNode(
      geometry: const SceneGeometry.box(),
      material: const SceneMaterial.unlit(color: Color3(.95, .45, .16)),
      onFrame: (mesh, time) => mesh.rotateY(time.deltaSeconds),
      onTap: (hit) => print(hit.object.id),
    ),
  ],
)
```

Give the canvas bounded dimensions, such as `Expanded` or `SizedBox`. Use
`SceneRuntime.nativeAndroid()` on Android. The runtime uses Zyren's existing
native renderer and presentation path. You don't need another package.

## Compose your scene

You can put `MeshNode`, `GroupNode`, `DirectionalLightNode` and `ObjectNode`
inside your own `StatelessWidget` or `StatefulWidget`. Flutter keys preserve
node identity when you reorder a list. Put visible Flutter controls in
`SceneCanvas.overlay`, or alongside the canvas in your normal layout.

Geometry descriptions cover boxes, spheres and planes. Equal descriptions reuse
geometry across rebuilds. Material descriptions cover unlit and standard PBR
materials; PBR scenes need lighting. Use `SceneGeometry.value(geometry)` and
`SceneMaterial.value(material)` for the rest of the engine API, including custom
geometry, texture maps and shaders. Keep those borrowed values outside `build`
when you want to reuse them.

`SceneCamera.perspective` and `SceneCamera.orthographic` configure the viewport.
An equal camera description preserves camera edits from orbit controls. Changing
the description replaces the camera. You can borrow one with `SceneCamera.value`.

## State, animation and ownership

Use `setState` for scene structure and widget properties. For animation, use a
node's `onFrame` callback or `SceneFrame`. Both run on Zyren's frame loop without
rebuilding Flutter widgets. Removing the callback releases its continuous frame
demand. Static scenes render on demand.

Keep a `SceneRef<Mesh>` in your widget State when you need the mounted mesh.
`ref.current` is nullable; `ref.require` throws if the node is unmounted. Refs clear
on removal and update when geometry changes. A ref can belong to one node only.

A material edit updates the existing mesh. Geometry and names are immutable in
the core API, so changing either replaces the object and reparents its declarative
children. Geometry replacement preserves animated transforms. Transform properties
apply when their values change; null leaves the current value untouched. Set an
explicit identity transform if you want to reset it. Use `renderOrder` to control
draw order, independently of widget list order.

`ObjectNode(object: modelRoot)` borrows an existing subtree. It must be detached
before mounting, and you cannot mount the same object twice. Removing the widget
detaches the object without disposing externally owned resources. Geometry and
material descriptions create CPU objects; the existing renderer owns GPU caches
and releases its session resources when the canvas closes.

Tap selection uses the existing CPU triangle picker. The nearest hit goes to the
first handler on that object or its ancestors. This API does not yet provide
hover transitions, pointer capture or multi-hit event propagation.

## Use existing plugins

Register plugins once in `onCreated`, before the canvas attaches its session:

```dart
SceneCanvas(
  onCreated: (controller) => controller.use(MyScenePlugin()),
  children: const [
    MeshNode(geometry: SceneGeometry.box()),
  ],
)
```

`SceneScope.of(context)` gives a component or overlay access to its controller,
asset scope and diagnostics. Extend `SceneNode<T>` to wrap another engine object.
Your existing `SceneView` and `SceneController` code continues to work.

Keep runtime, engine options and `orbitControls` stable for a mounted canvas.
Give the canvas a new key when you want a new session. `onCreated` runs once per
session. Renderer loading, failure and retry use the existing `SceneView` builders;
async model loading still uses `controller.assets` and the relevant loader package.

## Run the example

From `examples/multiple_views`:

```sh
flutter run -d macos -t lib/declarative_demo.dart
```

You can animate, resize, select, remove and restore the cube. The controls wrap on
narrow windows. This is a declarative authoring layer for Zyren, not a claim of
complete React Three Fiber or Drei API parity.
