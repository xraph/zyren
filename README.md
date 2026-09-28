# Native Flutter 3D and geospatial

Build a 3D scene in Dart and render it through Rust and wgpu. The native backends
are Metal on Apple platforms, Vulkan on Android/Linux and Direct3D 12 on Windows.
WebGL, OpenGL and browser backends are disabled.

The core is a general-purpose Dart 3D library. `flutter_geospatial` is an optional
plugin built on that core. Three.js-level rendering and scene capabilities are
the target for the core.

This is an early implementation. You can render opaque, masked and blended meshes, compose a scene
graph, move a perspective camera and build an ECEF globe. On macOS and iOS, you
can opt into direct Metal view presentation through `SceneRuntime.nativeMetal()`.
On Android API 29 or newer, use `SceneRuntime.nativeAndroid()` for Vulkan
presentation through Flutter textures. Neither path reads pixels back to the CPU
during ordinary presentation.
The portable examples still select explicit RGBA readback. Full Three.js and
three-geospatial parity is still ahead. Scenes have a [transparent canvas](docs/design/scene-alpha.md)
by default; assign a background color when you need an opaque fill.

The [implementation plan](docs/superpowers/plans/2026-09-26-native-3d-program.md)
sets out the remaining work, tests and platform gates. Read the
[proposed Dart API](docs/design/native-3d-api.md) for the controller, loading and
plugin design. Those documents describe the target; the examples below use the
current alpha API.

## Packages

- `gpu3d` contains the Dart scene graph, geometry, engine and plugin contracts.
- `gpu3d_native` supplies the Rust/wgpu backend and native build hook.
- `flutter_gpu3d` adds Flutter views and re-exports the common scene API.
- [`gpu3d_inspector`](packages/gpu3d_inspector/README.md) adds optional scene inspection and sampled statistics widgets.
- `flutter_geospatial` is a Dart-only plugin depending on `gpu3d`.

