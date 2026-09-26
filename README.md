# Native Flutter 3D and geospatial

Build a 3D scene in Dart and render it through Rust and wgpu. The native backends
are Metal on Apple platforms, Vulkan on Android/Linux and Direct3D 12 on Windows.
WebGL, OpenGL and browser backends are disabled.

The core is a general-purpose Dart 3D library. `flutter_geospatial` is an optional
plugin built on that core. Three.js-level rendering and scene capabilities are
the target for the core.

This is an early implementation. You can render opaque meshes, compose a scene
graph, move a perspective camera and build an ECEF globe. The viewport currently
copies GPU pixels into a Flutter image, so you should expect lower throughput
than a shared GPU texture implementation. Full Three.js and three-geospatial
parity is still ahead.

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

## Use the 3D package

Add a path dependency on `packages/flutter_gpu3d` while working in this checkout.

```dart
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

final scene = Scene();
final cube = Mesh(
  BoxGeometry(),
  MeshMaterial(color: Color3.hex(0x48bdb2)),
);
scene.add(cube);
final camera = PerspectiveCamera(position: Vector3(3, 2, 5));

// Put this inside a SizedBox or an Expanded with bounded dimensions.
final viewport = SceneView(scene: scene, camera: camera);
```

`SceneView` owns its engine, plugins and presentation resources and releases them
when the widget is removed. You can also create a `NativeRenderer` directly,
await `render`, then await `dispose`.
Only one frame may be in flight per renderer. Geometry is immutable, shared by
meshes and released from the GPU when no visible mesh references it. Construct
a new geometry when its contents change.

Colours use linear RGB; `Color3.hex` converts an sRGB hex colour for you. Positions
use double precision until the camera origin has been subtracted. The current
material supports opaque diffuse lighting and an unlit mode. There are no texture,
transparency, shadow or PBR APIs yet.

## Plugins and backends

Use `ScenePlugin` for lifecycle hooks and typed services. Dependencies determine
initialization and frame order; teardown runs in reverse and also handles partial
initialization failures. `SceneRenderer` and `FramePresenter` are independent
contracts with injectable factories. Keep their instances scoped to one viewport.

```dart
final geospatial = GeospatialPlugin();
final orbit = GlobeOrbitPlugin();
final globeScene = Scene()
  ..add(Mesh(geospatial.reference.globeGeometry(), MeshMaterial()));
final globeCamera = PerspectiveCamera(near: 100000, far: 200000000);
final viewport = SceneView(
  scene: globeScene,
  camera: globeCamera,
  plugins: [geospatial, orbit],
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
final tenMetresEast = frame.toEcef(Vector3(10, 0, 0));
final globe = Mesh(EllipsoidGeometry(), MeshMaterial());
```

Angles in the `Geodetic` constructor are radians. Heights and ECEF coordinates
are metres. ECEF uses Z up; use `Vector3(0, 0, 1)` for your globe camera's up vector.
The default generic 3D camera uses Y up. The inverse ellipsoid projection rejects
points near the centre, where this implementation does not provide a reliable
geodetic inverse.

## Checks

```sh
fvm flutter analyze
cargo test --manifest-path packages/flutter_gpu3d/native/Cargo.toml
cargo clippy --manifest-path packages/flutter_gpu3d/native/Cargo.toml --all-targets -- -D warnings
fvm flutter test packages/flutter_gpu3d/test packages/flutter_geospatial/test
```

On a host with a Metal, Vulkan or DX12 device, run the GPU checks too. A missing
device fails these checks; it does not silently switch to a browser renderer.

```sh
cargo test --manifest-path packages/flutter_gpu3d/native/Cargo.toml -- --include-ignored
cd packages/flutter_gpu3d
fvm flutter test --dart-define=RUN_NATIVE_GPU=true
cd ../../examples/planet
fvm flutter test integration_test/planet_test.dart -d macos
```

Run the FFI test from its package directory so Flutter includes that package's
native asset hook. The repository root is a workspace, not a Flutter app.

See [verification](docs/verification.md) for the checks actually run on each
platform, [architecture](docs/architecture.md) for ownership and presentation
details, and the [port inventory](docs/geospatial-port.md) for the remaining
three-geospatial work.
