# Externally driven particles

Set `ParticleEmitter(externallyDriven: true)` when your simulation owns time.
Call `controller.step(name, tick: nextTick)` once per fixed step. The first tick
is one. Duplicate and skipped ticks are rejected before the clock advances.
Rendering refreshes camera inputs and sorting without advancing this emitter.
External emitters invalidate the scene after stepping and do not acquire a
continuous frame demand by themselves.

Call `burst` before the step to emit a bounded population. The optional
`emissionVelocity` adds velocity only to particles born during that tick, after
the emitter transform. It uses world coordinates for world-space emitters and
local coordinates for local-space emitters. Existing particles retain their
velocity. The GPU and reference paths share this contract.

A paused or stopped emitter rejects external steps. Resume or start it first.
`reset`, replacement and recovery restart its tick sequence. Follow reset with
`start` and tick one. Keep any application checkpoint offset outside the emitter.
An external emitter with prewarm begins after its prewarm ticks; read
`simulationTick` before supplying its next tick.

Native Metal tests cover birth velocity, duplicate/skipped ticks and unchanged
particle positions across presentation frames. The existing fixed-clock,
reference/GPU and suspended-ocean tests also pass.
