# Declarative scenes on Android and iPhone, 3 October 2026

The bundled declarative integration passed on both physical devices below with
FVM Flutter 3.47.5. Each run executed the same scene test, including teardown.

| Device | OS | Runtime | Observed presentation | Result |
| --- | --- | --- | --- | --- |
| Pixel 9 Pro | Android 17, API 37, build CP3A.260905.009 | `SceneRuntime.nativeAndroid`, Vulkan | `sharedTexture` | Passed |
| iPhone 16 Pro | iOS 27.0, build 24A437 | `SceneRuntime.nativeMetal`, Metal | `nativeView` | Passed |

You can repeat these checks from `examples/multiple_views`. Use `flutter devices`
to find your device IDs, then run:

```sh
/Users/rexraphael/fvm/versions/3.47.5/bin/flutter test --no-pub integration_test/declarative_scene_test.dart -d <android-device-id>
/Users/rexraphael/fvm/versions/3.47.5/bin/flutter drive --no-pub --driver=test_driver/qualification.dart --target=integration_test/declarative_scene_test.dart -d <iphone-device-id> --publish-port
```

The Android command exited with code 0 and reported one passing test. The iPhone
driver also exited with code 0 and reported success for the scene test and its
teardown. The iPhone used a wired connection.

## What the runs checked

Both devices loaded the bundled PNG and animated glTF through native asset
services. An injected first texture read failed, the visible retry action loaded
the texture, and the error state cleared. The imported node's transform advanced
during playback and stayed fixed after pause.

The test injected pointer events through Flutter to check hover, capture outside
the cube, release, selection and missed clicks. Cube removal and restoration
changed presented draw counts. Orbit and FXAA toggled live, with a later presented
frame required after each FXAA transition. Camera and renderer identities stayed
the same, no plugin issue remained, and controller disposal completed within the
15-second timeout.

Every observed presentation reported zero `readbackBytes` and the device's
expected presentation path. These assertions cover the renderer and presenter;
they do not compare pixels or measure physical display scanout. Injected pointer
events do not qualify every hardware touch, mouse or stylus configuration.

## Build observations

The first iPhone attempt built successfully but did not start a test. Flutter
looked for `build/ios/iphoneos/Runner.app`, while the signed app was present under
`build/ios/Debug-iphoneos/Runner.app`. Inspection of Flutter's build flow showed
that it reads build settings before regenerating them. The regenerated settings
matched the actual output, and the same command then built, installed, connected
to the VM service and passed. No source or signing setting was changed, and no
app bundle was copied manually to bypass the failure.

The iPhone build reported the existing `flutter_zyren` Swift Package Manager
support warning; the first attempt also warned about the installed CocoaPods
version. Metal compilation reported an unused shader constant. Android reported
a Gradle Java native-access warning. None prevented the successful device runs.

The iPad was running another task and was left alone. This record covers the
listed Pixel and iPhone only. Other GPUs, OS versions, tablets, Linux, Windows and
DX12 remain unqualified for this scene. There were no screenshots or exhaustive
visual checks of every material, light, environment or effect.

See the [macOS record](2026-10-03-declarative.md) for the earlier desktop and
reference checks. These mobile runs used the existing integration unchanged.
