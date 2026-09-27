# Native camera lab

Run the upstream Manhattan and Fuji camera poses over a local ECEF calibration
scene. You can change heading, pitch and roll without losing the geographic
target. Colored axes show east, north and up. The example uses the shared
SceneView and optional geospatial plugin.

From `examples/planet`:

```sh
flutter run -d macos -t lib/camera_lab.dart
```

Choose your iOS or Android device ID in place of `macos`. Apple platforms use
the opt-in native Metal view. Android uses the existing native GPU readback
presenter, identified in the interface. Windows follows that explicit readback
path but has not been built or run for this slice.

The preset longitude, latitude, heading, pitch and distance come from
`storybook/src/atmosphere/3DTilesRenderer.stories.tsx` at the pinned revision.
The local grid is calibration geometry. There are no streamed city tiles,
atmosphere, clouds or upstream Orbit/GlobeControls in this example.

## Runtime results

| Platform | Build | Runtime evidence | Presentation |
| --- | --- | --- | --- |
| macOS 27, Apple Silicon | Debug passed | Pose changes, roll input, 1100x760 and 390x700 logical layouts, cleanup; actual app window visually inspected | Metal platform view, zero readback bytes |
| iPhone 17 Pro simulator, iOS 26.0 | Debug passed | Same pose/layout test, zero live sessions/renderers/held drawables after disposal | Metal platform view, zero readback bytes |
| Physical Pixel 9 Pro, Android 17/API 37 | Debug APK built and installed | Rendered pixels contain all three calibration axes; switching to Fuji produces a new image; controller disposal completes | Native Vulkan, explicit RGBA readback |
| Physical iOS | Not run | Unverified | Unverified |
| Windows | Not built here | Unverified | Unverified |

The Android pixel test counted 6,653 red, 7,999 green and 7,010 blue pixels in
the initial rendered frame. These counts prove the calibration geometry reached
the output image. They do not compare the image against an upstream screenshot.

The Metal test observed three diagnostic frame samples on each platform.
Native counters returned to zero renderers, sessions and held drawables. Frame
diagnostics are sampled, so those samples are not an FPS measurement.

```sh
flutter test integration_test/camera_lab_test.dart -d macos
flutter test integration_test/camera_lab_test.dart -d YOUR_IOS_DEVICE_ID
flutter test integration_test/camera_lab_readback_test.dart -d YOUR_ANDROID_DEVICE_ID
```

Apple CocoaPods integration is checked in for this example. Flutter still warns
that the core plugin needs Swift Package Manager support. Packaging and physical
device qualification remain separate renderer milestones.
