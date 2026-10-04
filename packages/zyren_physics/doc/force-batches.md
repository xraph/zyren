# Current mass properties and force batches

Read `PhysicsBody.state` for aggregate mass, local and world center of mass, and
world inverse inertia. Collider insertion, density changes, collider removal and
additional cargo mass refresh those properties before the command returns. You do
not need to advance physics to get the new values. `massPropertiesRevision` is a
conservative world-wide counter. Another body's mass change can advance it too.
A restored world has a new handle epoch.

`PhysicsInverseInertia.apply(angularImpulse)` gives the instantaneous angular
velocity change. It includes rotation locking. The tensor is already in world
axes and relative to the current center of mass.

Capture `world.revision` before preparing asynchronous forces. Supply it as
`expectedRevision` to `world.applyImpulses`. Any potentially mutating operation,
including a failed write or collision query, invalidates that revision. Read-only
state, gravity and diagnostics calls retain it. The batch checks body ownership
and validates every native command before changing velocity. Multiple commands for
one body combine their linear and angular impulses. A point impulse contributes
its moment about the authoritative center of mass exactly once.

```dart
final revision = world.revision;
world.applyImpulses([
  PhysicsImpulse(body, linear: force * seconds, at: forcePoint),
  PhysicsImpulse(body, angular: intrinsicTorque * seconds),
], expectedRevision: revision);
```

The batch is additive. It neither clears external forces nor advances the world.
Only your existing simulation owner calls `step`. Inputs obey the existing native
component bound of 1e12, and aggregate commands must produce finite velocities.

`world.rebase(oldToNew, expectedRevision: revision)` applies a proper rigid frame
change to every body, kinematic target, linear/angular velocity, user force/torque
and gravity. Local collider and joint frames remain local. Contacts refresh on the
next query or step. Prepare new world-space force batches after rebasing; earlier
batches are invalid. Rebase your other scene systems through their own frame
contracts before resuming the shared clock.

## Forces held through a native step

Use `queueForces` for forces that must act across all native integration intervals,
including buoyancy balancing gravity. A single impulse before a step can cancel
its final velocity change while leaving a position bias. A transient force acts
through the same intervals as gravity.

```dart
final contribution = world.queueForces([
  PhysicsForce(body, force: force, at: forcePoint, torque: intrinsicTorque),
], expectedRevision: world.revision);
world.step(); // Consumes the contribution exactly once.
```

Each returned `PhysicsForceBatch` owns its contribution. Dispose it before stepping
to cancel that source, or call `removeBody` to remove just one actor. Other sources
and persistent user forces remain intact. The native step adds transient loads,
integrates, then restores the persistent user loads, including when integration
reports a failure. Up to 64 sources may queue 16,384 commands each.

Until pending contributions are consumed or cancelled, pose, mass, topology and
other state changes are rejected. Additive user forces remain allowed. Snapshots
also require consumption or cancellation, so they cannot silently omit pending
work. Whole-world rigid rebasing rotates pending loads as well as persistent loads.
`completedSteps` counts successful calls to `step` on this world instance.
