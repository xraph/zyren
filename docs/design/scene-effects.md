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
depth. Effects run in registration order, then one terminal pass applies exposure,
tone mapping and sRGB conversion. Readback and native presentation use the same
conversion. Transparent output is premultiplied in sRGB for the compositor;
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

Each native view owns its previous final linear HDR result. That result is saved
before tone mapping. `screen.viewport.z` is 1 when history is valid and 0 when
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
per HDR pixel per view. Over-budget resize fails before replacing that view's
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

This profile has one sample per pixel. MSAA, a built-in antialiasing stage,
motion-vector reprojection and temporal rejection are not implemented here.
