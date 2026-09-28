# Zyren

Native 3D for Dart and Flutter.

Build a 3D scene in Dart and render it through Rust and wgpu. The native backends
are Metal on Apple platforms, Vulkan on Android/Linux and Direct3D 12 on Windows.
WebGL, OpenGL and browser backends are disabled.

The core is a general-purpose Dart 3D library. `zyren_geospatial` is an optional
plugin built on that core. Three.js-level rendering and scene capabilities are
the target for the core.

This is an early implementation. You can render opaque meshes, compose a scene
graph, move a perspective camera and build an ECEF globe. On macOS and iOS, you
can opt into direct Metal view presentation through `SceneRuntime.nativeMetal()`.
On Android API 29 or newer, use `SceneRuntime.nativeAndroid()` for Vulkan
presentation through Flutter textures. Neither path reads pixels back to the CPU
during ordinary presentation.
The portable examples still select explicit RGBA readback. Full Three.js and
three-geospatial parity is still ahead.

The [implementation plan](docs/superpowers/plans/2026-09-26-native-3d-program.md)
sets out the remaining work, tests and platform gates. Read the
[proposed Dart API](docs/design/native-3d-api.md) for the controller, loading and
plugin design. Those documents describe the target; the examples below use the
current alpha API.

## Packages

- `zyren` contains the Dart scene graph, geometry, engine and plugin contracts.
- `zyren_native` supplies the Rust/wgpu backend and native build hook.
- `flutter_zyren` adds Flutter views and re-exports the common scene API.
- `zyren_geospatial` is a Dart-only plugin depending on `zyren`.
- [`zyren_tools`](packages/zyren_tools/README.md) adds selection, reversible transforms and measurements.
- [`zyren_devtools`](packages/zyren_devtools/README.md) provides scene inspection, blank-scene diagnostics, a local CLI and MCP tools.
- [`zyren_timeline`](packages/zyren_timeline/README.md) plays and scrubs transform and camera tracks.
- [`zyren_engineering`](packages/zyren_engineering/README.md) binds stable IDs, metadata and review notes to scene objects, with temporary isolation and host-owned storage.

## AI developer tools

Connect an MCP assistant to the running workbench to inspect objects, explain
blank scenes and examine reported frame costs. The same seven read-only tools
are available through a local CLI. See [AI setup](docs/ai/README.md) for debug
startup, connection details and MCP configuration, and the
[agent guide](docs/ai/AGENT_GUIDE.md) for the current Dart API and tested recipe.

## Moving from the original package names

If you use an earlier checkout, update your dependencies and imports:

| Previous package | Zyren package | Main import |
| --- | --- | --- |
| `gpu3d` | `zyren` | `package:zyren/zyren.dart` |
| `gpu3d_native` | `zyren_native` | `package:zyren_native/zyren_native.dart` |
| `flutter_gpu3d` | `flutter_zyren` | `package:flutter_zyren/flutter_zyren.dart` |
| `flutter_geospatial` | `zyren_geospatial` | `package:zyren_geospatial/zyren_geospatial.dart` |
| `gpu3d_tools` | `zyren_tools` | `package:zyren_tools/zyren_tools.dart` |
| `gpu3d_devtools` | `zyren_devtools` | `package:zyren_devtools/zyren_devtools.dart` |
| `gpu3d_timeline` | `zyren_timeline` | `package:zyren_timeline/zyren_timeline.dart` |
| `gpu3d_engineering` | `zyren_engineering` | `package:zyren_engineering/zyren_engineering.dart` |

Use the matching folders under `packages/` for path dependencies, then run
`fvm flutter pub get` and fully restart your app so Flutter registers the renamed
native plugin. Scene types and the versioned C ABI keep their existing names.
These packages are still local development packages with `publish_to: none`.
The multiple-view example keeps its application IDs and review-file location,
so you can continue using saved reviews after updating your checkout.

## Choosing a package

Flutter callers import `flutter_zyren` for views and the native default. Dart-only
callers can import `zyren` and supply a renderer to `SceneEngine.create`. For native
headless output, use `zyren_native`; see [backend submissions](docs/extensions.md#captured-backend-submissions).

`NativeBackend` also provides scoped buffers and textures with binary uploads,
shared ownership and explicit readback. The [resource API](docs/design/gpu-resources.md)
documents the implemented operations and limits. Scene geometry now uses the same
registry and binary packets. Use `NativeBackend.createView()` for independent
readback views sharing one device, geometry and material images. `TextureImage`
and `TextureMap` provide opaque color textures with independent sampler settings.

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

For the ported OrbitControls, run `fvm flutter run -d macos -t lib/orbit_lab.dart`
from `examples/planet`. You can switch projection, pan, use cursor zoom and test
keyboard/touch input in a general 3D scene. See [native orbit evidence](docs/parity/native-orbit.md)
for the pinned source, device results and remaining differences. The separate
[camera lab](docs/parity/native-camera-lab.md) uses the upstream geographic poses.
You can run the [Three r184 mode](docs/parity/three-orbit.md) with
`fvm flutter run -d macos -t lib/three_orbit_lab.dart` from the same directory.

For surface selection, run `fvm flutter run -d macos -t lib/picking_lab.dart`
from `examples/planet`, or use your Android/iOS device ID. Tap a mesh to highlight
it and inspect its world position. The [picking API and evidence](docs/parity/picking.md)
cover CPU triangle queries and logical viewport coordinates.

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

For selection, transform history, engineering review and assembly playback, run
`fvm flutter run -d macos -t lib/scene_workbench.dart` from
`examples/multiple_views`. Use an Android device ID for Vulkan presentation.
You can select a part, move or rotate it, undo the edit, measure two surface
points and scrub an exploded view. Open Review to edit metadata, isolate parts,
attach surface notes and save them locally. The inspector and controls wrap at
narrow widths. Read the [workbench checkpoint](docs/scene-workbench-checkpoint.md)
for the implemented scope and platform checks.

## Use the 3D package

Add a path dependency on `packages/flutter_zyren` while working in this checkout.

```dart
import 'package:flutter_zyren/flutter_zyren.dart';

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
Only one frame may be in flight per view. Geometry is immutable and shared by
meshes. Hiding a mesh retains its allocation; removing it from every owning view
releases it after submitted work completes. Construct a new geometry when its
contents change. Flutter's native view presenters still own separate devices.

Colours use linear RGB; `Color3.hex` converts an sRGB hex colour for you. Positions
use double precision until the camera origin has been subtracted. The current
materials support opaque diffuse lighting, unlit shading and RGBA color textures.
See [color textures](docs/design/gpu-resources.md#color-textures) for UVs, samplers
and supplied mip levels. Image decoding, transparency, shadows and PBR remain
planned work.

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

Import `zyren_geospatial` for those two plugins. You can use the core without
that dependency. See [extensions](docs/extensions.md) for custom plugins,
services, renderer factories, presentation and ownership rules.

## Geospatial coordinates

```dart
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

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
cargo test --manifest-path packages/zyren_native/native/Cargo.toml
cargo clippy --manifest-path packages/zyren_native/native/Cargo.toml --all-targets -- -D warnings
(cd packages/zyren && fvm dart test)
(cd packages/zyren_geospatial && fvm dart test)
fvm flutter test packages/flutter_zyren/test examples/multiple_views/test
```

On a host with a Metal, Vulkan or DX12 device, run the GPU checks too. A missing
device fails these checks; it does not silently switch to a browser renderer.

```sh
cargo test --manifest-path packages/zyren_native/native/Cargo.toml -- --include-ignored
cd packages/zyren_native
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
