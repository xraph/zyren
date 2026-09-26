# Native Flutter 3D

You build scenes in Dart. Rust owns GPU resources and submits work directly to
Metal, Vulkan or Direct3D 12 through wgpu. There is no WebView, JavaScript runtime,
WebGL backend or OpenGL fallback.

## Package boundaries

- `flutter_gpu3d`: a general 3D API, Flutter viewport and native Rust renderer.
- `flutter_geospatial`: geodetic coordinates, ellipsoids, local frames and globe
  geometry built on the same scene API.
- `examples/planet`: a runnable native Flutter application.

Keep the geospatial package optional. A model viewer should not need an Earth
model, and a coordinate conversion should not need to initialize a GPU.

## Renderer

The first renderer uses indexed triangle meshes, a depth buffer, perspective
cameras, scene transforms, opaque materials and directional diffuse lighting.
Geometry is uploaded once per renderer and shared between meshes. Rust validates
the scene before changing GPU state. Invalid handles and malformed requests return
errors through the C ABI.

Dart keeps the scene graph. It composes transforms in double precision, subtracts
the camera position before converting matrices to float32, and sends one scene
snapshot per frame. Rust owns its device, pipelines, buffers and render targets.
The bridge runs in a persistent Dart isolate so GPU waits cannot block Flutter's
UI isolate. Each viewport allows one frame in flight.

The initial presentation path reads native GPU pixels into an RGBA buffer and
uploads that buffer into a Flutter image. This is real native GPU rendering, but
the extra copy limits throughput. You should use it to validate scenes and the
bridge, not as evidence of production frame rates. Shared GPU textures are the
next presentation milestone: IOSurface/CVPixelBuffer on Apple, hardware buffers
on Android and shared D3D textures on Windows. That work needs platform-specific
synchronization, resize and lifecycle tests.

## Build integration

Use Dart build hooks and `native_toolchain_rust` to compile and bundle the Rust
library. Flutter 3.38 introduced the recommended native asset workflow; this
repository pins Flutter 3.47.5 for development without changing your global SDK.
Cargo dependencies and Dart package resolutions are checked in.

Only native targets are supported. Metal is enabled for macOS/iOS, Vulkan for
Android/Linux and DX12 for Windows. A missing compatible device is an error.

## Geospatial conventions

Geodetic angles are radians. Heights and Earth-centered Earth-fixed (ECEF)
coordinates are metres. ECEF is right handed: X crosses longitude zero, Y crosses
90 degrees east, Z points north. Local frames use east, north, up. The ordinary
scene API is right handed with Y up by default; the globe example uses Z up.

Keep absolute world positions in double precision. Camera-relative rendering
preserves local detail at Earth scale. It does not fix depth precision across
arbitrarily large near/far ratios; reversed depth and terrain-specific depth
strategies belong in the later planetary renderer.

## Why this stack

wgpu provides the native backend portability we need while Rust handles GPU
resource ownership. Dart stays responsible for the public API and Flutter
lifecycle. A small versioned C ABI keeps the boundary independent of a bridge
generator. JSON scene snapshots make the first protocol inspectable; a binary
command stream can replace them after profiling.

Three.js provides an API reference, not a runtime dependency. We are not promising
source compatibility with its materials, loaders, shaders or extensions.

Sources: [wgpu](https://github.com/gfx-rs/wgpu),
[Flutter native code](https://docs.flutter.dev/platform-integration/bind-native-code),
[native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust).
