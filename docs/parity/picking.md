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

## Flutter viewport queries

Use `await controller.pick(ViewportPoint(x, y))` with coordinates local to the
SceneView, in logical pixels. The controller captures the result before returning
its Future. Later camera, scene and view-size changes do not alter that result.
The nearest hit inside the camera clip planes wins. Boundary comparison allows
`1e-14` in normalized depth for floating-point roundoff. Points outside the viewport
return null. A detached or zero-size viewport and nonfinite input return a
SceneException with `invalidPickRequest`; a disposed controller returns `disposed`.
Picking does not wait for GPU presentation or read pixels back.

The picking lab uses the raw viewport pointer stream alongside OrbitControls.
A primary pointer release selects only if it stayed within six logical pixels
of its start. Movement, cancellation, secondary buttons and multiple pointers
cancel selection. The subscription includes synthetic cancellation on viewport
suspension and is closed on disposal. Orbit's eager drag recognizer owns the
gesture arena, so a separate Flutter tap recognizer cannot receive those clicks.

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

The host suite passes 67 tests, including 13 viewport-picking cases across DPR
1 and 2.5, render scales 0.5 and 1, both projections, clipping, resize, captured
results, misses, invalid lifecycle states, geometry at the perspective eye and
clip-plane boundaries. The five multiple-view example tests also pass.

The native selection integration passes on macOS Metal and the physical Pixel
9 Pro Vulkan surface. It selects all three meshes in both projections, checks
panel UVs and world coordinates, restores materials on misses, changes to a
390 by 700 logical viewport, and distinguishes orbit dragging from selection.
It also suspends a held pointer and verifies selection after resume.
The final macOS and Pixel runs presented 30 and 31 frames respectively, each
with eleven diagnostic samples, zero readback and zero live native resources
after teardown. These are functional checks, not timing measurements. Desktop visual inspection also
confirmed the selected sphere changes from green to yellow on the native canvas.
The final physical iPhone 16 Pro run also passes, including the interrupted
pointer regression: 27 presented Metal frames, eleven diagnostic samples, zero
readback and zero live native resources. The driver keeps Planet installed.

## Limits

This is CPU picking for immutable indexed static meshes. Instancing, deformed
geometry and layers follow their rendering contracts. The first query builds
the geometry tree synchronously; large-scene latency has not been qualified.
EnvironmentControls and GlobeControls remain separate work.

## Review and scope decisions

The final review found a camera-origin projection failure, lost pointer
cancellation on suspension, and rejection of exact clip-plane boundaries.
Each has a regression that failed before its fix. The boundary issue was
promoted to a correctness fix because the API includes both clip planes.
The tiny depth allowance can include sub-precision overlap at a boundary.

The imported core is pinned to `4b619c0`; later core changes need separate
integration checks. Picking stays scoped to the rendering contracts that exist
today. Extending those contracts requires corresponding instancing, deformation,
layer and culling work. Surface navigation through EnvironmentControls and
GlobeControls follows this slice.

Large-scene latency and Windows/DX12 remain unqualified. The first BVH build can
block the UI on complex geometry. Review covered the core integration seams,
not every imported native-resource code path; hardware evidence came from the
implementation runs. This is not an exhaustive independent native audit.

The work remains on the local `geospatial-parity` branch. The separate core
checkout and the primary checkout do not automatically receive these commits.
