# Imported animation qualification

Checked on 2026-10-02 against the pose mixer in `37a5499`.

| Check | Result |
| --- | --- |
| Importer, timeline and adapter tests | 163 passed, including compiled release-worker transfer, errors and cancellation |
| macOS 27.0, Apple M3 Max, Metal | Four native pixel/upload tests passed, including imported crossfades, pose restoration, authored additive actions and reverse loops |
| Pixel 9 Pro, Android 17, Vulkan | Physical-device integration passed: imported crossfade pixels, joint and morph pose values, additive reverse loops, pose restoration and zero upload bytes on an unchanged frame |
| macOS Metal native view | Imported surface test passed: 49 frames, resized from 840x560 to 440x360 physical pixels, zero pixel readback bytes, renderer/session/drawable cleanup passed |
| Pixel Vulkan shared texture | Imported surface test passed: 44 frames, resized from 945x630 to 495x405 physical pixels, zero pixel readback bytes, renderer/session/surface cleanup passed |
| Analysis and formatting | No issues in the three packages and device test; 63 Dart files unchanged by the format check |
| Package boundaries and Apple ABI header | Passed after recognizing the engineering package's `crypto` dependency |
| Windows DX12 | Not run. This checkout is on macOS, and the repository has no registered self-hosted runners |

The pixel tests deliberately request readback. The separate
`imported_presentation_test.dart` uses Flutter's production native view on Metal
and shared texture on Android Vulkan. It checks crossfades, independent reverse
action loops, imported reverse-loop markers, additive poses, silent seeking and
an unchanged sibling instance. It also checks both frame statistics and native
host presentation counters before confirming that teardown releases resources.

These are automated surface checks, not screenshot comparisons. The macOS
launcher reported that it could not foreground the app; native presentation and
cleanup assertions still passed. Joint and morph deformation runs on the CPU.
GPU skinning and morph kernels are not implemented.

## Reproduce

From the workspace root, with the repository's Flutter 3.47.5 SDK:

```sh
RUN_NATIVE_GPU=1 dart test packages/zyren_gltf/test packages/zyren_timeline/test packages/zyren_gltf_timeline/test
dart analyze packages/zyren_gltf packages/zyren_timeline packages/zyren_gltf_timeline examples/multiple_views/integration_test/imported_animation_test.dart
dart run tool/check_package_boundaries.dart
```

For a connected Android device, run from `examples/multiple_views`:

```sh
flutter test integration_test/imported_animation_test.dart -d <device-id>
```

The passing device run reported:

```text
IMPORTED_ANIMATION backend=Vulkan crossfade=pass additive=pass reverseLoop=pass unchangedUploadBytes=0
00:01 +1: All tests passed!
```

You can run the production presentation checks from `examples/multiple_views`:

```sh
flutter test integration_test/imported_presentation_test.dart -d macos
flutter test integration_test/imported_presentation_test.dart -d <android-device-id>
```

The 2026-10-02 runs reported:

```text
IMPORTED_PRESENTATION backend=Metal path=nativeView frames=49 wide=840x560 narrow=440x360 readbackBytes=0 cleanup=pass
IMPORTED_PRESENTATION backend=Vulkan path=sharedTexture frames=44 wide=945x630 narrow=495x405 readbackBytes=0 cleanup=pass
```

Frame counts depend on the host's scheduling. The assertions require successful
playback, resizing and cleanup, without fixing the number of presented frames.

On a Windows host with a DX12 GPU, you can run the native suite in PowerShell:

```powershell
$env:RUN_NATIVE_GPU = '1'
dart test packages/zyren_gltf_timeline/test/native_animation_test.dart
```

The suite checks the platform's expected backend and logs its adapter name.
Record that result before claiming DX12 qualification. Linux CI runs the
adapter's CPU tests with the rest of the workspace suites; native GPU tests
remain opt-in because hosted runners do not establish a physical GPU.
