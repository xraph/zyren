# Physics Lab

You can drop balls, watch a motorized hinge, move a kinematic platform, inspect
sensor transitions, cast a ray and query overlaps in the same native scene.
Pause preserves the world. Reset restores the initial native snapshot and rebinds
its bodies. Debug lines show collider shapes, constraints and contacts.

```sh
flutter run -d macos
flutter test integration_test/physics_lab_test.dart -d macos
dart run tool/qualify.dart qualification/local
```

Use Flutter 3.47.5 and Rust 1.97.1. On macOS and iOS the app uses the shared native
Metal view; Android uses the native Vulkan runtime. Linux and Windows use native
rendering with RGBA readback presentation. The physics package itself does not
choose a renderer.

Controls wrap at narrow widths, and the viewport uses the remaining height.
Drag in the viewport to orbit. You can create up to 128 extra balls before resetting.
The query summary reports the actual current simulation state.

The integration test exercises controls, pause/resume, snapshot reset, kinematic
movement, narrow layout and disposal. The qualification runner saves a native
render and measured state in the directory you pass, including renderer recreation
and debug cleanup. It uses `qualification/` when you omit the argument, and names
the image after the backend it measured. You can run the same integration test with an Android device or iOS
simulator ID. It checks the actual backend and reports the presentation path.

For a wireless iPhone, you need the driver entry point and a published debugger
port. Unlock the phone and allow the app's Local Network prompt, then run:

```sh
flutter drive --driver=test_driver/qualification.dart \
  --target=integration_test/physics_lab_test.dart -d DEVICE_ID --publish-port
```

The CI workflow builds and tests arm64 and x64 on macOS, Linux and Windows. It also
runs native rendering and app integration, then uploads the render evidence from
that run. A runner without a working native graphics backend fails qualification.
Linux CI uses Mesa software Vulkan, so its result doesn't qualify a physical GPU.

See [the completion matrix](../../packages/zyren_physics/COMPLETION.md) for tested
platforms, linked builds and open hardware checks.
