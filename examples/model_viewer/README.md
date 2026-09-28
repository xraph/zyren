# Native model viewer

Load a static glTF model through the public Dart API and display it in a native
Flutter scene. The example starts with an authored three-part assembly. You can
switch between its GLB and relative-file glTF forms, enter a model URI, select a
scene, inspect object names, cancel a load or retry it. Drag to orbit, then pinch
or scroll to zoom. Frame model resets the camera to the loaded geometry.

```sh
cd examples/model_viewer
flutter run -d macos --release
# Or select an Android device:
flutter run -d DEVICE_ID --release
```

The viewer requires native presentation. macOS uses Metal; Android API 29+ uses
Vulkan. Both pass the bundle/HTTP loading and repeated-reload integration test
with zero presentation readback bytes. The iOS, Windows and Linux runners are
scaffolding, not qualified viewer targets. Unsupported presentation fails
explicitly. There is no browser or OpenGL renderer fallback.

The loading API is small:

```dart
final task = controller.assets.load(Gltf.asset('assets/models/assembly.glb'));
final model = await task.result;
controller.scene.add(model.instantiate(name: 'Assembly'));
```

Use `task.progress` for stage and byte counts, `task.cancel()` for cancellation,
and `controller.assets.release(model)` when you no longer need to instantiate
that template. A controller closes its asset scope when disposed. The example
retains the previous model until its replacement loads and frames successfully.

PBR preview is an explicit unlit approximation for the next load or retry. Its
warning stays visible on the loaded model. The loader currently supports a
static subset of glTF, with unsupported features reported through source/field
diagnostics. Read the [support matrix](../../packages/gpu3d_gltf/README.md) before
choosing an asset. HTTP sources stay within the configured source policy; this
example stores no credentials and adds no authentication UI.

You can also capture a native GPU render without opening a Flutter window:

```sh
dart run tool/capture.dart assets/models/assembly.glb /tmp/assembly.png
```

That command uses explicit readback to write a PNG. The interactive viewer uses
native presentation instead. Fixtures are authored in this repository; regenerate
them from the workspace root with `dart tool/generate_model_fixtures.dart`.

Verification:

```sh
flutter test
flutter test integration_test/viewer_test.dart -d macos
flutter test integration_test/viewer_test.dart -d DEVICE_ID
```

Widget tests cover narrow and desktop layouts, scene selection, input during a
pending load, unknown byte totals, cancellation, URI failure/retry and route
cleanup. The integration test serves the bundled glTF and its dependencies over
loopback HTTP, renders them with the native presenter, then repeats the load.
