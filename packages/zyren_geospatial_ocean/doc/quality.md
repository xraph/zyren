# Visual quality controls

`OceanRenderQuality.low`, `medium`, `high` and `ultra` provide the approved starting
work limits through `.settings`. These are resource profiles for qualification,
not measured device recommendations. Each profile maps to the LOD selector,
reflection pass, underwater settings and native opaque capture scale.

| Profile | FFT / bands | Patches / vertices | Capture / SSR steps | Shafts / spray cap | Payload allowance |
| --- | --- | --- | --- | --- | --- |
| Low | 64 / 2 | 96 / 65,536 | 0.5 / 0 | 0 / 0 | 32 MiB |
| Medium | 128 / 3 | 192 / 131,072 | 0.5 / 16 | 12 / 2,048 | 64 MiB |
| High | 256 / 4 | 384 / 262,144 | 0.75 / 32 | 24 / 8,192 | 128 MiB |
| Ultra | 512 / 4 | 768 / 524,288 | 1 / 64 | 48 / 32,768 | 256 MiB |

Caustic projections use 0, 64, 128 and 256 pixels per side respectively. Zero
removes the pass. Mesh defaults use 16 segments per patch and a two-pixel curvature
error target. The existing selector retains its hysteresis and coverage rules.
The spray cap belongs to the optional fixed-tick spray adapter; it is separate
from suspended underwater particles.

Use `copyWith` for custom limits. `preset` returns null when any saved work limit
differs from all four presets. Versioned JSON preserves every value and rejects
unknown keys or invalid bounds. The canonical spectrum, sea level, density,
physical query policy and simulation rate are outside this object.

`OceanAdaptivePolicy` is disabled by default. When enabled, it smooths measured
presentation cost and requires sustained pressure outside a 20 percent threshold,
at least 30 samples, and a five-second dwell before recommending one adjacent
profile. You can set the range and thresholds. Feed one consistent timing source.
An unavailable measurement is null and resets the pressure streak. Recommendations
also observe the dwell after a rejected candidate, avoiding repeated allocation
attempts every frame. The policy never advances a clock or publishes resources.

Native band limits, persistent wave inputs, caustic updates, scaled capture,
wave blending and atomic controller publication are implemented. The built-in
view pipeline and full W11 qualification remain in progress. A profile value or
passing policy test does not establish that every effect is installed or that a
device meets the frame target.

`OceanQualityAdmission.evaluate` preflights persistent wave fields, packing
scratch, all resident charts and optional wave-transition atlases. Supply each
view's actual planned geometry, material and history payload through
`OceanViewAllocation`. It adds scaled opaque color/depth targets, their MSAA
attachments, and requested boundary/medium targets. Extension-owned passes,
caustics, interactions and spray contribute through `additionalPayloads`.
Count current and other retained candidates in `retainedBytes`.

The returned breakdown separates candidate, transition and retained payloads.
Admission rejects missing features, a render grid above the canonical source,
unsupported advertised formats, dimensions, sample counts and byte allowances.
Duplicate view IDs are invalid. Host coefficient bytes describe the candidate
streams separately. Driver residency is not inferred from any of these values.
Other device owners can allocate after preflight, so candidate construction must
still handle a native allocation failure and preserve the published resources.

## Resource publication

Create an `OceanController<T>` with `OceanController.create<T>`. Your planner
returns an `OceanQualityPlan<T>` for each requested settings object. Build the
actual native resource bundle under `context.gpu` and register other cleanup
with `context.onClose`. Declare all owned view and extension payloads before
construction. Keep candidate meshes out of your live scene until publication.

The planner receives `previous` settings during a fade so you can construct
common refinement geometry. Both steady and transition bundles are ready before
`setQuality` publishes either. Build, admission or native allocation failures
leave the previous bundle usable. Read `resources` and `publicationRevision`
after awaiting `setQuality` or `advance`, then attach that bundle through your
frame owner. Retired bundles must not be reused.

`advance(seconds: ..., elapsed: ...)` updates both wave fields and the blend
without rebuilding their resources. `elapsed` is monotonic presentation time;
`seconds` is canonical wave time and may move backward during a replay. Neither
advances physics. Keep rendering and updates sequential. A failed mutable wave
update makes the controller unavailable until a successful retry, because some
chart data may already have changed.

Admission separates the final resource allowance from transition peak usage.
The target bundle must fit its own allowance. During replacement, old resources,
the candidate and the transition bundle must together fit the larger of the old
and target allowances, plus the backend limit. This lets you downgrade without
pretending the old resources have already been freed. A transition can still be
rejected when its temporary peak does not fit. Set zero transition duration for
an atomic replacement that needs no blend bundle.

Cleanup failures are recorded separately and their payload remains counted for
future admission. `close` drains accepted work and reports any cleanup failures.
Factories are responsible for declaring accurate payload recipes; the native
allocator remains authoritative when other owners compete for memory.

## Diagnostics

`controller.diagnostics()` reports the effective settings, actual resident chart
and band counts, estimated payloads, publication state and installed effect names.
Pass optional patch/vertex counts, physical query results and extension pass
measurements from the resources that produced them. Queries from another sea
state are rejected. Unknown counts and timings remain null.

Wave and blend host timings include completion waits. They are not GPU timestamps.
Native device inspection retains its whole-device scope, and presentation profiles
retain their whole-scene scope. Neither is attributed to ocean alone. Physical
residency stays null unless the backend actually measures it. Physical query age
is its age at delivery, not a claim that the result is still fresh now.
