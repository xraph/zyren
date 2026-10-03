# zyren_3d_tiles

Stream 3D Tiles through Zyren's native scene and asset services. The loader
supports explicit and implicit hierarchies, external tilesets, GLB/glTF and b3dm
content. Google Maps and Cesium Ion sessions use caller-provided credentials.
Keep provider attribution visible through `Tiles3DPlugin.attributions`.

`maximumScreenError` defaults to 8 render pixels. The plugin uses the actual
frame height after the host's resolution cap, while preserving the logical
viewport aspect for culling. Touch dimensions and raw device pixel ratio do not
set the detail level. If you drive `Tiles3DStreamer` directly, pass viewport
metrics with the rendered pixel height and the projection's aspect ratio.

You can enable refinement fades when attaching the plugin:

```dart
final tiles = Tiles3DPlugin(
  tileset: tileset,
  services: services,
  fadeDuration: const Duration(milliseconds: 250),
);
```

The parent stays owned and credited until the child coverage is complete and
the fade ends. Complementary pixel intervals preserve opaque depth behavior
and authored materials. A camera reversal finishes the current transition
before starting the next one. Leaving coverage, replacing the tileset or
disposing the plugin clears the transition.

Fades default to zero for immediate replacement. Durations can be up to five
seconds. The scheduler admits outgoing and incoming groups only when their
combined residency and tile count fit `Tiles3DBudget`; otherwise it switches
directly to complete coverage. `isTransitioning` reports active fades. If you
drive `Tiles3DStreamer` directly, pass monotonically increasing `elapsed` to
`update` for deterministic playback, or omit it to use its stopwatch.

Optional asset codecs provide meshopt, Draco 2.2 and KTX2 Basis support. Flutter's
default services include them. See `zyren_gltf` for format limits and fallback
behavior.

You can style features from b3dm batch tables or glTF structural property tables:

```dart
tiles.setStyle(TileStyle3D((feature) {
  final height = feature.properties['height'];
  return TileFeatureStyle3D(
    show: height is num && height > 20,
    color: const Color3(0.2, 0.6, 1),
  );
}));
```

Styles apply to cached tiles and future arrivals. Call `setStyle(null)` to
restore the authored materials and visibility. Callbacks run once per feature
when a tile arrives or you explicitly restyle it. An exception during restyling
leaves cached instances unchanged. A callback error on arrival appears in
`failures`; correct the style, then call `retryFailed()`.

`featureFor(pick)` returns the picked feature's immutable properties. IDs are
local to a tile. Use `featureLabel` or `featureSet` on `TileStyle3D` to select one
of several feature sets. Color replaces the material's base factor while keeping
its maps; opacity below one enables blending. Hidden features are excluded from
picking. Refinement coverage remains independent of styling.

The loader partitions uniform-feature triangles and points within the glTF
primitive and byte budgets. Mixed IDs within a triangle, feature textures and
feature lines are unsupported. Legacy batch tables support JSON values and
aligned binary scalar/vector columns, with count, range and finite-value checks.
Batch-table hierarchy extensions are unsupported. Modern property-table limits
are documented in `zyren_gltf`.
