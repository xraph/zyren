# Native water surfaces

You can render the spectral wave field through the public native mesh API. The
water material includes filtered displacement and normals, dielectric Fresnel,
GGX sun reflection, scene-depth refraction, wavelength-dependent extinction and
homogeneous in-scattering. It outputs linear HDR; the renderer applies display
tone mapping afterwards.

Prepare the fixed world charts your patches need. Each chart uses
`oceanChartSeaState(state, chartId)`, which shares the physical sampler's seed
mapping. Evaluate their `OceanWaveFieldGpu` instances at the same time and visual
resolution, then pack the current snapshots:

```dart
final renderWaves = await OceanWaveRenderData.pack(
  owner,
  state: state,
  charts: currentSnapshotsByChart,
  retainedBytes: previousRenderWaves?.logicalPayloadBytes ?? 0,
);
```

Packing stays on the GPU. The result copies one evaluated time into immutable
RGBA32F atlases. Later wave evaluations do not change that copy. Native compute
builds periodic averaged mip levels and slope moments; the shader interpolates
between levels and adds unresolved slope energy to roughness. Screen-space normal
variation also broadens the specular lobe. The physical sea state and query fields
remain independent of this visual filtering.

Each chart occupies `64 * resolution² * bandCount` logical bytes. Packing also
needs one temporary chart buffer and dispatch uniforms, which count toward the
admission limit alongside `retainedBytes`. The public per-texture cap is 64 MiB.
Four bands at 512 fit that cap; eight do not. A rejected candidate closes its
resources. Your previous packed snapshot stays usable.

## Stitched patches and morphs

Use `OceanWaterGeometry` for the stitched mesh. It preserves the control points
and interpolation weights from the surface topology. Displacement is evaluated
at those controls before interpolation, including both endpoints of a morph.
This keeps a fine edge on the displaced coarse segment.

```dart
final controls = OceanWaterGeometry.fromMorph(morph);
for (final patch in controls.patches) {
  final water = await OceanWaterMaterial.create(
    owner,
    waves: renderWaves,
    patch: patch.geometry.id,
    controls: patch,
    ellipsoid: ellipsoid,
    geometrySpacingMetres: 2,
    optics: OceanOptics(roughness: .08),
    lighting: lighting,
  );
  final mesh = water.createMesh(patch.geometry)..morphWeights = [fraction];
  scene.add(mesh);
}
```

For a static selection, use `OceanWaterGeometry.fromSurface(surface)`. Controls
supply their own conservative filter widths at shared vertices. Set the same
morph fraction on every participating mesh. Remove meshes before closing their
materials. A material retains its wave atlases and lighting until retirement;
submit the cleared scene to release the view's accepted draw references as well.

The supplied geometry uses ECEF-oriented positions local to its double-precision
patch origin. Positions and optical distances are metres. A rigid world-frame
transform is allowed; mesh scaling is unsupported. Custom local meshes may omit
controls and select `deformed: true` only when their geometry has morphs or skin.
Those custom meshes are responsible for their own boundaries and coverage.

## Lighting and reflections

`OceanLighting` accepts existing `AtmosphereLuts` or a native
`VolumeEnvironmentMap`. Atmosphere lighting uses the shared lookup equations for
sun attenuation, sky irradiance and directional reflected sky. Rough atmospheric
reflection uses a five-direction approximation. The volume environment path uses
its preconvolved roughness slices. Standalone sky/ground colors provide an explicit
hemispherical approximation for isolated scenes. If your environment includes a
solar disc, set `sunIrradiance` to zero to avoid adding a second analytic sun.

`OceanLighting.fromAtmosphereSample` reuses the shared CPU lighting sampler when
you only need sun and hemispherical sky lighting. Supply the LUTs as well when you
want the directional sky in the native shader. Directions use ECEF.

Reflection modes are `disabled`, `environment` and `screenSpace`. Screen-space
tracing uses current opaque depth, bounded distance, five hit-refinement probes,
edge confidence and thickness rejection. Missing or uncertain hits blend to the
environment. There is no temporal history to retain a removed object. Rough
reflections fade toward the environment; the scene hit is not a convolved scene
reflection. Transparent objects and other scene-input consumers are absent from
this capture.

`effectiveSteps(width, height)` reports the actual trace count. Large viewports
reduce steps to keep worst-case depth probes within
`pixelBudget * (stepLimit + 5)`. A zero result uses only the environment. The
optional `planar` mode throws `UnsupportedError` until a generic native secondary
view lease exists. It never falls back under the planar label.

Refraction rejects foreground depth and bounds the water path by
`maximumPathMetres`. The homogeneous source term excludes multiple scattering
and shadowed light-path integration. The capture precedes atmosphere and display
postprocessing; the material does not fog captured radiance a second time.
Underwater camera-volume integration, caustics, foam and spray follow in later
stages. Do not treat a backface refraction path as complete underwater rendering.

## Qualification

The native macOS checks cover analytic optical depth, HDR environment retention,
atmosphere day/night, reflection removal, standard/reversed depth, rigid/morphed
meshes, fixed-chart fields at poles/overlaps and displaced LOD seams. The measured
shared-edge gap in the 32 m test sphere was below 1.9 micrometres. That is a fixture
result, not a global error bound or a performance claim.

`OceanWaterDebug` exposes normals, normalized water-path length and reflection
confidence. `debugSurface` and `debugStencilOffsets` perform bounded explicit GPU
readback for qualification. They are not physical-query APIs.

See the [optics evidence](../../../qualification/2026-10-03/ocean-optics.md) for
captures, commands and remaining visual/device checks. Physical buoyancy and the
full professional-water acceptance gate remain open.
