# Zyren geospatial

Geospatial coordinates, globe controls, terrain streaming and atmospheric
rendering for Zyren's native renderer. Add `GeospatialPlugin` before plugins
that depend on its ellipsoid reference.

## Terrain imagery

Wrap your terrain source to apply geographic or Web Mercator imagery:

```dart
final imagery = TemplateImagerySource(
  baseUri: imageryEndpoint,
  template: '{z}/{x}/{y}.png',
  datasetId: 'survey-2026',
  services: assetServices,
  attribution: 'Your imagery provider',
);
final terrain = TerrainPlugin(
  source: ImageryTerrainSource(
    terrain: elevationSource,
    layers: [ImageryLayer(imagery)],
  ),
);
```

Supply a resolver and CPU image decoder through `AssetServices`. Keep credentials
in your resolver; dataset IDs and versions are public labels. Templates support
`{z}`, `{x}` and `{y}`. URLs default to north-origin XYZ rows; set
`urlScheme: ImageryUrlScheme.tms` for south-origin rows. The public coordinates
remain south-origin in both cases.

Imagery is reprojected into the terrain's existing geographic UVs on a CPU
worker. Geometry, skirts and picking stay intact. Layers use linear-light,
premultiplied-alpha composition and retain their order. You can configure up to
four layers, each with an opacity and a level offset. Set a positive offset when
a regional terrain source starts at level zero but its imagery uses global zooms.
Web Mercator imagery leaves polar regions covered by the terrain's base image.

`outputSize` defaults to 256 and can be 2-2048. Source tiles must match their
declared square `tileSize`. The source reduces imagery detail until the region
fits `maxTilesPerLayer` (2-16, default 4). Upload and decoded payload estimates
include composition storage and generated mips. These limits do not cap process
memory. CPU decoding and composition each admit two jobs per caller isolate,
with sixteen queued jobs; canceled physical work keeps its reservation until it
settles.

The terrain scheduler retains parent coverage until child geometry and imagery
both load. Failed reads appear in `TerrainPlugin.failures`; call `retryFailed()`
after fixing access or connectivity. Display `TerrainPlugin.attributions` beside
the viewport. It contains credits for visible terrain and imagery, excluding
zero-opacity layers.

Native tests use local HTTP fixtures for decoding, parent fallback, retry and
resource cleanup. Provider access and provider-specific requirements need their
own live qualification.

## Terrain metadata

`QuantizedMeshTerrainSource` supports EPSG:4326/TMS layers with static ranges or
`metadataAvailability`. Dynamic layers start with two roots. A validated mesh
response makes its advertised descendants available on the next selection pass;
`availabilityOf()` distinguishes unknown coverage from an unavailable tile.
The source requests advertised normals, water masks and metadata through both
Accept and the extensions query parameter.

Sparse siblings retain their parent. Fill tiles and `parentUrl` layer stacks are
not supported. Availability is stable for a source version: a changed metadata
page fails rather than mixing generations. Replace the source when the dataset
changes. Missing required metadata also fails and follows the normal retry path.

You can set `maxAvailabilityPages` and `maxAvailabilityRanges` when opening a
source. Defaults are 1,024 pages and 16,384 ranges, retained for the source lifetime
separately from the tile cache. A full metadata store stops further refinement
with a limit error. Each mesh also has `maxMetadataBytes` (64 KiB by default) and
`maxMetadataRanges` (1,024) decoder limits. Payload reservations include masks,
parsed ranges and credits; temporary JSON parsing is bounded by bytes and depth.

`TerrainTile.waterMask` contains one uniform byte or a north-first 256 by 256
coverage grid, where 0 is land and 255 is water. Values between them preserve
soft coastlines. `TerrainTile.availability` retains immutable relative-level
ranges. Imagery composition preserves both fields and the provider's credits.
These are CPU values; a water mask alone does not add a reflective water pass.

## Draped overlays

Wrap your imagery source with `OverlayTerrainSource` to tint water and draw
polygons or lines on the terrain:

```dart
final source = OverlayTerrainSource(
  terrain: imageryTerrain,
  overlays: [
    WaterTintOverlay(color: Color3.hex(0x247ba0), opacity: 0.6),
    TerrainPolylineOverlay(
      points: surveyBoundary,
      color: Color3.hex(0xffdd55),
      width: 3,
    ),
  ],
);
```

