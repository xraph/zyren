# Native optics, area shadows and compressed texture residency

User scope: finish iridescence, dispersion, rectangular area shadows and GPU
compressed textures. Continue on dart-core-api with local commits. Keep geospatial
optional and preserve concurrent work in the primary checkout.

## Task 1: Iridescence and dispersion

Add immutable PhysicalMaterial controls, two linear iridescence maps and required
glTF extensions. Use the Khronos thin-film Fresnel model and three wavelength
refraction paths with the specified dispersion spread. Version scene packets;
keep existing packets and zero-factor output compatible. Integrate direct,
environment and area lighting, transmission, instancing, maps and temporal AA.
Write failing API, glTF and pixel tests first, then implement and run full core,
loader, Rust and native GPU suites. Commit the passing increment.

## Task 2: Rectangular area shadows

Reuse the native shadow atlas and caster pipelines. Sample four rectangle patches
with cube projections, integrate each patch's lighting with its own visibility,
and preserve receiver/caster flags, masks, deformation and cache invalidation.
Bound views and atlas pixels before GPU allocation. Use existing shadow settings
for clipping, bias, resolution and strength. Test full occlusion, partial visibility,
light size/motion, non-receivers, multiple lights, budget rejection and cleanup.
Run full relevant suites and commit.

## Task 3: GPU compressed texture residency

Add sampled BC7, ETC2 RGBA and ASTC 4x4 storage with linear/sRGB variants. Count
block-rounded mip payloads, validate uploads and reject unsupported usage before
allocation. Request supported compression features from the adapter and expose
capabilities. Extend Basis decoding to explicit target formats while retaining
RGBA compatibility. Configure loader services from device capabilities, preserve
authored mips and color/data interpretations, and fail clearly for unsupported
explicit formats. Test real Basis fixtures, raw block uploads, pixel equivalence,
mip tails, limits, ownership, disposal and unsupported-device behavior. Commit.

## Qualification

Run core, glTF, native GPU, Rust including hardware tests, Flutter package checks,
analysis, formatting, strict Clippy, package boundaries and ABI synchronization.
Extend the native gallery and run macOS and available iOS simulator surfaces.
Record resource and performance evidence with source identity. One fresh-context
review checks packet bounds, physical edge cases, atlas indexing and compressed
mip accounting. Fix every important finding with a failing regression, then
repeat affected suites. Keep physical-device qualification limits explicit.

Interfaces: optical descriptors and map counts cross Dart snapshots, packets,
Rust validation and shader uniforms. Area shadows share the bounded atlas and
lighting indices. Compressed formats cross descriptors, image packets, native
allocation, capability negotiation and loader color-space handling. Each path
must agree on counts, storage and lifetime before its task is complete.
