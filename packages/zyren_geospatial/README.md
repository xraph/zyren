# Zyren geospatial

Geospatial coordinates, globe controls, terrain streaming and atmospheric
rendering for Zyren's native renderer. Add `GeospatialPlugin` before plugins
that depend on its ellipsoid reference.

Inspired by [Takram's three-geospatial](https://github.com/takram-design-engineering/three-geospatial),
whose source code and examples guided our implementation of geospatial maths,
atmosphere and cloud rendering for Dart and Flutter. Thank you to its authors
and contributors. See the [third-party notices](../../THIRD_PARTY_NOTICES.md#three-geospatial)
for attribution and license details for adapted code.

## Extensions and headless layers

Install `geospatial.scenePlugins` when you configure extensions. The list retains
plugin identity across builds, and composition validation rejects missing adapters
before creating a renderer or detaching your current plugins.

```dart
class SurveyExtension extends GeospatialExtension {
  @override
  String get localId => 'survey';

  @override
  void attachGeospatial(GeospatialContext context) {
    context.registerLayer(GeoLayer(
      id: 'survey',
      owner: id,
      kind: 'survey',
      capabilities: {GeoLayerCapability.query},
    ));
  }
}

final geospatial = GeospatialPlugin(extensions: [SurveyExtension()]);
// Pass geospatial.scenePlugins to SceneEngine or SceneCanvas.
```

This registers layer metadata. Your extension supplies its rendering and queries
through its own core `sceneContext`. If you expose ordinary scene plugin adapters,
give them IDs beneath the extension ID, make them depend on it, and return stable
instances from `adapters`. Each receives its own attachment scope.

Call `context.provide(GeoServiceKey<YourType>('name', 1), service)` for an optional
capability. Consumers use `context.find(key)` and can subscribe to
`registry.capabilityChanges` through their attachment scope. Required dependencies
use full scene plugin IDs. Detaching a provider withdraws only its registrations;
failed updates expose the surviving IDs through `PluginUpdateException`.

You can control layers without building any widgets:

```dart
final layers = geospatial.layers;
layers.transact(layers.revision, (edit) {
  edit.setVisible('survey', false);
  edit.select([GeoFeatureId('survey', 'point-42')]);
});
```

Transactions publish one immutable revision. Stale revisions, invalid parents,
cycles and unsupported opacity leave the previous snapshot intact. Selection holds
layer/feature IDs and clears removed references in the same transaction. Sibling
order does not override depth testing. Group opacity multiplies child opacity and
requires every affected content layer to support it.

Visibility, query access and readiness are separate. Hidden layers retain data
and continue simulation by default; set `GeoLayerPolicies` explicitly when your
adapter supports another policy. Queries can opt into hidden content. Distance,
scale and time filters affect `visibleAt`; they do not advance simulation or infer
that a source is ready. Coverage can be unknown, and dateline bounds retain their
crossing. `empty`, `unavailable` and `failed` remain distinct data states.

Use `layers.beginLoad(id)` to guard source completions. A superseded, cancelled or
removed generation returns false from `publish`. Scope layer registrations through
`context.registerLayer` so a partial attachment failure removes owned layers.

`GeoLayerCodec(layers)` encodes and restores JSON configuration. Register a
`GeoLayerConfigurationCodec<T>` for each custom kind and provide one-step schema
migrations. Unknown kinds and unsupported versions retain their original
configuration with a diagnostic and unavailable data state. Saved readiness is
never treated as a completed load. Documents reject credentials, live handles,
nonfinite values and excessive nesting or size before publication. Keep source
credentials in your resolver. The codec stores configuration; persistent resource
caching and offline regions are separate services.

## Cameras and visual contributions

Install as many `GlobeCameraExtension` instances as your view needs, then call
`geospatial.cameras.activate('detail')` to switch. The first attached rig starts
active. Each rig keeps its own camera state; switching cancels the old gesture
owner before the new rig accepts input. Removing the active rig selects the
remaining rig with the first sorted ID. Legacy standalone controls still work,
but cannot share a view with these managed rigs.
Managed globe rigs currently require a perspective camera.

You can modify a pose without owning another frame loop:

```dart
context.sceneContext.scope.keep(context.cameras.registerModifier(
  'inspection-offset',
  20,
  (pose) => pose.copyWith(position: pose.position + offset),
  components: {GeoCameraComponent.position},
));
```

Lower priorities run first. Equal priorities use the modifier ID, so registration
order cannot change the result. The controller rejects edits to undeclared
components, applies the active rig's constraints and validates the complete pose
before publication. Globe rigs use the existing terrain-clearance query after
modifiers. Their base pose remains independent of visual offsets, avoiding drift
across frames. `GeoCameraRig` lets you install another rig through an ordinary
scene plugin and publish only while its ID is active.

`GeoVisualRegistry` keeps versioned `GeoVisualStyle` configuration separate from
image effects. Keep style registration tokens in your attachment scope. Add real
GPU work with `visuals.addEffect`, `addCompute` or `addRender`, passing your own
`PluginContext` and a `GeoVisualPass`. These methods register with the existing
shared native graph and return a scoped `GeoVisualRegistration`; you can toggle
`enabled` or invalidate a changed layout without taking ownership of composition.

Pass contracts declare required native features, depth convention, alpha handling,
output lifetime and exclusive capabilities. Shader colour values are linear.
Names and dependency sets must agree with GPU descriptors, and explicit dependency
edges stay within one graph stage. Install named dependencies through the same
registry. Validation rejects missing passes, cycles and conflicting owners;
core still checks resources, hazards and final composition ownership. The native
fixture in `test/extensions/native_visual_test.dart` executes two ordered colour
passes and verifies their output and cleanup at two sizes.

Open **Layer lab** from the Planet example, or run
`flutter run -d macos -t lib/layers/main.dart` inside `examples/planet`.
You can switch cameras, hide either terrain layer or the sky, fail and retry the
east source, then save your layout. Restart the view to restore it from the app's
support directory. This uses procedural regional terrain, with no provider key.
The geospatial package itself stays free of widgets and platform storage paths.

Extensions can claim matching restored definitions once through
`context.registerLayer`. Saved visibility, ordering, filters and policies survive;
capabilities and readiness come from the real adapter. Resolve a different source
or configuration before installing its extension. Registration rejects mismatches
rather than labelling old renderer data as the restored source.

## World frames and simulation time

`GeospatialPlugin` provides `clock`, `worldFrame` and `heightProvider`, also
available from each extension's context. Its local frame defaults to east/north/up
at longitude and latitude zero; pass an `origin` for your working area. Terrain
rendering continues to use ECEF. Converting a local frame does not silently move
your scene or physics world.

`GeoWorldFrame` converts positions and rotates vectors independently. A rebase
publishes its old-to-new transform and revisions before the new frame becomes
current. Apply `transformPosition` to local positions and `transformVector` to
velocities or forces. Keep rebase listeners in your attachment scope. The default
height provider supports ellipsoid-height identity only. Mean sea level and
terrain elevation require a provider and otherwise return unavailable.

Acquire one driver for a simulation graph and one for its clock:

```dart
final clockDriver = geospatial.clock.acquireDriver('world');
final simulation = GeoSimulation(systems: worldSystems);
final driver = simulation.acquireDriver('world');
await driver.advance(clockDriver, elapsedSinceLastUpdate);
```

Call this from the application simulation loop. Rendering does not advance it.
Systems run in deterministic sample, force, integrate, interaction and publication
phases, with dependencies inside those phases. You can declare a required tick
rate and catch-up limit per system. The smallest limit applies. Clocks retain
integer tick identity, expose dropped ticks and interpolation fraction, and accept
rational speed changes. Pausing discards pending fractional wall time; explicit
`step` still supports single stepping.

When a game session already owns time, pass its tick to `GeoExternalClock.accept`
and use `driver.step(externalClock.instant)` only when a new tick was accepted.
Do not advance a second clock or step the physics world again. The Planet
`geospatial_clock_test.dart` exercises this arrangement with the existing game
session and native physics, then renders camera-only frames without moving the
body or advancing the game tick.

Failures report the completed systems and block further steps. They do not roll
back solver state. Replay needs a newer generation and a real `restore` operation
on every participating system; call `beginReplay` with the restored checkpoint.
A driver holds ownership until an asynchronous step drains after disposal. Await
`driver.whenClosed` before replacing it. Advancement reserves its clock until the
pending work drains too, preventing another consumer from moving time mid-step.

`GeoSample<T>` carries availability, units, frame/source revisions and a tick.
Use `isCurrent` before feeding a sample into another solver. Unknown age fails a
requested age bound. UTC, TAI and TT are explicit time-standard labels; these
contracts do not provide leap-second conversion or ephemeris data. Camera updates
cannot change a sample's provenance or make an unavailable field valid.

## Built-in layer adapters

Use `TerrainExtension` for independently owned terrain sources, with optional
imagery layers that participate in the headless layer controller:

```dart
final geospatial = GeospatialPlugin(extensions: [
  TerrainExtension(
    id: 'ground',
    source: elevationSource,
    imagery: [
      GeoImageryLayer(id: 'survey-imagery', source: surveyImagery),
    ],
  ),
  AtmosphereExtension(id: 'sky', date: DateTime.utc(2026, 3, 20, 12)),
  GlobeCameraExtension(id: 'camera'),
]);
```

`ground`, `survey-imagery` and `sky` are layer IDs. Adapter plugin IDs use the
extension prefix, so two terrain extensions can retain separate sources, groups,
failures and caches. `TerrainExtension.pick` returns geodetic hits with stable
layer/tile IDs and source revision. It honors query policy, including explicit
queries of hidden retained data.

Change imagery opacity and sibling order through the controller. The existing
CPU imagery worker recomposes an immutable source generation. Old coverage stays
visible while the replacement loads or fails. Replacement bytes count against the
terrain budget; when there is not enough room for both generations, the previous
coverage stays visible and streaming statistics report the budget limit. Imagery
layer readiness follows the composed terrain result, with credits limited to that
imagery source. Elevation layers do not advertise opacity.

`setImageryStack` accepts an increasing revision for application-owned stacks.
Use the registered imagery layers when you want the layer controller to own that
stack. Obsolete loads are cancelled. Retry source failures with
`TerrainExtension.retryFailed()`.

Hiding terrain retains its CPU tile cache by default and stops view-driven loads.
The release policy clears it. Removing the layer stops its rendering and queries.
Hiding an atmosphere layer removes its screen effect while retaining its lighting
tables for sampling, and showing it restores the effect. These APIs use the
existing native renderers and do not create a layer panel.

Standalone `TerrainPlugin`, `GlobeControlsPlugin` and `AtmospherePlugin`
constructors retain their original IDs and behavior. Do not install a standalone
plugin alongside its equivalent extension. Atmosphere and the default camera rig
have exclusive providers. Cloud integrations that require the standalone
`atmosphere` plugin ID need an explicitly compatible adapter before using the
namespaced atmosphere extension.

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

Imported tables use hardware interpolation, including the depth axis of the
scattering volume. Generated 32-bit tables keep manual interpolation to retain
their precision. Set `luts.shader(hardwareFiltering: false)` when you need the
manual path for comparison. Native source checks cover both packed and full Mie
tables, with and without a separate higher-order table.

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

Enable `moonLight` for surface lighting from the current lunar direction and
phase. `moonLightIntensity` defaults to 1, using the full-moon irradiance scale
already used by the sky disk. Larger values help you view night-side albedo at
daytime exposure. This control is independent of `moonIntensity`, which changes
the disk. Moonlight uses atmospheric attenuation and surface normals, with a
Lambert-sphere phase approximation. The solar cloud shadow map is not applied
to lunar rays.

`nightLightIntensity` adds optional night-side fill as a fraction of sunlight,
fading out through twilight. It defaults to zero. Set it when you need terrain
to remain visible with a new Moon or the Moon below the horizon. For example:

```dart
AtmosphereAppearance(
  sunLight: true,
  skyLight: true,
  moonLight: true,
  moonLightIntensity: 5000,
  nightLightIntensity: .02,
)
```

This example favors visibility. Set `moonLightIntensity: 1` and
`nightLightIntensity: 0` for the natural lunar scale. Existing lighting masks
and normal inputs apply to both controls.

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

`CloudTextureGenerator(scope).generate(kind)` produces native weather, shape,
detail and curl-turbulence textures. Default sizes are 512 square, 128 cubed,
32 cubed and 128 square. You can request smaller sizes. Volumes use single-channel
float textures; weather and turbulence use linear RGBA8. Keep each returned
`CloudTexture` until its consumer retains it, then close it when you no longer
need it. All four defaults occupy 11,222,256 registry payload bytes, including
their mip chains. This count does not measure physical GPU residency.

Generation admits one job per generator and checks cancellation between batches
of eight volume slices. Cancellation waits for submitted work before cleanup.
Temporary shaders, graphs and buffers retire before the result is returned.
The source sine hash is evaluated once into a pinned 87,552-byte table because
small CPU/GPU sine differences can change cell positions. Perlin/Worley generation
and curl evaluation run on the GPU. Tests compare 256 original GLSL samples and
require identical bytes when you regenerate the same texture on a device.

`CloudTextures` accepts your linear weather, shape, detail and turbulence maps.
You can retain the set in another GPU scope or generate all four with
`CloudTextures.generate(scope)`. Weather and turbulence include native mipmaps;
shape and detail include GPU-generated volume mipmaps. Sampling blends repeated
trilinear levels using the projected pixel footprint, keeping close detail while
filtering distant noise. Weather levels use weather texture dimensions.
Source volumes retain their original 8-bit density values in filterable linear
textures. The GPU interpolates them directly; caller-provided float volumes keep
explicit interpolation. Procedural float generation keeps its source precision.

`CloudAppearance` keeps source phase, powder and haze settings separate from
layer density. `CloudShadowCascades.build()` computes the source frustum splits
and texel-snapped projections in double precision, including orthographic views.
The internal Beer shadow atlas preserves front depth, mean extinction and the
optical-depth tail.

Add `CloudPlugin` after `AtmospherePlugin` to render the layers. It generates
textures when you don't supply them. You can change coverage and appearance on
the controller, then use `setTextures` or `setQuality` for asynchronous changes
that keep the current view until the replacement is ready.

Use `CloudParameters.densityMultiplier` to thin every layer while preserving its
relative density, altitude and coverage. The default is 1; 0 removes layer
extinction. Values from 0 through 100 are accepted. Cloud rendering and cloud
shadows share this multiplier; the separate haze settings stay unchanged.

Use `CloudParameters.sparsity` to reduce how much of the sky has clouds. You can
set it from 0 to 1: 0 keeps your base coverage, and 1 clears the cloud layers.
The renderer uses `effectiveCoverage`, calculated as `coverage * (1 - sparsity)`,
for both clouds and their shadows. Layer density coefficients and haze stay
unchanged. The default is 0, so existing presets keep their coverage.

You can pause weather, shape and detail motion with `animationEnabled: false`
when you create the plugin, or change it on the attached controller:

```dart
layer.controller.parameters = layer.controller.parameters.copyWith(
  densityMultiplier: .5,
  sparsity: .5,
);
layer.controller.animationEnabled = false;
// Resume from the frozen cloud position with the same velocities.
layer.controller.animationEnabled = true;
```

Paused clouds still refine the image and respond to camera, lighting and quality
changes. Once the Bayer cycle finishes, they release their continuous frame
demand. Motion uses accumulated frame delta, so a long pause does not move the
clouds forward when you resume. `animationElapsed` reports that active time.
Temporal history uses the same clock, so a wall-time gap does not discard a
paused cloud image. Camera, lighting and parameter changes still reject stale
history.

```dart
CloudPlugin(
  quality: CloudQualityPreset.medium,
  maxResolution: 384,
  shadowMapSize: 256,
)
```

Clouds clip against scene geometry and use the atmosphere's date, lighting tables
and world frame. Lunar direct light, sky light and ground bounce follow
`AtmosphereAppearance.moonLight` and `moonLightIntensity`; `nightLightIntensity`
also fills cloud volumes. Lunar phase and the Sun's horizon fade use the same
rules as globe tiles. Moonlight has its own secondary optical-depth ray.
The producer runs before atmosphere composition, which applies
cloud shadows to direct aerial lighting. High and ultra quality need more memory.
Set a smaller shadow map when your scene also retains terrain or 3D tiles; failed
allocations leave the current maps installed. The default 384-pixel target cap
leaves room for history and resize replacement within the native resource budget.
If you raise it, budget for both the active and replacement maps.

`maxResolution` accepts up to 4096 pixels. `maxPixels` bounds the total cloud
target area independently of orientation and defaults to 1,048,576 pixels.
Device defaults choose Medium at 768 pixels on phones, High at 1536 on tablets,
and High at 1920 on desktops. Their pixel budgets are 589,824, 1,572,864 and
2,097,152 respectively. You can override either limit for your scene and device.

You can start with a device profile, then override its sampling preset:

```dart
final settings = CloudQualitySettings.forDevice(CloudDeviceType.phone);
final layer = CloudPlugin(
  quality: settings.preset,
  maxResolution: settings.maxResolution,
  maxPixels: settings.maxPixels,
  shadowMapSize: settings.shadowMapSize,
);
// After the layer attaches to your scene:
await layer.controller.setQualitySettings(
  CloudQualitySettings.forDevice(
    CloudDeviceType.phone,
    preset: CloudQualityPreset.high,
  ),
);
```

Low uses a 512-pixel cloud edge. Ultra allows 1920 pixels on phones, 2560 on
tablets and 4096 on desktop, with area limits of 2, 4 and 8 Mi pixels respectively.
Targets also stay within the scene viewport. These profiles retain the source ray-marching presets while
bounding shadow maps to 128 pixels, or 192/256 for mobile/desktop Ultra. Choose
your device class in the application and tune these limits for its GPU and scene.

`setQualitySettings` changes the preset, cloud resolution and shadow-map limit
together. The controller keeps its previous settings if allocation fails. A
successful change restarts temporal refinement; selecting the same settings
preserves history. `setQuality` changes only the sampling preset and retains your
current limits. You can inspect `settings`, `width` and `height` on the controller.

Temporal reconstruction defaults to the source's 4x4 Bayer upscaling. Use
`CloudTemporalSettings(mode: CloudTemporalMode.antialias)` for full-resolution
temporal sampling, or `CloudTemporalMode.off` to inspect a single frame. The
controller's `setTemporal` replaces those resources atomically. Cloud history
uses source variance clipping, nearest-depth motion and alpha 0.1; shadow history
uses nine samples and alpha 0.01, with filtering kept inside each cascade.

Ordinary camera and weather motion retain history. Resize, projection changes,
large camera moves, time jumps, lighting changes and parameter edits reset it.
Call `controller.resetHistory()` after a scene cut, or increment your scene's
`RenderSettings.historyEpoch`. You can inspect `controller.history` to check the
last reset reason and successful frame count. Static clouds request 16 frames to
fill the Bayer pattern, then release their frame demand.

For source blue noise, pass the result of
`CloudBlueNoise.load(services: services, cancellation: cancellation)` as
`CloudPlugin.blueNoise`. You can also supply the pinned 128x128x64 raw bytes to
`CloudBlueNoise(bytes)`. A packed read-only buffer holds the samples without using
another texture slot. Scenes without that asset use deterministic, frame-varying
interleaved gradient noise.

You can let the plugin load both pinned asset sets during attachment:

```dart
CloudPlugin(
  source: CloudTextureSource.upstream(services: services),
  blueNoiseSource: CloudBlueNoiseSource(services: services),
  maxResolution: 192,
  shadowMapSize: 128,
  shadowFarScale: .25,
)
```

The plugin owns these resources and releases them if initialization fails.
Choose either `source` or `textures`, and either `blueNoiseSource` or `blueNoise`.
`shadowFarScale` limits the shadow cascades to that fraction of the camera range.

For the original textures, use `CloudTextureSource.upstream(services: services)`
with your resolver and image decoder, then call
`CloudTextures.load(scope, source, cancellation: cancellation)`. You can host the
same four filenames under your own directory URI. The loader validates the
512-square weather PNG, 128-cubed shape bytes, 32-cubed detail bytes and 128-square
turbulence PNG, flips image rows to match the source and uploads complete linear
textures. Close the returned set after the plugin retains it. Reads, decoding and
upload respect cancellation, and source errors omit endpoint details.

You can register cloud outputs through `AtmosphereController.registerCloudInputs`.
The returned registration owns retained color, depth/velocity/shadow-length and
transmittance maps. Cloud color composites before your aerial overlay. Closing
that registration leaves your normals, lighting mask and overlay installed.

Cloud transmittance attenuates direct sunlight while preserving skylight. The
atmosphere shader library also exposes `atmosphereSkyShadow` and
`atmosphereSegmentShadow`, with shadow lengths in kilometres. Both preserve the
source's separate handling of higher-order scattering when that table is present.

## Geographic data access

Use `GeoResourceResolver` for encoded terrain, imagery, masks and field resources.
A `GeoResourceKey` includes the dataset and source version, authorization
partition, relative address, representation, decoder version and optional
projection, time slice and derivation. Its digest hashes those typed fields.
Keep transport URLs and credentials in `GeoTransportLocation`, outside the key.

```dart
final memory = MemoryGeoDataStore(maxBytes: 32 << 20, maxEntries: 128);
final transport = GeoByteSourceTransport(
  source: byteSourceResolver,
  locate: locateResource,
  maxBytes: 8 << 20,
);
final resources = GeoResourceResolver(
  store: memory,
  fetch: transport.fetch,
  maxResourceBytes: 8 << 20,
  metadata: sourcePermissions,
  authorize: authorizeResource,
);
final bytes = await resources.read(
  resourceKey,
  GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
  cancellation: cancellation,
);
// Close the resolver before its caller-owned store.
await resources.close();
await memory.close();
```

`offlineOnly` checks authorization, integrity and freshness without constructing
a transport location. Missing bytes return `offlineMiss`. Stale offline reads
require `allowStaleOffline`; stale fallback after transport failure requires
`allowStaleOnTransportFailure`. Neither option overrides a denial, corrupt
response or missing remote resource. Protected partitions require an explicit
authorization callback, which runs again before delivery. The callback is the
application's access decision; a partition label does not prove permission.

`cacheFirst` reuses fresh entries. `networkFirst` tries the source before eligible
cached fallback. `onlineOnly` bypasses cache reads and admission. Source metadata
must explicitly allow persistence before a fetched resource is stored. Offline
export is a separate permission. Store implementations also reject resources
whose response forbids retention.

Compatible requests share physical work. Cancelling one consumer leaves other
consumers active. Cancelling all consumers keeps the physical slot and byte
reservation occupied until transport settles. Limits cover active jobs, each
source, queued jobs, consumers and encoded resource bytes. They do not measure
physical GPU residency or total decoder memory. Custom fetchers must bound their
reads before allocating a response, just as `ByteSourceResolver` does.

The byte-source adapter maps structured HTTP status into stable errors and omits
transport details from public messages. It applies age and expiration bounds,
rejects ambiguous freshness metadata and declines retention for `no-store`,
`no-cache`, revalidation requirements and responses with `Vary`. Public partitions
also decline `private` responses. It does not implement conditional validation
or a general HTTP cache. These conservative rules follow
[RFC 9111](https://www.rfc-editor.org/rfc/rfc9111.html#section-5.2.2).

Removal cancels the old read generation and drains accepted writes before
removing bytes. Closing the resolver waits for physical requests and accepted
store operations. Source errors retain a cause for trusted diagnostics; their
public text contains only a stable error code.
