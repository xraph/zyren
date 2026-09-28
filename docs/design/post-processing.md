# Post-processing

Install one plugin per view and enable HDR color:

```dart
final effects = PostProcessing(
  bloom: BloomOptions(threshold: 1, intensity: .6, radius: 1),
  antialias: true,
);
final controller = SceneController(
  colorPipeline: ColorPipeline(sampleCount: 4),
)..use(effects);

// Uniform edits keep the compiled graph and its targets.
effects.bloom = BloomOptions(threshold: 1.5, intensity: .4);
// Removing bloom rebuilds the graph and retires its allocations.
effects.bloom = null;
```

Bloom extracts bright linear light into a half-resolution texture, applies a
separable nine-tap Gaussian blur, then adds the result before tone mapping. The
threshold is a linear light value. Knee softens the threshold between 0 and 1;
radius controls tap spacing from 0.5 to 4 half-resolution pixels. This is a
single-scale bloom, not UnrealBloomPass's multi-scale implementation.

Blurred color is alpha-weighted. On transparent output, the glow expands alpha
so you can composite its halo in Flutter. Zero intensity returns the original
pixels. Opaque backgrounds remain opaque.

Spatial AA is an optional, edge-aware filter. It compares local luminance and
alpha contrast, filters along the edge, then restores straight color. It can
soften shader and texture edges that MSAA leaves untouched. It has no temporal
history and does not claim FXAA, SMAA or TAA parity.

All effects run after MSAA resolve and before the terminal tone map. Your other
effects can order themselves with `after`, using this plugin's configurable ID.
The implementation uses the public graph, shader and resource APIs. It doesn't
need native renderer hooks or the geospatial package.

The default intermediate allowance is 64 MiB per effect graph. Bloom needs three
half-resolution textures and one full-resolution texture; spatial AA adds one
full-resolution texture. Each texel uses eight bytes. This allowance excludes
scene input, environment maps, MSAA attachments and the previous graph, which
stays alive during replacement. The device's shared resource allowance is also
enforced. Reduce viewport resolution or disable an effect if either limit is hit.

Run the native demo from `examples/shader_lab`:

```sh
flutter run -d macos -t lib/post_processing.dart
```

The demo uses half the display pixel density to leave room for graph replacement.
Its controls switch bloom, spatial AA and four-sample MSAA without restarting the
view. The native Metal integration covers toggles and 320/960 logical-pixel
layouts, with zero presentation readback. Vulkan and DX12 still need device runs.
