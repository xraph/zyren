# Fixed-tick ocean spray

Import `package:zyren_particles/ocean.dart` and create `OceanSprayParticles` from
an attached particle controller. A zero budget creates no emitters. Other budgets
reserve up to eight lanes, each with one birth position per tick. Capacity rounds
down to equal lane sizes and is exposed as `effectiveCapacity`.

Map each ocean event to `OceanSprayEvent`. Preserve its source, sequence, tick and
generation. Transform ECEF positions, velocities and normals into the scene's
world frame. Pass an initial `anchor` near the emission region so delayed first
births keep metre precision at Earth coordinates. The adapter belongs to one
simulation timeline and uses the supplied `hz`; it does not own a geospatial clock.

Call `advance(nextTick, events: mappedEvents)` after your simulation has produced
that tick's events. Keep it independent of the wake field's admission result.
Events sort by source and sequence, while returned admission results retain input
order. Duplicates, wrong generations and source/event limits are explicit. A
source watermark stays allocated until reset, bounding memory for long runs.

The event's `energy` matches the visual m² strength used by ocean interactions.
Its square root sets birth count and a normal launch velocity capped at 10 m/s.
The supplied velocity is added in world coordinates. Gravity, drag and optional
collision planes then act on each droplet. Particle overflow drops new births
within each lane; accepting an event does not guarantee all its droplets fit.
Colors are caller-supplied lit colors. Droplets use a procedural radial texture,
velocity stretching and lifetime fade. This is not volumetric spray scattering.

Pause by omitting ticks and resume at the next tick. `reset(newGeneration)` clears
particles and identities for replay. A failed native update requires reset.
`close` drains accepted work and removes only this adapter's emitters. Closing the
parent particle plugin also releases them.

The native replay fixture compares exact positions and velocities under different
presentation rates, checks admission and Earth-scale positions, and verifies
resource return after close. All 22 particle tests pass on macOS Metal after
updating the measured upload expectation for the added birth-velocity uniform.
