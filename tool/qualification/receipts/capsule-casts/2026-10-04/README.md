# Capsule cast qualification

Status: regression checks passed on macOS arm64. All 216 floor cases pass,
alongside native geometry, Dart physics, game controls, saves and AI integration.
The five suites contain 139 tests. Strict Clippy checks also pass.

You can reproduce the defect with a capsule standing on a flat floor. After ten
idle ticks, a small diagonal movement can produce a missed collision or a false
downward snap. The character may remain marked as grounded while penetrating
the floor. Clearances and travelled distance therefore have separate assertions.

The unchanged engine fails 44 of 72 cuboid cases and 58 of 144 authored convex
and triangle-mesh cases. Each case runs 160 physics ticks. The matrix covers
three scene scales, three floor widths and eight movement directions, with the
same clearance, progress and grounding bounds for every representation.

The repair specializes translational capsule casts against cuboids, triangles
and convex polyhedra. It computes segment distances in double precision and
advances by a conservative bound, retaining the existing target distance,
maximum time and pair-orientation contracts. Generic GJK queries and the
character controller remain unchanged. A bounded failure returns an explicit
conservative hit status instead of reporting free travel.

## Evidence boundaries

- The static-GJK and generic-contact candidates failed the wider matrix and were
  rejected. Their logs remain attached.
- The shared-cache run is excluded. Cargo reused a temporary Rapier artifact
  even though the main source was unchanged. The baseline was rebuilt after
  cleaning the affected dependencies, and later temporary experiments used an
  independent target directory.
- The standalone geometry checks include 20,000 triangle separation
  certificates and 20,000 convex-box comparisons against an independent
  piecewise segment-to-box calculation. They validate the geometry routines.
- Existing bridge responses do not expose every internal failed or exhausted
  cast status. Conservative fallback hits are not claims of convergence.
- Application inference and save/restore pass for the retained guard and vehicle
  policies. Their held-out model evaluation and sustained device capacity remain
  separate checks. Neither is established by these regressions.

`receipt.json` pins the dependency commit, source, native libraries, commands and
compressed logs. Run `cargo test --locked` in `packages/zyren_physics/native` to
repeat all 33 native tests, including the independent geometry comparison. The
remaining commands reproduce the 52 physics, 28 game, 24 AI and two application
tests. The rejected experiments and excluded cache run remain attached so you can
distinguish the final evidence from earlier diagnostics.
