# Particle Lab

You can run sparks, atlas sprites, ribbons, flow fields and mesh particles in a
native Zyren viewport. Pick an effect across the top. Drag the viewport to orbit;
scroll to zoom. Play, Pause, Drain, Reset and Burst act on the selected emitter.
The slider sets burst size. Inspect count reads the GPU once and labels that
value as the last inspection.

From the repository root, use Flutter 3.47.5:

```sh
flutter pub get
cd examples/particles
flutter run -d macos
# Or select your Android or iOS device from flutter devices.
```

macOS and iOS require Metal native presentation. Android requires a Vulkan
native surface. The Windows and Linux runners use the native DX12/Vulkan
renderer with explicit image readback presentation, as supported by the shared
Flutter package. There is no browser renderer.

The footer reports dispatches, uploaded bytes and host work. It does not report
GPU timing or equate capacity with live particles. See the
[package API and limits](../../packages/zyren_particles/README.md).

You can run the interaction check on a connected native device:

```sh
flutter test integration_test/particles_test.dart -d macos --timeout=4m
# Wireless iOS uses the driver entrypoint:
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/particles_test.dart -d <device-id> --publish-port
flutter build apk --debug --target-platform android-arm64
flutter build ios --simulator --debug --no-codesign
```

The check runs all five effects, verifies native frames and explicit particle
state, exercises pause/reset/burst, and checks desktop and narrow constraints.
The Android sample uses debug signing, including local release builds. Configure
your own signing identity before distributing a derived application.

[Qualification results](../../packages/zyren_particles/qualification/2026-10-02.md)
record what was built and run. Windows and Linux require their respective hosts.
