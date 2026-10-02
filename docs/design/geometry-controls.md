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

For a rounded control mesh, you can subdivide its triangles:

```dart
final rounded = GeometryUtils.subdivide(BoxGeometry(), levels: 2);
final dense = GeometryUtils.subdivide(
  geometry,
  mode: SubdivisionMode.linear,
  limits: const SubdivisionLimits(maxTriangles: 20000),
);
```

Loop mode moves vertices and recomputes smooth area-weighted normals. It uses
the [Loop refinement rules described by PBRT](https://www.pbr-book.org/3ed-2018/Shapes/Subdivision_Surfaces),
with interior weights of 3/16 for valence three and 3/(8n) otherwise. You get
the refined mesh after the requested number of steps, without a final projection
to the infinite limit surface. Linear mode preserves your surface and interpolates
authored normals. Both modes interpolate UV0, UV1 and colors independently on
each face, so UV seams stay separate even when positions are shared.

Exact position welding is enabled by default. It closes duplicated face seams
such as those on `BoxGeometry`; set `weldPositions: false` if coincident vertices
belong to separate surfaces. Inputs must have consistent triangle winding and
manifold vertex fans. Boundaries are allowed. Duplicate or degenerate triangles,
disconnected fans and float32 precision collapse fail, but intersections between
otherwise valid faces are not tested. Skin and morph bindings are rejected.
Tangents are removed and need regeneration.

Each level makes four times as many triangles. You can request zero to six
levels, with at most 100000 input vertices. The default output limit is 100000
triangles and 64 MiB of vertex/index payload; `SubdivisionLimits` lets you lower
the byte budget or set a triangle cap up to 250000. These are checked before
refinement. Dart topology storage uses additional heap memory. Output corners
are expanded to preserve face attributes, and must fit the chosen index format.
For worker-isolate preparation, call `subdivideGeometry(geometryData, ...)`
and construct `BufferGeometry.fromData` on the receiving isolate.

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
beveled shapes through the regular scene geometry path. Subdivision tests cover
hand-calculated boundary/interior weights, closed seams, attributes, malformed
topology and native silhouette coverage. [Text geometry](text-geometry.md) builds
flat or extruded outline glyphs through the same shape path. CSG remains separate
work.
