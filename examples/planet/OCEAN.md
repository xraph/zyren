# Ocean Lab

You can inspect six saved scenes: open water, storm swell, shallow coast, a
buoyant vessel, underwater transport and an orbit-to-surface camera route.
The scene definitions pin the sea-state seed, epoch, camera and fixture revision.

Run with the workspace Flutter 3.47.5 SDK:

```sh
cd examples/planet
fvm flutter run -d macos
```

Choose Ocean in the launcher, then open a saved scene.

The app requests native Metal views on macOS/iOS and native Vulkan surfaces on
Android. Windows/Linux use the native renderer with its available presentation
path. These platform projects do not establish device qualification.

Use the scene selector to rebuild the world. Detail changes are queued for the
next water frame; the status bar shows the applied FFT resolution. Debug selection
restarts the scene so you can compare the same saved initial state. Drag and scroll
navigate the globe, and the orbit scene supplies a 30-second camera route.

The four detail choices are custom lab profiles: 16/32/64/128 wave grids, one band
and 96/192/384/768 patch caps. They are not the package's stock quality presets.
Every scene keeps a canonical 128 grid and a 60 Hz simulation owner. Lowering
visual detail does not alter that physical model.

The shallow coast is an owned synthetic fixture with revision
`ocean-lab-coast-1`. Its height, depth and water-mask resources pass through the
region manifest, checksum and offline resolver. On restart, rendering and queries
consume the stored bytes. No real geographic coastline is bundled.

## Checks and captures

```sh
fvm dart test test/ocean_scenes_test.dart
RUN_NATIVE_GPU=1 fvm dart test test/ocean_native_scenes_test.dart --concurrency=1
fvm flutter test test/ocean_layout_test.dart
fvm flutter test integration_test/ocean_lab_test.dart -d macos
fvm dart run tool/ocean_benchmark.dart --output=/tmp/ocean-lab --frames=60 --width=1280 --height=720 --detail=balanced
```

The benchmark writes PNGs and JSON. You can select `--scene=vessel`,
`--debug=foam` or `--motion=true`. Five warmup frames are excluded from timing
percentiles. Whole-frame host readback includes submission and GPU completion
waits. The JSON keeps unavailable isolated-water timing and physical residency
measurements null.

See [qualification](../../qualification/2026-10-04/ocean-lab.md) for the current
results and failures. Visual acceptance, performance targets and real Earth data
remain open. The procedural vessel is a buoyancy fixture; it is not finished
marine artwork.
