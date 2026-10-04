# Rendered band limits

`OceanWaveFieldGpu.evaluate(seconds, resolution: n, bandCount: count)` computes
a prefix of the canonical band's ordered list. Omit `bandCount` to retain all
bands. Invalid counts fail before replacing the current field.

The canonical sea state, chart seed and retained coefficients stay unchanged.
Changing the count replaces the native work set, and admission includes both
old and candidate payloads. Each omitted band removes its actual FFT buffers,
textures and dispatches. It does not remove that band from physical queries.

`OceanFieldSnapshot.omittedBandSlopeVariance` reports the sum of the omitted
bands' seeded slope variances. Packed visual data carries it into roughness along
with unresolved frequencies. `OceanWaveRenderData.bandCount` describes the actual
packed band count; its texture height and payload shrink with that count.

The native two-band fixture verifies half the dispatches and payload at one band,
identical retained samples, and unchanged values after restoring both bands.
Twenty-three wave, packing and material-field checks pass on macOS Metal. These
are primitives for W11; complete profiles and atomic controller transitions are
still in progress.
