# Native device qualification

The integrated core runs on macOS Metal and Pixel 9 Pro Vulkan. iOS has a
successful signed device build, but its runtime checks still need an unlocked
phone. No Windows or Linux execution target was available on 2 October 2026.
These results do not qualify other GPU families or older OS releases.

| Target | Runtime evidence | Status |
| --- | --- | --- |
| Pixel 9 Pro, Android 17 API 37, build CP3A.260905.009 | Mali-G715, Vulkan driver v1.r54p3-00eac0.03d8d836cbf5c9f29d765e58a6bdfb98 | Physical gallery and six native SceneView tests pass |
| macOS 27, Apple M3 Max | Metal | Physical gallery, atmosphere lab and six native SceneView tests passed during core integration |
| Rex's iPhone, iOS 27.0 (24A437) | Signed native build succeeds | Runtime pending: device requires its passcode and the wireless VM service was not discovered |
| Windows | No execution target | Unverified |
| Linux | No execution target | Unverified |

## Android checks

The gallery exercises iridescence, dispersion, area shadows, compressed GPU
textures, roughness and light edits, TAA, bloom and 4x MSAA. It resizes to 320x640
and 960x720 logical pixels. The device advertises ETC2 and ASTC texture formats
and sample counts 1 and 4. Presentation uses a shared native texture and reports
zero pixel readback bytes.

The SceneView suite checks independent cameras, input, idle rendering, remount,
physical size, visibility, image and sampler updates, and 100 managed view
cycles. Sessions, surfaces, renderers and retiring renderers return to zero.
Explicit capture is separate: a 63x47 red image produces the expected RGBA pixels
and 11,844 readback bytes. Android's standalone capture uses its FFI renderer;
SurfaceProducer's presentation readback counter stays zero.

Three faults surfaced on the physical device. Duplicate JNI API members prevented
compilation. The codec runtime needed the NDK's separate C++ ABI archive. Finally,
wgpu's image-robustness detection selected a shader path that crashed the Mali
compiler. The fixes are in `25919c5`, including a linker check for unresolved
symbols and the [upstream Vulkan capability correction](https://github.com/gfx-rs/wgpu/pull/10291).
The capability regression failed before the fix and now passes all nine feature
combinations. All seven vendored HAL unit tests pass.

Flutter's native build cache also needed the vendored source directory declared
as an input. Without it, a dependency patch left the previous native binary in
the app. Qualification now records the source hashes before and after each run,
including all examples and tools.

## Run the checks

Use your Flutter SDK and the physical device ID reported by `flutter devices`.
From `examples/shader_lab`, run:

```sh
flutter test integration_test/physical_test.dart -d DEVICE --reporter expanded
```

From `examples/multiple_views`, run:

```sh
flutter test integration_test/native_scene_test.dart -d DEVICE --reporter expanded
```

For a wireless iPhone, use the integration driver from the shader lab directory:

```sh
flutter drive --target=integration_test/physical_test.dart \
  --driver=../multiple_views/test_driver/qualification.dart \
  -d DEVICE --publish-port
```

Unlock the phone before launching. The cancelled wireless attempt returned exit
code zero without executing a test, so an exit code alone is not a runtime pass.
Confirm the test results and the recorded source hashes.

You can wrap a command from the repository root with the provenance recorder:

```sh
python3 tool/qualification/run_check.py --output /tmp/zyren-device-run \
  --cwd examples/shader_lab -- flutter test \
  integration_test/physical_test.dart -d DEVICE --reporter expanded
```

`command.log` contains the actual result; `evidence.json` records the command,
source hashes, elapsed time and exit code. Device unlock is the remaining iOS
qualification step. Performance work and broader core features remain separate
from this device report.
