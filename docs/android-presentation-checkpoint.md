# Android Vulkan presentation checkpoint

You can run the public SceneView demo on an Android device with API 29 or newer:

```sh
cd examples/multiple_views
flutter run --release -d <device-id> -t lib/native_scene_demo.dart
flutter test integration_test/native_scene_test.dart -d <device-id>
```

Select `const SceneRuntime.nativeAndroid()` in your SceneController or managed
SceneView. It implements the shared-texture output contract through Vulkan and
SurfaceProducer. Both `requireNative` and `requireSharedTexture` accept it.
Explicit capture is unsupported and is absent from its reported capabilities.

The lower-level `lib/android_surface_demo.dart` draws two four-color fixtures
through Vulkan. Pause, resize or close
the first view using the controls above them. The status line reports submitted
frames and CPU readback bytes. The example keeps its own window awake while it
is in the foreground; it doesn't change your device's sleep settings.

The Android runtime remains opt-in while broader platform qualification continues.
The default runtime still has its earlier capabilities. These examples don't
establish full renderer, Three.js or geospatial feature parity.

## Ownership and presentation

Kotlin owns Flutter's `SurfaceProducer`. Each render gets its current Surface,
and JNI obtains an `ANativeWindow` without passing a platform pointer to Dart.
Rust retains the window alongside the Vulkan swapchain and any acquired image.
It chooses a supported sRGB format and FIFO presentation. No frame pixels cross
JNI or Dart during presentation.

The bridge resolves symbols in the exact Rust asset already loaded by Dart and
checks its runtime identity. A mismatched identity fails connection. Each
session allows one pending render; native work runs on a serial worker. Resize,
replacement, suspension and surface callbacks revoke the attachment epoch.
Publication checks that epoch after rendering. Geometries remain resident
across surface replacement, with separate scene-applied and frame-presented
results so callers know when an upload has reached the renderer.

The public runtime creates a renderer before allocating a view attachment.
Detaching a borrowed controller releases its SurfaceProducer after queued native
work finishes, while keeping the renderer and uploaded geometry for remount.
Attachment IDs increase monotonically. A detached ID cannot recreate a surface
or close a newer attachment.

Publication claims the captured generation atomically. If revocation wins, the
completed image is discarded. If publication wins, it owns the old window until
the serial worker finishes presenting and processes detach or close. This gives
revocation and publication one ordering point without making the platform thread
wait for a Vulkan present call. The Dart receipt is also checked against the
current attachment and epoch.

GPU completion has the existing two-second wait limit. Failed renderer ownership
moves to bounded retirement, retaining the acquired image and window until GPU
idle or device loss. Android fault injection still needs to test this path on a
real Vulkan queue. Normal close releases the native renderer before unregistering
the Flutter producer.

Flutter's [SurfaceProducer guidance](https://docs.flutter.dev/release/breaking-changes/android-surface-plugins)
and the pinned [wgpu Surface API](https://docs.rs/wgpu/30.0.1/wgpu/struct.Surface.html)
define the platform boundary used here. The bridge doesn't call the undocumented
`scheduleFrame` method.

## Verified on 26 September 2026

The physical Pixel 9 Pro runs Android 17/API 37 with a Mali-G715 GPU. Its driver
reports `v1.r54p3-00eac0.03d8d836cbf5c9f29d765e58a6bdfb98`; the surface uses
`Rgba8UnormSrgb`. Flutter also reports its Vulkan Impeller backend.

The integration test passes two independent renderers, 100 resizes, surface
replacement with a changed native generation, landscape/portrait requests,
suspension/resumption and 100 create/remove cycles. Every cycle returns to zero
sessions, live renderers and retirements. Presentation readback remains zero.
The fixture first failed with a missing native adapter before implementation.

ARM64 debug and release builds pass. With the device unlocked, OS screenshots
show both opaque Vulkan surfaces with the correct corner order. Interior samples
match red, green, blue, white and sRGB gray `(128, 128, 128)` exactly, including
after resize and background/resume. The final capture records 4,470 and 6,600
submitted frames with zero readback.

You can pause, resume, resize, close and reopen the first surface using the demo
controls. Android input delivered through ADB exercised these actions. Closing
the first surface exposed a widget identity bug that recreated the second
renderer. Stable keys on the outer layout children fix it; the regression fails
without the keys, and the rebuilt release keeps the second renderer's frame
count advancing across close/reopen.

Pressing Android Home stops frame reports. Returning to the activity resumes
both surfaces with new native generations and zero readback. This checks normal
background/resume; pending GPU work and device loss remain separate gates.

The updated example passes all 52 Flutter/example tests, analyzer and Dart
formatting. The earlier native checkpoint passed 21 Rust host tests, including
real Metal GPU cases, Rust formatting, host Clippy and package/header boundaries.
Android target checking passed. Android Clippy passed with
`missing_const_for_thread_local` allowed on the command line: Rust 1.97 reports
it from `thread_local!` although the existing initializer is already `const`.
No source suppression was added.

Local evidence is saved under `artifacts/`: `android-vulkan-release-final.png`,
`android-vulkan-pixel-check.json` and `android-vulkan-background-resume.json`.
These run artifacts are ignored by Git. The color checks sample opaque fixture
interiors; they don't qualify alpha, edge blending or general color management.

## Public SceneView checkpoint

The physical Pixel passes four public SceneView integrations: scene updates,
plugin hooks, pointer input and borrowed remount; independent cameras; physical
resize and visibility; and 100 managed create/remove cycles. The suite records
142 presentations, zero ordinary readback and zero sessions, registered surfaces,
live renderers or retirements after removal. Android explicit capture is skipped
because this runtime does not implement it.

The shared suite also passes all five macOS tests, including explicit capture.
The 56 Flutter/example tests cover geometry residency after superseded frames,
late prepare replies, close during rendering and cross-renderer surface rejection.
Analyzer, Dart formatting and package boundaries pass.

The final combined Android run passes six integrations, with explicit capture
skipped. The attachment regression pauses the worker after its old pre-publication
check, revokes the epoch and verifies that the native presentation count does
not advance. It failed before the atomic claim was added. Those bounded test
gates are absent from the release DEX.

The rebuilt ARM64 release demo was inspected on the Pixel. Moving the left camera
changes only its image; editing the shared mesh changes both. Closing/reopening
the left view and Android Home/resume work. Both viewport regions match their
pre-background pixels after resume, and a subsequent mesh edit redraws both.
Evidence: `artifacts/android-native-scene-release-final.png`,
`android-native-scene-camera-check.json` and `android-native-scene-resume-check.json`.

## Remaining gates

- Add explicit capture to the Android surface runtime.
- Measure actual swapchain image count and resident bytes. The requested frame
  latency is two; that is a hint, not proof of the negotiated image count.
- Verify alpha, clipping, transformed composition, broader color handling,
  viewport gestures and physical touch input.
- Exercise replacement and close during a deliberately pending GPU submission,
  engine detach, low-memory callbacks and device-loss recovery.
- Test a physical Adreno device, broader Android versions and release packaging
  beyond the pinned Flutter 3.47.5, AGP 9.1 and NDK 27.2 setup.

Keep default selection disabled until the remaining qualification checks pass.
