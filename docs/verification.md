# Verification

Checked locally on 26 September 2026 with Flutter 3.47.5, Dart 3.13.4,
Rust 1.97.1 and Xcode 27.0.

| Target | Build | Runtime evidence |
| --- | --- | --- |
| macOS ARM64 | Debug and release apps passed | Apple M3 Max / Metal pixel tests, Dart FFI tests and Flutter integration test passed; globe and wrapping controls inspected in desktop and narrow native windows; standalone release launch rendered without a development runner |
| iOS ARM64 simulator | Debug app passed | iPhone 17 Pro simulator on iOS 26.0 passed the Flutter integration test with a rendered native image |
| Android ARM64 | Debug APK passed | No device run yet |
| iOS physical device | Build target configured | Signing, device deployment and GPU behaviour not verified |
| Windows | Build hook and CI job configured | No Windows host build or runtime verification yet |
| Linux | Build hook and CI job configured | No Linux host build or runtime verification yet |
| Other CPU architectures | Rust target declarations configured | Not built or tested locally |

The CI workflow has been written but has not run remotely. Nothing has been
pushed. A simulator pass does not establish physical mobile GPU performance.

## Checks passed

- Rust: three tests, including the explicitly enabled native GPU test. Assertions
  cover actual pixels, front/back depth ordering, row padding, target resizing up
  to 4096 pixels, geometry release, malformed scenes and handle/finalizer cleanup.
- Dart: four scene/geometry tests and five geodesy tests. The geodetic round-trip
  test covers 200 combinations across WGS84 and a triaxial ellipsoid, including
  poles, the date line, negative heights and orbital altitudes.
- Plugins and viewports: 22 tests cover dependency ordering, typed services,
  unsupported capabilities, partial attach rollback, exclusive ownership, frame
  timing, injected renderer/presenter implementations, pending-frame replacement,
  initialization cancellation, retries, error-observer and frame-cleanup failures,
  hidden/resume transitions, unfocused startup and separate world models. The
  core imports no geospatial package.
- Dart/native: one FFI test covers actual pixels from a worker isolate, geometry
  eviction/re-upload, resizing, concurrent-frame rejection and disposal while a
  frame is in flight.
- Flutter integration: desktop and 390-pixel layouts, city selection, a non-null
  rendered GPU image and viewport removal. The plugin test also checks that city
  selection changes the camera through the orbit plugin and produces a new image.
- Flutter analysis, Dart formatting, Rust formatting and Clippy passed.

## Core extraction checkpoint

The core now lives in `gpu3d`, the native hook and renderer in `gpu3d_native`,
and Flutter presentation in `flutter_gpu3d`. Geospatial depends on `gpu3d` only.
The native crate and Cargo lockfile were compared byte-for-byte with the previous
commit after relocation; their contents did not change.

The extraction passed 25 Dart VM tests, 10 Flutter widget tests, two opt-in
Dart/native GPU tests, three Rust tests including real GPU pixels, analysis,
formatting and Clippy. The macOS integration passed rendering, city selection,
narrow layout and teardown from the new package layout. Its test runner reported
an inability to foreground the app; the rendering assertions still passed.
The headless Dart example also rendered the expected red centre pixel without a
Flutter engine. The rebuilt macOS release app launched independently and its
native globe was inspected visibly after the extraction.

`FrameSubmission` captures immutable scene/camera data. `NativeBackend` exposes
explicit readback output and rejects unsupported shared-surface requests. The
current Flutter view retains the original native default and readback behavior.
Physical mobile and Windows/Linux runtime qualification remain outstanding.
Earlier iOS simulator and Android build results above describe the pre-extraction
layout; they have not yet been repeated for the new packages.

## Known limits

Default example presentation copies RGBA data from the GPU to Dart and back
into Flutter. The opt-in Apple prototype avoids this transfer but fails its
compositor-retention gate. No frame-rate target has been verified. The renderer supports
opaque indexed meshes, diffuse directional lighting and an unlit material.
Custom native shader/pass registration, texture loading, glTF, PBR, shadows,
animation clips, picking, terrain streaming, atmosphere and clouds are not
implemented.

Geometry uploads are limited to one million vertices and three million indices
per frame. Resident geometry has a 64 MiB budget; frames support 1 to 4096 pixels
per axis and up to 4096 mesh instances. The protocol rejects unsupported sizes
and invalid data before rendering.

