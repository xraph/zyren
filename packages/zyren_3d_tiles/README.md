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

The default transition retains the displayed cover until a complete replacement
has decoded and its native uploads have published. Each frame shows a complete
cover. Picks and attribution follow that displayed cover, including while uploads
are staged. Style updates build separate instances so they cannot hide displayed
features early. A deferred pick retains its feature properties and source credits
through `featureFor(pick).attributions`.

You can opt into motion selection and a separate CPU prefetch allowance:

```dart
final tiles = Tiles3DPlugin(
  tileset: tileset,
  services: services,
  motionPolicy: const Tiles3DMotionPolicy(),
  budget: Tiles3DBudget(maxPrefetchRequests: 1),
  visibilityPolicy: (bounds, camera) => const EllipsoidHorizon()
      .isSphereVisible(camera.position, bounds.center, bounds.radius),
);
```

The horizon callback is optional. Import `EllipsoidHorizon` from
`zyren_geospatial`. The Earth helper expects ECEF bounds and uses
an ellipsoid lowered by 12 km to stay conservative around terrain. Local datasets
can leave the callback unset or provide their own world-space policy.

Motion prediction lasts 200 ms, looks no further than a quarter of the camera's
target distance, and resets on reversals or large turns. Adjacent prefetch widens
the view by 15 percent. The pixel-error target rises smoothly up to twice your
configured value during motion and recovers over 300 ms. On-demand views request
those settling frames, then return to idle without an animation plugin.

Visible requests run first. Prefetch reserves at most one request with the above
budget, eight tiles and 8 MiB of decoded data, all within the existing request and
CPU limits. Set `maxPrefetchBytes` to at least `perTileDecodedBytes` to admit a
prefetch request. Decoded prefetch is not GPU readiness. `prefetchBytes` includes
physical requests that have been cancelled but have not finished draining.

The resident allowance counts shared assets once across displayed and candidate
covers. Refinement keeps room for a cached complete coarse cover. When two detail
covers cannot overlap, that coarse cover can publish first and release the old
resources. If no complete bridge fits, the old cover remains and `budgetLimited`
is true. This cannot guarantee coverage after an arbitrary camera teleport.
These byte counts describe resource payloads, not measured physical GPU memory.

You can still enable explicit refinement fades when attaching the plugin:

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

Fades default to zero for a stable replacement after publication. Durations can be up to five
seconds. The scheduler admits outgoing and incoming groups only when their
combined residency and tile count fit `Tiles3DBudget`; otherwise it switches
to complete coverage after admission. `isTransitioning` reports active fades. If you
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

If you drive a streamer directly, CPU-only selection remains the default. With
`trackPublication: true`, call `beginFrame()` for the exact candidate you submit
and `completeFrame(stats.admission)` only after successful rendering. A null
receipt preserves synchronous renderer compatibility; it does not confirm native
readiness. Retain the old state on a render failure. `Tiles3DPlugin` manages these
calls and its `PublicationGroup` for you.
