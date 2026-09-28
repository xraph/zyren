# Procedural geometry and curves

Create shapes with the same materials and scene API you use for imported meshes:

```dart
final path = CatmullRomCurve3([
  const Vec3(-2, 0, 0),
  const Vec3(0, 1, 1),
  const Vec3(2, 0, 0),
]);
final mesh = Mesh(
  TubeGeometry(path, radius: .1, tubularSegments: 64),
  StandardMaterial(baseColor: const Color3(.1, .4, .8), roughness: .3),
);
scene.add(mesh);
final guide = LineGeometry(points: path.spacedPoints(segments: 100));
```

The core exports `CircleGeometry`, `RingGeometry`, `CylinderGeometry`,
`ConeGeometry`, `TorusGeometry`, `CapsuleGeometry`, `LatheGeometry` and
`TubeGeometry`, alongside plane, box and sphere. Every new surface supplies
positions, unit normals, UV0 and indexed triangles. They use the existing
material, culling and picking paths; no renderer extension is required.

Circles and rings face +Z. Cylinders, cones, lathes and capsules follow Y. A
capsule's length is the straight section between hemispheres. Torus geometry
revolves around Z. Angular ranges use radians. Partial cylinders have optional
horizontal caps, with no extra wall across the angular cut; partial tori have
open ends.

A lathe consumes `Vec2(radius, height)` points ordered bottom to top. Adjacent
points must differ and radius must be nonnegative. Normals interpolate the
profile slope. Cylinders keep separate cap vertices so their normals stay sharp.
Tube frames use parallel transport and distribute residual twist around closed
paths. Closed tubes require matching endpoint positions and tangent directions;
a sampled 180-degree reversal is rejected as a cusp.

`LineCurve3`, `QuadraticBezierCurve3` and `CubicBezierCurve3` provide point and
tangent evaluation. `CatmullRomCurve3` supports centripetal, chordal and uniform
variants, with optional closure. The control list is captured. Tension applies
only to uniform Catmull-Rom.

`pointAt(t)` uses the curve parameter in [0, 1]. `sample(divisions: 200)` returns
an immutable polyline length table; `parameterAt(fraction)` maps a distance
fraction back to that parameter. `spacedPoints` uses this table to approximate
uniform distances. Increase divisions when the path bends sharply. Tubes use
this spacing by default; set `spaced: false` for uniform parameter steps.

Tessellation checks happen before large arrays are allocated: at most one million
vertices and three million indices, or 65,536 vertices with `IndexFormat.uint16`.
New constructors also accept `dynamic: true` for the standard range-update API.
Very thick tubes or self-intersecting paths can still intersect themselves;
parallel transport does not detect collisions or repair the swept surface.

The tests compare bounds, winding, cap counts, curve length, closed seams and
native front-face pixels against CPU ray queries. Interior Catmull-Rom samples
come from the supplied project's Three.js version, 0.184.0, covering all three
parameterizations with open and closed curves. The fixture generator lives in
`packages/gpu3d/test/fixtures`.

Run `flutter run -d macos -t lib/procedural.dart` from `examples/shader_lab` for
the native geometry gallery with PBR lighting, bloom and MSAA controls.

Shape triangulation with holes, beveled extrusion, subdivision, CSG, text meshes
and the remaining Three.js geometry utilities are separate work. These factories
do not establish full geometry or full core parity.
