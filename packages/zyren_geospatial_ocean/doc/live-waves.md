# Animated wave inputs

Use `OceanWaveStream.create` for animated water. Supply your canonical sea state,
resident chart IDs, FFT resolution and optional rendered band count. Each chart
keeps its FFT fields, packing scratch, configuration buffers and output atlas.
Both FFT publication slots have prepared packing graphs.

Await `stream.update(seconds)` before you render. Existing water materials read
the updated atlases without rebuilding their bindings. `seconds`, `revision`,
`lastDispatches` and `lastHostTime` describe the last update. Host time includes
submission and completion waits. It is not a GPU timestamp or a frame benchmark.

A stream is not ready during an update or after an update fails. A failed update
can leave some chart textures changed, so consumers must wait for a successful
retry. `OceanWaterMaterial.isReady` includes that state and the interaction field.
Surface captures also check the material's revision. Serialize stream updates,
foam generation, boundary capture and rendering through your frame owner.

`OceanWaveRenderData.pack` still creates an immutable snapshot. Retained material
inputs survive that snapshot's close. Closing a live stream invalidates its
materials even while retained texture handles keep the native allocations alive.
Close dependent materials and passes when you retire a stream.

Admission counts every resident chart's FFT work set, output atlas, packing
scratch and configuration. Include other retained resources with `retainedBytes`.
This is logical GPU payload, not physical residency. `hostCoefficientBytes` is a
separate estimate of the canonical CPU coefficient arrays.

The native qualification checks 100 updates with constant live allocation count,
unchanged texture identity, changed material samples and exact agreement with an
independent immutable pack at every mip level. It also checks two-chart admission,
partial native allocation failure and close during an accepted update.

`OceanCaustics.update()` reuses its projection and flux-reduction graph. Call it
after the wave update and before rendering receivers. `isCurrent` checks the
source revision; `isReady` only says the output is available. `lastStats` reports
the executed pass counts. The pass projects spectral waves, so local wake fields
do not deform its light pattern. Recreate it when layout, footprint, lighting or
optical parameters change. A 100-update native check keeps allocations constant,
changes the light pattern and matches a fresh projection at the final time.

For a quality fade, create `OceanWaveBlend` from two ready streams at the same
time, with the same canonical sea state and resident chart IDs. Create transition
materials from that blend. Update both streams to the next presentation time,
then call `blend.update(fraction)` with a value in `[0, 1]`. The blend borrows its
sources; close its materials and passes before retiring it or either source.

The transition atlas copies both layouts without resampling. Its header carries
the original grids, mip offsets and unresolved variances. Material evaluation
samples each source at its own filter scale, then blends displacement,
derivatives and variance. Endpoint samples therefore preserve the source filters.
Physical queries still use the unchanged canonical state.

Admission must include both source streams, the transition atlas and dependent
materials. Pass those retained payloads through `retainedBytes`. A transition
can fail even when either endpoint fits alone, including the 64 MiB limit on one
texture. Rejection must keep the current quality active. Native tests cover
logical and actual allocation rejection, constant live allocation counts during
updates, and endpoint displacement, normal and variance within `2e-6` of the
source material at three times and three filter footprints. W11 controller
publication and automatic profile selection remain in progress.
