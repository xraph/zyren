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

The event and stability contracts are implemented. Native field transport, foam,
spray and visual integration remain in progress under W10.
