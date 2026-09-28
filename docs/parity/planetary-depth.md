# Planetary depth precision

Set `camera.depthStrategy = DepthStrategy.reversed` to use reversed floating-point
depth. Check `RenderFeature.reversedDepth` first. The scene engine rejects an
unsupported backend before submission; legacy v1 snapshots reject the mode too.
Standard depth remains the default for existing cameras.

Perspective and orthographic cameras share the native 0..1 clip interval. Standard
depth maps near to zero and far to one; reversed depth maps near to one and far to
zero. Clear values, comparison, transparent ordering and nearest covered MSAA
resolve follow that choice. Camera transitions keep the visible camera's convention
until reaching the destination. Light-space shadow maps retain standard depth.

Keep absolute positions in doubles and local geometry near its origin. The native
renderer still subtracts the camera origin before float conversion. Reversed depth
addresses depth-buffer precision; it cannot recover detail already lost in vertices,
transforms or an excessively coarse terrain mesh.

## Reconstruction

Use `Camera.unprojectPoint` with normalized depth on the CPU. Screen effects can
call `scenePosition(uv, depth)`, `sceneNearDepth()` and
`sceneDepthIsBackground(depth)` from `PostProcessDescriptor.interfaceWgsl`.
UV starts at the top left; reconstructed positions are camera-relative.
`screen.depth.x` identifies the convention. The public uniform now includes a
trailing depth vector; the existing color-output controls keep their meaning.

Atmosphere uses these helpers for haze endpoints, background detection and
orthographic ray origins. Custom render graphs keep their explicit attachment,
projection and comparison settings. A custom camera must implement the selected
projection convention itself.

## Measured fixture

The core fixture uses near 0.1 m and far 1,000,000,000 m. It projects an axial point,
rounds depth to float32, then reconstructs distance using the double-precision
inverse. These are depth quantization measurements, not total GPU geometry error.

| Distance | Standard absolute error | Reversed absolute error | Reversed test budget |
| --- | --- | --- | --- |
| 1 m | 0.000000239 m | 0.000000016 m | 0.000001 m |
| 1 km | 0.167 m | 0.0000288 m | 0.001 m |
| 100 km | 1,320 m | 0.00470 m | 0.01 m |
| 10,000 km | 989,999,917 m | 0.0700 m | 1 m |

The separate Metal pixel fixture includes float32 matrices, GPU projection and
depth testing. At an ECEF origin of (6,378,137, 0, 0), reversed depth correctly
orders planes separated by 1 mm at 1 m and 1 km, 1 m at 100 km, and 10 m at
10,000 km. It passes with one and four samples. Standard depth loses the tested
100 km and 10,000 km separations. This establishes those discrete occlusion
cases, not a universal world-space error bound.

Orthographic projection supports both conventions but does not gain the same
distance-dependent precision. Finite near/far planes are required. Infinite far,
partitioned passes, intersecting transparent geometry and representative global
terrain stress tests remain outside this fixture.

## Native lab

From `examples/planet`:

```sh
flutter run -d macos -t lib/depth_lab.dart
flutter test integration_test/depth_strategy_test.dart -d macos
```

The lab switches between surface, city, horizon and orbit distances, both depth
modes and four-sample rendering. The green plane is nearer than the coral plane.
The terrain and atmosphere labs also opt into reversed depth.

Metal pixel checks cover transparent meshes and instances, explicit depth writes,
custom/PBR materials, sections, clipped shadow casters, MSAA edge depth, screen
reconstruction and atmosphere reference colors in both projections. The macOS
and Pixel 9 Pro native-surface tests pass mode/range changes, MSAA, a 390 × 700
layout and teardown with zero readback bytes or retained sessions/renderers.
Pixel presentation checks do not establish the Metal pixel error measurements
on Vulkan. This slice has not qualified iPhone, Windows or Linux depth precision.

## Verification commands

- `packages/zyren`: `dart test`, 425 passed.
- `packages/zyren_native`: `RUN_NATIVE_GPU=1 dart test --concurrency=1`, 72 passed.
- `packages/zyren_geospatial`: `dart test`, 112 passed.
- `packages/flutter_zyren`: `flutter test`, 89 passed.
- Native Rust: `cargo +1.97.1 test --lib --tests`, 62 passed, 20 device tests ignored.
- Workspace analysis, formatting, package boundaries and Apple ABI header checks pass.

Run the native Dart suite serially. Its renderer-finalization test compares a
process-wide live count, which can change when other test files create devices.
The initial parallel run hit that race; the complete serial run passes.

The reversed-depth atmosphere lab passes day, dusk, night, horizon/orbit changes,
dragging and narrow layouts on macOS. The terrain lab passes detail changes,
offline parent fallback, retry and teardown. Both finish with zero retained
native sessions, renderers or drawables. CUA inspection confirms the depth lab's
standard/reversed horizon comparison and reversed orbit rendering with MSAA.