Layers draw in list order. `TerrainPolygonOverlay.rings` starts with an outer
ring, followed by holes. Supply `Geodetic` coordinates; heights are ignored
because these shapes drape on the existing mesh. Segments are straight in
longitude/latitude, take the shorter path across the dateline, and clip at tile
edges. Split paths that span half the globe or more. Polygon filling uses the
even-odd rule within each ring and subtracts holes.

Line width is in output texture pixels, so its ground width changes with terrain
level. Lines have round caps and joins. Vector edges use four coverage samples
per pixel, and all layers blend in linear light. Water tint uses the provider's
soft coverage mask; without a mask that layer has no effect. It does not animate
waves or reflections. Picking still returns the terrain mesh.

Use `outputSize` (2-1024, default 256) to set the texture resolution. A source
accepts up to 64 overlays and 4,096 vertices, subject to `maxSampleTests`
(default 64 million). The conservative work estimate rejects oversized jobs
before requesting terrain. Imagery and overlays share two CPU worker slots and
sixteen queue positions. Geometry, skirts, metadata and credits remain owned by
the terrain tile. Replace the source to change its immutable overlays.

## Atmosphere table decoding

`AtmosphereTableDecoder` reads raw little-endian RGBA half floats and single-part
scanline EXR files with RGBA HALF channels, full sampling and NONE, ZIPS or ZIP
compression. Supply the expected width, height and depth. EXR rows reverse before
the image is reshaped into volume slices, matching the source loader.

Decoded tables own immutable bytes. Encoded and decoded limits are checked before
allocation, and ZIP output cannot exceed its declared scanline storage. Invalid
headers, duplicate channels or chunks, truncated data and nonfinite samples fail
with a typed load error. Tiled, multipart, deep and other compression profiles
are unsupported. This decoder does not upload a texture by itself.

The optional reference test uses `ZYREN_SOURCE_LUTS` to compare the five pinned
binary/EXR pairs. The upstream exports differ by up to one half-float step, so
that comparison allows one step instead of requiring identical bytes.

To use the upstream tables in a native scene, pass a source to the atmosphere:

```dart
final source = PrecomputedAtmosphereSource.upstream(services: assetServices);
final sky = AtmospherePlugin(date: DateTime.utc(2026, 3, 20, 12), source: source);
```

The pinned upstream source defaults to EXR, packed Mie scattering and a separate
higher-order table. Use `format: AtmosphereLutFormat.binary` for the raw files.
Set `combinedScattering: false` to read the full RGB Mie file. Set
`higherOrderScattering: false` to omit the separate higher-order file; the combined
scattering table still contains multiple scattering. Each mode preserves the
upstream interpolation and short-path Mie reconstruction.

For your own files, construct `PrecomputedAtmosphereSource` with a directory URI,
asset services and the parameters used to compute those files. This layout uses
256 by 64 transmittance, 64 by 16 irradiance and 256 by 128 by 32 scattering.
Keep credentials in your resolver. Limits from `AssetServices` apply alongside
16 MiB per encoded file and 32 MiB per complete encoded or decoded set. Two loads
run at once per caller isolate, with eight queued loads. Cancellation waits for
physical reads and CPU decoding to settle before releasing a slot.

Tables upload as RGBA16 float through public resource scopes. The default source
set uses 16,916,488 GPU bytes, including its unused binding placeholder. Full Mie
plus a separate higher-order table uses 25,305,088 bytes. Account for active and
candidate sets when sizing a scene. Cache entries share only within the same
source instance and device; their keys never contain source URLs.

Use `controller.setSource(source)` to replace tables atomically. A failure keeps
the active view and existing lighting leases. `setParameters()` switches back to
GPU precomputation after generation succeeds. `acquireLighting()` returns the
current set in either mode. Read `luts.dimensions` for both modes; `luts.quality`
is null for imported tables. Close each lease when its consumers retire.

Native checks compare the upstream GLSL runtime with the actual source assets,
render sky and aerial perspective with both depth modes, and check replacement,
cancellation and zero residency after cleanup. Generate the source reference
records with `python3 tool/atmosphere_reference/source_tables.py <asset-directory>`
from the repository root. The script verifies the supplied LFS hashes first.

## Automatic atmosphere lighting

Add `AtmosphereLightingPlugin` after your atmosphere to drive native material
lighting from its current date, observer and tables:

```dart
plugins: [
  sky,
  AtmosphereLightingPlugin(environment: true),
],
```

