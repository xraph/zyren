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
and atmosphere misses. Scene integration and device evidence are recorded below.

## Scene plugin

Add `AtmospherePlugin(date: DateTime.utc(...))` to your native scene. Positions
are ECEF metres by default. For a local scene, supply a proper rigid
`worldToEcef` matrix. Scaling, reflection and shear are rejected. The default
altitude correction subtracts the ellipsoid's osculating-sphere centre, matching
the source. Set `correctAltitude: false` when your world already uses the
atmosphere's spherical radii.

The plugin publishes the typed `atmosphere` controller service. You can change
`date` and `appearance` without rebuilding tables. Await `setParameters` for a
transactional table and effect replacement. A cancellation or allocation failure
keeps the previous effect usable. Replacements preserve their slot in the effect
chain, including when all eight slots are occupied.

Call `acquireLighting()` if your material needs the current tables. Its lease
provides `luts.shader()` with sky, segment, direct irradiance and indirect
irradiance functions. Keep the lease until your material retires. Existing
leases remain valid across parameter updates; they also count against the
bounded cache. The plugin does not automatically replace your scene's PBR lights
or environment map. Those remain separate consumers of the lighting functions.

The sky compositor reconstructs camera-relative rays and scene depth, converts
metres to shader kilometres, then applies transmittance and in-scattered light.
It supports perspective and orthographic cameras. An effect-owned transparent
clear preserves premultiplied foreground coverage without changing your saved
background settings. The final sky is opaque. With `appearance.sky: false`,
you get the scene over a transparent background, with optional haze.

Opaque and masked depth receives finite-distance haze. Blended surfaces without
depth writes remain visible over the sky, but their own distance cannot be
recovered from the shared depth buffer. Haze at those pixels uses the nearest
written depth, if one exists. There is no per-layer transparent haze or shadow
length integration in this slice. Disks and stars are hidden in orthographic
views, matching the source celestial convention.

The sun uses the atmosphere's angular radius and solar radiance. The moon uses
the source Oren-Nayar diffuse response, a default 0.0045 radian angular radius,
2.5e-6 relative solar brightness, topocentric direction and Moon-fixed
orientation. An optional `MoonMap` supplies an owned equirectangular sRGB RGBA8
albedo image, with the north pole in the first row. White albedo is the default.
Lunar displacement and moonlight atmospheric scattering are not enabled.

Stars use the original 9,096-record Yale catalogue, J2000 directions, source RGB
values and apparent magnitudes. Their intensity follows the pinned WebGPU
surface-brightness formula, including projected pixel solid angle. Overlapping
stars accumulate in a linear RGBA16 float target. Its longest edge is bounded
by `maxStarResolution` (default 1024, maximum 2048), with preserved aspect ratio.
The default target costs at most 8 MiB. Resizing builds a replacement and retires
the old target; ordinary frames upload uniforms and draw without readback.

The source asset comes from revision
`eac103980f20c0956f2d3215833e73514be08462`. Its SHA256 is
`2fa0fd8318c85e9b0c8e318d84278d00e0610784e57a20e06b5715763bf4d5d6`.
`tool/embed_star_catalog.py` verifies that object before embedding it for pure
Dart use. No Flutter asset loader or runtime download is required.

## Rendered qualification

Nine original runtime fixtures pass through the actual sky compositor and scene
geometry with a three-byte-per-channel sRGB tolerance. Both perspective and
orthographic centre rays are checked. Separate native fixtures cover stellar
photometry and overlap, UTC rotation, sun and lunar radiance, lunar albedo and
orientation, opaque occlusion, translucent foregrounds, day/night changes,
resize, memory pressure, cancellation and disposal during replacement.

The Planet atmosphere lab uses only public package APIs. On macOS Metal and
Pixel 9 Pro Vulkan, day/dusk/night changes, horizon/orbit views, navigation, haze
and 320/390/1000 pixel layouts passed. Each run observed 11 test frames, zero
presentation readbacks and zero native owners after disposal. Foreground window
activation failed on the locked Mac, so this is presentation-counter evidence
plus separately inspected native render images, not a manual window review.
The iPhone 16 Pro Metal profile run also passes all controls, widths and cleanup
checks: 31 native presentations, 11 samples, zero readbacks and zero remaining
owners. Its layout check measures canvas height after system safe areas. Planet
stays installed after the test. Windows DX12 remains unverified.

The Pixel initially crashed inside the Mali Vulkan compiler while compiling the
direct-irradiance pass with texture arguments passed through helper functions.
Atmosphere templates now generate a helper per global texture binding. Numerical
bodies are unchanged. The complete Metal numerical suite and the Pixel native
presentation fixture pass with that specialization. No backend fallback is used.
