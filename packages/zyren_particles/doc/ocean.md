# Suspended water particles

Import `package:zyren_particles/ocean.dart` to use `OceanSuspendedParticles`.
It adapts the existing native particle controller without adding a geospatial
dependency. You supply the ocean's budget, submersion state and lit particle color.

You can attach an empty `ParticlePlugin(emitters: [])`, then configure the adapter
once its controller is available:

```dart
final dust = OceanSuspendedParticles(particles.controller);
dust.position = wetRegionCenter;
await dust.configure(
  budget: underwaterSettings.particleBudget,
  radiusMetres: 2,
  litColor: const Color3(.08, .12, .15),
  currentVelocity: currentVelocity,
);
await dust.setSubmerged(submersion.submerged);
```

Call `setSubmerged` when the hysteretic state changes. Leaving water stops emission
and clears existing particles. A zero budget removes the emitter and its owned
resources. A nonzero budget changes native capacity through atomic configuration.
Changing capacity restarts this visual population; it does not alter the sea state
or rigid-body simulation.

Update `position` as the wet emission region moves. Existing particles keep their
world positions and drift with the configured current. Radius and optional
collision planes are caller-defined bounds, not bathymetry queries. Keep the
emission region in water. Supply a darker lit color at night; the adapter does not
invent illumination or cast shadows. Soft scene-depth intersections are not
claimed by this adapter.

Await `dust.close()` before retiring its controller. The native test exercises
Earth-scale positions, world motion, capacity reduction, leaving water and zero
remaining emitter resources. It uses explicit diagnostic readbacks; normal
adapter operation does not read particle state back to the CPU.

## Spray and quality preparation

`OceanSprayParticles` consumes bounded, deduplicated events on your shared fixed
clock. Its emitters are externally driven: rendering another frame does not
advance droplets. Use `budget` to select native capacity and `maxEventsPerTick`
to bound simultaneous event sources. Capacity is split evenly across lanes;
`effectiveCapacity` reports the resulting total.

For a quality replacement, create a detached candidate with `autoAttach: false`.
Pass the current shared `initialTick`, `generation` and the old adapter's
`sourceWatermarks`. You can prepare GPU resources without adding the candidate's
objects to the scene. After publication, mount `candidate.objects` synchronously
and close the previous adapter. The next `advance` takes `initialTick + 1`.
This starts a new visual population at the existing simulation time; it does not
replay old events or reset your physics clock.

`estimateBytes` includes particle buffers, sprite textures and expanded quad
geometry. Pass `retainedBytes` and `maxLogicalBytes` to reject an over-budget
candidate before installing emitters. Count the old population while it is
retained. Shader descriptors, renderer bookkeeping and physical driver residency
are separate; the native allocator remains authoritative. A zero budget creates
no emitters. Closing the adapter removes its objects, including objects you
mounted after detached preparation.

The native preparation test covers failed admission, duplicate event rejection,
an existing shared tick, detached construction, publication and full cleanup.
It does not transfer living droplets between capacities or implement a visual
crossfade between particle populations.
