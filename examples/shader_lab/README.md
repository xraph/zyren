# Native shader lab

Run the demo to change exposure, saturation and vignette on a native scene. Drag
to orbit, pinch or scroll to zoom, and change resolution to exercise texture
replacement. Switch effects off to compare the original scene.
The middle box uses a custom WGSL material. Change Stripes to update its uniform
without compiling another pipeline. The Effects switch controls post-processing;
the mesh material remains active.

```sh
fvm flutter pub get
fvm flutter run -d macos
# Or select an Android device running API 29 or newer.
fvm flutter run -d DEVICE_ID
```

The app requires native presentation. Metal is selected on Apple platforms and
Vulkan on Android. The other platform folders are scaffolds, not platform
qualification. Windows and Linux still need their own build and device checks.

The separately packaged [effects plugin](effects_plugin/README.md) imports only
the public Dart core API. Its two spatial render passes run after the scene on
the same GPU device. Choose History 50% or 90% to add the separate temporal blend
plugin, then move the camera to see the retained pixels. The adjacent reset button
discards that history. The blend runs continuously while enabled and uses
alpha-weighted linear color. The PBR lab below uses the new HDR color pipeline.
TAA and motion/depth rejection remain later renderer work.

The Scale selector scales each physical dimension. Lower it for large or
high-density windows: transactional resize needs space for both texture sets
until the new graph replaces the old one. Each enabled history also needs two
textures. The native resource budget is 64 MiB.

```sh
fvm flutter test test/app_test.dart
fvm flutter test integration_test/effects_test.dart -d macos
cd effects_plugin
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1
cd example
fvm dart run render.dart /tmp/shader-lab.png
fvm dart build cli --target=render.dart --output=/tmp/shader-lab-cli
```

The integration checks shader pixels, native presentation with zero readback,
controls, resize, history pixels/reset, compute history and cleanup. The standalone Dart command saves an explicit
readback image for inspection; it is not the app's presentation path.

## PBR lab

Run the separate material demo with native presentation:

```sh
fvm flutter run -d macos -t lib/pbr.dart
fvm flutter run --release -d DEVICE_ID -t lib/pbr.dart
fvm flutter test test/pbr_app_test.dart
fvm flutter test integration_test/pbr_test.dart -d macos
fvm flutter test integration_test/pbr_pixels_test.dart -d DEVICE_ID
```

The grid shares one sphere geometry across 12 materials. Roughness increases
left to right (`0.1`, `0.35`, `0.65`, `1`); metallic increases top to bottom (`0`,
`0.5`, `1`). Light changes directional intensity in lux. Angle rotates that light
around Y in radians. A blue point light adds a fixed fill. Ambient controls the
hemisphere light. Exposure adjusts the HDR multiplier; the adjacent selector
chooses ACES, Reinhard or Linear tone mapping. Textures switches the shared base-color, normal, packed
occlusion/roughness/metallic and emissive images on or off. The maps multiply the
grid's material factors. Light edits redraw without uploading geometry or images;
re-enabling released texture maps uploads their pixels again.

The integration checks reference pixels, point falloff, narrow spot cones,
texture masks, negative scale, emission, resource cleanup and native presentation
with zero readback. See [standard materials](../../docs/design/standard-materials.md)
for the implemented parameters and remaining renderer work. `pbr_pixels_test`
runs the native readback assertions without mounting a window. Keep that result
separate from `pbr_test`, which also verifies Flutter controls and presentation.
