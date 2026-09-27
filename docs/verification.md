# Verification

Checked locally on 26 September 2026 with Flutter 3.47.5, Dart 3.13.4,
Rust 1.97.1 and Xcode 27.0.

| Target | Build | Runtime evidence |
| --- | --- | --- |
| macOS ARM64 | Debug and release apps passed | Apple M3 Max / Metal pixel tests, Dart FFI tests and Flutter integration test passed; globe and wrapping controls inspected in desktop and narrow native windows; standalone release launch rendered without a development runner |
| iOS ARM64 simulator | Debug app passed | iPhone 17 Pro simulator on iOS 26.0 passed the Flutter integration test with a rendered native image |
| Android ARM64 | Debug and release APKs passed | Pixel 9 Pro / Mali-G715 public Vulkan SceneView passes updates, remount, independent cameras, resize/visibility and 100 create/remove cycles with zero presentation readback; broader composition and device qualification remain open |
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
into Flutter. The experimental Apple texture bridge avoids this transfer but fails its
compositor-retention gate. The newer native Metal view path also avoids readback;
its integrated checks are recorded below. No frame-rate target has been verified. The renderer supports
opaque indexed meshes, diffuse directional lighting, an unlit material and RGBA
color textures with supplied mip levels.
Custom native shader/pass registration, image decoding, glTF, PBR, shadows,
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


## Native Metal platform view proof

The experimental AppKitView/UiKitView adapter renders a static core scene into
CAMetalLayer drawables through Rust. Both macOS and the iOS 26.0 simulator pass
three integrations: two simultaneous views with resize and independent
suspension; 100 create/remove cycles returning to the ownership baseline; and a
rejected scene with an observable error and complete renderer cleanup.
Presentation reports zero renderer readback bytes. The 21 Rust tests include an
explicit capture that changes the adapter's readback diagnostic by 512 bytes,
which guards against a hardcoded zero.

The iOS OS screenshot compares actual native pixels against Flutter reference
widgets. Four corner colors and gray match exactly. With 50% Flutter opacity,
rotation and rounded clipping, 99% of pixels differ by at most one channel value.
The screenshot checker permits fewer than 1% of pixels to differ by more than
two for rasterized edges; the capture measured 0.87%. Native material alpha is
not implemented by this fixture.

The standalone macOS release smoke rendered 884 frames across two views and
returned to zero live/retiring renderers and held drawables after removal. It
uses the loaded Rust native asset's runtime identity. The simulator demo is
running for visual inspection. macOS foreground inspection remains unavailable
on the locked desktop. See the [commands and limits](apple-presentation-checkpoint.md).

This proof does not yet implement SceneView presentation, scene updates, plugin
hooks, pointer delivery or complete visibility/recovery policy. Default backend
capabilities stay unchanged. Physical iOS qualification, Android and Windows
presentation, and Swift Package Manager packaging remain open.

## Native Metal SceneView integration

`SceneRuntime.nativeMetal()` now connects native Metal views to the core engine.
Both macOS and iOS 26.0 simulator pass five integration tests: updates and hooks
with borrowed remount, independent cameras and teardown, physical resize and
visibility, 100 managed create/remove cycles, and explicit pixel capture.
Normal presentation reads back zero bytes. Capture returns the expected red
RGBA pixel and reports 11,844 bytes for a 63 by 47 image.

The lifecycle suite reproduced a native cleanup crash caused by capturing a
shared_ptr reference parameter in an async block. The helper now receives an
owning value. All 100 cycles on each platform return sessions, live and retiring
renderers, and held drawables to zero after the fix.

The 50 core/geospatial tests and 51 Flutter/example tests pass. Analyzer, Dart
formatting and package/header boundaries pass. The Apple backend uses the existing
Rust renderer without changing its implementation in this checkpoint. The
native view capability is explicit; strict shared-texture requests still fail.

The independent static review found no correctness defects. It recommends a
dedicated native regression for disposal while view creation or rendering is
pending. Existing widget cancellation tests cover that contract at the Flutter
boundary, but completed-frame native cycles do not prove those races. Physical
devices, OS-delivered input, native alpha and automatic device-loss recovery
remain open qualification work.

The standalone macOS release SceneView smoke passed: 937 frames presented across
two controllers, zero readback, then zero sessions, live/retiring renderers and
held drawables after removal. Its statistics subscriptions receive sampled
diagnostics, so native presentation counters provide the total frame count.

