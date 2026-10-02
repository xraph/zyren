# Zyren effects

Optional native screen effects over the public Zyren resource and material APIs.
You can use them without geospatial or Flutter dependencies.

```dart
final lookup = HaldLookup.fromImage(decodedImage);
final grading = await ColorGradingEffect.create(
  gpuScope,
  lut: lookup,
  interpolation: HaldInterpolation.tetrahedral,
);
final slot = scene.addEffect(grading.effect);

// Build a replacement first, then replace the registration and retire its owner.
slot.dispose();
await grading.close();
```

Hald images must be square and contain a cubic grid with 2 to 64 voxels per
axis. The loader preserves raw encoded color values and source voxel order,
accepts padded RGBA/BGRA rows, copies the pixels and rejects premultiplied input.
Trilinear interpolation is the default; tetrahedral interpolation follows
postprocessing 6.39.1. Grading preserves scene alpha and runs after exposure and
tone mapping. `intensity` ranges from zero to one.

`DitheringEffect.create(gpuScope)` reproduces the Three.js r184 RGB dither in
linear color. Register it after grading and custom antialiasing. Its noise stays
fixed to the viewport; sine precision can change the pattern between GPU
backends. Tests check the source amplitude, channel correlation and repeatability.
The native source fixtures also cover 192 Hald interpolation cases, transparent
coverage, resize, invalid inputs and scoped cleanup.

Run native checks with `RUN_NATIVE_GPU=1 dart test --concurrency=1`.
