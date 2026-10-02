# Physics qualification, 2026-10-02

You can reproduce these checks with Flutter 3.47.5, its bundled Dart 3.13.4,
Rust 1.97.1 and Rapier 0.36.0. The package remains unpublished.

## Results

| Check | Measured result |
| --- | --- |
| Physics package | 17 tests passed on macOS arm64 and Linux arm64/x64 |
| Rust package | 3 tests passed; strict Clippy and rustfmt passed |
| Rust cross-target checks | Windows arm64/x64 and Android armv7/x64 passed without linking or execution |
| Static checks | Dart analysis, formatting and package boundaries passed; workflow passed actionlint |
| macOS arm64 | Linked app and Metal/nativeView integration passed |
| macOS x64 | Linked app passed; bundled app and native frameworks verified as x86_64; execution open |
| Pixel 9 Pro, Android 17 | Linked APK and Vulkan/sharedTexture integration passed |
| Android armv7, arm64 and x64 APK | Physics, renderer and surface libraries packaged; ELF architectures verified |
| iPhone 17 Pro simulator, iOS 26.5 | Linked app and Metal/nativeView integration passed |
| iOS simulator x64 | Linked app passed; bundled app and native frameworks verified as x86_64; execution open |
| Linux arm64, Debian 12 | Linked app and Vulkan/readback integration passed under Xvfb |
| Linux x64, Debian 12 | Linked app, Vulkan/readback integration and native render/recreation/cleanup passed under CPU emulation |
| Signed iPhone 16 Pro, iOS 27 | Built and installed; wireless debugger discovery timed out before test results |
| Manual macOS desktop | Ball creation, pause/resume, ray and overlap controls inspected |
| Narrow layout | Integration test exercised 396 by 800 without Flutter errors; manual capture unverified |

Result excerpts are saved in [test-results.txt](test-results.txt). The
[Intel macOS binary record](macos-x64-build.json) and
[Intel iOS simulator binary record](ios-simulator-x64-build.json) list the verified
slices. The [Android ABI record](android-abis-build.json) identifies the packaged
libraries, and [cross-target checks](cross-target-checks.json) record the remaining
Rust compilation checks. The multi-ABI APK was inspected after building; the Pixel
integration result comes from the separate device test build.

Linux arm64 ran inside Docker on an Apple Silicon host. Its Vulkan adapter was
`llvmpipe (LLVM 15.0.6, 128 bits)`, Mesa 22.3.6. Linux x64 used Docker's amd64 CPU
emulation on the same host with llvmpipe's 256-bit variant. These are software
rendering checks. Physical Linux GPU qualification is still open.

## Render and lifecycle evidence

The native runner simulates a falling sphere and a motorized hinge, pauses the
world, recreates the renderer at 640 by 400, and closes the engine and world.
All saved runs put the sphere at `0.4999312162399292` metres, include collider,
joint and contact debug geometry, and return body/world counts to zero.

| Backend | Image | Measurements |
| --- | --- | --- |
| macOS Metal | [Render](macos/metal-physics.png) | [JSON](macos/native-physics.json), 245 pixel colours |
| Linux arm64 Vulkan, llvmpipe | [Render](linux-arm64-vulkan.png) | [JSON](linux-arm64-native.json), 239 pixel colours |
| Linux x64 Vulkan, llvmpipe under emulation | [Render](linux-x64/vulkan-physics.png) | [JSON](linux-x64/native-physics.json), 239 pixel colours |

Host checks ran against the shared working tree while other changes were in
progress. The Linux x64 container used tracked snapshot
`94edf1967b74c455f15dea8dcdbaccde4bd46d6e`, with the qualification runner from
`79955c6`. The Linux arm64 snapshot's exact commit wasn't captured; its source
hashes were recorded before removing the container:

```text
65c516da32d9bb2c7ac17f304bee43e283d3d6be15ce2b06be4b8b52197d33c5  packages/zyren_physics/native/src/lib.rs
abc1fcd3f5ee956ddc93601fc3cf85383b670907d096910e7724926fc9cfcfb0  packages/zyren_native/native/src/scene.rs
```

## Reproduce

From the repository root:

```sh
flutter pub get
dart analyze packages/zyren_physics examples/physics_lab
dart run tool/check_package_boundaries.dart
cargo +1.97.1 fmt --manifest-path packages/zyren_physics/native/Cargo.toml --check
cargo +1.97.1 clippy --manifest-path packages/zyren_physics/native/Cargo.toml --all-targets --locked -- -D warnings
cargo +1.97.1 test --manifest-path packages/zyren_physics/native/Cargo.toml --locked
```

Run `dart test --concurrency=1` from `packages/zyren_physics`. Use the Dart bundled
with the Flutter version above and set `FLUTTER_ROOT` to that SDK.

From `examples/physics_lab`:

```sh
dart run tool/qualify.dart qualification/local
flutter test integration_test/physics_lab_test.dart -d macos --no-pub
```

Replace `macos` with your device ID for Android or the iOS simulator. For headless
Linux, install GTK development files, Clang, CMake, Ninja, Mesa Vulkan, Xvfb and
xauth, then run:

```sh
flutter build linux --debug --no-pub
xvfb-run -a flutter test integration_test/physics_lab_test.dart -d linux --no-pub
```

For the Intel Apple builds, use Xcode with `ARCHS=x86_64`,
`ONLY_ACTIVE_ARCH=NO`, `FLUTTER_TARGET=lib/main.dart`,
`CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`. The macOS build used
`macos/Runner.xcworkspace`, scheme `Runner`, configuration `Debug` and destination
`generic/platform=macOS`.

Prepare the iOS simulator configuration first:

```sh
flutter build ios --simulator --debug --config-only --no-codesign --no-pub
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios-intel "BUILD_DIR=$PWD/build/ios" \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO FLUTTER_TARGET=lib/main.dart \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Using a separate derived-data directory without Flutter's configured `BUILD_DIR`
first failed to find `Flutter/Flutter.h` in the integration-test Swift package.
The command above linked successfully. The binary records verify the bundled
physics and renderer frameworks as well as the app executable.

You can use the driver command in the [example README](../../README.md) for a
wireless iPhone. The signed install completed here, but no pass was recorded
because Flutter never connected to its debugger. The device needs to be unlocked
with Local Network access allowed, or connected by USB, before retrying.

## Open checks

Windows arm64/x64 need Windows hosts. Intel macOS and iOS simulator execution need
an available x64 runtime; Rosetta is absent on this Mac. Android armv7/x64 execution
needs a matching device or emulator. Native library compilation from earlier
checks remains separate from these execution results.

The local CI workflow includes both desktop architectures and saves fresh render
artifacts. It hasn't run remotely because the physics commits and workflow haven't
been pushed. Manual narrow inspection also remains open: the capture tool kept
returning the desktop window size after resizing was requested.
