# Physics Lab

You can drop balls, watch a motorized hinge, move a kinematic platform, inspect
sensor transitions, cast a ray and query overlaps in the same native scene.
Pause preserves the world. Reset restores the initial native snapshot and rebinds
its bodies. Debug lines show collider shapes, constraints and contacts.

```sh
flutter run -d macos
flutter test integration_test/physics_lab_test.dart -d macos
dart run tool/qualify.dart
```

Use Flutter 3.47.5 and Rust 1.97.1. On macOS and iOS the app uses the shared native
Metal view; Android uses the native Vulkan runtime. Linux and Windows use native
rendering with RGBA readback presentation. The physics package itself does not
choose a renderer.

Controls wrap at narrow widths, and the viewport uses the remaining height.
Drag in the viewport to orbit. You can create up to 128 extra balls before resetting.
The query summary reports the actual current simulation state.

The integration test exercises controls, pause/resume, snapshot reset, kinematic
movement, narrow layout and disposal. The qualification runner saves a native Metal
render and measured state in `qualification/`, including renderer recreation and
debug cleanup. You can run the same integration test with an Android device or iOS
simulator ID. It checks the actual backend and reports the presentation path.

See [the completion matrix](../../packages/zyren_physics/COMPLETION.md) for tested
platforms, linked builds and open hardware checks.
