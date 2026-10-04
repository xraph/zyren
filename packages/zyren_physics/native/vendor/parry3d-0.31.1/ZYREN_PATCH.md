# Parry capsule casts

You can verify the published Parry 0.31.1 source with UPSTREAM_SHA256.json.
Every copied file matched the cached crate archive before modification. The
registry extraction marker .cargo-ok is excluded. The installed registry is
unchanged. PATCH_SHA256.json pins the two changed upstream files, two new
modules and complete capsule-casts.patch.

The native character controller uses translational shape casts to stop movement
and snap to nearby ground. The generic support-map cast can mistake a stagnant
simplex residual for a separating plane when a capsule starts within the target
distance of a broad flat surface. Direct regressions preserve both observed
failures: a missed movement hit and a false snap distance with a nearly horizontal
normal. Initial-bound static GJK and generic contact admission experiments failed
the broader floor matrix and were rejected.

The dispatcher now routes capsule pairs with cuboids, triangles and convex
polyhedra through double-precision segment distance and conservative advancement.
The capsule radius and requested target distance define the contact boundary.
Segment-to-box distance uses piecewise quadratic intervals. Triangle distance
checks face, edge and vertex features; convex distance uses every face and solid
half-space membership. Polyhedron face normals use the largest nonzero fan area
to retain collinear boundary vertices. Both pair orientations share the same
caster. Other shape pairs, generic GJK and the character controller are unchanged.

Advancement is bounded to 64 iterations. An exhausted or stalled computation
returns a conservative hit with OutOfIterations or Failed status. It never turns
uncertainty into free travel. Initial segment penetration uses the existing live
contact manifold, checks finite witnesses and a unit normal, and selects the
deepest contact. Missing geometry returns Failed at time zero. Existing native
bridge responses do not expose every internal status, so these fallback paths
must not be described as successfully converged casts. Current checked floor and
direct-cast fixtures produced no such status.

The focused native tests execute the exact distance source through a test-only
module. They cover the original casts, target and time limits, separating and
tangent velocities, rotated and swapped pairs, degenerate capsule segments and
collinear convex faces. The separate floor matrix exercises cuboid, convex and
triangle-mesh ground at three scales, three widths and eight directions. These
checks do not establish all-shape, solver, trained-model or device qualification.
Retained accepted models need a separate evaluation against the repaired engine.

The published archive contains no license or NOTICE file. LICENSE comes from
https://raw.githubusercontent.com/dimforge/parry/3383f51cbbe9af70565427e7a66c605e1557c1fc/LICENSE,
the commit recorded in .cargo_vcs_info.json. That metadata records a dirty
publishing tree, so the verified archive defines source identity. NOTICE retains
upstream attribution and identifies the local changes. Cargo uses this path for
the existing Parry dependency; it does not add another collision engine. Native
hooks watch the complete vendor directory.