The final macOS release demo was inspected visibly through native app controls:
both cameras render, mesh edits update the display, and the left view closes and
reopens while the right remains active. The app is left running. The iOS
simulator demo was relaunched and its narrow layout was inspected in
`artifacts/ios-native-scene.png`. That local screenshot is a run artifact.

## Native lifecycle and Android surface follow-up

Four deterministic Apple race scenarios now pass on macOS and iOS simulator:
close during creation, dispose before attachment, delayed attachment across
remount and dispose during native frame completion. Ownership returns to zero;
stale work cannot publish. These gates are absent from the macOS release binary.

The Android native surface fixture passes on the physical Pixel 9 Pro, with
100 resizes, portrait/landscape requests, replacement, suspension and 100
create/remove cycles. After unlocking the phone, OS screenshots confirm correct
corner order and exact opaque RGB/gray samples. ADB input exercises pause/resume,
resize and close/reopen. Stable keys on the demo's layout children fix the second
renderer restarting when the first closes. The regression reproduces that extra
creation before the fix, and the rebuilt release preserves the surviving session.

Android Home stops frame reports; returning resumes both native surfaces with
new generations and zero readback. The final release capture records 4,470 and
6,600 submitted frames. All 52 Flutter/example tests, analyzer and Dart formatting
pass after the demo fix. The preceding native checkpoint passed 21 Rust
GPU/ownership tests and package boundaries. See the
[Android checkpoint](android-presentation-checkpoint.md) for commands, evidence
files and remaining platform gates.

## Public Android SceneView

`SceneRuntime.nativeAndroid()` selects Vulkan presentation through Flutter's
SurfaceProducer on Android API 29 or newer. A controller owns its renderer and
geometry residency; a view attachment owns its replaceable Flutter texture.
Detach releases that texture while a borrowed controller remains reusable.
The runtime supports native/shared-texture policies and explicitly reports no
RGBA capture support.

The Pixel passes all four supported public SceneView tests, including 100
managed cycles with zero resources left over. The separate attachment test
checks stale IDs and geometry reuse. Review found a race between epoch checking
and publication; a deterministic worker gate reproduced it as an extra native
presentation after revocation. Publication now claims its generation atomically.

The final combined Android run passes six integrations with capture skipped.
The race gates are absent from the release DEX. The ARM64 release demo was
inspected on the Pixel: camera edits remain independent, shared mesh edits update
both views, close/reopen works and rendering resumes after Android Home. The
final screenshot is `artifacts/android-native-scene-release-final.png`.

All 56 Flutter/example tests and the five macOS native SceneView tests pass.
Analyzer, formatting and package boundaries pass. Explicit Android capture,
physical iOS, Windows, broader mobile GPU qualification and device-loss testing
remain open.

## Binary scene resources, 2026-09-27

Scene snapshots now retain immutable CPU geometry recipes. Dart sends typed
binary geometry and changed mesh records; Rust resolves the resulting buffers
through the resource registry. Two explicit readback views can share one worker
and device. The GPU test renders both, verifies one 720-byte box upload, moves
and hides it without another upload, closes the first view, restores the second
view's red pixels, then removes the final owner and verifies zero resident bytes.

The Metal host passes 61 core/geospatial tests, 14 native Dart tests with serial
execution, 56 Flutter/example tests and 33 Rust tests including every ignored GPU
test. Protocol coverage includes every truncation of empty and populated frames,
bad counts/indices/flags, nonfinite transforms, stale revisions and seeded byte
mutations. A rejected delta leaves the previous native scene usable. Analyzer,
strict Clippy, formatting, C resource-header syntax and package boundaries pass.

Release validation caught a first-frame crash in Dart 3.13.4's compiled encoder
that did not occur under the JIT. A standalone executable reproduced it without
Flutter or GPU calls. Selecting full replacement before entering the delta loop
avoids the nullable baseline access. The core suite now compiles and runs this
scenario with first-frame, transform, unchanged-frame and visibility checks.

Five native SceneView integrations and two resource integrations pass on macOS.
The view run includes 100 mount/close cycles with zero remaining renderers and
drawables, plus explicit capture. Flutter failed to launch the resource test
after the first integration app; rerunning that file alone passed both tests.
The standalone `shared_views.dart` example also passed its upload, pixel and
cleanup checks.