Flutter callers keep the existing import and native default. Dart-only callers
can import `gpu3d` and supply a renderer to `SceneEngine.create`. For native
headless output, use `gpu3d_native`; see [backend submissions](docs/extensions.md#captured-backend-submissions).

`NativeBackend` also provides scoped buffers and textures with binary uploads,
shared ownership and explicit readback. The [resource API](docs/design/gpu-resources.md)
documents the implemented operations and limits. Scene geometry now uses the same
registry and binary packets. Use `NativeBackend.createView()` for independent
readback views sharing one device, geometry and material images. `TextureImage`
and `TextureMap` provide opaque color textures with independent sampler settings.

You can also run custom WGSL compute and procedural render passes through
`NativeBackend.createGraphCompiler()`. The [render graph guide](docs/design/render-graphs.md)
includes a native heatmap example, typed bindings and graph replacement rules.
Plugins on `SceneRuntime.nativeMetal()` and `SceneRuntime.nativeAndroid()` can
allocate and execute graphs on their presenter's device through the context's
resource, shader and graph services. Frame graphs process scene color through
compute/render passes and present the result directly on those native views.
Custom WGSL materials, transactional resize and texture history are available
through the public plugin API. See the [shader lab](examples/shader_lab/README.md)
for an independent effects plugin using those services.

## Run the example

You'll need Rust through rustup and the Flutter SDK pinned in `.fvmrc`. The
example also needs the normal platform tools: Xcode, an Android SDK/NDK, Windows
Visual Studio C++ tools, or Linux Flutter desktop dependencies.

```sh
fvm install
fvm flutter pub get
cd examples/planet
fvm flutter run -d macos
```

Use a connected iOS or Android device ID in place of `macos`. On a Windows host,
use `windows`; on Linux, use `linux`. Native build hooks compile and bundle Rust
with the app. The first build downloads the pinned Rust toolchain and target
standard libraries.

Drag the globe to orbit. Scroll or pinch to zoom, and choose a city to centre
its geodetic marker. The grid is procedural geometry. No map service, imagery
download or API key is required.

For a general 3D example, run the app in `examples/multiple_views`. It shares one
scene across two native renderers. Camera edits stay local to each view; scene
edits wake both. You can close and reopen the left view while the right stays
active. The same folder contains small managed and borrowed view examples.

To run those two cameras through native Metal views on Apple platforms:

```sh
cd examples/multiple_views
fvm flutter run -d macos -t lib/native_scene_demo.dart
```

Use an iOS device ID for the simulator. This runtime is opt-in while physical
devices, OS input and composition are being qualified. See the
[Apple checkpoint](docs/apple-presentation-checkpoint.md) for evidence and limits.

For the Android Vulkan `SceneView` demo, run
`flutter run --release -d <device-id> -t lib/native_scene_demo.dart` from the same
example folder. It uses the same controllers, scene and camera API as the Apple
demo. `lib/android_surface_demo.dart` remains the lower-level color fixture.
Android presentation is opt-in while broader device qualification continues.
See the
[Android checkpoint](docs/android-presentation-checkpoint.md).

For native texture filtering and wrapping, run
`fvm flutter run -d macos -t lib/textured_scene_demo.dart` from
`examples/multiple_views`. Use your Android device ID in place of `macos` on
Android. You can change the sampler without uploading the image again.

## Use the 3D package

Add a path dependency on `packages/flutter_gpu3d` while working in this checkout.

```dart
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

final scene = Scene();
final cube = Mesh(
  BoxGeometry(),
  DiffuseMaterial(color: Color3.hex(0x48bdb2)),
);
scene.add(cube);
final camera = PerspectiveCamera(position: Vec3(3, 2, 5));

// Put this inside a SizedBox or an Expanded with bounded dimensions.
final viewport = SceneView.scene(
  scene: scene,
  camera: camera,
  runtime: const SceneRuntime.nativeMetal(),
);
```

This snippet uses the Apple runtime. Select `const SceneRuntime.nativeAndroid()`
on Android. The default presentation policy is
`requireNative`, which accepts native views or qualified shared textures.
`requireSharedTexture` accepts the Android surface path and rejects Metal platform
views. Android's surface runtime does not yet support explicit pixel capture;
its capabilities report that limit. On other platforms, explicit
`readbackOnly` with the default runtime is available for development while the
direct presentation adapters are built.

`SceneView.builder` and `SceneView.scene` own their controllers. A rebuild keeps
the scene; changing `sceneKey` replaces it after cleanup. For external controls,
you can create a `SceneController`, pass it to `SceneView(controller: controller)`
and call `controller.dispose()` from your State. Borrowed views retain their
scene and session across unmounts. Static scenes render only after an edit. You can also create a `NativeRenderer` directly,
await `render`, then await `dispose`.
Only one frame may be in flight per view. Meshes can share geometry. Create it
with `dynamic: true` to update position, normal or UV ranges while preserving
captured frames. Hiding a mesh retains its allocation; removing it from every
owning view releases it after submitted work completes. Flutter's native view
presenters still own separate devices. See
[dynamic geometry](docs/design/gpu-resources.md#dynamic-geometry) for ownership
and upload rules.

Colours use linear RGB; `Color3.hex` converts an sRGB hex colour for you. Object
positions use double precision until the camera origin has been subtracted.
Local vertex attributes use float32 storage. The current
materials support diffuse lighting, unlit shading, direct metallic/roughness
lighting and RGBA color textures.
See [color textures](docs/design/gpu-resources.md#color-textures) for UVs, samplers
and supplied mip levels. `NativeImageDecoder` decodes bounded PNG/JPEG inputs.
Automatic mips and opaque, masked and blended materials are implemented.
[`StandardMaterial`](docs/design/standard-materials.md) works with directional,
point, spot and hemisphere lights. It supports normal, metallic/roughness,
occlusion and emissive maps with independent UV selection and shared images.
[HDR color and tone mapping](docs/design/color-pipeline.md) preserve bright light
through effects. [Environment lighting](docs/design/environment-lighting.md)
adds diffuse and rough specular reflections from HDR panoramas.
[Native shadows](docs/design/shadows.md) support directional cascades, spot maps
and six point-light faces.

## Plugins and backends

Use `ScenePlugin` for lifecycle hooks and typed services. Dependencies determine
initialization and frame order; teardown runs in reverse and also handles partial
initialization failures. `SceneRuntime` injects `RenderBackend` and `FramePresenter` factories. Keep their instances scoped to one viewport.

```dart
final geospatial = GeospatialPlugin();
final orbit = GlobeOrbitPlugin();
final globeScene = Scene()
  ..add(Mesh(geospatial.reference.globeGeometry(), DiffuseMaterial()));
final globeCamera = PerspectiveCamera(near: 100000, far: 200000000);
final viewport = SceneView.scene(
  scene: globeScene,
  camera: globeCamera,
  plugins: [geospatial, orbit],
  options: const EngineOptions(presentation: PresentationPolicy.readbackOnly),
);
```

Import `flutter_geospatial` for those two plugins. You can use the core without
that dependency. See [extensions](docs/extensions.md) for custom plugins,
services, renderer factories, presentation and ownership rules.

## Geospatial coordinates

```dart
import 'package:flutter_geospatial/flutter_geospatial.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

final location = Geodetic.degrees(3.3792, 6.5244, 25);
final ecef = location.toEcef();
final frame = EastNorthUpFrame(location);
final tenMetresEast = frame.toEcef(Vec3(10, 0, 0));
final globe = Mesh(EllipsoidGeometry(), DiffuseMaterial());
```

Angles in the `Geodetic` constructor are radians. Heights and ECEF coordinates
are metres. ECEF uses Z up; use `Vec3(0, 0, 1)` for your globe camera's up vector.
The default generic 3D camera uses Y up. The inverse ellipsoid projection rejects
points near the centre, where this implementation does not provide a reliable
geodetic inverse.

## Checks

```sh
fvm flutter analyze
cargo test --manifest-path packages/gpu3d_native/native/Cargo.toml
cargo clippy --manifest-path packages/gpu3d_native/native/Cargo.toml --all-targets -- -D warnings
fvm dart test packages/gpu3d/test packages/flutter_geospatial/test
fvm flutter test packages/flutter_gpu3d/test examples/multiple_views/test
```

On a host with a Metal, Vulkan or DX12 device, run the GPU checks too. A missing
device fails these checks; it does not silently switch to a browser renderer.

```sh
cargo test --manifest-path packages/gpu3d_native/native/Cargo.toml -- --include-ignored
cd packages/gpu3d_native
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1
cd ../../examples/planet
fvm flutter test integration_test/planet_test.dart -d macos
```

The FFI tests now run in the Dart VM. Set `RUN_NATIVE_GPU=1` in your shell to
enable them; the normal CPU suite keeps them opt-in. The native package's build
hook compiles and bundles Rust for both Dart and Flutter consumers.

See [verification](docs/verification.md) for the checks actually run on each
platform, [architecture](docs/architecture.md) for ownership and presentation
details, and the [port inventory](docs/geospatial-port.md) for the remaining
three-geospatial work.
