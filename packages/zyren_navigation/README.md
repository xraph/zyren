# zyren_navigation

Query a small authored floor mesh in metres, with Y up. You supply indexed
triangles on one horizontal plane. The mesh validates shared edges, winding,
degeneracy, overlap and T-junctions before you can query it.

```dart
final mesh = NavigationMesh(
  vertices: const [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0, 0, 2)],
  triangles: const [[0, 1, 2]],
);
final path = mesh.findPath(const Vec3(.1, 0, .1), const Vec3(1, 0, .1));
if (path.status == NavigationStatus.found) {
  final position = path.pointAt(.5); // Metres along the route.
}
```

A successful query returns a triangle corridor and waypoints through shared edge
midpoints. Each segment stays inside a corridor triangle. You get a deterministic
route, but it may be longer than a funnel path. The route describes a point
agent; it does not guarantee clearance for a capsule or avoid dynamic obstacles.

Outside endpoints, disconnected islands and exhausted search budgets have
separate statuses. A failed query has no waypoints. There is no automatic floor
projection. Triangle IDs are your input indices, and shared edges must use the
same vertex IDs. Vertex heights must match exactly; point elevation and planar
cross-product checks use a tolerance of `1e-8`.

Meshes contain at most 1024 triangles and 3072 vertices within +/- 10 km.
Construction uses quadratic validation for these small meshes. Inputs and output
lists are immutable snapshots. The generated surface API below handles slopes,
multiple floors, agent clearance and obstacle updates separately.

Run `dart test` from this package directory with the workspace Flutter SDK.
The character package includes a route-following native physics example.

Import `package:zyren_navigation/agents.dart` for the optional shared runtime
provider. Register it with an `AgentRegistry` and your attachment scope. Queries
accept three-component metre coordinates and a visited-triangle budget. Discovery
states the flat surface, point-agent and clearance limits. You supply a stable
source ID and an availability callback; replacement requires a new registration.
The immutable mesh uses revision zero for that registration lifetime.

## Generated surfaces and obstacles

Use `NavigationBaker` with world-space `NavigationGeometry` snapshots or
`NavigationGeometry.fromMesh`. Supply stable source IDs and transform revisions.
The source must contain static triangles; freeze animated or skinned geometry
before baking. Settings declare cell size, capsule radius, height, slope and step
limits, plus triangle, cell and operation budgets.

The baker clips triangle coverage into layered cells, retains holes and rejects
insufficient headroom. It erodes whole cells for a conservative footprint.
Four-neighbor links join compatible heights across seams and steps. Results expose
vertices, triangles, source revisions and cell adjacency. Routes are resolution
bound and can be longer than a funnel path. Closed doors and dynamic actors are
obstacles, not new walkable support surfaces. Movement still needs collision
resolution in the physics world.

```dart
final baked = NavigationBaker(
  settings: NavigationBakeSettings(cellSize: .2, radius: .3, height: 1.8),
).bake(sources, cancelled: () => cancellationRequested);
final world = NavigationWorld(baked);
final follower = NavigationFollower(world)..setGoal(goal);
world.setObstacles([
  NavigationObstacle('crate', min: const Vec3(2, 0, 2), max: const Vec3(3, 2, 3)),
]);
final intent = follower.intent(actualFootPosition, metresThisStep);
```

Obstacle boxes are world-space snapshots, inflated by the agent footprint.
Replace the full snapshot when sources move or disappear. Each replacement or
rebake increments the world revision. Routes belong to that world and revision;
a follower replans before moving on stale data. Failed, cancelled and exhausted
queries return no partial route, and the follower stops. Submit the returned
intent to a collision controller, then feed its actual position into the next
query. Navigation does not create physics bodies or silently move scene objects.

`pipeline.dart` bakes a completed `PipelineRuntime` load job through its public
model API. It pins bundle version, source ID, imported node/primitive IDs and the
provided transform revision. Released, incomplete and validation-only jobs fail.

`world_agents.dart` exposes passive inspection, bounded path queries, obstacle
replacement and an optional host-owned rebake command. Mutations require
`navigation.edit`, current revisions and retry keys through the shared registry.
Hosts must keep navigation obstacles and physical colliders in sync; the native
Character Lab demonstrates that update. See its qualification record for device
coverage.
