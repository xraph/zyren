# Zyren physics

You can add native rigid-body simulation without changing the base renderer.
This package builds a separate Rapier 0.36.0 native asset. Apps that do not depend
on `zyren_physics` do not build or load it.

```dart
final world = PhysicsWorld();
final ground = world.createBody(kind: BodyKind.fixed);
ground.addCollider(const BoxShape(Vec3(10, .1, 10)));
final ball = world.createBody(
  pose: PhysicsPose(position: const Vec3(0, 5, 0)),
  ccd: true,
);
ball.addCollider(const SphereShape(.5));
final plugin = PhysicsPlugin(world: world);
plugin.bind(ballMesh, ball);
controller.use(plugin);
```

Import `package:zyren/zyren.dart` and `package:zyren_physics/zyren_physics.dart`.
In Flutter, hide Flutter's `BoxShape` from your material import or prefix the
physics import. You own the world. Detach the scene controller, await its disposal,
clear plugin bindings and close the world. `close()` is idempotent. Native finalizers
also release abandoned worlds, but you should use explicit disposal for predictable
resource release.

## Bodies and units

Use metres, kilograms, seconds and radians. Gravity defaults to `(0, -9.81, 0)`.
Positions and rotations cross the FFI boundary as Rapier single-precision values.
Use a local origin for large scenes.

You can create fixed, dynamic, position-controlled kinematic and velocity-controlled
kinematic bodies. Position kinematics use `setTarget`; velocity kinematics use
`setVelocity` and `setAngularVelocity`. Forces, impulses, torque and explicit mass
properties require dynamic bodies. Forces persist until you call `clearForces`.
`teleport` wakes the body and clears velocity and forces by default. Pass
`resetVelocity: false` when you want to preserve motion.

Mass and inertia properties are **additional** to collider density contributions.
Set collider density to zero when you supply the body's complete mass and principal
inertia. Principal inertia and the centre of mass use body-local coordinates.
You can configure linear/angular damping, sleep, wake, CCD and initial velocities.
Removing a body also removes its attached colliders and joints. Removed handles fail
explicitly on later use.

## Colliders and queries

Box extents are half sizes. Capsules run along local Y; `halfHeight` is half the
straight section, excluding the rounded caps. Convex hulls require non-coplanar
points. Triangle meshes require fixed or kinematic bodies, including meshes inside
compound shapes. Compound children and colliders have independent local poses.

You can configure friction, restitution, density, sensor state and 32-bit membership
and filter masks. Both colliders' masks must accept the other membership. Sensors
report intersections without applying contact impulses. CCD is enabled per body.

`rayCast` normalizes its direction and reports distance in metres. `shapeCast` uses
velocity in metres per second and reports seconds to impact. `overlap` reports
collider IDs. Queries refresh collision detection, so you can query newly inserted
or teleported colliders before stepping. Filters can exclude a body or sensors and
apply collision groups. Shape-cast normals use world coordinates.

## Stepping and transform ownership

The default fixed step is 1/60 second. `PhysicsWorld.step()` advances exactly once;
`PhysicsPlugin` accumulates frame time, bounds catch-up to eight steps, caps input
frame delta to .25 seconds, and reports discarded time in `droppedSeconds`.
Pause discards the fractional accumulator. Resuming begins with a fresh accumulator.
Interpolated rendering stays one fixed step behind the current simulation state.
Queries and body states always use current simulation poses.

A bound object belongs to physics. External pose writes, reparenting and scale
changes fail explicitly. Unbind before timeline or tools take over its transform.
Parents may have fixed rigid transforms, and the plugin converts world poses into
parent-local coordinates. Parent scaling and moving parents are unsupported.
Build shapes at their intended size; do not scale a bound object. Nested moving
physics parents are therefore unsupported. You can bind again after reparenting.

## Constraints and events

You can create hinge, slider, fixed, spherical, spring and distance constraints.
Distance constraints use Rapier's rope joint, which bounds maximum distance and
allows slack. Springs have a positive rest length, stiffness and damping. Hinge and
slider limits use their free axis. Spherical limits and motors select an angular
axis. Fixed frames and all anchors use body-local coordinates. Joint contacts are
disabled by default. `setMotor` changes a motor at runtime and rejects locked axes.

`step()` returns collision transitions and contact force events. Sensor transitions
carry `sensor: true`. The plugin delivers an immutable event batch after all steps
and pose synchronization, outside Rapier's mutable simulation iteration. You can
change bodies in the callback. Event collection and debug geometry are bounded.

## Snapshots and recovery

`snapshot()` captures native bodies, colliders, constraints, sleep state and solver
state. `restore()` checks the format, pinned Rapier version and fixed timestep before
replacing the world. Restore invalidates every existing handle. Use `body(id)` to
reacquire a body, clear plugin bindings and bind the restored bodies again.
Only restore snapshots you trust. The serialized solver state is a native engine
format, not an input format for arbitrary untrusted files.

Enhanced determinism is enabled in Rapier. Replays require the same engine build,
platform, timestep, insertion order and sequence of inputs. Cross-platform bitwise
reproducibility is not promised. Renderer recreation does not reset the physics
world; plugin detach removes debug geometry and frame demand, and reattach continues
with the same world. You can use a saved snapshot to restart an experiment.

## Native targets and verification

The Rust build hook declares macOS, iOS, Android, Linux and Windows targets. This
uses native Dart assets and Rust target toolchains, independently of Metal/Vulkan/
Direct3D rendering. There is no browser renderer or web physics fallback.

Run the package tests from its directory so Dart includes this package's native hook:

```sh
cd packages/zyren_physics
dart test --concurrency=1
cargo test --manifest-path native/Cargo.toml --locked
cargo clippy --manifest-path native/Cargo.toml --all-targets --locked -- -D warnings
```

If your shell uses standalone Dart inside this Flutter workspace, set `FLUTTER_ROOT`
to the matching Flutter installation. The dedicated app lives in
`examples/physics_lab`; run it with `flutter run -d macos` from that directory.
The completion matrix records actual platform evidence separately from build support.

Rapier, Parry and their dependencies retain their upstream licences. See
`THIRD_PARTY_NOTICES.md` and the exact dependency closure in `native/Cargo.lock`.
