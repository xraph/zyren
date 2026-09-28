# Frustum culling

Built-in triangle meshes now skip their color draw when their bounds are outside
the camera's clip volume. It works with both camera types, parent transforms,
reflections, skinning and morph targets. Each view captures its own visibility.

You can opt a mesh out:

```dart
mesh.frustumCulled = false;
```

The default is `true`. Changing it advances the scene revision and requests a
frame through the existing scene subscriptions. It does not change `visible`,
layer membership or CPU picking.

## Bounds you control

The renderer derives bounds from built-in triangle geometry and its captured
pose. An `InstancedMesh` uses one aggregate bound for its active instances. If
that bound intersects the view, the whole batch draws; this path does not compact
individual instances or change their IDs.

Custom vertex shaders and expanded line/point footprints have unknown bounds.
They remain visible by default. You can supply a conservative bound when you
know the full range of your shader or primitive:

```dart
mesh.cullingBounds = Bounds3(
  const Vec3(-2, -1, -.5),
  const Vec3(2, 1, .5),
);
mesh.cullingBounds = null; // Restore automatic bounds.
```

Use mesh-local coordinates after all deformation and instance transforms, before
the mesh's world transform. Include every position the shader can produce.
Update the override when that range changes. A bound that is too small can hide
visible geometry. `Bounds3.empty()` intentionally suppresses the color draw.

## Native rendering and shadows

Scene packet opcode 27 carries color visibility independently of shadow flags.
The native color queue skips culled records, while offscreen casters continue to
contribute shadows. Older packet versions default color visibility to enabled.
The reader rejects flags other than zero or one and truncated payloads.

Culling reduces draw submission. It retains geometry, texture, pose and instance
ownership, including validation and preparation, so it does not currently defer
initial uploads or edits to offscreen meshes. Returning to a previously uploaded
mesh reuses its resources. Use `visible = false` when you intend to suppress both
color and shadow participation through scene visibility.

Bounds are transformed relative to the camera before testing. The frustum uses
native zero-to-one depth, with a conservative tolerance for float32 GPU rounding
at its planes. This can keep a mesh just outside a boundary. It does not reject
meshes hidden behind other objects.

## Standalone queries

```dart
final frustum = Frustum.fromCamera(camera, width / height);
final intersects = frustum.intersectsBounds(worldBounds);
final inside = frustum.containsPoint(worldPosition);
```

`Frustum.fromMatrix(matrix, origin: origin)` accepts a camera-relative clip
matrix. Its queries take world coordinates; leave `origin` at zero for a matrix
that already includes world translation. Unknown (`null`) bounds stay visible,
empty bounds do not intersect, and invalid planes raise `ArgumentError`.

Run the [culling lab](../../examples/shader_lab/README.md#culling-lab) to pan
across 61 meshes, switch projection and compare draw counts with culling disabled.
The fixture also checks that camera movement does not upload the shared box
geometry again.
