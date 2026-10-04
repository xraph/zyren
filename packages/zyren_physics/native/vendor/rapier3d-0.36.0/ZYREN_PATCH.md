# Rapier collision-only island and joint repair

The native physics bridge uses this local Rapier 0.36.0 dependency. You can verify
every upstream file with UPSTREAM_SHA256.json and the two-file patch with
PATCH_SHA256.json. The published crate archive SHA256 is
c2e2b20538584bb3ba5bfe6a66c2d9a242ee17d15e5398be0fa35279c7d73739,
matching the original Cargo.lock registry pin. Every copied file matched that
archive before modification. The local Cargo extraction marker .cargo-ok is
excluded. The installed registry is unchanged.

CollisionPipeline previously passed no island manager to rigid-body user changes,
narrow-phase user changes and pair registration. Collision-only refresh could
clear wake flags before registering an awake body, or remove and swap a contact
edge without updating the persistent island link table. The bridge regressions
exposed both invariant failures during later physics steps.

Those three callbacks now receive the existing island manager. The additive
CollisionPipeline.step_with_joints method also processes actual impulse and
multibody joint sets during body changes and contact computation. This retains
joint collision filtering, assembly bookkeeping, body-type changes and wake
propagation when a fixed joint anchor moves. PhysicsWorld.detect_collisions uses
that method with its own joint sets. The existing step signature remains as a
compatibility wrapper for callers without joints.

Collision-only timing, body geometry propagation, solver settings, crate version
and serialization definitions are unchanged. Both modified source files carry
a repair notice; collision-islands.patch records their complete changes. This
correctness repair does not establish solver parity, target-device speed or
workload capacity. Checked results belong to the focused bridge regression
report, not this upstream inventory.

The published archive contains no license or NOTICE file. LICENSE is copied from
https://raw.githubusercontent.com/dimforge/rapier/b716d375efc0201003f0cd9ef7168eee0b62c177/LICENSE,
the commit recorded in the published .cargo_vcs_info.json. That metadata records
a dirty publishing tree, so the verified crate archive defines source identity;
the commit identifies the separately retrieved license. NOTICE retains the
upstream copyright and identifies this local modification. Both additions are
outside the upstream source inventory.

Cargo.toml selects this path directly without changing transitive dependency
versions or adding a second physics engine. Old frozen executables and their
native library pins are retained independently. Native hooks watch all vendored
files so changes to a Rust module cannot reuse an obsolete build output.
