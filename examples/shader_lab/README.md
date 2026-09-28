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
the same GPU device. It does not blend previous frames. Temporal history, HDR
formats and motion/depth rejection remain later renderer work.

The resolution selector scales each physical dimension. Lower it for large or
high-density windows: transactional resize needs space for both texture sets
until the new graph replaces the old one. The native resource budget is 64 MiB.

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
controls, resize and cleanup. The standalone Dart command saves an explicit
readback image for inspection; it is not the app's presentation path.
