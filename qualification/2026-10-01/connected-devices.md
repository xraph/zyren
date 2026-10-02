# Connected-device follow-up

The Pixel 9 Pro is connected over USB. It is awake and unlocked, running Android
17 (API 37). Apple reports the iPhone 16 Pro on iOS 27 as paired over
`localNetwork`, with Developer Mode enabled. Its connection is still wireless.
The iPad and Watch remain unavailable in the Apple device inventory.

Native runtime qualification is blocked on both phones. These runs follow the
earlier report; they do not replace its historical source snapshots. The new
commands, commits, dirty source hashes and outcomes are in
`connected-devices.json`. Full local logs are at
`/tmp/zyren-qualification-connected`.

## Android startup failure

The APK builds and installs, but its native runtime cannot load:

```text
Couldn't resolve native function 'fg2_runtime_token'
Failed to load dynamic library 'libzyren_runtime.so'
dlopen failed: cannot locate symbol "_ZTISt12length_error"
```

Three checks reproduce the failure or its immediate effect:

- `timeline_workbench_test.dart` times out waiting for the timeline control to
  become enabled. It does not reach playback or a marker assertion.
- `qualification_native_layout_test.dart` surfaces the loader error directly.
  It measures the real phone viewport as 426.7 by 952 logical pixels, with no
  test surface override. Native rendering never becomes ready.
- `android_presentation_test.dart` fails at `NativeSurfaces().runtimeToken`
  before creating a Vulkan surface.

The packaged runtime's ELF dependencies include `libstdc++.so`. Its dynamic
symbol table contains unresolved `_ZTISt12length_error`, `__cxa_throw`,
`__cxa_begin_catch` and `__cxa_end_catch`. The APK has no `libc++_shared.so`.
The extracted library's SHA-256 and dependency list are in the JSON evidence.

The locally installed `meshopt` 0.6.2 build script matches Android's
`aarch64-linux-android` target through `target.contains("linux")` and explicitly
selects `stdc++`. The `basisu_c_sys` 0.9.1 build script explicitly selects
`c++_static` on Android. Both versions are pinned in
`packages/zyren_native/native/Cargo.toml`; the native build hook delegates to
`RustBuilder` in `packages/zyren_native/hook/build.dart:15`.

This points to the Android C++ runtime link configuration. The native build
owner needs to resolve that configuration and verify the packaged library loads
before we can qualify outlines, timeline, persistence, Vulkan presentation or
GPU disposal. Qualification work did not change those implementation files.

## iOS launch failure

`flutter test` rejects the wirelessly tethered phone before starting the test.
The dedicated `flutter drive` attempt uses `--publish-port` and the existing
signing configuration. Its device build passes in 30.9 seconds.

Xcode then stalls during installation and launch. Flutter reports that it has
not discovered the VM service after 75 seconds. The qualification launcher was
interrupted after about six and a half minutes. It returned zero without
running the test, so its outcome is recorded as cancelled, not passed.

The user requested continuing over wireless. A profile build also succeeds,
but Flutter looks for `build/ios/iphoneos/Runner.app` while the artifact is in
`build/ios/Profile-iphoneos/Runner.app`. Packaging the signed profile app and
passing it through `--use-application-binary` still produces no VM service or
test result. That attempt was cancelled, despite its zero exit code.

Apple's `devicectl` successfully installs the packaged app over wireless and
launches it. The console then reports termination by signal 9 after about 30
seconds, with no integration-test completion. The IPA hash is recorded in the
JSON evidence. Installation and launch establish those steps only.

Other chats are concurrently launching GPU-diagnostics and section tests in
the same phone app. The generated Xcode target also changes during these runs.
The cause of signal 9 is not established. An isolated wireless qualification
window is required before attributing this result to the renderer or wireless
transport. Permission to coordinate those chats has been requested separately.

The native phone layout test should follow timeline, editing and persisted-review
checks once launch works. Neither phone run establishes the outstanding macOS
narrow-window visual check.

## Qualification test

`examples/multiple_views/integration_test/qualification_native_layout_test.dart`
uses the real device metrics and requires native presentation. It checks the
viewport, scene area, timeline controls, selection outline, mixed playback,
markers and zero readbacks, then waits for controller disposal in teardown.
Startup failures include the public scene issue instead of a generic marker
timeout.

Formatting and Dart analysis pass. Its Pixel run fails on the native loader
error above. That is an explicit blocker, not a passing native layout result.
You can repeat it from `examples/multiple_views` with:

```sh
fvm flutter test integration_test/qualification_native_layout_test.dart \
  -d <android-device-id>
```
