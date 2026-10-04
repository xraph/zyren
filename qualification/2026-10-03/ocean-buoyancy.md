# W8 hydrostatic force evidence

The CPU buoyancy solver passes 15 tests with the pinned Dart SDK. No renderer or
physics world is required for these fixtures.

| Fixture | Result |
| --- | --- |
| Sphere dry, half, full and clamped caps | Analytic volume and centroid references pass |
| Overlapping spheres | Rejected without explicit matching volume weights |
| Tetrahedron oblique clips | Similar-tetrahedron volume, centroid and complement moments pass |
| Box at seven water levels, three subdivisions | Volume and centroid agree within 1e-12 |
| Sloped box cuts | Three oblique planes bisect volume within 1e-12 |
| Hull validation | Open, duplicate-face, reversed-face, unused/duplicate-vertex and nonconvex inputs rejected |
| Hydrostatic loads | Half-box balance, overload sinking, dry body, zero gravity and righting torque pass |
| Batch admission | Query identity/order, new body, frame rebase, failed sample, time/age/source mismatch and invalid errors rejected |
| Canonical sampler integration | Actual CPU all-water samples feed the solver; flat-earth-local displacement is within 1e-5 m³ of four |
| Sample error interval | 1 cm plane error gives [3.96, 4.04] m³ for the half box |
| Coupled drag | Energy decreases and point projections do not reverse at 30, 60 and 120 Hz; currents accelerate a resting body |
| Curved height refinement | Eight rounds reduce volume error below 0.02 m³ and below one third of the unrefined error |
| Invalid inputs | Mass, inertia, drag, density and step admission pass |

Command from `packages/zyren_geospatial_ocean`:

```sh
/Users/rexraphael/fvm/versions/3.47.5/bin/dart test test/buoyancy --reporter expanded
```

The curvature fixture integrates `height = 0.2 x²` over a two-metre box. Its exact
wet volume is `4 + 0.8/3` m³. Samples use horizontal local planes to isolate the
quadrature error. Subdivision changes this approximation; it does not change the
physical sea state.

The solver does not estimate unknown surface curvature. Plane-error intervals
exclude that discretization error and do not claim formal clipping roundoff bounds.
Weighted overlapping spheres remain an explicitly authored approximation.

Native body mass properties, compound-collider cargo changes, shared stepping,
sleep/re-entry, frame transfer and render-cadence independence belong to W9 and
are not established by this record. W12 retains visual and device qualification.
