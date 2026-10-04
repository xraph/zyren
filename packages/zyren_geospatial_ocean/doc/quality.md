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

Native band limits, persistent wave inputs, caustic updates, scaled capture and
wave blending are implemented. Atomic controller publication and combined view
admission are still W11 work. A profile value or passing policy test does not
establish that every effect is installed or that a device meets the frame target.
