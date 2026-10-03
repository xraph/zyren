# Zyren geospatial ocean

You can define a deterministic sea state and inspect its numerical surface with
this optional package. Native FFT evaluation and the water renderer follow in
the implementation plan. This package does not yet draw an ocean.

```dart
final state = OceanSeaState(
  seed: 42,
  canonicalResolution: 256,
  bands: [
    OceanWaveBand(
      patchMetres: 512,
      minWaveNumber: 0,
      maxWaveNumber: 1.5,
      windSpeed: 12,
      windHeadingRadians: 0,
      amplitude: .02,
    ),
  ],
);
final waves = OceanSpectrum(state);
final coefficients = waves.evolve(0, 2.5);
final saved = state.toJson();
final restored = OceanSeaState.fromJson(saved);
```

Keep `OceanSpectrum` when you evaluate more than once. It owns immutable seeded
coefficients and dispersion frequencies. The convenience `evolveSpectrum` function
constructs those again. You can round-trip a state through JSON; decoding requires
the exact spectrum ID and version in `OceanSpectrumRegistry`. Custom models must
be deterministic and stateless. Change their registered version when you change
an equation or constant.

## Numerical convention

Arrays interleave real and imaginary Float64 values in row-major z/x order.
Wrapped centered frequencies run `[0, 1, ..., N/2-1, -N/2, ..., -1]`. DC occupies
index zero. Inverse transforms use the positive complex exponential and normalize
once by `1/N²`. Seeded coefficients include `N²`; selecting a smaller visual grid
will require rescaling by its squared size to preserve physical amplitudes.

The directional Phillips model uses wind length `V²/g`, squared wind alignment,
short-wave damping at `0.001` times wind length and a `0.07` counter-wind factor.
Amplitude scales density, which is integrated over `dkx * dkz`. These constants
belong to Phillips version 1. Heights follow the model developed in
[Tessendorf's course notes](https://people.computing.clemson.edu/~jtessen/reports/papers_files/coursenotes2004.pdf).

Time evolution uses `h0(k) exp(-iωt) + conjugate(h0(-k)) exp(iωt)` so the wind
heading points toward dominant wave travel, from +x toward +z. A supplied depth
uses `ω² = gk tanh(kd)`; otherwise dispersion is deep-water. Phases reduce time
modulo each frequency's period before evaluation. Accepted times span ±1e12
seconds from the epoch, though Float64 time resolution still limits very long
runs. DC and both Nyquist axes are zero. This keeps spectral derivatives real.

Bands have raised-sine frequency windows. At each wave number their weights are
divided by `max(1, sum(weights))`, so overlapping bands do not allocate more than
one unit of window weight. The canonical grid still bounds represented frequency;
a requested window does not add frequencies beyond that grid.

The seed algorithm is SplitMix64 with exact unsigned 64-bit modular arithmetic.
Mix the uint32 seed and the packed tuple `(band+1)<<32 | (nx+32768)<<16 |
(nz+32768)` separately, XOR them, then mix again. A second mix supplies the other
Box-Muller uniform. Uniforms use `(top52bits + 0.5) / 2^52`. Gaussian draws happen
on the CPU; the GPU will receive these coefficients without another random seed.
The descriptor revision is an FNV-1a fingerprint, not a cryptographic integrity key.

## Reference checks

`inverseDft2` is an independent O(N⁴) oracle limited to grids of at most 32.
`OceanSpectrum.reference(x, z, seconds)` reconstructs small fixtures with at most
4096 coefficients by default. It returns height, choppy displacement, spatial
derivatives and water velocity. Coordinates describe the undisplaced material
surface; this function does not solve the inverse displacement query for buoyancy.

The macOS numerical checks cover transform sign and normalization, Hermitian
pairs, reproducible coefficients, finite-depth limits, long elapsed time,
overlapping bands and finite-difference derivatives. The 8 x 8 fixture with seed
42 has little-endian Float64 coefficient SHA-256
`80c7073b2f58831998d2d2b0e69cd1cddab32589e5b3e9d0faabfec4108d36fe`.
An independent Python calculation reproduced that hash. Native GPU agreement,
rendering, physical buoyancy and cross-platform qualification are still pending.
