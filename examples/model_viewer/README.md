# Native model viewer

Load a glTF model and its transform animations through the public Dart API and display it in a native
Flutter scene. The example starts with an authored three-part assembly. You can
switch between its GLB and relative-file glTF forms, enter a model URI, select a
scene, inspect object names, cancel a load or retry it. Drag to orbit, then pinch
or scroll to zoom. Frame model resets the camera to the loaded geometry.

```sh
cd examples/model_viewer
flutter run -d macos --release --dart-define=GPU3D_MODEL=pbr.glb
# Or select an Android device:
flutter run -d DEVICE_ID --release --dart-define=GPU3D_MODEL=pbr.glb
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

Open Examples and choose PBR model for a metallic/roughness assembly with authored point and
directional lights. Its second scene has no lights, so the viewer supplies a
studio setup that you can toggle in the header. Imported lights always take
precedence. Choose Colors to see normalized RGB vertex colors on the same
assembly. You can start there with `--dart-define=GPU3D_MODEL=colors.glb`.
The material-mode menu also offers an unlit diagnostic approximation
for the next load or retry, with a warning on the loaded model. The loader currently supports a
bounded subset of glTF, with unsupported features reported through source/field
diagnostics. Read the [support matrix](../../packages/gpu3d_gltf/README.md) before
choosing an asset. HTTP sources stay within the configured source policy; this
example stores no credentials and adds no authentication UI.

Choose Animation for an authored PBR assembly with cubic lift, linear rotation
and step scale clips. The compact playback row selects clips, plays or pauses,
seeks and restarts. Replacing the model releases its mixer registration. Start
with that asset using `--dart-define=GPU3D_MODEL=animated.glb`.

```sh
flutter run --release -d DEVICE_ID --dart-define=GPU3D_MODEL=animated.glb
flutter test integration_test/animation_test.dart -d DEVICE_ID
```

You can also capture a native GPU render without opening a Flutter window:

```sh
dart run tool/capture.dart assets/models/assembly.glb /tmp/assembly.png
dart run tool/capture.dart assets/models/animated.glb /tmp/animated.png 1.5
```

That command uses explicit readback to write a PNG. The interactive viewer uses
native presentation instead. Fixtures are authored in this repository; regenerate
them from the workspace root with `dart tool/generate_model_fixtures.dart`.

Verification:

```sh
flutter test
flutter test integration_test/pbr_pixels_test.dart -d macos
flutter test integration_test/viewer_test.dart -d macos
flutter test integration_test/pbr_pixels_test.dart -d DEVICE_ID
flutter test integration_test/viewer_test.dart -d DEVICE_ID
```

Widget tests cover narrow and desktop layouts, scene selection, input during a
pending load, unknown byte totals, cancellation, URI failure/retry and route
cleanup. The integration test serves the bundled glTF and its dependencies over
loopback HTTP, renders them with the native presenter, then repeats the load.

## Instancing demo

Run `flutter run -d macos -t lib/instancing.dart` to display 10000 boxes in one
native draw. The same entry point runs on an Android device with `-d <device>`.
Use the count menu to change visibility, “Move one” for a 112-byte update, and
“Rotate group” for a transform change with no instance upload. Drag to orbit;
pinch or scroll to zoom. See [instancing](../../docs/design/instancing.md) for
bounds, material support, limits and transparent ordering.

## Skin and morph demo

Run `flutter run --release -d <android-device> -t lib/deformation.dart` or
`flutter run -d macos -t lib/deformation.dart`. Two meshes share a ribbon geometry
and keep independent two-joint poses. Playback, pose, speed and width controls
affect the blue mesh. Pausing releases frame demand. See the
[deformation API](../../docs/design/deformation.md) for binding rules, limits and
native verification commands.


## Imported skin and morph animation

Choose **Skin + morph** to load the authored `deformation.glb`. Its two ribbons
share geometry and keep separate joint hierarchies. The clip bends and widens
one ribbon while the other retains its pose. Existing playback, seek and speed
controls apply to the imported clip. Camera framing uses the current deformed
bounds, including cancellation of the glTF mesh node transform during skinning.

```sh
flutter run --release -d <android-device> --dart-define=GPU3D_MODEL=deformation.glb
flutter test integration_test/gltf_deformation_test.dart -d macos
```


The capture tool accepts `--studio` to add explicit lighting for a standalone
PBR image: `dart run tool/capture.dart assets/models/deformation.glb output.png 1 --studio`.
