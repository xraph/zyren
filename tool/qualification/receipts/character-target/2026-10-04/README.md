# Character target checks

You can resolve capsule movement and submit its target through one native call.
The game primitive controller and imported character motor use that call.
Physics still advances only when you step the world.

The focused run passed 21 physics tests, 23 game controller/save tests and eight
Rust tests. Scoped Dart analysis, strict Rust clippy and independent source
review passed. These counts include existing regression tests.

The paired native worlds follow the same 600-step path with an offset capsule,
a floor, a wall and changing orientation. Their pre-step poses match exactly.
The initial runs caught rotation normalization and target rounding differences;
the final implementation preserves the explicit target path's admission rules.
Failed admission also preserves the previous target, and queued transient forces
block target mutation until integration or cancellation.

The receipt retains the failed checks and final logs. Source pins describe the
shared checkout after checks, including a concurrent slope-constant cleanup
that this commit does not own. No device speed or capacity result is claimed.
