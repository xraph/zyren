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
lists are immutable snapshots. Navmesh generation, slopes, multiple floors,
agent clearance and obstacle updates remain in the workstream plan.

Run `dart test` from this package directory with the workspace Flutter SDK.
The character package includes a route-following native physics example.

Import `package:zyren_navigation/agents.dart` for the optional shared runtime
provider. Register it with an `AgentRegistry` and your attachment scope. Queries
accept three-component metre coordinates and a visited-triangle budget. Discovery
states the flat surface, point-agent and clearance limits. You supply a stable
source ID and an availability callback; replacement requires a new registration.
The immutable mesh uses revision zero for that registration lifetime.
