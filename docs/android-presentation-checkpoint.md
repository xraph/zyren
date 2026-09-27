# Android Vulkan presentation checkpoint

You can run the native surface fixture on an Android device with API 29 or newer:

```sh
cd examples/multiple_views
flutter run --release -d <device-id> -t lib/android_surface_demo.dart
flutter test integration_test/android_presentation_test.dart -d <device-id>
```

The example draws two four-color fixtures through Vulkan. Pause, resize or close
the first view using the controls above them. The status line reports submitted
frames and CPU readback bytes. The example keeps its own window awake while it
is in the foreground; it doesn't change your device's sleep settings.

This is an internal qualification bridge. Android `SceneView` integration is
next, and the default runtime still has its earlier capabilities. The fixture
doesn't establish full renderer, Three.js or geospatial feature parity.

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

ARM64 debug and release builds pass. The release demo runs two surfaces, each
past 2,940 submitted frames with zero readback. At this checkpoint the device's
keyguard hides OS composition, so visible corner order, gray values and user
interaction remain unverified.

The 21 Rust host tests, including real Metal GPU cases, and 51 Flutter/example
tests pass. Analyzer, Rust formatting, host Clippy and package/header boundaries
pass. Android target checking passes. Android Clippy passes with
`missing_const_for_thread_local` allowed on the command line: Rust 1.97 reports
it from `thread_local!` although the existing initializer is already `const`.
No source suppression was added.

## Remaining gates

- Wire this path into the public backend, presenter and `SceneView` lifecycle.
- Measure actual swapchain image count and resident bytes. The requested frame
  latency is two; that is a hint, not proof of the negotiated image count.
- Verify alpha, clipping, transformed composition, color and OS input.
- Exercise replacement and close during a deliberately pending GPU submission,
  engine detach, low-memory callbacks and device-loss recovery.
- Test a physical Adreno device, broader Android versions and release packaging
  beyond the pinned Flutter 3.47.5, AGP 9.1 and NDK 27.2 setup.

Keep the bridge experimental until these checks and the public adapter pass.
