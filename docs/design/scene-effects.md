# Compose native HDR effects

Set `scene.renderSettings` to choose HDR, exposure, background alpha and tone
mapping. `ToneMapping.none` clips at the output boundary; `reinhard` and `aces`
compress bright values. The ACES option uses the fitted filmic curve, not an
OCIO color-management pipeline. Existing scenes keep their direct opaque path
until you enable HDR or add an effect.

```dart
scene.renderSettings = RenderSettings(
  hdr: true,
  toneMapping: ToneMapping.aces,
  exposure: 1.2,
);
```

The renderer draws enabled scenes into RGBA16 float color and Depth32 float
depth. Effects run in registration order, followed by optional bloom, exposure,
tone mapping and sRGB conversion. Optional FXAA filters the encoded result.
Readback and native presentation use the same conversion. Transparent output is premultiplied in sRGB for the compositor;
`ImageData.alphaMode` reports that convention. Effects operate on premultiplied
linear color and must preserve that convention themselves.

## Write an effect

Compile a `PostProcessDescriptor` with `context.materials.compileEffect()`.
Include `PostProcessDescriptor.interfaceWgsl` in your WGSL source. It supplies a
fullscreen triangle and group 0 bindings for `sceneColor`, `sceneDepth`,
`historyColor` and `screen`. Add readonly buffers, textures or samplers in groups
1 through 3. A screen shader cannot be assigned to a mesh.

```dart
final effect = await context.materials.compileEffect(
  PostProcessDescriptor(program: program, label: 'my effect'),
);
context.scope.keep(context.scene.addEffect(effect));
```

`scene.effects` lists the configured effects followed by removable registrations.
Changing `renderSettings` leaves registrations intact. Closing an attachment
removes its registrations before closing the compiled shaders. You can also put
an immutable list directly in `RenderSettings.effects`. There are at most eight
active stages per scene.

The native compiler validates the entire fullscreen pipeline before publishing
a candidate. Invalid layouts preserve earlier compiled effects. Effects retain
their shader and resource allocations, just like custom mesh materials. Uniform
uploads change subsequent frames without recompilation.

## Use history deliberately

Each native view owns its previous custom-effect linear HDR result. That result
is saved before built-in bloom, tone mapping and FXAA. Keeping bloom out of
history prevents temporal effects from adding the same halo again. `screen.viewport.z` is 1 when history is valid and 0 when
it must be ignored. The other viewport components contain width, height and
exposure. `screen.inverseViewProjection` reconstructs camera-relative positions
from the depth buffer, whose normalized range is 0 through 1.

Resize, camera position, camera orientation, projection, effect order and render
settings changes invalidate history. Increment `historyEpoch` for a camera cut
or discontinuous edits to effect uniforms or scene content. Ordinary camera
motion currently invalidates too. This conservative rule avoids reusing images
without motion vectors; it does not implement temporal antialiasing.

Two views sharing a scene keep separate histories. Device recreation creates
new invalid history. Closing a view or returning it to the direct path releases
its intermediate targets. `NativeBackend.graphStats().targetBytes` reports these
allocations. A device has a separate 128 MiB target budget, charged at 36 bytes
per HDR pixel per view at one sample, or 84 bytes with four-sample color and
depth targets, plus the bloom pyramid when enabled. Over-budget resize fails
before replacing that view's
targets. Explicit resource allocations retain their existing 64 MiB budget.

## Run the consumer

[`examples/shader_lab`](../../examples/shader_lab) is a separate Dart package.
Its plugin composes a uniform-controlled gain stage and a spatial glow stage,
then exports typed controls to a dependent plugin. It uses public Zyren imports.
From that package, run:

```sh
RUN_NATIVE_GPU=1 fvm dart test
```

Planet's `native_graph_test.dart` combines this plugin with a compute-generated
3D float texture and a custom mesh material. The macOS Metal test passed native
presentation and resize with zero presentation readback and zero native objects
after teardown. Numerical GPU probes cover HDR values above one, both tone-map
curves, depth input, per-view history, camera cuts and premultiplied alpha. Mobile
postprocessing and transparent OS composition still need device qualification.

## Multisample antialiasing

Set `RenderSettings(sampleCount: 4)` for four samples, or leave the default of
one. `backend.capabilities.limits.sampleCounts` reports the adapter's supported
HDR/depth counts. Native backends query those format capabilities when they start;
they do not infer them from the operating system. `NativeGpuContext.deviceInfo()`
exposes the same adapter name, backend and sample counts to host integrations.
Unsupported counts fail explicitly.

Color resolves into the linear HDR image before effects run. A separate depth
pass keeps the nearest covered sample for position reconstruction. At a silhouette,
that depth describes the closest covered surface; it is not an averaged position.
Color retains fractional coverage in its premultiplied alpha. Effects need to keep
that coverage when applying depth-based shading.

The Metal fixture compares fractional edges with single-sample output, verifies
depth reconstruction and checks custom WGSL and instanced PBR pipelines. Resize,
budget rejection, returning to one sample and target cleanup also pass. Four-sample
native presentation and mobile output remain part of final qualification.

## Spatial antialiasing and bloom

```dart
scene.renderSettings = RenderSettings(
  toneMapping: ToneMapping.aces,
  spatialAntialiasing: SpatialAntialiasing.fxaa,
  bloom: BloomSettings(intensity: .15, threshold: 1, levels: 5),
);
```

FXAA uses the luminance and edge-search equations from Three.js r184. It filters
encoded display colors after tone mapping, where its contrast thresholds apply.
The display pass reuses an existing ping-pong image; FXAA adds no image allocation.
For transparent output, alpha contrast can select an edge even when the object is
black. Interpolating premultiplied color and alpha together avoids a dark fringe.
FXAA can soften fine text and shader detail. You can choose it, MSAA, both, or
neither. Motion-vector reprojection and temporal rejection remain follow-up work.

Bloom extracts positive radiance before exposure using the maximum RGB channel,
a linear threshold and a soft knee. Downsampling happens after extraction so a
small bright source survives averaging. A normalized tent pyramid spreads the
light; `scatter` controls the weight of broader levels. Levels range from one
through six and stop at 1x1. Intensity ranges from zero through 16. Zero intensity
skips pyramid allocation. `copyWith(clearBloom: true)` removes the settings.

Each pyramid level has two RGBA16 float images. Starting at half resolution with
rounded-up dimensions, its charge is `16 * sum(levelWidth * levelHeight)` bytes.
This shares the 128 MiB target budget with HDR, history and MSAA. Parameter changes
reuse targets when their size is unchanged. Resize and level changes stage a new
set before replacing the old one.

Bloom retains the original alpha and scales its added radiance by that coverage.
A transparent background therefore clips the halo outside covered pixels. Use an
opaque sky or backdrop when the glow should extend into the background.

The Metal probes cover a constant field across pyramid depths, an analytical
single-level impulse, soft thresholds, pre-exposure extraction, history isolation,
MSAA composition, odd sizes, 1x1 targets, shared views and budget recovery. Four
FXAA fixtures compare the output with a CPU evaluation of pinned Three.js r184
within one byte per channel. The generator is `tool/fxaa_reference.mjs`; its fixture
records the source hash. These checks do not establish mobile presentation parity.