The Android ARM64 release build passes (21.2 MB). The Pixel is disconnected, so
the new binary scene integration could not run on Vulkan in this checkpoint.
Earlier Pixel resource/view evidence above does not qualify this new packet
path. Flutter platform views still own separate devices; shared-device rendering
is currently an explicit readback backend capability. This checkpoint adds no
new iOS, Windows or Linux runtime qualification.

The fixed macOS release app builds (48.1 MB), starts and remains running. Visual
inspection of that release is pending because the Mac locked before the check.

## Opaque color textures, 2026-09-27

You can map an immutable RGBA image onto UV0 or UV1 with an independent sampler.
Metal pixel tests check the four corners, nearest/linear filtering, repeat,
clamp and mirrored repeat, supplied mip sampling and linear/sRGB conversion.
They also check mixed textured/untextured draw order, hidden-image retention,
shared-view teardown and zero resident bytes after removing the final owner.
Alpha stays opaque, including when the source alpha is zero.

Checks pass: 63 core/geospatial tests, 16 native Dart tests, 57 Flutter/example
tests and 36 Rust tests including real GPU tests. The Rust count includes the
new populated texture-packet test run after the full suite. Bounds checks cover
truncation, image extents/mips, UV flags, nonfinite UVs, sampler values, image
ownership and seeded mutations. Invalid image edits leave the prior frame usable.
The standalone AOT regression also exercises a first textured frame and a sampler
edit. Analyzer, strict Clippy, formatters, C-header syntax and package boundaries
pass.

All six macOS native SceneView integrations pass. On the physical Pixel 9 Pro,
eight Vulkan integrations pass with the unsupported platform-presenter capture
case skipped. Those checks cover the new texture view, the earlier binary scene
migration, 100 view cycles, shared scene images and explicit resource transfers.
The separate readback backend verifies sRGB gray 128 and linear gray near 188,
one upload across two owners, retention through hide/close/restore and final
release. Ordinary native presentation reports zero readback bytes on both hosts.

The previous two-camera macOS release was visibly checked after the Mac unlocked.
The textured macOS release builds at 48.4 MB and runs independently. Its nearest,
linear and mirrored-repeat controls visibly change the textured plane. The
Flutter layout test checks working controls at 320 pixels wide.
The Android ARM64 release builds at 21.4 MB and launches on the Pixel through
Flutter's release runner. Its automated Vulkan checks above provide the pixel
and lifecycle evidence; the manual visual check was on macOS.

Task 2 remains open. PNG/JPEG decoding, automatic mip generation, dynamic
attributes, alpha modes, render ordering and portable lines/points are pending.
Box and sphere UV generation is pending too. Public native view presenters still
own separate devices. No new iOS, Windows, Linux or Adreno qualification was run.


## Dynamic geometry checkpoint

Fixed typed layouts and position, normal and UV range updates pass 63 core tests,
8 geospatial tests, 21 native Dart tests with GPU execution, 59 Flutter/example
tests and 50 Rust tests including GPU cases. The AOT encoder regression covers
an accepted dynamic update followed by a frame with no geometry upload. Analysis,
strict Clippy, formatting and package/header boundary checks pass.

Native integration passes on macOS Metal and the physical Pixel 9 Pro's Vulkan
backend. Two views retain different captures of one geometry; closing the old
owner retires its version. An exclusive position/normal edit to the same vertex
uploads 24 bytes and retains one allocation. Changed UV rows produce the expected
red-to-green pixels. Removing the final mesh returns resident bytes to zero.
Malformed patch ranges, every packet truncation and reproducible packet mutations
are rejected. Rejected patches preserve prior pixels, ownership and revisions.

The float32 vertex contract required a 1e-7 ellipsoid normal tolerance. Geodetic
round-trip and local-frame precision tests still use their stricter float64
bounds. Example tests run from their owning package so Flutter bundles the image
fixtures; CI uses the same commands.

The macOS release demo was rebuilt and inspected through its native controls.
Deform changes the visible shape, Shift UV moves its texture coordinates, and
PNG and JPEG decode into that same edited mesh. Desktop and narrow native
windows were inspected. The demo uses direct native Metal presentation.
macOS release (49.1 MB) and Android ARM64 release (21.7 MB) builds pass. Task 2 remains open for index widths, automatic mips, alpha modes,
ordering and portable lines/points. Native material shaders still reject tangent,
color, joints and weights. This checkpoint adds no iOS, Windows, Linux or Adreno
qualification and makes no Three.js or Takram parity claim.
