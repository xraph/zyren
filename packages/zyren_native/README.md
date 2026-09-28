# Zyren native backend

Render Zyren scenes through native Metal, Vulkan or Direct3D 12. Dart build hooks
compile the bundled Rust crate. You need Rust and the platform toolchain.

`NativeRenderer` implements the existing scene renderer. `NativeBackend` accepts
immutable `FrameSubmission` values through the advanced backend contract. Both
use the same native worker and ABI; neither requires a Flutter engine.

```sh
fvm dart run example/offscreen.dart
fvm dart run example/resources.dart
fvm dart run example/shared_views.dart
fvm dart run example/shader_compiler.dart
fvm dart run example/render_graph.dart /tmp/native-graph.png
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1
```

Run these commands from `packages/zyren_native` so the native build hook refreshes
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
view sharing the device, geometry revisions and material images. Closing a view
releases its scopes and scene references; the last view closes the worker.
Use `TextureImage.rgba` and `TextureMap` for color textures, UV selection,
wrap/filter settings and supplied or native-generated mip levels. Set
`generateMipmaps: true` to build a full chain in linear light on the GPU. `NativeImageDecoder` decodes PNG
and JPEG on a CPU isolate with bounded admission. Dynamic geometry uploads
merged attribute ranges while preserving captures held by other views.

Worker requests carry a generation and a monotonic request ID. Worker exit or
error settles every pending request. Stale and duplicate replies are ignored.
Explicit close remains the normal path; native finalization also releases the
handle if the worker exits before it receives a dispose request. The opt-in
finalization test checks the process-local handle count with a real GPU device.

Use `MaterialAlphaMode.mask` for cutouts or `MaterialAlphaMode.blend` for
source-over transparency. Blended materials sort back to front and leave depth
writes off by default. `Mesh.renderOrder`, `DepthWrite` and `depthTest` let you
override those choices. Run `lib/material_alpha_demo.dart` from
`examples/multiple_views` on macOS or Android to try the native material controls.

Use `Line` with `LineGeometry` for paths, `LineGeometry.segments` for independent
pairs, and `Points` with `PointGeometry` for circle or square markers. Their
materials let you choose physical pixel or world sizes. Native triangle expansion
keeps widths portable across backends, and camera or size edits reuse geometry.
Run `lib/primitives_demo.dart` to try both size modes. Current lines have butt
ends; joins, configurable caps, dashes and textured sprites remain open.

Use `createShaderCompiler()` or a plugin's `context.shaders` to validate WGSL
modules on the native worker. Source errors include Dart string locations and
leave the device usable. Compilers own their programs, and shared views can
retain them independently. See [shader compilation](../../docs/design/shader-compilation.md)
for the API and limits.

Use `createGraphCompiler()` to execute compute and procedural render passes with
typed buffer, texture and sampler bindings. Failed edits preserve the active
graph, and uniform updates reuse its pipelines. The
[render graph guide](../../docs/design/render-graphs.md) covers ownership,
dependencies and limits. The example saves a native compute-to-render heatmap
as a PNG. Custom mesh materials and direct platform-view graph composition
remain in progress.
