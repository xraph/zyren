# Physics qualification, 2026-10-02

You can reproduce these checks with Flutter 3.47.5, its bundled Dart 3.13.4,
Rust 1.97.1 and Rapier 0.36.0. The package remains unpublished.

## Results

| Check | Measured result |
| --- | --- |
| Physics package | 17 tests passed on all six hosted desktop architectures |
| Rust package | 3 tests passed; strict Clippy and rustfmt passed |
| Rust cross-target checks | Windows arm64/x64 and Android armv7/x64 passed without linking or execution |
| Static checks | Dart analysis, formatting and package boundaries passed; workflow passed actionlint |
| macOS arm64 | Linked app and Metal/nativeView integration passed |
| macOS x64 | Linked app, 17 package tests and native Metal render/recreation/cleanup passed; app integration failed on GPU completion timeout |
| Pixel 9 Pro, Android 17 | Linked APK and Vulkan/sharedTexture integration passed |
| Android armv7, arm64 and x64 APK | Physics, renderer and surface libraries packaged; ELF architectures verified |
| iPhone 17 Pro simulator, iOS 26.5 | Linked app and Metal/nativeView integration passed |
| iOS simulator x64 | Linked app passed; bundled app and native frameworks verified as x86_64; execution open |
| Linux arm64, Debian 12 | Linked app and Vulkan/readback integration passed under Xvfb |
| Linux x64, Debian 12 | Linked app, Vulkan/readback integration and native render/recreation/cleanup passed under CPU emulation |
| Hosted Linux arm64/x64 | Linked apps, Vulkan/readback integration and native render/recreation/cleanup passed |
| Hosted Windows arm64/x64 | Linked native-architecture apps, DX12/readback integration and native render/recreation/cleanup passed |
| Android x64 emulator | First attempt ran out of disk before boot; retry pending |
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

## Hosted qualification

The [desktop and mobile build run](https://github.com/xraph/zyren/actions/runs/37032185252)
tested `847d041e9d79ac231f2ba9bb9cc0a48adc26f425`. Five desktop jobs and the
mobile build job passed. Intel macOS passed its package tests and native render,
then failed the app's kinematic assertion after resume: the position was still
zero when the test expected two metres. Its original 400 ms pump loop did not
wait for asynchronous native frames.

The [Intel macOS retry](https://github.com/xraph/zyren/actions/runs/37037930833)
tested `0c01e9f` with a bounded 30-second wait for the same pose assertion and
an explicit renderer-failure check. The renderer reported `GPU completion failed;
recreate this renderer: The requested Wait timed out before the submission was
completed.` The native renderer's GPU wait is bounded at two seconds. This result
does not establish whether the cause is the hosted GPU or the native-view path.
Intel macOS app integration remains failed. Package tests and native offscreen
render/recreation/cleanup passed again on the retry.

The first [Android x64 run](https://github.com/xraph/zyren/actions/runs/37035431446)
could not boot the emulator: its userdata partition needed 7.37 GB while the
runner had 5.86 GB free. No app tests ran. The
[retry](https://github.com/xraph/zyren/actions/runs/37037728562) removes unused
runner toolchains and uses a 2 GB userdata partition with SwiftShader Vulkan.
That emulator booted, but the log stopped during Gradle compilation with no
compiler diagnostic or test result. The
[next run](https://github.com/xraph/zyren/actions/runs/37039990216) bounds Gradle
and Cargo concurrency, builds the test APK first, then runs it in a 2 GB emulator.
The APK built and launched, then failed a layout assertion before renderer
qualification. The reduced 480 by 800 display had retained the Pixel's high
density, leaving about 183 by 305 logical pixels. The [next run](https://github.com/xraph/zyren/actions/runs/37041893216) sets
density to 160 before launch and saves the test APK as an artifact; its result
is pending.
Software Vulkan execution does not establish physical Android GPU coverage.

The [Intel iOS simulator run](https://github.com/xraph/zyren/actions/runs/37038863037)
found an available iPhone simulator on the hosted x86_64 Mac. Its build and Metal
integration result is pending.

You can inspect the exact commits, job and step conclusions in
[ci/runs.json](ci/runs.json), and selected output in
[ci/test-results.txt](ci/test-results.txt). All six native render runs passed
renderer recreation and returned body/world counts to their zero baseline:

| Runner | Backend | Image | Measurements |
| --- | --- | --- | --- |
| macOS arm64 | Metal | [Render](ci/macos-15/metal-physics.png) | [JSON](ci/macos-15/native-physics.json), 245 colours |
| macOS x64 | Metal | [Render](ci/macos-15-intel/metal-physics.png) | [JSON](ci/macos-15-intel/native-physics.json), 252 colours |
| Linux arm64 | Vulkan | [Render](ci/ubuntu-24.04-arm/vulkan-physics.png) | [JSON](ci/ubuntu-24.04-arm/native-physics.json), 239 colours |
| Linux x64 | Vulkan | [Render](ci/ubuntu-24.04/vulkan-physics.png) | [JSON](ci/ubuntu-24.04/native-physics.json), 242 colours |
| Windows arm64 | DX12 | [Render](ci/windows-11-arm/dx12-physics.png) | [JSON](ci/windows-11-arm/native-physics.json), 244 colours |
| Windows x64 | DX12 | [Render](ci/windows-latest/dx12-physics.png) | [JSON](ci/windows-latest/native-physics.json), 244 colours |

The hosted evidence records the native backend, not the adapter model. It does
not qualify specific physical GPUs. Windows arm64 bootstrapped the pinned
Flutter source and built an arm64 app; it did not use an x64 Flutter process.

The separate [Native checks run](https://github.com/xraph/zyren/actions/runs/37032185202)
failed repository-wide formatting in eight files outside physics. Its mobile
job also timed out downloading Rust; the mobile job passed on the
[subsequent run](https://github.com/xraph/zyren/actions/runs/37037729129). The
formatting failures remained on all three desktop hosts. The physics workflow's
scoped formatting and Rust checks passed, but repository-wide checks are not green.
The [formatting failure list](ci/repository-formatting-failures.txt) names the eight files.

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

Intel macOS app integration needs investigation of the GPU completion timeout.
Android x64 emulator and Intel iOS simulator execution await their results.
Android armv7 execution needs a matching device. The
signed iPhone debugger connection and physical GPU coverage described above also
remain open.

Manual narrow inspection remains open: the capture tool kept returning the
desktop window size after resizing was requested. The iOS simulator integration
ran, but a Simulator app window was not available for manual inspection.

The qualification branch was pushed with approval. Remote main is unchanged.
Later commits and uncommitted work in the shared main checkout are outside this
record's tested snapshots.
