# Shapes, topology and free camera controls

You can prepare these shapes and geometry operations in Dart without a renderer.
Create a shape once, then use it for a flat surface or an extrusion:

```dart
final shape = Shape2D(
  const [Vec2(-2, -2), Vec2(2, -2), Vec2(2, 2), Vec2(-2, 2)],
  holes: const [
    [Vec2(-.5, -.5), Vec2(.5, -.5), Vec2(.5, .5), Vec2(-.5, .5)],
  ],
);
final geometry = ExtrudeGeometry(
  shape,
  depth: 2,
  bevelSize: .1,
  bevelThickness: .15,
  bevelSegments: 3,
);
scene.add(Mesh(geometry, StandardMaterial()));
```

`Shape2D` copies your rings, accepts either winding and normalizes the outer
contour to counterclockwise and holes to clockwise. A repeated closing point is
optional. Concave contours work. Self-intersections, touching rings, nested holes
and collapsed edges fail before triangulation. The validation budget is 4096
ring vertices; predicates run in normalized local coordinates with a 1e-12
tolerance. Keep geometry coordinates local and place distant objects with their
scene transform.

`ShapeGeometry` faces +Z. `ExtrudeGeometry` extends toward +Z with optional caps,
wall subdivisions and faceted quarter-ellipse bevels. Bevel insets must preserve
the shape's topology; an inset that collapses a gap or reverses an edge fails.
Bevel thickness must stay below half the extrusion depth. Caps use local XY UVs;
walls use perimeter distance and depth. Cap, wall-edge and bevel-segment normals
are separate. Geometry and index limits are checked before tessellation.

`GeometryUtils.toNonIndexed` duplicates each triangle corner while preserving
packed colors, UVs, skin attributes and morph deltas. `merge` combines matching
layouts in their existing local coordinates, with index offsets applied for you.
It rejects skin, morph and line-strip bindings because their remapping needs
additional context. Both operations limit their output payload to 64 MiB.
`computeVertexNormals` computes area-weighted normals and removes stale tangents;
regenerate tangents before using anisotropy or an authored tangent normal map.
Morph geometry requires updated deltas before normal regeneration.

Choose one controls plugin per view:

```dart
final trackball = TrackballControls();
final flight = FlyControls(movementSpeed: 4, rotationSpeed: 1);
// Add one of these to SceneEngine.create(plugins: [...]).
// Once flight is attached, your keyboard or gamepad adapter can call:
flight.setMovement(forward: 1, right: .5);
flight.setRotation(yaw: .25);
// Release held axes when the input ends or focus is lost.
flight.stop();
```

Trackball allows roll and pole crossings. It shares orbit's pan, zoom, pinch,
damping and gesture ownership; only distance and zoom limits apply. The arcball
maps pointer positions onto a sphere. `rotateBy` and `rotateTrackball` also work
without pointer input. Save/reset restores the camera pose and projection.

Fly uses camera-local movement and angular velocity. Simultaneous translation
and rotation follow an integrated rigid-body path, so changing frame rate does
not change the path for a constant input. Time steps are capped at 100 ms after a
stall, and the first newly requested frame starts the clock without a jump.
Dragging looks around; scrolling moves along the forward axis. Keyboard/gamepad
bindings stay with the host through `setMovement` and `setRotation`.

Each plugin owns its frame demand and gesture registrations. Cancel, disable and
detach release those resources. Use separate instances for separate views. Camera
replacement or an external pose edit discards pending movement.

Tests cover triangulated area, closed extrusion volume and outward normals,
invalid rings, packed attributes, morph expansion, picking through holes,
control timing and gesture cancellation. Metal fixtures render both flat and
beveled shapes through the regular scene geometry path. Text, CSG and subdivision
remain separate geometry work.
