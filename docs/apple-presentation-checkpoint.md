# Apple presentation checkpoint

The experimental bridge can render Metal content into a Flutter `Texture`
without sending frame pixels through Dart. It is disabled by default. Flutter's
Core Video texture cache retains old IOSurfaces and blocks the three-buffer
budget after a few frames, so this is an interoperability proof, not a qualified
viewport backend.

## What works

- The core engine and Flutter controller consume `FrameOutput`. Shared output
  carries frame statistics and a surface receipt; explicit capture carries pixels.
  Plugin `afterRender` hooks receive `FrameStats` through the same engine loop.
- Rust allocates an aligned, bounded IOSurface, imports its Metal texture into
  the renderer's device and waits for successful producer completion before
  publication. Normal shared rendering reports zero renderer readback bytes.
- The Apple plugin finds the existing `gpu3d_runtime` image with `RTLD_NOLOAD`
  and compares runtime tokens before accepting a surface. Flutter texture IDs
  stay separate from native surface identities.
- The macOS and iOS simulator integrations capture the actual texture and check its red center
  pixel. Native counters show Flutter's raster callback consumed the buffer.
  Test screenshot reads are separate from ordinary presentation counters.
- Native tests prove buffer turnover without Flutter, held-consumer backpressure,
  teardown after release and recovery when an epoch changes during GPU work.

The Rust framework has a distinct name because CocoaPods creates a
`flutter_gpu3d.framework` for the platform plugin. Both still use one native
registry. iOS uses its supported IOSurfaceRef header, and the native helper has
an explicit deployment floor instead of inheriting the installed SDK version.

## The failed gate

The first Flutter test checked a texture widget and one successful frame. A
stronger test required continued publication beyond the three-buffer bound and
zero retained allocations after teardown. That test failed: the producer stopped
after four frames, and three IOSurfaces stayed alive after macOS unregistration.
The iOS 26.0 simulator also hit the live-buffer bound during rendering, but its
texture teardown released all three buffers. Neither result meets continuous
rendering qualification.

A separate Core Video probe reproduced the cause without Flutter: imported
surfaces remained owned after their wrappers were released and after two seconds
of idle time. Explicitly flushing the texture cache released them. The plugin
does not own Flutter's cache and has no public API to flush it.

An experiment that re-notified Flutter about the current completed frame allowed
cache aging to resume allocation, but throughput remained poor and teardown still
retained buffers. It was removed. The implementation never increases the buffer
budget, fabricates consumer completion or reuses storage with an outstanding
owner to make this test pass.

## Reproduce the prototype

For development experiments only, you can enable the bridge explicitly:

```dart
final controller = SceneController(
  runtime: SceneRuntime(
    backendFactory: () => NativeBackend.create(
      experimentalAppleSurfaces: true,
    ),
  ),
);
```

The default backend does not advertise shared textures, and `requireSharedTexture`
continues to report `presentationUnavailable`. Existing runnable examples select
`readbackOnly` explicitly. They still render through native Metal; they do not
use WebGL or a browser.

From `examples/multiple_views`, run:

```sh
flutter test integration_test/apple_presentation_test.dart -d macos
```

This is a characterization test. It checks real pixels, zero producer readback,
runtime mismatch rejection and the known retained-cache behavior. A passing
result does not pass the continued-rendering or cleanup qualification gates.
The [standalone probe](../experiments/apple_presentation/README.md) records the
cache and GPU lifetime behavior independently.

## Next proof

Keep the public scene API and optional geospatial plugin unchanged. Prove a
supported presentation contract that permits prompt consumer retirement. The
next candidate is a native CAMetalLayer platform view whose drawable lifecycle
is owned by Metal. Verify Flutter opacity, clipping, transforms, input, resize
and removal before selecting it. Any texture alternative must establish an
explicit consumer lifetime guarantee; private engine selectors are not part of
the library design.

Then repeat continuous rendering, 100 route transitions, two views, release
runtime identity, four-corner color and alpha composition fixtures, and physical
iOS testing. Android SurfaceProducer/Vulkan and Windows DXGI remain independent
plan tasks. Three.js feature parity, assets/materials/animation and the full
geospatial port remain later milestones.

## Checks run

The checkpoint passes 50 core/geospatial tests, 46 Flutter and executable-example
tests, 11 native Dart tests, and 20 Rust tests with real GPU cases enabled.
Analyzer, Clippy, formatting and the package/header boundary check pass.
The existing macOS two-view integration passes through explicit readback.
The experimental texture characterization passes on macOS and iPhone 17 Pro
simulator with iOS 26.0, including rejection of a mismatched runtime token.

The macOS release app and iOS simulator debug app build. Rust checks pass for
Android ARM64 and the iOS ARM64 simulator. These builds do not prove release
shared-runtime identity, physical iOS behavior or Android presentation.

## Packaging limits

The shared Darwin plugin currently uses CocoaPods. Flutter 3.47.5 accepts this
and warns that Swift Package Manager support will become mandatory in a future
release. Add that packaging path before distribution. A build on the simulator
or a source-level Android check does not qualify physical-device presentation.
