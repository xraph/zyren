# Atmosphere equations and lookup tables

The optional geospatial package computes a three-wavelength RGB atmosphere with
Rayleigh scattering, Cornette-Shanks Mie scattering, ozone absorption, ground
reflection and four scattering orders. It ports the supplied Bruneton equations
from three-geospatial `b012ad06d858fc035d88aacfd73f092f93c994e4` to WGSL.

Public parameters use metres and inverse metres. Shader functions use kilometres.
`AtmosphereParameters.legacy()` preserves the legacy defaults, including ground
albedo 0.1 and the rounded Mie density exponent. `webgpu()` preserves the newer
albedo 0.3, exact 1/1200 metre Mie scale and luminance coefficients. Parameters
and density profiles are immutable and validated. This profile does not perform
spectral integration or load the source's precomputed binary/EXR assets.

## Layout and ownership

`AtmosphereQuality.balanced` has a 256 by 64 transmittance table, a 64 by 16
irradiance table, and three 192 by 64 by 24 volumes. The volumes store single
Rayleigh, single Mie and phase-reduced higher-order scattering separately. All
use linear RGBA32 float with explicit interpolation. There is no assumption of
hardware filtering support for float32 textures.

Published tables occupy 14,434,304 bytes. The temporary integration workspace
adds 14,188,544 bytes during generation. This fits the existing 64 MiB resource
budget, including one previous published set during replacement. Other resources
on the device still count against that shared limit. Allocation failure preserves
the caller's previous lease; it does not raise the budget.

`AtmosphereLutCache` belongs to one `GpuScope` and device generation. Keys include
all parameters, precision, layout, quadrature and algorithm version. Concurrent
requests for the same key share work. Leases prevent eviction, idle entries use
LRU order, and admission fails when all bounded entries remain in use. Closing a
consumer lease does not invalidate another consumer's lease. Closing the cache
invalidates the set and drains pending work. Recreate it after device replacement.

Each candidate has separate persistent and temporary child scopes. Precomputation
publishes only after all stages finish and the workspace retires. A cancelled or
failed candidate releases its allocations. Closing the parent during generation
rejects publication and waits for accepted native operations. Ordinary generation
and shader use perform no CPU texture readback.

## Numerical qualification

`tool/atmosphere_reference/generate.py` compiles the original GLSL equations in a
small C++ double-precision host. It checks the pinned Git blob hashes before
adapting parameter passing and a GLSL array copy. The equations themselves remain
unchanged. Generate the bounded fixture with `--profile balanced` and the original
256 by 128 by 32 scattering layout with `--profile reference`.

Both retain 500 optical-depth intervals, 50 line-integration intervals, 16 polar
scattering-density intervals, 32 irradiance intervals and four scattering orders.
The committed fixtures cover boundary texels, stratified interior texels, 648
physical view/sun configurations and sky/finite-distance runtime paths.

The bounded layout differs from the original layout by a median 0.224%, 95th
percentile 2.990% and maximum 53.467% on those 648 radiance probes. The comparison
uses the largest RGB component error divided by the reference peak component,
with a 0.001 floor. The largest relative error is a dim twilight sample. Maximum
absolute error is 0.008825; the largest reference component is 0.791340. These are
sampled error bounds, not a uniform guarantee for every camera or atmosphere.
A coarser experimental layout failed the error budget and is not exposed.

On Apple M3 Max Metal, the WGSL result at the bounded layout has maximum absolute
radiance error 0.000142 against the same-grid CPU fixture. Per-table fixture
limits are 0.0002 plus 2% relative, except Rayleigh (2.5% relative) and the
phase-reduced higher-order volume (0.008 plus 2%). The latter is multiplied by the
Rayleigh phase function at runtime. Maximum sampled table errors are 0.0000102
transmittance, 0.010314 Rayleigh, 0.000260 Mie, 0.013407 higher-order and 0.0000024
irradiance. All texels are checked for finite, nonnegative values; transmittance
must stay in [0,1]. The vacuum fixture requires unit transmission and zero
scattered light throughout the tables.

The native implementation preserves exact vertical and radial table endpoints
and factors radius-square differences to reduce float cancellation. Before this
fix, fused GPU arithmetic could map a zero-length outward ray at the atmosphere
top into a 4,789 km inward ray. A regression checks every top outward texel.
Runtime functions also return identity transmission for zero path length and
reject rays that miss the outer sphere. These are intentional numerical repairs.

`AtmosphereLuts.shader()` provides readonly bindings and the WGSL sky, segment,
direct-irradiance and indirect-irradiance functions. Runtime fixtures check day,
twilight, night, upper-atmosphere and space views, ground clipping, zero paths
and atmosphere misses. Rendered sky/celestial integration and mobile atmosphere
qualification remain separate gates.
