# Static mesh picking

You can query visible meshes with `Raycaster.intersectScene(scene, ray)`. The
result is sorted by world distance, then scene traversal and triangle order for
ties. Hidden ancestors suppress their subtree. Both triangle sides are pickable,
matching the current native renderer.

Each hit captures the mesh, world point, world distance, triangle index,
barycentric weights, optional UV0 and UV1, and scene revision. The normal is a
world-space face normal transformed by the inverse transpose. It retains the
geometry's orientation when hit from behind. The mesh reference stays live;
the other fields describe the query at the time it ran.

Geometry is immutable. Each Raycaster caches a triangle BVH weakly by geometry,
while reading parent transforms for each query. Shared geometry shares that
acceleration structure. World distance survives nonuniform scaling because the
inverse-transformed ray direction is left unnormalized. Planetary translation
is subtracted before applying the inverse linear transform.

## Evidence

The core suite passes 263 tests. Picking adds 12 behavior tests and 12 upstream
fixture replays covering 300 rays and 278 hits from Three r184. The fixtures use
perspective and orthographic cameras, indexed planes, boxes and spheres,
nested nonuniform and mirrored transforms, and Earth-scale translations.
Object, triangle, distance, point, face normal and UV agree within `1e-8`.

Regenerate the fixture with the development-only reference dependency directory:

```sh
node tool/picking_reference.mjs /tmp/geospatial-reference packages/gpu3d/test/fixtures/picking.json
```

The fixture includes source hashes. Regeneration was byte-for-byte identical.
Additional behavior tests cover hidden ancestors, removal, shared geometry,
degenerate triangles, edge ties, UV1, finite ranges and invalid transforms.
Analyzer and formatting pass.

## Limits

This is CPU picking for immutable indexed static meshes. Instancing, deformed
geometry and layers follow their rendering contracts. The first query builds
the geometry tree synchronously; large-scene latency has not been qualified.
EnvironmentControls and GlobeControls remain separate work.
