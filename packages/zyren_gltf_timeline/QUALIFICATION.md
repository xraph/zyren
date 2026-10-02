# Imported animation qualification

Checked on 2026-10-02 against the pose mixer in `37a5499`.

| Check | Result |
| --- | --- |
| Importer, timeline and adapter tests | 163 passed, including compiled release-worker transfer, errors and cancellation |
| macOS 27.0, Apple M3 Max, Metal | Four native pixel/upload tests passed, including imported crossfades, pose restoration, authored additive actions and reverse loops |
| Pixel 9 Pro, Android 17, Vulkan | Physical-device integration passed: imported crossfade pixels, joint and morph pose values, additive reverse loops, pose restoration and zero upload bytes on an unchanged frame |
| Analysis and formatting | No issues in the three packages and device test; 63 Dart files unchanged by the format check |
| Package boundaries and Apple ABI header | Passed after recognizing the engineering package's `crypto` dependency |
| Windows DX12 | Not run. This checkout is on macOS, and the repository has no registered self-hosted runners |

The GPU tests deliberately request pixel readback. They verify native rendering
and dynamic geometry uploads, not Flutter surface presentation or zero-readback
production rendering. Joint and morph deformation runs on the CPU. GPU skinning
and morph kernels are not implemented.

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

On a Windows host with a DX12 GPU, you can run the native suite in PowerShell:

```powershell
$env:RUN_NATIVE_GPU = '1'
dart test packages/zyren_gltf_timeline/test/native_animation_test.dart
```

The suite checks the platform's expected backend and logs its adapter name.
Record that result before claiming DX12 qualification. The regular desktop CI
runs the adapter's CPU tests; native GPU
tests remain opt-in because its hosted runners do not establish a physical GPU.
