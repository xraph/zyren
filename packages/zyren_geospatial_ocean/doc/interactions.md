# Timestamped water interactions

Give each wake or debris emitter an `OceanInteractionId(source, sequence)` and use
the shared `GeoInstant`. A source enqueues increasing sequences at nondecreasing
timestamps. Different sources can arrive in any order. Accepted events sort by
source and sequence for each tick.

`OceanInteractionQueue` defaults to 256 pending events, 64 events per tick, 128
sources and a 600-tick future window. Admission returns a typed result for duplicate,
late, wrong-timeline, out-of-order and over-budget events. Rejection does not
consume a source slot. One sequence/time watermark per source keeps memory bounded
without forgetting played identities. Reusing a source sequence requires a newer
replay generation.

`peekTick` leaves state unchanged. `takeTick` consumes exactly the next shared tick.
`reset(newGeneration)` clears events and source watermarks and resets to tick zero,
with an optional checkpoint tick. Event JSON records preserve ECEF position,
water-relative velocity, source identity and the full time standard. Use
`atGeneration` to replay a record on the new timeline.

Interaction `energy` is a visual strength in m²; its square root gives a
characteristic displacement before filtering. It is not mechanical energy
transferred from a rigid body. The interaction field is visual-only. Canonical
physical queries retain their own wave state and error contract.

`OceanInteractionSettings.substepsFor(hz)` checks the actual damped five-point
recurrence, including the strongest absorbing-edge damping:

```text
2 * (waveSpeed * dt / cellMetres)^2 + maximumDamping * dt / 2 <= courantLimit
```

The default margin is 0.9. Admission selects bounded substeps and rejects settings
that cannot meet the limit. No display-quality label can override stability.

`OceanInteractionField.create` allocates two native state buffers, a stable
RGBA32F publication texture, a foam source texture and bounded event/configuration
buffers. It compiles reusable graphs once. Await each `step`, `recenter`, source
write or reset before drawing or starting another mutation. `close` rejects new
work and drains an accepted operation before releasing resources.

The published channels are height, east slope, north slope and foam coverage.
`foamSources` RG channels hold whitecap and shore emission rates in 1/s. A native
producer can retain this texture; `writeFoamSources` supports validated uploads.
Foam uses semi-Lagrangian transport, exponential decay and bounded coverage
emission. `foamVelocityEcef` is explicit and limited to four cells per substep.

The tangent axes stay fixed. `recenter` snaps to whole cells, shifts both height
states and foam on the GPU, clears newly exposed cells and invalidates the old
source map. It does not advance time. Pause by omitting ticks, then resume with
the next tick. Reset requires a newer generation and clears all history.

Logical payload is `64 * resolution² + 80 * substeps + 32 * maxPerTick` bytes.
This excludes native pipeline overhead and does not claim physical residency.
The per-step dispatch count is `substeps + 1`. `debugState` is an explicit
readback for diagnostics, outside the simulation path.

Nine interaction tests pass on macOS Metal: independent scalar recurrence,
impulse symmetry, bounded propagation, decay, foam transport, recentering,
replay, queue admission and native allocation return over 100 create/close
cycles. Surface shading, source generation and spray remain in progress under W10.
