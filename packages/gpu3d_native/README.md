# gpu3d_native

Render gpu3d scenes through native Metal, Vulkan or Direct3D 12. Dart build hooks
compile the bundled Rust crate. You need Rust and the platform toolchain.

`NativeRenderer` implements the existing scene renderer. `NativeBackend` accepts
immutable `FrameSubmission` values through the advanced backend contract. Both
use the same native worker and ABI; neither requires a Flutter engine.

```sh
fvm dart run example/offscreen.dart
fvm dart run example/resources.dart
fvm dart run example/shared_views.dart
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1
```

Run these commands from `packages/gpu3d_native` so the native build hook refreshes
the library. The root workspace has no runtime dependencies of its own.

The example renders a red box and prints the centre pixel. GPU tests require a
compatible device. In PowerShell, set `$env:RUN_NATIVE_GPU = '1'` before running
`fvm dart test`.

The default backend returns explicit RGBA8 sRGB readback. Apple shared textures
require `experimentalAppleSurfaces: true`; they remain experimental because
Flutter's texture cache delays buffer retirement. Flutter's opt-in native view
presenters are documented in the workspace README.

Use `createResourceScope()` for typed buffer and texture allocations on this
backend's device. Scopes support shared references, binary uploads, explicit
readback and deterministic close. See [the resource API and protocol](../../docs/design/gpu-resources.md)
for limits and ownership. Scene geometry uses the same registry with binary
uploads and changed mesh records. `createView()` returns an independent readback
view sharing the device, immutable geometry and material images. Closing a view
releases its scopes and scene references; the last view closes the worker.
Use `TextureImage.rgba` and `TextureMap` for opaque color textures, UV selection,
wrap/filter settings and supplied mip levels. PNG/JPEG decoding is still pending.

Worker requests carry a generation and a monotonic request ID. Worker exit or
error settles every pending request. Stale and duplicate replies are ignored.
Explicit close remains the normal path; native finalization also releases the
handle if the worker exits before it receives a dispose request. The opt-in
finalization test checks the process-local handle count with a real GPU device.