The default mode supplies a sun light and a diffuse sky probe. With
`environment: true`, native sky capture and GGX convolution also light reflective
materials, and the separate probe defaults off to avoid adding diffuse sky twice.
You can disable the sun or select the probe explicitly. The probe reproduces the
source's hemisphere irradiance function through the core's `HemisphereLight`.
These lights affect `StandardMaterial`; legacy `DiffuseMaterial` keeps its
existing simple lighting model.

`AtmosphereLightingSampler` copies the small transmittance and irradiance tables
once per LUT generation. Its CPU sampling matches the upstream sun/probe helpers,
including their texel interpolation. Frame updates use those copies. HDR light
values are split into bounded RGB and an intensity multiplier, preserving energy.
Adjust `controller.sunIntensity` and `controller.skyIntensity`; the controller
owns the light colors, directions and physical intensities. You can configure
shadows through `controller.sunLight`.

The environment captures world-oriented atmospheric radiance with ground enabled
by default and excludes sun, moon and star disks. It updates after a LUT change,
a change of the observer's rounded 1 km ECEF cell, or a sun-direction change over
0.1 degrees. Camera rotation reuses it. You can change these thresholds and the
bounded capture/convolution settings. Capture height defaults to 64, convolution
height to 32, with eight roughness slices and 128 samples. CPU lighting tables
use 278,528 bytes; candidate GPU environments retire after atomic replacement.

`tableReadbacks` counts completed lighting-table reads, and
`environmentGeneration` counts published sky captures. Changing sky intensity
reuses the textures. Tests check 48 original helper cases, ECEF/local rendering,
day/night lighting, metallic reflections, invalidation thresholds, stable-frame
residency and zero GPU resources after disposal.

## Spectral color integration

Use `SpectralDistribution` for a sampled spectrum over 360-830 nm. You supply
2-1024 increasing wavelengths and nonnegative power values per nanometre.
`toXyz()` integrates the piecewise-linear spectrum against the source's CIE 1931
observer table, using 683 lm/W. `toLinearSrgb()` preserves negative out-of-gamut
channels so you can choose gamut handling when you display the result.

`Cie1931.matching()` exposes the source's interpolated lookup, including its zero
endpoints. Reference checks cover 385 wavelengths and five independently
integrated spectra. This helper does not change the three-channel atmosphere
precompute.

## Aerial perspective

Use `AtmosphereAppearance` to select `transmittance` and `inscatter` separately.
`haze: false` disables both without changing their individual settings. For
unlit albedo, enable `sunLight` or `skyLight` and set `albedoScale` (1 by default).
Leave relighting off for materials that already compute their lighting.

`reconstructNormal` derives camera-facing surface normals from depth. Otherwise,
the effect uses radial normals or a supplied normal map. Enable
`correctGeometricError` to blend positions and normals toward the atmosphere's
sphere as the globe shrinks on screen, following the source's projected-scale
thresholds. This correction is off by default to preserve existing scenes.

You can install maps with `controller.setAerialInputs(AerialPerspectiveInputs(
normal: normals, lightingMask: mask, overlay: overlay))`. Maps use top-left screen
UVs and linear 2D textures. RGB normals encode `.5 * (normal + 1)` in view space;
world-space and signed octahedral float normals are also supported. Zero RGB
normals bypass relighting. Reconstruction takes precedence over the normal map.
The selected mask channel blends existing radiance with relit albedo.

Overlay RGB must be premultiplied by alpha. The effect composites both color and
alpha, including on transparent backgrounds. It retains installed maps across
resize and LUT replacement, so you can close the caller's resource scope once
installation succeeds. Install an empty `AerialPerspectiveInputs()` to clear
them. A failed replacement keeps the previous effect active.

## Cloud configuration

`CloudLayers.defaults()` preserves the source's low, middle and high layers, plus
its disabled fourth weather channel. You can supply up to four immutable
`CloudLayer` values; height zero disables a layer. Altitudes and heights are in
metres. Layer gaps and shadow bounds are derived from those intervals.

`CloudParameters` holds weather coverage, medium coefficients, texture repeats,
offsets and velocities. Volume repeats use inverse metres. Weather and turbulence
repeats use globe UVs. `CloudQuality.forPreset()` exposes the original low,
medium, high and ultra raymarch/shadow settings. The default values and interval
calculations are checked against the original TypeScript. These configuration
types do not attach a cloud renderer by themselves.
