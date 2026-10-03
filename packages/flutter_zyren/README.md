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
      onClick: (event) => event.stopPropagation(),
    ),
  ],
)
```

Give the canvas bounded dimensions, such as `Expanded` or `SizedBox`. Use
`SceneRuntime.nativeAndroid()` on Android. You get the existing native renderer
and presentation path. No extra consumer package is required. Core `zyren` stays
Flutter-free; `flutter_zyren` exports the model types used below from `zyren_gltf`.

## Compose your scene

You can put scene nodes inside your own `StatelessWidget` or `StatefulWidget`.
Flutter keys preserve node identity when you reorder a list. `SceneCanvas.children`
are offstage. Put visible Flutter controls, asset progress and retry UI in
`SceneCanvas.overlay`, or alongside the canvas in your normal layout. Scene nodes
built inside the overlay still attach to the scene root.

Geometry descriptions cover boxes, spheres and planes. Equal descriptions reuse
geometry across rebuilds. Use `SceneGeometry.value(geometry)` and
`SceneMaterial.value(material)` for borrowed engine objects. Keep those values
outside `build` when you want to reuse them. Unlit and standard PBR descriptions
accept `colorMap`, side, opacity, alpha mode/cutoff, depth test/write and vertex
colors. Standard materials also accept normal, metallic/roughness, occlusion and
emissive maps, their strengths, roughness and metallic values. PBR needs lighting.

```dart
SceneCanvas(
  colorPipeline: ColorPipeline(exposure: 1.2),
  children: [
    const DirectionalLightNode(intensity: 2),
    const PointLightNode(position: Vec3(2, 3, 4), intensity: 20, range: 12),
    const SpotLightNode(
      position: Vec3(0, 4, 2), direction: Vec3(0, -1, 0),
      innerConeAngle: .2, outerConeAngle: .6, intensity: 15,
    ),
    const HemisphereLightNode(
      skyColor: Color3(.7, .8, 1), groundColor: Color3(.2, .15, .1),
    ),
    const RectAreaLightNode(width: 2, height: 1, intensity: 3),
    InstancedMeshNode(
      geometry: const SceneGeometry.box(), capacity: 2, count: 2,
      transforms: [
        Mat4.identity(),
        Mat4.compose(const Vec3(2, 0, 0), Quat.identity, const Vec3(1, 1, 1)),
      ],
      colors: const [Color3(1, .3, .2), Color3(.2, .6, 1)],
    ),
    const PostProcessingNode(antialias: true),
  ],
)
```

Point and spot lights accept their matching shadow options. Directional lights
accept directional shadows; rectangular area lights accept `AreaShadow`. Use
quaternions to orient an area light and `up` to orient hemisphere lighting. Light
properties update the mounted object. Instance
`count` must fit `capacity`; transforms and optional colors apply to active
instances. Changing capacity replaces storage. Missing transforms become identity
and removed tints reset. `InstancedMeshNode` also supports shadow flags and render
order. Device capability limits still apply.

`SceneCamera.perspective` and `SceneCamera.orthographic` configure the viewport.
An equal camera description preserves camera edits from orbit controls. Changing
the description replaces the camera. You can borrow one with `SceneCamera.value`.

## Load assets and play models

Use a stable request value. Equivalent source, loader options and version reuse
completed decoded recipes. In-flight work remains local to its widget scope, so
removing one consumer won't cancel a sibling. Replacement and unmount cancel stale
loads; late results cannot mount into the new request.

```dart
SceneCanvas(
  overlay: SceneAsset<TextureImage>(
    request: AssetRequest(
      uri: Uri.parse('asset:///assets/images/corners.png'),
      loader: const TextureImageLoader(generateMipmaps: true),
    ),
    loadingBuilder: (_, progress) => const LinearProgressIndicator(),
    errorBuilder: (_, error, stack, retry) => ZeroState(
      title: 'Texture could not load', message: '$error',
      actionLabel: 'Retry', onAction: retry,
    ),
    builder: (_, image) => MeshNode(
      geometry: const SceneGeometry.box(),
      material: SceneMaterial.standard(colorMap: TextureMap(image: image)),
    ),
  ),
  children: const [HemisphereLightNode()],
)
```

This example also uses `package:flutter/material.dart`. `ZeroState` is available
from the Flutter entrypoint or `package:flutter_zyren/widgets.dart`. Declare bundle
paths under `flutter.assets` in your app's pubspec. `LoadProgress` exposes its stage,
completed bytes and optional total bytes. Keep an unknown total indeterminate.
The error callback's retry starts a fresh request with the current services.

```dart
ModelNode(
  request: Gltf.asset('assets/models/floating_triangle.gltf'),
  name: 'model',
  builder: (_, instance) => ModelAnimationNode(
    instance: instance, clipName: 'Float',
    speed: 1, loop: AnimationLoop.repeat, paused: false,
  ),
)
```

Each `ModelNode` creates its own mutable `ModelInstance`, even when recipes are
cached. You can set `sceneIndex`, transforms, visibility, refs, event callbacks and
child nodes. `nativeDeformation` defaults to true for imported skin/morph animation.
The instance retains immutable storage after its template is released; it has no
separate disposal method.

Choose one of `clipName` or `clipIndex`. `ModelAnimationNode` also accepts `playing`,
`paused`, `speed`, `repetitions`, `loop`, `onAction` and a child widget. It owns one
mixer action and drives it through the scene plugin loop. Don't also update that
mixer in `onFrame`, attach it as another plugin or start competing actions. If a
later imperative action causes a render failure, stop that foreign action and
call `controller.retry()`. The declarative action resumes. Removing the animation
node stops only its owned action and releases its frame demand.

The canvas owns a bounded cache by default: 64 completed recipes and 128 MiB of
reported decoded storage. You can supply `assetCache` on the canvas or `cache` on
an asset widget. You own supplied caches and must dispose them after their scopes
close. Clearing or evicting a recipe doesn't invalidate delivered assets. The
cache limits retained CPU recipes, not GPU residency or total live asset memory;
asset load limits and renderer resource budgets remain separate. Texture maps
borrow image identities, and the renderer owns its session's GPU caches.

## Pointer events and selection

`MeshNode`, `GroupNode`, `ObjectNode`, `ModelNode` and instanced meshes accept
`onPointerEnter`, `onPointerLeave`, `onPointerDown`, `onPointerMove`, `onPointerUp`,
`onPointerCancel` and `onClick`. `onTap` remains available with its `PickResult`.
Events visit hits from near to far and bubble through registered ancestors. Each
object or ancestor receives at most one callback per dispatch. Call
`stopPropagation()` to prevent later targets from receiving the event.

```dart
MeshNode(
  geometry: const SceneGeometry.box(),
  onPointerDown: (event) => event.capturePointer(),
  onPointerMove: (event) {
    if (event.captureIntersection != null) {
      // The original capture hit is available even outside the object.
    }
  },
  onPointerUp: (event) => event.releasePointer(),
  onClick: (event) {
    event.stopPropagation();
    controller.selection = event.currentTarget;
  },
)
```

You get the current `intersection`, all sorted `intersections`, the world ray and
`currentTarget`. Instance hits include `instanceIndex`. Capture routes subsequent
moves outside the object and clears on up, cancel, unmount or viewport teardown.
`SceneCanvas.onPointerMissed` reports clicks with no registered target, even when
unhandled geometry was intersected. Blocking UI overlays suppress scene events.
Interactive object gestures take priority over orbit navigation; background drags
remain available to the controls.

Picking uses CPU triangles and current supported deformation/instance transforms.
It doesn't reproduce texture alpha, custom shader displacement or line/point pixel
footprints. Pointer input has no device identity: hover uses one cursor per mouse
or stylus kind across changing pointer IDs. Touch capture stays pointer-specific.

## Select state without rebuilding every frame

```dart
SceneSelector<String>(
  select: (state) => state.selection?.name ?? 'No selection',
  builder: (_, name, child) => Text(name),
)
```

Use a selector in scene children, the overlay or with an explicit `controller`.
It rebuilds when the selected value changes using `==`, or your `equals` callback.
You can pass a stable `child` through the builder. Snapshots expose selection,
status, renderer info, frame stats, viewport, plugin IDs/issue and camera values.
Plugin ID lists retain identity while their contents remain equal.

Select `cameraPosition`, `cameraTarget`, `cameraUp` or `cameraRevision` for camera
motion. Selecting `camera` subscribes to camera identity, not its mutable fields.
Likewise, selection is an object identity handle. The controller clears selection
when its object leaves the scene and rejects selection from another scene.

Use `setState` for structure and widget properties. Use `SceneFrame` or a node's
`onFrame` for per-frame animation without Flutter rebuilds. Removing the callback
releases continuous frame demand. Static scenes render on demand.

Keep a `SceneRef<Mesh>` in your State when you need the mounted object.
`ref.current` is nullable; `ref.require` throws after unmount. One ref belongs to
one node. Material edits retain the mesh; changes to geometry or immutable names
replace it and reparent declarative children, preserving animated transforms.
Transform properties apply when their values change. Null leaves the current
value untouched; use explicit identity values to reset it. `ObjectNode` borrows a
detached subtree and detaches it on removal without disposing caller resources.

## Update plugins and controls live

You can update `SceneCanvas.plugins`, toggle `orbitControls` and change
`configureOrbitControls` without replacing the session. `OrbitControlsNode` offers
an `enabled` flag and a `configure` callback inside the scene tree. Choose one
orbit-control owner per canvas. Keep runtime and engine options stable; give the
canvas a new key when you need a new session. `onCreated` runs once per session.

```dart
ScenePluginNode.create(
  create: () => MyScenePlugin(),
  enabled: enabled,
  onError: (issue, retry) {
    // Surface the issue and wire retry to your recovery action.
  },
)
```

You supply `MyScenePlugin` and the enabled state. The factory runs once, including
when initially disabled. A new closure alone doesn't replace the plugin; change
`factoryKey` for that. `ScenePluginNode(plugin: plugin)` borrows a stable instance.
The engine owns attachment scopes, not an arbitrary plugin instance's external
resources. Removing a node detaches its registration.

Dependencies and duplicate IDs are validated together after the widget tree has
updated. Failed live attachment preserves the unaffected attached subset. Inspect
`controller.pluginIssue` and `pluginIds` for actual state, then use the error
callback's retry or `controller.retryPlugins()`. A failed desired graph is not
reported as attached. Initial startup/render failures use the normal SceneView
error builder and `controller.retry()`.

`EnvironmentLightingNode(image: hdrImage)` attaches HDR environment lighting.
You can change intensity and rotation live, or replace image/quality. Replacement
uses a new attachment; failed preparation can leave no panorama and exposes the
plugin issue. Direct `EnvironmentLighting.setImage` has a different contract: it
retains its accepted panorama if preparation fails. Both environment and
`PostProcessingNode` accept `enabled`, `onError` and `onPlugin` for inspection.
Post-processing accepts bloom, antialiasing, a byte budget and dependency ordering
through `after`. Set `SceneCanvas.colorPipeline` for HDR lighting and tone mapping.

## Run the example

From `examples/multiple_views`:

```sh
flutter run -d macos -t lib/declarative_demo.dart
flutter test test/declarative_demo_test.dart
flutter test integration_test/declarative_scene_test.dart -d macos
```

The demo bundles its texture and animated glTF, so you don't need a network or
credentials. You can select, hover and capture the cube, clear selection on the
background, pause animation, resize/remove the cube and toggle orbit/FXAA live.
The selector label, instanced spheres and additional lights share one viewport.
Asset failures use the shared retry state. Controls wrap on narrow windows.

The declarative API is not a claim of full React Three Fiber or Drei parity.
Reference tests establish API behavior; native platform qualification is separate.
The integration test checks native presentation with zero readbacks. A macOS run
does not qualify Android, iOS, Linux, Windows, Vulkan or DX12 behavior.

See [the macOS integration record](qualification/2026-10-03-declarative.md) for
the tested scene, reference checks and qualification limits.
