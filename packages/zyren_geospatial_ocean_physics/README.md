# Zyren ocean physics

Bind water volume proxies to bodies in your existing native `PhysicsWorld`.
`OceanPhysicsBridge` borrows that world and an `OceanSampler`; it calculates
hydrostatic loads and queues them for the next integration. Your simulation owner
still advances physics exactly once. The bridge never writes scene transforms.

```dart
final bridge = OceanPhysicsBridge(
  world: world,
  sampler: sampler,
  policy: OceanQueryPolicy(),
);
final binding = bridge.bind(
  vessel,
  BuoyancyProbes([
    for (final x in [-2.0, 2.0])
      for (final y in [-1.0, 1.0])
        BuoyancyProbe(Vec3(x, y, 0), .5),
  ]),
  solver: BuoyancySolver(
    drag: BuoyancyDrag(linear: 1200, quadratic: 500, angular: 3000),
  ),
);

// Run after control/cargo/pose updates, on the existing fixed simulation tick.
final batch = await bridge.prepare(clock.instant);
bridge.apply(batch, world.fixedStep);
physics.advance(world.fixedStep); // Existing externally driven PhysicsPlugin.
```

The sampler's `now` must return the shared tick. Its frame is the world's local
coordinate frame. The tick rate must equal `world.fixedStep`. With a
`GeoSimulation`, register `OceanBuoyancySystem(bridge)` in its force phase and keep
the existing physics integration system in the integrate phase. That system can
depend on `ocean.buoyancy`. Configure `PhysicsPlugin(externallyDriven: true)` when a
shared clock owns it; render callbacks then present the current state.

## Loads, admission and ownership

The bridge uses current native mass, world center of mass and inverse inertia.
Collider density and additional cargo mass refresh before preparation. Water
proxies describe displaced volume, not rigid-body inertia. Default water density
comes from the canonical sea state. You can explicitly override it per bridge or
binding for a different fluid volume.

One bridge owns the water bindings for a world. Defaults admit 64 bodies, bounded
further by the sampler and policy's total quadrature budget. Every actor's samples
must pass. Failure pauses force application for the batch; unavailable water does
not become height zero. The last preparation error is available as `lastFailure`.

Preparation captures body/world, frame, binding, coverage, current-source and tick
state. Changes before `apply` reject the complete batch. Duplicate ticks are
rejected, and the next tick cannot prepare before the existing owner integrates.
The bridge uses scoped transient forces, which act across Rapier's internal
integration intervals and are consumed once. Point forces already carry their
moment; only intrinsic torque is added separately. Persistent external force
contributors remain intact.

Complete control, cargo, pose and topology changes before preparation. While
transient forces are queued, native state-changing commands and snapshots require
integration or cancellation first. Additive external force commands remain valid.
This includes commands in a physics `beforeStep` callback: move pose and cargo
updates earlier in the shared system order.

Dispose a binding to remove its water contribution, including queued forces for
that actor. Other bound actors retain theirs. `await bridge.close()` invalidates
pending work, cancels its queued forces and drains accepted sampling. The borrowed
world and sampler stay open. Source providers must settle accepted requests so
close can drain them.

## Currents and sleep

An optional `GeoFieldSource<Vec3>` current provider supplies fluid transport
velocity in body-fixed ECEF axes, in m/s. Each result needs the requested tick,
zero age, frame revision zero, matching source revision and a finite error bound.
The bridge adds its velocity error to the wave sample's bound and admits at most
16 concurrent provider reads. Stale, unavailable or inaccurate current data
rejects the batch. Currents affect relative drag velocity; they do not advect or
change the spectral wave geometry.

`OceanSleepSettings` defaults to 0.02 m/s² net linear acceleration, 0.02 rad/s² net
angular acceleration and 0.02 m/s water velocity. A sleeping body remains asleep
only within all three thresholds. Lost support, sufficient current or changed
loads wake it. Awake bodies can settle through the native sleep system. These
are explicit physical approximations, independent of render quality. Set all
thresholds to zero when you require strict load response.

## Rebase and replay

Forward a `GeoWorldFrame.rebases` event to `bridge.applyRebase(event)` exactly once,
or call it immediately after rebasing and before resuming simulation. The bridge
transforms the whole native world: poses, kinematic targets, velocities, gravity,
persistent external loads and queued water forces. It rejects scale, shear and
reflection. Other scene systems must follow the same frame change. Prepared
batches become invalid.

After the owner restores physics and its clock, call `beginReplay(checkpoint)`
with a newer generation. Reacquire native body handles and bind them again. The
bridge does not restore a second physics world or clock.

The [qualification record](../../qualification/2026-10-03/ocean-native-buoyancy.md)
covers native trajectories and lifecycle tests. Presentation-cadence fixtures use
real physics and a pixel stub for scene callbacks. They do not qualify GPU water
visuals, mobile devices or performance. Effective visual quality changes are
qualified with the W11 controller, and full vessel rendering belongs to W12.
