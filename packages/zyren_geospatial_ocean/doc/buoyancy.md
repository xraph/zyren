# Buoyancy forces

Use `BuoyancySolver` to calculate displaced volume, forces and torque from current
physical water samples. You supply an authoritative body snapshot in a
`GeoWorldFrame`, a volume proxy and the integration step. The solver does not move
a scene object, advance a clock or import a physics engine.

```dart
final solver = BuoyancySolver(
  drag: BuoyancyDrag(linear: 20, quadratic: 50, angular: 10),
);
final shape = BuoyancyProbes([
  BuoyancyProbe(const Vec3(-2, 0, 0), .5),
  BuoyancyProbe(const Vec3(2, 0, 0), .5),
]);
final queries = solver.queries(body, shape);
final samples = await sampler.sampleBatch(queries, OceanQueryPolicy());
final loads = solver.solve(
  body,
  shape,
  samples,
  gravity: const Vec3(0, 0, -9.81),
  density: 1025,
  stepSeconds: 1 / 60,
);
```

`body` is a `BuoyancyBodyState` with current position, rotation, world center of
mass, velocities, mass and world inverse inertia. Inertia includes collider and
cargo contributions. Do not infer it from the water proxy. `BuoyancyInverseInertia`
stores a symmetric tensor in world axes; zero eigenvalues represent locked axes.

Queries are cached on the immutable body snapshot. Their object identities act as
ordered sample IDs. The canonical sampler preserves them. A different body pose,
shape, order, timestamp, world-frame revision or reconstructed query object cannot
reuse that batch. All samples must be available, at exactly the body's timestamp,
with consistent source revisions and within the solver's error limits. A bad
sample rejects the whole solve. Create a new body snapshot each tick. The owner
must still check source and body revisions before applying asynchronous results.

## Displaced volume

Spherical probes use the exact spherical-cap volume and centroid for a planar
water surface. Overlapping spheres require an explicit `BuoyancyProbePartition`.
Its weights must be in `(0, 1]`, one per sphere, and their weighted volumes must
sum to the declared hull volume. This is an authored approximation of displaced
volume. It does not calculate the geometric union of overlapping spheres.

`BuoyancyHull` accepts a closed convex mesh with outward triangle winding. It
rejects degenerate faces, unused or coincident vertices, open or nonmanifold edges,
and nonconvex geometry. A star decomposition partitions its volume into disjoint
tetrahedra. Each cell is clipped against its sampled water plane. Integration
returns both volume and centroid. Optional longest-edge subdivision improves the
local-plane approximation without adding overlapping volume. Limits are 1,024
vertices, 2,048 faces, eight subdivision rounds and 4,096 final cells. The query
policy must admit the resulting sample count and work.

Buoyancy is `-gravity * density * volume`. Water normals define clipping planes;
they do not define the direction of gravity. Point loads act at displaced-volume
centroids. `totalTorque` includes their moment around the authoritative center of
mass. When applying point impulses, add only `intrinsicTorque` separately to avoid
counting the point-force moment twice. Dry bodies have zero displaced volume and
a null center of buoyancy. Gravity remains the physics world's responsibility.

## Drag and error limits

Drag uses body linear velocity plus angular velocity at each force point, relative
to the sampled water velocity. Linear and quadratic coefficients are per displaced
cubic metre, in N s/m⁴ and N s²/m⁵. Angular damping is per displaced cubic metre in
N s/m². All default to zero. Angular damping is relative to a stationary fluid
rotation because the sample contract does not supply water vorticity.

A common limiter accounts for mass, world inverse inertia, every point-force
moment, angular damping and step duration. The drag-only impulse cannot reverse
a nonzero point velocity's projection onto its original water-relative direction.
It also bounds the frozen-flow work quadratic. Other forces, including buoyancy,
remain unchanged. Moving water can transfer energy to a body. The limiter is not
a stability guarantee for all external forces or a substitute for a suitable
physics step.

Diagnostics report sample errors, cell diameter, drag scale and the displaced-volume
interval obtained by perturbing each local plane within the supplied sample
position/normal bounds. These intervals do not include unknown surface curvature,
proxy-authoring error or a formal floating-point clipping proof. Curvature error
is explicitly null. Check refinement for your hull and sea state. The current
fixture converges toward an independently integrated curved-height reference.

The optional [native physics bridge](../../zyren_geospatial_ocean_physics/README.md)
applies these loads through the existing simulation owner. Its qualification
record covers native trajectories and sleep separately from these CPU fixtures.