The build disables Rust's release debuginfo stripping because it produced a
misaligned Mach-O string table rejected by this macOS 27 host. The issue and
workaround are recorded in [rust-lang/rust#157750](https://github.com/rust-lang/rust/issues/157750).
The FFI test verifies that the resulting library actually loads.

## Observable values checkpoint

The scene and geospatial APIs now use immutable double-precision values. Core
revision/scheduler regressions and existing geodesy fixtures passed together
(35 Dart tests). The 10 legacy viewport tests, 2 native pixel tests, workspace
analyzer and macOS planet integration passed. The planet fixture uses a valid
ECEF starting camera before orbit attachment; field of view is now in radians.

The scheduler is tested in the core. Flutter controller integration is the next
checkpoint, so this does not yet establish idle rendering for the legacy view.

## Controller checkpoint

Managed and borrowed views now use one controller and frame scheduler. Coverage
includes rebuilds, replacement order, cancellation during initialization, typed
late cleanup failures, retry without duplicate setup, idle scenes, zero-size
layout, visible inactive windows, and remounting during an in-flight frame.

The macOS globe integration passed with the borrowed controller, public plugin
frame demand, hot-reload reassembly, city selection and narrow layout. Native
pixel tests and the 35 pure Dart tests passed after the camera contract change.
This checkpoint still presents native GPU frames through explicit RGBA readback.

## Input and policy checkpoint

Typed input fixtures cover transformed viewports at DPR 1.5, render scales 0.5
and 1, overlay taps and keyboard entry, pinch recognition, and wheel ownership
inside a Flutter scroll view. Policy fixtures cover unavailable shared textures,
explicit readback, plugin capability errors, sampled diagnostics and one automatic
device-loss recovery attempt. The macOS globe integration passed with plugin-owned
gestures, including a drag through the native view.

The pure Dart and native pixel suites passed after capability migration. Flutter
checks use 3.47.5; the declared 3.38 floor has not been rerun for this checkpoint.
Shared native surface registration remains plan 02 work.

## API milestone: scoped work and executable examples

The final review fixes passed 49 core/geospatial Dart tests, 34 facade widget
tests and three executable-example widget tests. The native package passed six tests:
three worker protocol tests and three real GPU tests, including a worker killed
without a dispose request returning its native handle count to baseline. Run
native tests from `packages/gpu3d_native`, with `RUN_NATIVE_GPU=1` and
`--concurrency=1`, so build hooks refresh the correct library and handle-count
checks run in isolation.

Both macOS integration suites passed: planet controls and the two-view example.
The latter verifies independent cameras sharing one scene, hot-reload reassembly,
390-pixel layout, closing/reopening a controller and continued native rendering
in the surviving view. Rust formatting, Clippy and all three Rust tests (GPU test
explicitly included), Dart formatting, package boundaries and analyzer passed.
The post-extraction iOS simulator debug build and Android ARM64 debug APK also
passed at 1102442. Those builds establish compilation, not a new device runtime
claim. Windows and Linux builds remain unverified locally.

Load cancellation primitives are implemented; built-in asset source resolution
and decoders are not. Native finalization is verified for worker isolate exit on
macOS. Whole Flutter-engine hot restart and OS process teardown on every platform
still belong to platform qualification. Presentation remains explicit readback.

## Final branch review

An independent reviewer found three cleanup/pacing defects. All three were
reproduced before repair: asynchronous stream cancellation escaped engine
cleanup; closing a supplied lifetime left rendering active; rounded vsync times
dropped valid frames. The fix tracks asynchronous cancellation, makes lifetime
closure stop and dispose the engine, and keeps fractional frame deadlines.

The final suites above and both native macOS integrations passed after the fixes.
Scheduling tests submit 600 frames over ten seconds of synthetic 60, 90 and
120 Hz ticks with a 60 FPS limit. This checks pacing logic, not measured GPU frame
rate. Additional regressions cover cancellation errors and lifetime closure
during a pending frame. The reviewer reported no separate minor findings.

The implementation decisions and remaining limits are recorded in
[API implementation decisions](api-implementation-decisions.md). The release
builds passed; a final desktop visual launch was blocked because the Mac was
locked. Automated macOS integrations still ran and rendered successfully.

## Native surface ownership checkpoint

The versioned surface registry and generated Dart ABI are implemented. The Rust
ownership tests cover GPU and consumer completion independently, stale identities,
resize epochs, timeouts and bounded frame requests. Flutter attachment tests cover
close during creation or resize, suspension, runtime mismatch and failed mutations.
See [native surface ownership](native-surface-ownership.md) for the contracts.

The existing two-view macOS integration still renders and closes both native
sessions. Its runner could not foreground the window. Surface metadata and tests
do not enable shared presentation: the examples continue to use explicit readback,
and debug/release plugin-to-FFI runtime identity remains an adapter integration check.

## Rust Metal target checkpoint

The Rust renderer can draw directly into an IOSurface-backed BGRA8 sRGB texture
created on its Metal device. The native fixture renders an opaque red triangle
over blue at 63 by 47 pixels, checks the resulting BGRA pixels after completion,
and verifies zero renderer readback bytes for that submission. An explicit RGBA
capture then checks the existing readback path. Capture reads in the fixture are
separate from renderer counters.

A second GPU test blocks the renderer's Metal queue for three seconds. The
two-second wait returns an error, retains the imported texture and rejects new
submissions. It then disposes the renderer in under 250 ms while the GPU is still
blocked. Native retirement keeps its device permit charged until the gate opens
and destruction completes. The same bounded wait protects explicit readback.

The current suite passes 19 Rust tests with GPU cases explicitly enabled, eight
native Dart tests, 49 core/geospatial tests and 42 Flutter facade tests. Clippy,
formatting, analyzer and package boundary checks pass. The rebuilt macOS release
app and existing two-view macOS integration pass with the pinned HAL patch.
The iOS simulator debug app also builds successfully. The macOS runner cannot
foreground its window on the locked Mac. Rust checks pass for Android ARM64 and
the iOS ARM64 simulator; these are compile checks, not device qualification.

The checkpoint review found three defects: Metal fence completion accepted failed
commands, native destruction could still block after a GPU timeout, and a Flutter
resize requested during a completion microtask could be lost. Regression tests
reproduced each failure. The renderer now checks retained Metal command statuses
through a small [pinned HAL patch](../packages/gpu3d_native/native/vendor/README.md),
retires failed device ownership off the caller's thread, and drains newer Flutter
requests before completing their shared operation. The process limits active and
retiring devices to 32; permanently blocked devices remain charged. All three
review fixes pass their relevant checks.

You can reproduce the separate compositor ownership experiment using
[the Apple probe](../experiments/apple_presentation/README.md). Its pixel-buffer
pool reused storage while a consumer still held the Metal texture. A fresh
IOSurface with a lifetime guard stayed owned through blocked GPU work and
released once afterward. The production bridge must prove that ownership path
inside Flutter before shared presentation is enabled. This checkpoint does not
qualify Flutter composition, physical iOS, Android or Windows presentation.

## Experimental Apple Flutter bridge checkpoint

The Apple plugin and Dart worker now share one native runtime and render real
Metal content into a Flutter Texture. The macOS test reads the composed texture's
red pixel and checks native raster-consumption counters with zero producer
readback. The stronger continuous-rendering and cleanup checks failed because
Flutter's Core Video cache retains the IOSurfaces. Three allocations remain
after macOS texture unregister; the three-buffer limit stops further publication.

The adapter therefore requires `experimentalAppleSurfaces: true` and is excluded
from default capability selection. The checked-in integration is a
characterization of that limitation. It is not a production qualification pass.
See the [checkpoint and reproduction](apple-presentation-checkpoint.md).

Review also found an epoch-race recovery defect: a discarded frame could evict
geometry in Rust while Dart still treated it as resident. The regression changes
epoch during an actual 1,000-mesh submission, then renders an evicted geometry.
`FG2_FRAME_SUPERSEDED` now records that scene changes were applied before
publication was cancelled. Early stale-epoch and backpressure errors leave the
upload cache unchanged. This preserves the immutable geometry ID contract.

A separate cleanup regression closes a surface, reuses its slot, and verifies
backend disposal still releases its worker without closing the replacement.
The native registration path rejects a detached texture registry and macOS's
zero failure result while preserving valid iOS texture ID zero.

The checkpoint passes 20 Rust tests including native GPU cases, 11 native Dart
tests, 50 core/geospatial tests and 46 Flutter/example tests. The existing macOS
two-view integration and experimental macOS/iOS simulator characterization pass.
The iPhone 17 Pro simulator on iOS 26.0 also reaches the cache bound while
rendering, but releases its three buffers when the texture is unregistered.
Neither platform passes the sustained shared-presentation gate.

macOS release and iOS simulator debug builds pass. Android ARM64 and iOS ARM64
simulator Rust checks pass. Analyzer, Clippy, formatting and the package/header
boundary guard pass. CocoaPods packaging is verified; Swift Package Manager,
release shared-runtime identity and physical platform qualification remain open.

The two-camera demo was launched in the iPhone simulator and its rendered views
were inspected in a simulator capture. That app uses explicit native RGBA
readback presentation. A macOS foreground launch remains blocked by the locked
desktop; automated native macOS integrations still run.
