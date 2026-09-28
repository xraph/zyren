# zyren_3d_tiles

Stream 3D Tiles through Zyren's native scene and asset services. The loader
supports explicit and implicit hierarchies, external tilesets, GLB/glTF and b3dm
content. Google Maps and Cesium Ion sessions use caller-provided credentials.
Keep provider attribution visible through `Tiles3DPlugin.attributions`.

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
behavior. Feature metadata and feature styling remain separate work.
