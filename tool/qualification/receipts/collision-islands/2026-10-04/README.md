# Collision refresh repair

You can reproduce the checks with the commands in [receipt.json](receipt.json).
All 120 pass on macOS arm64. Strict Clippy also passes.

The original Rapier 0.36.0 dependency panicked when collision queries crossed
sleep transitions or removed a contact edge during interleaved character steps.
The retained upstream failure log records both faults. The local repair gives
collision-only updates the existing island manager and actual joint sets, so
joint collision filtering and fixed-anchor wake propagation use the same state
as the next physics step.

Four focused regressions cover current geometry and failed target admission,
600 interleaved steps, sleep/save/restore with collider changes, and joint
filtering with anchor wake. The broader checks include native recurrent AI,
multiple actors and the trained guard/vehicle runtime checkpoint paths.

The source inventory and complete dependency patch live in
[the vendored dependency](../../../../../packages/zyren_physics/native/vendor/rapier3d-0.36.0/ZYREN_PATCH.md).
No system Cargo registry files were edited. An earlier query-cache optimization
changed contact response and was reverted; this repair retains the existing
refresh cadence.

The first repair run exposed missing collision-group fields in two test fixtures.
After correction, all four passed. A later AI command also named two nonexistent
test files; its failure log is retained beside the successful corrected run.

These results do not qualify model success rates or sustained device capacity.
The original model evaluation receipts keep their engine pins. A separate frozen
worker and unchanged held-out cases are required to qualify the repaired engine.
