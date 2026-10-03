# Declarative scene integration, 3 October 2026

The bundled declarative demo passed its macOS integration test on arm64 macOS
27.0.1 (26A434), using FVM Flutter 3.47.5. You can reproduce the native check from
`examples/multiple_views`:

```sh
/Users/rexraphael/fvm/versions/3.47.5/bin/flutter test --no-pub integration_test/declarative_scene_test.dart -d macos
```

One integration test passed. It loaded the bundled PNG and embedded-buffer glTF
through Flutter's bundle resolver and native asset services. The test injected one
texture read failure, used the visible ZeroState retry action and verified the
second request mounted the textured sphere. Imported animation advanced the model
node's actual transform, then held its pose when paused.

The same run checked mouse hover, pointer capture outside the cube, release,
selection through a click and clearing selection on a missed click. Removing and
restoring the cube changed presented draw counts. Orbit and FXAA toggles updated
the mounted session, and both effect transitions waited for a later presented
frame. Camera and renderer identities stayed stable. Disposal completed within the
test's 15-second timeout.

Every observed presentation reported `PresentationPath.nativeView` and zero
`readbackBytes`. These are renderer/presenter checks, not pixel comparisons or a
measurement of physical display scanout. No screenshot or GPU readback was used.
The native test covers the bundled scene and its updates; it does not establish
visual parity for every material, light, environment or post-processing option.

Flutter emitted its existing Swift Package Manager support warning for
`flutter_zyren`, and macOS returned `Failed to foreground app; open returned 1`.
The app still built and the native integration assertions passed. Foreground
window behavior was not verified by this run.

## Reference checks

- `flutter test --no-pub test/declarative_demo_test.dart` from
  `examples/multiple_views`: two tests passed at 1024×768 and 360×740. Both kept the
  canvas over 400 logical pixels tall and checked bundle loads, retained object
  identity, live orbit toggles and renderer cleanup. The backend is a reference
  fixture for these layout tests.
- `dart test test/asset_cache_test.dart test/texture_image_loader_test.dart
  test/plugin_updates_test.dart test/raycaster_test.dart
  test/animation_plugin_test.dart test/animation_lifecycle_test.dart` from
  `packages/zyren`: 47 tests passed.
- `dart test test/model_test.dart test/animation_model_test.dart` from
  `packages/zyren_gltf`: 17 tests passed.
- `dart tool/check_package_boundaries.dart` from the repository root: package
  boundaries and the Apple ABI header passed.
- Analysis of the changed controller, tests and example files passed. The README's
  Dart examples were also checked as temporary widget expressions with their
  documented imports and caller-supplied controller/plugin values.

Use the FVM binaries shown above for these commands. The first full
`flutter_zyren` suite run exposed an orbit lifecycle cancellation failure outside
the demo. Its correction and the final suite result are recorded with the
integration work; the native evidence above does not depend on declaring that
failed run successful.

Android, iOS, Linux, Windows, Vulkan and DX12 were not qualified by this task.
Reference tests do not replace those device runs.
