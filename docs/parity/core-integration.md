# Core integration checkpoint

The port includes the core work through `4b619c0`: native Android presentation,
scoped GPU resources, binary scene submissions, shared geometry and opaque color
textures. The `dart-core-api` checkout remains separate. Its later commits need
their own integration checks.

The orbit lab selects `SceneRuntime.nativeAndroid()` on Android and
`SceneRuntime.nativeMetal()` on Apple platforms. Both require native
presentation. Other platforms retain explicit readback until their presentation
adapters are qualified.

## Combined checks

- Core: 239 tests, including both upstream orbit replays.
- Geospatial: 17 tests.
- Flutter host and multiple-view examples: 59 tests.
- Native Dart/FFI: 16 tests with GPU execution enabled.
- Rust: 36 tests with the ignored GPU cases enabled; strict host Clippy passes.
- Analyzer, formatting and package-boundary guard pass.

The native orbit integrations exercise perspective and orthographic cameras,
touch continuation, cursor zoom, focus, resize and disposal. The macOS Metal run
presented 16 stdlib and 17 r184 frames. The physical Pixel 9 Pro Vulkan run
presented 15 and 17. Each mode produced eight diagnostic samples. Both platforms
reported zero ordinary readback bytes and zero live native resources after each
teardown. These counters are not frame-rate measurements.

The combined build installs on the iPhone, but its new run is waiting for
on-device developer trust after the previous runner removed Planet. The earlier
iPhone orbit result predates this core integration. Windows remains unrun.

The Android test first failed because the lab still selected readback. It passes
after selecting the public native runtime. Its earlier readback pixel results
remain in [the orbit notes](three-orbit.md); that run used a different presenter.

## Remaining renderer work

The merged texture path supports immutable RGBA8 images and supplied mip levels
on opaque materials. PNG/JPEG decoding, automatic mips, transparent materials,
float/3D textures, public shader pipelines, render graphs and device recovery
remain open. See [resource ownership](../design/gpu-resources.md) and
[Android qualification](../android-presentation-checkpoint.md) for their limits.
