# Offline terrain streaming

The native terrain work starts with a deterministic regional patch. You can
use `TileSource<T>` to supply quadtree metadata and cancellable CPU loads.
`TileScheduler<T>` selects content by projected error, retains ready ancestors
until child coverage is complete, and enforces request and payload budgets.

## Source mapping

This slice reuses `TileCoordinate`, `TilingScheme` and `GeographicRectangle`
from the pinned source's core package. Coordinates increase northward in Y;
image V increases southward. `ProceduralTerrainSource` unwraps geographic bounds
explicitly when a patch crosses the antimeridian.

The source stories delegate terrain streaming to `3d-tiles-renderer` through
`storybook/src/plugins/CesiumIonTerrainPlugin.ts` and its WebGPU counterpart.
The offline source is our deterministic fixture for that native prerequisite.
It does not implement Cesium quantized mesh, Cesium Ion authentication or the
3D Tiles format.

## Selection and ownership

Perspective error in logical pixels is
`errorMetres * viewportHeight * zoom / (2 * tan(fov / 2) * distance)`.
Distance is measured to the nearest point of the conservative bounding sphere
and clamped to 0.001 metres. Orthographic error is
`errorMetres * viewportHeight * zoom / (top - bottom)`.
Sphere/frustum tests reject invisible branches. Refinement starts above the
configured threshold and remains active until error falls below 80% of it.

Parents load before their descendants. Refinement reserves an entire selected
sibling group, including its retained ancestors, within both payload budgets.
This conservative rule may choose coarser detail than a leaf-only budget would.
It keeps fallback data available without risking a partial replacement.

The scheduler reserves decoded bytes before each request and counts cancelled
requests until their futures settle. Obsolete data cannot attach. Replacing a
source invalidates all results from the prior attachment, including sources
with the same identity. Unused decoded tiles leave the cache in least recently
used order when requests need space; selected ancestors stay pinned.

Failures retain the visible parent and identify the source and coordinate.
Retries are explicit and capped at three attempts per selection by default.
Sources receive cancellation and a byte reservation. They must honour that
reservation while decoding and return CPU data without native allocations.
Admission rejects payloads larger than declared; it cannot prevent a custom
source from allocating excessive temporary memory internally.

## Fixture evidence and limits

The initial 16 tests cover projections, hysteresis, frustum exit, cancellation,
replacement, bounded retries, LRU eviction, byte reservations, parent coverage,
height normals, winding, imagery orientation and dateline edges. Shared edges
differ by at most 0.000031405 metres after float conversion in the checked
fixture. Geometry vertices are relative to a double-precision ECEF tile origin.
Edge skirts cover the bounded fixture's mixed-detail gaps.

Native presentation evidence is recorded after the terrain plugin is qualified.
Logical resident bytes include native vertex/index payloads and texture mipmaps.
They exclude driver overhead and frames awaiting GPU retirement. This regional
fixture does not qualify planetary depth accuracy, provider data, all upstream
stories or Windows/Linux support.
