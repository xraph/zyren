# Mobile CPU qualification

You can bundle ONNX Runtime 1.23.2 on Android and iOS through the same native
assets and C API used on desktop. Your host still supplies model bytes and owns
its worker's lifecycle. No remote service or additional engine is involved.

The Android AAR comes from Microsoft's Maven release. The Apple XCFramework
comes from the official Microsoft.ML.OnnxRuntime NuGet package at the same
version. The build hook verifies the outer archive SHA256 and, for Apple, the
nested XCFramework ZIP SHA256 before extraction. See
[native/runtime-manifest.json](../native/runtime-manifest.json) for exact sources
and pins. Runtime license and third-party notices are included in the probe's
assets and must accompany redistributed libraries.

## Required host settings

Android requires API 24. All four AAR ABIs are packaged: arm64, arm, x64 and x86.
The shim links its C++ standard library statically. The actual arm64 APK's two
native libraries have at least 16 KiB LOAD alignment and no libc++_shared dependency.

Apple requires an iOS 16 deployment target, selecting either device arm64 or
simulator arm64/x64. The official static archive has a 15.1 minimum. The hook wraps
that archive in a bundled runtime dylib and compiles both native assets at the
host's declared deployment floor. Your Runner must use that same floor.

Flutter 3.47.5 sends iOS 15 to native hooks even when Runner targets 16. The workspace
pubspec therefore needs this explicit declaration:

```yaml
hooks:
  user_defines:
    zyren_ml:
      ios_deployment_target: 16
```

The hook rejects an incompatible or missing floor. The declaration does not
modify your Xcode project. Apple compilation requires macOS and Xcode; Android
compilation requires the Android NDK.

## Verified checks

| Target | Evidence |
| --- | --- |
| Android arm64, physical Pixel 9 Pro, Android 17/API 37 | 1,032 native runs passed, zero live sessions/results after close |
| Apple arm64 simulator, iPhone 17 Pro, iOS 26.5 | Same 1,032-run probe passed, zero live sessions/results |
| Apple arm64 device | Unsigned Runner.app compiled with both native assets, required exports and Mach-O minimum 16.0 |
| Android arm/x64/x86 and Apple x64 simulator | Actual native hook crossbuilds passed, no device execution claim |
| macOS arm64 | Native inference/worker/lifetime regression passed 17 tests after the hook update |

The mobile probe contains 30 repeated linear load/run/release cycles, 1,000 LSTM
steps with explicit hidden/cell state and resets, one CNN 84x84 run and exact int64
and bool tensors. It compares real outputs to local deterministic references at
atol 1e-5/rtol 1e-4. Both Android and Apple simulator had maximum absolute error
2.384185791015625e-7. Expired work did not enter native execution. Corrupt model
bytes were rejected.

The complete crossbuild test passed 11 checks across seven real target slices,
including incompatible minima and deployment declaration validation. Both Apple
runtime outputs exported OrtGetApiBase and had no residual dependency on the
original static XCFramework. The packaged simulator and device frameworks have
Mach-O minimum OS 16.0.

From packages/zyren_ml:

```sh
ANDROID_HOME=/path/to/android/sdk ZYREN_MOBILE_HOOKS=1 \
  fvm dart --packages=../../.dart_tool/package_config.json test/build_hook_test.dart
fvm dart test --concurrency=1 test/native_inference_test.dart \
  test/native_worker_test.dart test/lifetime_test.dart
```

From packages/zyren_ml/example:

```sh
fvm flutter test --no-pub integration_test/native_probe_test.dart -d DEVICE_ID
fvm flutter drive --no-pub --driver=test_driver/integration_test.dart \
  --target=integration_test/native_probe_test.dart -d WIRELESS_APPLE_DEVICE_ID \
  --publish-port
fvm flutter build ios --no-pub --debug --no-codesign \
  --target=integration_test/native_probe_test.dart
```

Physical Apple execution was blocked before launch. Xcode reported that the
team's maximum App ID limit had been reached and no profile existed for the new
probe ID. We did not replace another installed app. Simulator execution and
unsigned compilation do not establish physical-device performance or signing.

These are CPU fixture checks. NNAPI, CoreML and GPU providers remain disabled.
Native allocator bytes are unknown. Debug probe elapsed times are not production
latency benchmarks, and the fixtures are not accepted trained policies. The
GameLab scene/frame benchmark is separate.
