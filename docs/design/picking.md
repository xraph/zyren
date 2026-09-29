# Cameras and selection

Call `SceneController.pick` with a point local to your `SceneView`. You get the
nearest triangle, its mesh, world point, distance, triangle index, optional
instance index, barycentric coordinates, and UV0 coordinates when available.
`triangle` contains the three captured world vertices in index order.

```dart
final tap = controller.input.registerGesture(SceneGesture.tap);

SceneView(
  controller: controller,
  onPointer: (event) async {
    if (event.phase != ScenePointerPhase.tap) return;
    final hit = await controller.pick(event.point);
    if (hit == null) return;
    print('${hit.object.name}: instance ${hit.instanceIndex}');
    print('Triangle ${hit.triangleIndex} at ${hit.point}');
  },
);

// Dispose the registration when your widget or tool stops handling taps.
tap.dispose();
```

Use logical coordinates. Device pixel ratio and `resolutionScale` do not enter
the conversion. The renderer also uses the logical aspect ratio, so rounding a
physical texture size does not move the surface under your pointer.

The call captures camera, viewport, geometry, material side, transforms, skin
matrices, morph weights, and active instance count before it returns the future.
Subsequent edits cannot change that result. `object` identifies the live mesh;
the numeric values and `sceneRevision` describe the captured state. If your tool
needs a current result, compare the revision before applying it or issue another
pick. Camera changes have their own revision and do not alter `sceneRevision`.

A miss returns `null`. An unattached or zero-size view, invalid camera, or
singular world transform raises `SceneException` with `invalidPickRequest`.
A disposed controller raises `disposed`. Picking failures do not put the
rendering session into `SceneFailed`.

## Core queries

You can query geometry without Flutter or a GPU:

```dart
final raycaster = Raycaster(near: 0, far: 100);
final query = raycaster.capture(
  scene,
  Ray(const Vec3(0, 0, 5), const Vec3(0, 0, -1)),
);
final closest = query.intersectFirst();
final allHits = query.intersectAll();
```

`captureFromCamera` takes a camera, `ViewportPoint`, `logicalWidth`, and
`logicalHeight`. It clips against that camera's near and far planes. Hits are
ordered by world distance, including under nonuniform and mirrored transforms.
Equal distances retain scene traversal, instance, and triangle order.

`Ray` provides triangle and axis-aligned box intersections. Triangle edges count
as hits; degenerate triangles do not. Its direction is normalized at construction.
Box queries return the entry distance, or zero when the origin is inside.

## Accelerated queries

Keep your `Raycaster` between queries. It builds bounding volume hierarchies
(BVHs) for triangle geometry and scene instances, then visits the nearest bounds
first. `SceneController` keeps its own raycaster for you. Repeated picks on an
unchanged scene reuse the captured geometry, model inverses and both trees.

Position, morph and joint edits refit triangle bounds. Attribute edits that leave
positions unchanged reuse those bounds. Each deformed mesh has its own posed
tree; ordinary meshes can share a geometry tree. Scene edits refit the instance
tree when membership and traversal order stay the same. Changed membership or
geometry topology builds a new tree.

Refits preserve the old partitions, so substantial movement can reduce pruning
efficiency. Call `raycaster.clearCache()` to build fresh partitions on the next
capture. That also releases the raycaster's reusable indices. Requests you've
already captured keep their original data and remain valid after edits, removal
or a cache reset.

You can inspect the work a query performs:

```dart
final report = query.trace(); // Nearest hit; false returns all intersections.
print(report.hits);
print(report.statistics.triangleTests);
print(report.statistics.geometryRefits);
```

`trace(firstHitOnly: false)` returns all hits. Its immutable statistics combine
the build/refit work recorded during capture with the tests performed by that
invocation. Repeating `trace` repeats the traversal and reports the same captured
build counters; it does not rebuild the captured tree. `modelMatrixInversions`
counts mesh/instance inverses computed by the raycaster, excluding camera and
skin preparation. `bvhBoundsTests` counts tree-node bounds, while `meshTests`
counts candidate mesh/instance records and `triangleTests` counts exact tests.

Use `RaycastAcceleration.none` to compare with linear traversal or avoid building
trees for a one-off query. BVH build and refit work runs synchronously. A changing
surface with only one query per revision can cost more than a linear scan; see
the [benchmark](../../packages/zyren/benchmark/README.md) for measured examples.

## Projection and layers

`OrthographicCamera(verticalSize: 4)` shows four world units vertically. Its
horizontal extent follows the viewport aspect. Increase `zoom` to see a smaller
area, or change `verticalSize`. `position`, `target`, `up`, `near`, and `far`
work alongside the perspective camera's existing settings. Orthographic rays
are parallel and measure distance from their offset on the camera plane.
Both cameras use camera-relative matrices and native zero-to-one depth.

Every object and camera starts on layer zero. Assign immutable masks to change
membership; the assignment advances the object's revision.

```dart
mesh.layers = LayerMask.only(2);
camera.layers = camera.layers.including(2);
final terrainOnly = Raycaster(layers: LayerMask.only(2));
```

Layers range from 0 through 31. `LayerMask.all`, `none`, `including`, and
`excluding` let you build a mask without mutating a shared value. Camera queries
intersect the camera and raycaster masks. Direct ray queries use the raycaster's
mask alone, which defaults to all layers. Rendering filters meshes and lights
against the camera mask. A parent's layer does not filter its children, but its
`visible` flag does.

## Current limits

Queries test CPU bounds followed by triangles. They run on the calling isolate;
returning a future does not move the work to a background worker. Renderer
[frustum culling](frustum-culling.md) uses a separate color-visibility decision;
CPU queries continue to test captured triangle geometry.

Skinning and morph positions match the built-in native deformation. Queries do
not execute custom vertex shaders, sample texture alpha, or test line and point
footprints. Transparent triangle surfaces remain selectable regardless of
fragment coverage. Tools that need those policies must account for them when
using a hit. GPU resources stay on the native renderer.

The Shader Lab geometry demo lets you switch projection and tap either the
skinned ribbon or an instance. Selection pauses animation and outlines the
captured triangle. Pose edits, playback, and projection changes clear the outline.

Tests cover immutable captures, instance IDs, sidedness, deformed surfaces,
camera clipping, layer filtering, and typed failures. Flutter fixtures check DPR
1, 1.5, and 3 at full and half resolution, plus desktop and narrow layouts.
The native pixel fixture compares selection against actual skinned, morphed,
and mirrored instance colors under both projections.
