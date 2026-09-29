# Verification

This file records successive checkpoints. Later sections supersede earlier
feature counts and limits; a historical runtime result is not a fresh device check.

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

The core now lives in `zyren`, the native hook and renderer in `zyren_native`,
and Flutter presentation in `flutter_zyren`. Geospatial depends on `zyren` only.
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
native tests from `packages/zyren_native`, with `RUN_NATIVE_GPU=1` and
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
through a small [pinned HAL patch](../packages/zyren_native/native/vendor/README.md),
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

## Compact index buffers

Explicit uint16/uint32 geometry passes 66 core tests, 8 geospatial tests, 23 native
Dart tests with GPU execution, 59 Flutter/example tests and 52 Rust tests including
GPU cases. The compact triangle regression places the next record after six
index bytes, checks actual pixel output and keeps an older shared version alive
after a dynamic edit. Input above 65,535 is rejected for uint16 and preserved for
uint32. No index conversion truncates values.

The compact plane passes the same Metal and physical Pixel Vulkan integration:
shared copies preserve pixels, merged dirty rows upload 24 bytes and final removal
releases all descriptor bytes. AOT encoding, malformed packets, truncation,
seeded mutations, analysis, Clippy, formatting and package/header boundaries pass.
The demo opts into uint16; existing callers retain the uint32 default. CPU patch
admission uses expanded recipe bytes independently of GPU index width.

The compact-index release demo builds for macOS (49.1 MB) and Android ARM64
(21.7 MB). Native macOS inspection confirms both the initial textured plane and
its deformed, UV-shifted version at narrow width. The new binaries use the same
public entrypoint. Android release launches successfully; sustained visual
interaction remains unverified. Its focused Vulkan GPU tests passed.


## Generated mipmaps

Automatic scene mipmaps and explicit `ResourceScope.generateMipmaps` pass 69 core,
8 geospatial, 25 native Dart GPU, 59 Flutter/example and 55 Rust tests including
GPU cases. AOT scene encoding combines generated levels with uint16 indices.
Analysis, strict Clippy, formatting and package/header boundary checks pass.

The same GPU fixtures run on macOS Metal and the physical Pixel's Vulkan backend.
A black/white sRGB image reduces to approximately 188, independent RGBA preserves
hidden colors, alpha-weighted RGB excludes them, and odd extents retain the last
row and column. Tests cover 1-by-N and single-level textures, regeneration,
shared ownership, cleanup and byte accounting. Invalid policies, usage, stale
keys, packet truncation and oversized generated chains are rejected before
mutation. Generated pixels do not count as uploaded bytes.

The native demo builds for macOS (49.2 MB) and Android ARM64 (21.7 MB). Metal UI
inspection confirms the Dense UV and Mips controls change the rendered texture.
Desktop and narrow layouts were checked; the 320-pixel widget test retains more
than 320 pixels of canvas height. Android GPU integration passed and the release
app launches on the Pixel. Sustained manual interaction with its release
presentation remains unverified.

This checkpoint generates RGBA8 linear and sRGB mip chains. Materials still
render opaquely; mask/blend modes, alpha coverage preservation, ordering and
portable lines/points remain open. It adds no iOS, Windows, Linux or Adreno
qualification and does not establish Three.js or Takram parity.

## Material alpha and draw ordering

Opaque, mask and blend modes pass 71 core, 8 geospatial, 26 native Dart GPU,
60 Flutter/example and 58 Rust tests including GPU cases. AOT encoding exercises
alpha state together with generated mipmaps and compact indices. Analysis,
strict Clippy, formatting and package/header boundary checks pass.

The same material fixture passes through Flutter on Metal and the physical
Pixel's Vulkan backend. Pixel probes cover source-over blending in linear light,
texture alpha multiplied by opacity, cutoff equality, opaque alpha, lit
materials, automatic depth writes and explicit depth overrides. Camera movement,
render order and dynamic geometry centers change draw order without reuploading
unchanged resources. Final removal releases all resident bytes. Invalid material
records, every packet truncation and seeded mutations preserve the prior scene;
older packet formats restore their opaque defaults.

The material demo builds for macOS (49.5 MB) and Android ARM64 (21.9 MB). Native
Metal inspection confirms that Mask, Blend and Depth order change the overlapping
planes at desktop and narrow widths. The 320-pixel layout test keeps more than
300 pixels of canvas height. The Android release launches on the Pixel; sustained
manual interaction with that release remains unverified.

The canvas remains opaque. Transparent Flutter composition needs its own output
color-conversion path, and object sorting cannot resolve intersecting transparent
triangles. Portable lines/points are the next Task 2 work. This checkpoint adds no
iOS, Windows, Linux or Adreno qualification and makes no parity claim.

## Portable lines and points

Line strips, independent segment pairs and point markers pass 73 core,
8 geospatial, 27 native Dart GPU, 61 Flutter/example and 61 Rust tests including
GPU cases. AOT encoding combines primitive and triangle records, then changes
point size without a geometry upload. Analysis, strict Clippy, formatting and
package/header boundaries pass.

Flutter integration passes two checks on each of Metal and the physical Pixel's
Vulkan backend: deterministic pixel tests and direct native presentation. The
pixel tests cover constant physical widths at different distances and aspect
ratios, world-size attenuation, point shapes, blending, segment pairs, degenerate
segments and near-plane clipping. Native views report zero readback bytes, and
camera, shape and size edits report zero uploaded geometry bytes.

Shared views retain one allocation until a dynamic position edit creates a new
recipe. The older capture keeps its pixels, closing its owner releases that
version, and final removal returns resident bytes to zero. Protocol tests cover
topology and size validation, expanded allocation limits, truncation and seeded
mutations. Invalid material/geometry pairs preserve prior pixels and ownership.

The release demo builds for macOS (49.5 MB) and Android ARM64 (21.9 MB). Native
Metal inspection checks Pixels/World, camera distance and circle/square markers
at desktop and narrow widths. The 320-pixel widget test retains more than 300
pixels of canvas height. Android release launch is checked separately; sustained
manual interaction remains unverified.

Lines currently use independent segment quads with butt ends. Joins, configurable
caps, dashes, textured sprites and antialiased edge coverage remain open. Object
alpha sorting does not reorder individual points or segments. Built-in box/sphere
UVs are next, before the final Task 2 audit and asset loading. This checkpoint adds
no iOS, Windows, Linux or Adreno qualification.

## Built-in texture coordinates

Box and sphere UVs pass 75 core, 8 geospatial and 28 native Dart GPU tests.
The same texture fixture passes through Flutter on Metal and the physical
Pixel's Vulkan backend. Six box faces preserve their expected image orientation;
four sphere quadrants sample the expected north/south colors. CPU tests cover
exact seam positions, pole UV midpoints and dynamic UV edits. Analysis,
formatting and package/header boundary checks pass.

The three existing resource integrations also pass on both devices. A uint32
box now uploads 1,104 geometry bytes, including its UV buffer. The native
shared-view example confirms that another view and device restoration reuse
the allocation, then final removal returns geometry residency to zero. Camera
changes in the new texture fixture upload no additional bytes.

This checkpoint changes geometry recipes and their allocation accounting. It
adds no renderer backend or platform qualification. Task 2's opaque native
presentation is unchanged; transparent Flutter composition remains tracked in
Task 4. Typed asset loading and glTF are next.

## Shared typed asset loading

Typed requests and scoped load ownership pass 93 core, 8 geospatial, 35 native
Dart and 66 Flutter/example tests. The native suite includes its GPU cases.
Analysis, formatting and package/header boundaries pass. Tests cover shared
fetch/decode, immediate and final-consumer cancellation, retry, late decoded
ownership, independent result release, reentrant disposal and cleanup failures.

Local HTTP fixtures check manual redirects, effective base URIs, forbidden
origins, unknown response lengths, gzip expansion, byte limits, cancellation,
HTTP errors and deadlines. File reads and Flutter bundle offsets/keys have their
own fixtures. Concurrent dependency and image tests check aggregate admission;
plain controller tests confirm that CPU loading starts no GPU backend.

The bundle-loading integration passes on Metal and the physical Pixel's Vulkan
backend. Two consumers share one fetch and one native PNG decode, then receive
separate templates over shared geometry and pixels. Releasing the templates
prevents new instances while existing meshes keep rendering. Both views upload
200 bytes together, surviving instances upload zero more, and final removal
returns native residency to zero.

The native primitives demo rebuilds for macOS (49.5 MB) and Android ARM64
(21.9 MB). The Metal release is visibly rendering at narrow width, and the
Android release launches on the Pixel. Sustained manual Android interaction
remains unverified.

The source adapters do not establish glTF support. Model parsing, accessor and
extension validation, worker responsiveness and the model viewer remain open.
HTTP fixtures ran on the desktop host; this checkpoint does not qualify mobile
network configuration or add iOS, Windows, Linux or Adreno evidence.

## glTF parser foundation

The optional `zyren_gltf` package passes 25 parser tests, including a compiled
Dart release executable. Fixtures cover GLB truncation and seeded mutations,
JSON depth/token limits and duplicate keys, version and extension errors,
relative buffers after redirects, embedded base64 payloads, URI policy, sparse
accessors, normalized integers, interleaved data and padded matrix columns.
Worker tests check bounded admission, cancellation, retry, error field paths and
caller event-loop responsiveness. All 101 core/geospatial tests pass alongside
whole-workspace analysis and package/header boundary checks.

This checkpoint provides internal decoder components. It does not expose public
model requests or claim glTF rendering support. Scene conversion, material
handling, independent model templates and native model-viewer fixtures remain
open. No renderer code changed, and no additional GPU or platform qualification
is claimed here.

## Native material sides

Front/back culling, double-sided rendering and back-face lighting pass 64 Rust
checks and 231 Dart/Flutter tests. The Dart count includes 25 glTF parser tests
and 36 native tests with GPU cases enabled. Strict Clippy, whole-workspace
analysis, formatting and package/header checks pass.

The same sidedness fixture passes through Flutter on macOS Metal and the
physical Pixel's Vulkan backend. Its 120 render probes cover plain and textured
materials, unlit and diffuse shading, both camera directions, negative and
nonuniform parent scales, and two nested reflections. Material/camera changes
upload no additional geometry. Removing the final mesh returns residency to zero.
Packet fixtures reject invalid side values, single-sided expanded primitives and
every truncation while preserving legacy double-sided defaults.

`material_side_demo.dart` uses public APIs and native presentation. Its controls
and disposal pass at 320px width with more than 350px of canvas height. Release
builds succeed for macOS (49.2 MB) and Android ARM64 (21.8 MB), and the Android
release launches on the Pixel. The Mac was locked during release UI inspection;
that manual check remains open. Sustained manual Android interaction also remains
unverified. These results add no iOS, Windows, Linux or Adreno qualification.

The first Android release build retained the integration-test plugin in a
generated Java registrant. Rebuilding with normal dependency refresh regenerated
the release plugin list and passed. Use a normal `flutter build` after running an
integration target; `--no-pub` can leave that generated development entry behind.

## Worker-prepared geometry and images

`GeometryData` and `TextureImageData` separate validated CPU storage from resource
identity. Four new tests check isolate transfer, unique caller IDs, owned immutable
inputs, padded rows and independent dynamic edits. All 132 core/geospatial/glTF
and 36 native Dart tests pass, including GPU cases. Workspace analysis and
package/header boundaries pass. This CPU handoff changes no native protocol or
platform support; public glTF model conversion remains in progress.


## Mask cutoffs above one

The core and native packet validator accept nonnegative finite float32 mask
cutoffs, including values above one. A real Metal image probe confirms that a
cutoff of 1.1 discards every fragment. Negative and nonfinite packet values
remain rejected. The focused checks pass: two core tests, seven Rust packet
tests and the native material-alpha fixture. This does not establish glTF
material parity.

## Public static glTF model loading

The public `Gltf.asset`/`Gltf.uri` path passes 52 glTF tests, including a compiled
release executable. Tests cover independent model templates and instances, shared
loads, cancellation during images, scope close, hierarchy validation, expanded
primitive limits, native transform ranges, seven topology modes, image buffer
views, normalized UVs, all minification filters and explicit material diagnostics.

The native glTF fixture loads PNG data through `NativeImageDecoder`, renders four
texture corners and mirrors the loaded instance. Two views share uploads.
Releasing templates preserves existing instances; closing one view preserves its
sibling. Removing the final instance leaves zero resident GPU bytes. The fixture
passes in native Dart on Metal and Flutter integrations on macOS Metal and the
physical Pixel's Vulkan backend. This establishes the tested static profile only.
PBR, deformation, additional extensions and platform qualification remain open.
The standalone viewer now passes two widget tests and its native integration on
Metal and Pixel Vulkan. That integration exercises GLB bundles, relative-file
glTF bundles, loopback HTTP dependencies and three reloads with zero presentation
readback bytes. The narrow layout retains over 270 logical pixels for the canvas
at 320 by 640. An explicit native capture also produced the authored assembly's
PNG with three draws and 36 triangles; this verifies the rendered artifact, not
the locked Mac's visible window. Manual macOS release inspection remains open.

The viewer release builds pass: macOS app 53.8 MB and Android arm64 APK 24.1 MB.
The first Android release attempt failed because a concurrent Flutter test
regenerated the plugin registrant with `integration_test`. A sequential build
with dependency refresh regenerated it correctly. Serialize Flutter tests and
platform builds in this workspace; do not repair generated registrants by hand.
The final analyzer, formatter and package/header boundary checks pass. Regression
coverage includes 159 core/geospatial/glTF tests (52 glTF), 37 native GPU tests,
57 Flutter facade tests, 10 existing example tests and two viewer widget tests.

The Android release installed and launched successfully on the Pixel, PID 21516
at verification. No Flutter or AndroidRuntime error was reported for that
process. The device's screensaver covered the app during the final inspection,
so a manual release-screen check is still pending. The integration tests and
standalone native PNG are the visual/rendering evidence for this checkpoint.

## Scoped WGSL compiler

Native WGSL module validation passes through the Dart worker on macOS Metal and
the physical Pixel's Vulkan device. Tests cover syntax and type errors, UTF-16
locations around emoji, duplicate-source caching, independent shared-view
ownership, foreign handles and close during pending compilation. Each fixture
renders an existing red mesh after a failed compile to verify that the device
remains usable, then checks that closing shader owners clears their cache.

The Rust tests also cover the 256-program and 16 MiB source budgets, response
capacity before mutation, strict command fields, cross-type handle rejection,
entry point stages and workgroup overrides. The complete Rust suite passes all
68 tests, including GPU tests. Clippy reports no warnings. Dart coverage passes
169 core/geospatial/glTF tests, 39 native tests and 57 Flutter facade tests;
workspace analysis, formatting and package/header boundaries also pass.
A scope regression also confirms that synchronous closure during stream
subscription still cancels the rejected listener.

The standalone `example/shader_compiler.dart` ran on Metal and reported a validated
compute entry point, a labeled error at line 1, column 45, and zero programs or
cached modules after close. This is module-validation evidence. Custom shader
dispatch, render graph execution and native platform-view bindings remain open.
The macOS integration passed even though the app could not be foregrounded;
the locked desktop's manual window inspection remains unverified. These checks
add no iOS, Windows, Linux or Adreno qualification.

The wider Rust run found an obsolete JSON-material test that rejected mask
cutoffs above one. Its regression now accepts finite float32 values through
`f32::MAX` and rejects negative cutoffs, matching the existing glTF/binary contract.

## Native render graphs

The public graph API runs a compute shader into a 64 by 64 storage texture, then
samples it on a full-screen quad. Every output pixel matches the red fixture.
Replacing that graph with a gradient verifies orientation and spatial sampling.
These checks pass on macOS Metal and the physical Pixel's Vulkan backend.

The same integrations check uniform buffers at aligned offsets, read-write
storage buffers, parameter updates without recompilation and pipeline reuse.
Invalid sampler slots, undersized uniform bindings and read-only bindings for a
writing shader fail with the pass name while preserving the active graph.
Closing the author scopes preserves compiled execution; releasing the final
owners leaves zero graph allocations, pipelines, shader modules and resource bytes.

Core tests cover immutable registrations, dependency ordering, cycles, resource
aliases, discarded attachments and compiler close during compilation or graph
replacement. Rust additionally checks strict control messages, response capacity
before mutation, invalid handle types and binding-group overflow. The complete
Rust suite passes 71 tests, including GPU cases, with strict Clippy clean.
Regression suites pass 181 core/geospatial/glTF, 41 native Dart and 57 Flutter
facade tests. Analysis, formatting, C-header syntax and package/header checks pass.

An existing mipmap fixture requested every texture usage. Storage support made
that include an invalid sRGB storage usage; the fixture now declares its actual
sampling, rendering and copy usages, and its original image checks pass.

`example/render_graph.dart` ran on Metal and saved the 256 by 256 heatmap PNG,
which was visually inspected. It reports one dispatch, one draw and zero resource
bytes or cached pipelines after cleanup. The macOS integration again passed
despite a foreground failure; this is native GPU evidence, not manual inspection
of the locked desktop. No iOS, Windows, Linux or Adreno graph qualification was
added. Scene materials, platform-view graph composition, plugin graph ownership
and resize/history remain open.

## Attachment-owned graph services

`PluginContext.resources` and `graphs` now join the existing shader service.
Five core regressions verify lazy allocation, independent attachment owners,
scope closure before detach, cancellation during compilation, failed attachment
cleanup and labeled unsupported-service errors. They pass with all 186
core/geospatial/glTF tests. All 42 native Dart tests also pass.

The native plugin fixture publishes its computed texture through a typed service
and a dependent plugin retains and reads it. Two engines share one device and
one cached pipeline. Closing the first leaves the second rendering; closing both
returns graphs, pipelines, resource bytes and shader modules to zero. A provider
that fails after compilation also leaves no allocations. This fixture passes on
Metal and Pixel Vulkan through the Flutter integration.

Execution remains explicit in `beforeRender`. These services establish plugin
ownership and typed output sharing, with no automatic scene insertion or native
view composition. The locked Mac still prevented manual window inspection.

## GPU services on native view devices

The native Metal and Android view backends pass the same compute-to-texture,
procedural rendering, typed buffer binding, failed replacement and cleanup
fixtures as the Dart worker. Two integration tests pass on each device. A plugin
also compiles a shader with UTF-8 diagnostics, executes compute work, reads its
result and then renders a scene on the presenter's device. The Pixel submits
that scene to a Vulkan surface with zero presentation readback bytes.

The platform queues reject invalid command kinds and transfer capacities before
calling Rust. Unit tests cover closing every GPU owner while allocation is
pending, release before session destruction, idempotent close, and preservation
of both resource cleanup and session-close failures. All 186 core/geospatial/glTF,
44 native Dart and 63 Flutter facade tests pass, 293 in total. Analysis,
formatting, C-header syntax, package boundaries and both mirrored ABI headers
also pass. Rust implementation code is unchanged since its 71-test run.

The native scene demo builds in release mode for macOS (49.8 MB) and Android
arm64 (22.0 MB). The graph CLI also builds with `dart build cli` and runs from
outside the workspace using its bundled native library. Its inspected PNG
contains the expected gradient and rings, and cleanup reports zero resource
bytes and cached pipelines. An initial `dart compile exe` build omitted that
library and could not create the backend; the package README now gives the
bundle command.

The Android release installed and launched on the physical Pixel, PID 13176 at
verification, with no errors in the process log. This confirms launch; manual
release-screen inspection is still open.

These checks establish GPU service access on the presenter device. Graph output
composition, custom scene materials, resize/history and the independent effects
consumer remain open. The macOS integration passed despite a foreground failure;
manual inspection of the locked desktop remains unverified. No iOS, Windows,
Linux or Adreno qualification was added.

## Scene frame composition

Frame graphs now render scene color, run compute/render effects and sample the
final texture into native output in one GPU submission. Tests check every pixel
of an odd-sized 17 by 13 frame, a changed scene, a red mesh, linear-to-sRGB values,
dimension rejection without losing the next frame, and cleanup after author
scopes close. Both render-to-render and compute-to-render chains pass on Metal
and the physical Pixel's Vulkan device. The Pixel presenter also runs the plugin
chain into a native surface with zero presentation readback bytes.

Seven core regressions cover the frame contract, discarded output, device and
size checks, plugin ownership, unsupported backends and pending-frame lifetime.
A reentrant adapter-close test failed before submission was registered ahead of
the callback; it now passes. Draw and triangle counts include effects and the
terminal draw, and compute dispatches are reported separately.

All 193 core/geospatial/glTF, 46 native Dart and 63 Flutter facade tests pass,
302 in total. Rust passes 72 tests including GPU cases, with strict Clippy clean.
The native frame envelope also rejects truncation, incorrect lengths, nested
packets and oversized keys. The standalone `example/frame_graph.dart` ran in
both JIT and bundled AOT modes, producing identical inspected PNGs with five
draws and one compute dispatch.

Analysis, formatting and package/header checks pass. The native scene demo builds
in release mode for macOS (49.9 MB) and Android arm64 (22.1 MB). The Android release
was relaunched on the Pixel, PID 16080 at verification, with its Flutter runner
retained and no errors in the process log. The composition integrations and CLI
image verify the effects; the running demo retains its existing scene controls.

The Metal integration passed despite the existing foreground failure. Manual
inspection of the locked desktop remains open. These tests add no iOS, Windows,
Linux or Adreno qualification. Custom mesh materials, automatic pass registration,
resize/history management and the independent effects consumer remain unfinished.

## Independent native effects consumer

`ResourceScope.createChild` now supports independently replaceable allocation
sets. Four regressions cover descendant admission, independent closure, collected
cleanup errors and a reentrant adapter closing its parent during allocation.
That last test found a late-allocation leak, fixed by tracking accepted work
before calling the adapter while preserving synchronous upload snapshots.

`examples/shader_lab/effects_plugin` depends only on the public Dart core API.
Its exposure/saturation and vignette passes use typed controls and explicit
capability rejection or bypass. Uniform edits preserve pipelines; resize compiles
new textures transactionally and closes author references on success or failure.
Tests cover failed replacement, closure during compilation, independent views,
reattachment and return to zero graph, shader and resource ownership.

197 core/geospatial/glTF tests, 46 native Dart tests, 63 Flutter facade tests,
seven effects tests and one desktop/narrow demo widget test pass, 314 in total.
The native effects integrations pass on macOS Metal and Pixel Vulkan. Pixel
assertions use the Vulkan readback backend; the Android surface adapter does not
support capture. Both platforms exercise the real Flutter controls, orbit input,
resolution changes and native presentation with zero readback. The fixture
requests observations across the existing five-per-second statistics limit.

Analysis, formatting and package/header boundary checks pass. The standalone CLI
runs in JIT and bundled AOT modes outside the workspace, producing byte-identical
768 by 432 PNGs with six draws. The image was inspected. The CLI has its own
runtime dependency on `zyren_native`, which is required for the executable to
bundle the native asset; the effects library stays independent of that backend.

The narrow-layout regression also checks that first-frame diagnostics preserve
the canvas dimensions. An initial release run replaced its ImageReader when the
footer appeared. The footer now reserves its space and the canvas fills the
available width; the regression and Pixel integration pass after that fix.

Release builds pass for Android arm64 (23.2 MB) and macOS (51.7 MB). The updated
shader lab release is running on the Pixel, PID 19444 at verification, with its
Flutter runner retained and no error entries in the process log. Manual
release-screen inspection remains unverified. The Metal integration still
reports the existing foreground failure, so manual desktop
inspection remains open. These checks add no iOS, Windows, Linux or Adreno
qualification. The new effects are spatial. Temporal history, HDR, custom mesh
materials and automatic cross-plugin pass registration remain unfinished.

## Custom mesh materials, 2026-09-28

`ShaderCompiler.compileMesh` and `ShaderMaterial` now render custom WGSL vertex
and fragment programs through the native scene path. The shader lab applies a
UV stripe material through its independent plugin package. A frequency slider
updates the uniform without rebuilding pipelines.

The checkpoint passed 144 core, 52 glTF, 8 geospatial, 49 native Dart, 63 Flutter
facade, 10 effects-plugin and 1 app-layout tests. Native Dart tests ran with
`RUN_NATIVE_GPU=1 --concurrency=1`: the first concurrent suite run exposed the
existing process-wide renderer-count assertions in image-decoder/finalization
tests. The serial suite passed. The Rust suite passed 55 tests with 18 tests
ignored by default; eight focused material, graph and shader tests also passed
with `--include-ignored`. Analyzer, strict Clippy, formatters, package boundaries
and diff checks passed.

Metal pixel tests cover uniforms, UV textures in group 3, shared pipeline caches,
shader replacement without geometry changes, alpha mask/blend, culling, mirrored
transforms, depth, frame effects and binding ownership after author scope closure.
Failed pipelines and render-attachment sampling are rejected without breaking
later valid frames. Shared-device views accept the same programs; foreign and
legacy renderers reject them. Closing immediately after a frame containing two
programs now drains both before release, pinned by core and native regressions.

The macOS Metal and physical Pixel Vulkan shader-lab integrations passed, covering
shader pixels, the custom material with post-processing, controls, orbit, resize,
zero-readback native presentation and final session cleanup. The final program-swap
assertions and immediate-close regression were subsequently rerun in native Dart
on Metal. The standalone JIT and bundled AOT commands produced byte-identical
images; `artifacts/shader-lab-materials.png` was inspected.

Release builds passed for Android arm64 (23.3 MB) and macOS (52.0 MB). The Android
release was installed and launched as `dev.zyren.shader_lab`, PID 21186 at the final
check, with no error-level process log entries. The device screensaver obscured
manual release inspection. The macOS integration could not foreground its app,
though its assertions passed; manual macOS release inspection remains unverified.
No new iOS, Windows, Linux or Adreno qualification was performed. Task 4 remains
open for shared pass registration, temporal history and transparent compositor
output. This checkpoint does not establish full Three.js or Takram parity.

## Before-scene preparation, 2026-09-28

Frame graphs now run preparation passes before the scene and effects afterward
in one command buffer. Metal pixel tests change a compute-generated material
texture from red to green to white and check the result in that same frame.
Both preparation-only and preparation-plus-effects graphs pass. Author scopes
can close while compiled owners remain usable, and final cleanup returns GPU
resource bytes, graphs and mesh programs to zero.

Four core regressions cover phase ordering, the scene boundary, imported aliases,
backward dependencies, combined pass limits and failed candidate preservation.
Native validation also rejects forged boundaries and early scene-color access.
A separate regression caught oversized engine uniform declarations passing
material compilation. The engine layout now supplies its actual minimum binding
size, so these programs fail before publication and valid materials still render.

The checkpoint passed 148 core, 50 native Dart, 63 Flutter facade, 10 effects-plugin
and 1 app-layout tests. Native Dart ran serially with GPU tests enabled. Six focused
Rust graph and shader tests passed with ignored GPU cases enabled. Analysis,
strict Clippy, formatting, package boundaries and ABI header checks passed.

The shader-lab integrations passed on macOS Metal and physical Pixel Vulkan.
They check the preparation pixels and exercise the same compute-to-material path
through native Flutter surfaces, including resize, zero presentation readback and
final cleanup. Release builds passed for Android arm64 (23.3 MB) and macOS
(52.0 MB). Manual release inspection remains unverified. The macOS runner
still could not foreground the app. No iOS, Windows, Linux or Adreno qualification
was added. Shared plugin registration, history and transparent compositor output
remain open.

The follow-up compiler check reproduced reentrant shutdown returning before a
pending build, missing its release failure, and admitting a second build from an
adapter callback. Accepted compilation is now registered before adapter entry.
All 151 core tests, nine focused native graph/material cases and ten effects-plugin
tests passed afterward. Analysis is clean. The initial native test command named
two absent files; their actual graph suites were then run and passed. The updated
Android release was rebuilt and launched on the Pixel with its runner retained.

## Shared plugin frame graphs, 2026-09-28

`context.graph` combines attachment-owned preparation passes and effect builders
in one frame graph. Registrations can be enabled, invalidated or disposed. The
engine owns resize candidates and replaces the active graph after compilation.
Failed edits preserve a compatible graph and report a single nonfatal issue;
failed initial builds and resizes still fail that frame. Flutter keeps the
viewport ready when an edit falls back to the last valid graph.

Thirteen core regressions cover independent ordering, reuse, resize, bypass,
failed edits, stale candidates, attachment rollback, capability errors, manual
composition conflicts and teardown while building or presenting. All 164 core
tests passed, along with 50 native Dart, 64 Flutter facade, 12 effects-plugin and
1 app-layout tests. Native suites ran serially with GPU tests enabled. Analysis,
formatting, package boundaries and ABI header checks passed. Rust code did not
change in this checkpoint.

The native effects consumer now uses shared registration. Two independent plugins
produce checked Metal pixels in dependency order, bypass independently, preserve
pixels after a failed edit and return resource, graph and shader ownership to zero.
The macOS Metal and physical Pixel Vulkan integrations passed those checks and
combine compute material preparation with post-processing on native Flutter
surfaces. Resize and zero presentation readback are asserted on both devices.
The effects teardown regression was added afterward and passed in the consumer
suite: closing an attachment cannot turn an already submitted frame into a hook
failure.

Release builds passed for macOS (52.0 MB) and Android arm64 (23.9 MB). The updated
Android release is running as `dev.zyren.shader_lab`, PID 24617 at verification,
with its Flutter runner retained and no error-level process log entries.
The macOS runner could not foreground its app. Manual release inspection and
new iOS, Windows, Linux or Adreno qualification remain open. Task 4 still needs
history and transparent compositor output; this is not full Takram parity.

## Transparent compositor output, 2026-09-28

`Scene()` now has a transparent canvas. Nullable `background` and validated
`backgroundOpacity` are captured in JSON or binary opcode 18. Older native
packets remain opaque. The renderer resolves blended scene color before effects,
returns straight-alpha captures and premultiplies encoded sRGB at presentation.
Flutter image adapters preserve alpha metadata through both compatibility paths.

The checkpoint passed 168 core, 51 native Dart, 67 Flutter facade, 12 effects-plugin
and 1 app-layout tests. Native Dart ran serially with GPU tests enabled. All 75 Rust
tests passed with ignored GPU cases included. Analysis, strict Clippy, formatting,
package boundaries and ABI header checks passed.

New GPU checks cover clear and fractional backgrounds, overlapping translucent
meshes, resize, opaque transitions, alpha-changing effects and malformed alpha
packets. Metal surface bytes match premultiplied sRGB expectations while explicit
capture remains straight. The physical Pixel test captures a native Flutter
texture over white and checks fractional and midtone colors, plugin fading and
bypass, including an effect that makes an opaque scene translucent. Presentation
readback stays zero; sessions and surface ownership return to zero after disposal.

Both shader-lab integrations passed on Pixel Vulkan and macOS Metal. The combined
macOS run failed to start its second app; that effects integration passed on a
separate retry. The macOS runner still could not foreground the app. Apple
window-compositor pixels remain unverified because Flutter's RepaintBoundary
capture excludes native platform views.

Release builds passed for macOS (52.0 MB) and Android arm64 (23.3 MB). This adds
no iOS, Windows, Linux or Adreno qualification. Task 4 still needs temporal
history; the full Three.js core and Takram port remain in progress.

## Shared texture history, 2026-09-28

Shared effects now allocate previous/current texture pairs through
`EffectBuildContext.createHistory`. The engine compiles both binding variants
before publication, uploads validity/generation metadata and advances history
only after successful backend completion. Resize, projection changes, camera
replacement, explicit invalidation and engine recreation reset samples. Camera
and scene snapshots are frozen before asynchronous graph preparation.

The checkpoint passed 182 core, 51 native Dart, 67 Flutter facade, 15 independent
effects-plugin and 1 app-layout tests, 316 in total. GPU tests ran serially with
`RUN_NATIVE_GPU=1`. Analysis, formatting, package boundaries and ABI header checks
passed. No Rust implementation changed; this checkpoint did not rerun the prior
75-test Rust suite.

Core regressions cover failed renders, failed second-variant compilation, failed
resize, reset races during upload/submission, retained aliases, frozen camera
capture and teardown during a build. Invalid previous writes, imported current
textures and discarded history attachments reject before compilation.

Native Metal and physical Pixel Vulkan checks verify successive blended pixels,
compute accumulation, transparent color, independent view histories, reset and
resize, bypass/re-enable, pipeline reuse and final resource cleanup. Flutter
integration adds history to a compute-prepared custom mesh and spatial effects,
then exercises History controls, reset and resize with zero presentation readback.
The app layout test passes at 320, 390 and 1100 pixels.

Release builds passed for macOS (52.3 MB) and Android arm64 (23.5 MB). The Pixel
release is running as `dev.zyren.shader_lab`, PID 29283 at verification, with its
Flutter runner retained. The macOS integration could not foreground its window,
so manual release inspection and Apple window-compositor pixels remain unverified.
There is no new iOS, Windows, Linux or Adreno qualification.

Task 4 needs its acceptance audit. The demo supplies frame blending; HDR/TAA,
motion/depth rejection, later core features and the full Takram port remain open.

## Render-graph acceptance, 2026-09-28

Plan 03 task 4 is accepted for the implemented native graph profile. Source review
and fresh runs passed 182 core, 51 native Dart and 15 independent consumer tests,
plus all 75 Rust tests with GPU cases included. This reruns the exact 64x64
compute-to-quad fixture and shader diagnostics after the final history commit.
The preceding Metal/Pixel integrations and release builds used the same code.

| Requirement | Evidence |
| --- | --- |
| WGSL compilation and labeled failures | `shader_compiler_test.dart`, Rust `shader_diagnostics.rs`, native syntax/type recovery and source-location checks |
| Graph ordering, access declarations and lifetimes | `render_graph_test.dart`, `graph_phase_test.dart`, Rust `render_graph.rs`; dependencies reorder passes and reject cycles, invalid aliases and uninitialized/discarded reads |
| Transactional ownership and pipeline reuse | Core compiler/closure regressions and native graph fixtures preserve accepted work, retain resources, reuse live pipelines and return residency to zero |
| Custom mesh materials | `mesh_shader_test.dart`, native material fixtures and shader-lab's independently packaged stripe material |
| Public plugin composition and typed services | `shared_graph_test.dart`, native `graph_test.dart`, independent effects tests and the package-boundary check |
| Resize/history and capability policy | `history_graph_test.dart`, consumer resize/temporal tests, native accumulation and explicit rejection/bypass tests |

No transient alias allocator is enabled. Whole-allocation hazards and owned
textures are the accepted first profile, as recorded when graph execution was
implemented. The API additions arrived in focused commits through `0ae2760`,
instead of the plan's single suggested commit.

This acceptance does not qualify additional devices, HDR/TAA, shadows, PBR or
Takram parity. Apple window-compositor inspection and iOS, Windows, Linux and
Adreno remain open in the program's platform gates.

## Direct-light standard materials, 2026-09-28

`StandardMaterial` now renders metallic/roughness shading, base-color textures,
emission and existing alpha/depth/side modes. Directional, point and spot lights
use ordinary scene transforms and explicit intensity units. The native profile
admits 16 visible lights. Binary opcode 19 carries the frozen light table and
material deltas; material and light edits reuse resident geometry and images.

The checkpoint passed 249 core/glTF/geospatial tests, 52 native Dart tests,
69 Flutter facade/demo tests and 15 independent effects tests, 385 in total.
All 80 Rust tests passed with GPU cases included. Native Dart ran serially with
`RUN_NATIVE_GPU=1`. Analysis, strict Clippy, formatting, package boundaries,
Apple ABI header consistency and diff checks passed.

Independent numeric GPU probes verify the direct BRDF, no ambient contribution,
emission, roughness, point inverse-square falloff and range. Other fixtures cover
spotlight direction/cones, base-color masks, negative/nonuniform scales,
transparent emission, bounded packets and final resource cleanup. A narrow-cone
regression first produced black at the centre because float32 collapsed the two
cosines. The shader now preserves centre intensity at that representable limit.
The legacy `Scene.snapshot` path rejects visible standard materials and lights
instead of silently losing their shading data; a regression verifies the failure
and hidden-object behavior.

The PBR lab and existing effects lab passed separately on macOS Metal and the
physical Pixel's Vulkan backend. PBR integration checks 12 sphere draws, light
controls, zero geometry/image uploads for parameter edits, and zero presentation
readback. The effects integration covers the custom mesh shader and temporal
history after the native uniform layout extension. Layout tests pass at 320,
390 and 1100 pixels. The PBR app explicitly selects native Metal or Android
presentation; its first integration run caught an accidental readback default.

The standalone Metal example rendered a 768x512 sphere grid, saved to
`artifacts/pbr-metal-grid.png` and inspected locally. PBR release builds passed
for macOS (50.5 MB) and Android arm64 (22.6 MB). The Pixel release is running as
`dev.zyren.shader_lab`, PID 3142 at verification, with its runner retained and no
error-level process logs. Its screen capture showed the screensaver, so this
checkpoint does not claim visual inspection of the Android release window.
The Mac is locked and its integration runner could not foreground the app;
manual release inspection and Apple window-compositor pixels remain unverified.

Task 5 remains open for normal/ORM/emissive maps, HDR, environment lighting,
shadows, hemisphere lights and standard glTF material/extension qualification.
There is no new iOS, Windows, Linux or Adreno evidence. This direct-light profile
does not establish full Three.js or Takram parity.

## Standard material maps and hemisphere lighting, 2026-09-28

`StandardMaterial` now supports normal, metallic/roughness, occlusion and emissive
maps alongside base color. Each channel selects its own sampler and UV set.
Data maps require linear storage; color maps use their declared texture format.
Explicit tangents preserve handedness under mirrored and nonuniform transforms.
Meshes without tangents use a derivative basis, with degenerate UVs retaining
the geometric normal. This fallback does not claim MikkTSpace equivalence.

`HemisphereLight` supplies diffuse indirect irradiance between sky and ground.
Its local +Y axis selects the sky direction, and the native profile admits four
visible hemispheres in addition to 16 punctual lights. Occlusion affects this
indirect contribution, leaving direct light and emission unchanged. Hemisphere
lighting does not supply environment reflections or establish IBL support.

Binary opcode 20 carries the additional maps, tangent stream and hemisphere
table. Tangent edits upload changed ranges while preserving geometry retained
by other views. Parameter and sampler edits reuse image uploads; removing maps
releases their residency when no remaining submission retains them.

The checkpoint passed 253 core/glTF/geospatial tests, 53 native Dart tests,
69 Flutter facade/demo tests and 15 independent effects tests, 390 in total.
All 87 Rust tests passed with GPU cases included. Native Dart ran serially with
`RUN_NATIVE_GPU=1`. Analysis, strict Clippy, formatting, package boundaries,
Apple ABI header consistency and diff checks passed.

Numeric GPU fixtures cover packed channels, emissive sRGB decoding, independent
UV selection, normal scale, explicit and derivative tangents, mirrored basis
orientation, occlusion strength and final resource cleanup. An off-axis light
makes the handedness fixture distinguish both bitangent directions. A second
view retains its old pixels while another submission patches tangents. Invalid
data-map formats, UVs, tangent values and truncated packets reject cleanly.

The PBR and effects app integrations passed on macOS Metal with zero presentation
readback. The physical Pixel passed the standalone PBR GPU integration on Vulkan,
including the UV1 derivative case. Its expanded PBR window interaction test
stalled while the app surface stayed inactive and was cancelled. A normal wake
and foreground request did not restore that surface. This checkpoint therefore
does not claim an Android window interaction pass. The separate GPU test has a
90-second timeout; the window test also bounds its initial frame wait.

The PBR lab adds texture and ambient controls. Layout tests pass at 320, 390 and
1100 pixels. Standalone Metal JIT and bundled AOT executables produced identical
768x512 PNGs at `artifacts/pbr-maps-metal-grid.png` and
`artifacts/pbr-maps-metal-aot.png`; the grid was inspected locally. Release builds
passed for macOS (50.8 MB) and Android arm64 (22.8 MB). The Pixel release is running
as `dev.zyren.shader_lab`, PID 10023 at verification, with its runner retained and
no error-level process logs.

The Mac remains locked and its integration could not foreground the app. Manual
release-window inspection and Apple compositor pixels remain unverified. There
is no new iOS, Windows, Linux or Adreno qualification. Task 5 remains open for
HDR, environment lighting, shadows and standard glTF material/extension gates.
Full Three.js and Takram parity remain open.

## HDR scene color and terminal tone mapping, 2026-09-28

`ColorPipeline` now selects linear RGBA16Float scene color with exposure and
Linear, Reinhard or ACES filmic tone mapping. Flutter owns the setting per
`SceneController`; Dart callers select it per frame. Binary opcode 21 carries
immutable settings. A null pipeline preserves the existing RGBA8 path.

The native compositor applies the curve after transparency and graph effects,
then performs output transfer and surface premultiplication. Readback retains
straight alpha. Shared color effects inherit HDR precision and reject RGBA8
outputs. Explicit graphs require HDR scene/output endpoints. Exposure edits reuse
compiled effects; precision changes rebuild the graph and reset its history.
Custom mesh shaders use the selected scene format without interface changes.

RGBA16Float resources support render, sample, storage, upload and readback usage.
Mip sizes, copies and residency account for eight bytes per texel. The byte-image
API explicitly rejects float formats. Each resource and internal HDR attachment
retains the 64 MiB bound. This is internal HDR lighting with SDR output, not HDR
monitor support or a new HDR asset decoder.

The checkpoint passed 259 core/glTF/geospatial, 54 native Dart, 69 Flutter
facade/demo and 15 independent effects tests, 397 total. All 92 Rust tests passed
with GPU cases enabled, along with strict Clippy. Native Dart ran serially with
`RUN_NATIVE_GPU=1`. Analysis, formatting, package boundaries and Apple ABI header
checks passed.

The first numeric probes reproduced clipped bright channels. Their passing
replacements verify exposure before conversion, independent ACES values,
transparent overlap in linear light, straight alpha and output transfer once.
Other tests cover float texture bytes, compute storage, effect ordering, custom
mesh shaders, independent view exposure and cleanup. A failing shared-effect
regression exposed a silent RGBA8 narrowing; that graph now rejects before
submission. Failed precision changes cannot fall back to an incompatible graph.
History resets when precision changes and preserves linear samples across
exposure edits. Invalid curves, exposure values and truncated opcode 21 packets
reject before GPU work.

The physical Pixel passed the final standalone Vulkan GPU integration, including
custom shader and independent-view checks. macOS Metal passed the PBR app with
Exposure interaction and zero presentation readback, and the separate effects
app passed after the compositor change. Layout tests pass at 320, 390 and 1100
pixels. The PBR lab exposes ACES/Reinhard/Linear plus Exposure.

The standalone native example produced identical JIT and bundled AOT PNGs at
`artifacts/pbr-hdr-metal.png` and `artifacts/pbr-hdr-metal-aot.png`. The grid was
inspected locally. The first broad native Dart invocation used the wrong cwd,
which caused three missing-fixture failures; the corrected package run passed.
Its byte-image test also needed an explicit RGBA8 format list after the enum
expanded. Float resources have separate GPU assertions.

Task 5 remains open for environment reflections, shadows and glTF qualification.
Task 8 still includes bloom, multisampling, antialiasing and broader profiles.
No new iOS, Windows, Linux or Adreno evidence was added. Full Three.js/Takram
parity is not established.

Final release builds passed for macOS (51.8 MB) and Android arm64 (23.2 MB) after
the shared-effect precision guard. The Pixel release is running as
`dev.zyren.shader_lab`, PID 13912 at verification, with its Flutter runner retained
and no error-level process logs. Pixel window interaction remains unverified in
this checkpoint. The Mac integration could not foreground its window; manual
release-window inspection and Apple compositor pixels remain unverified.


## HDR asset loading, 2026-09-28

You can load Radiance RGBE files through `HdrImageLoader` and keep their values
in immutable RGBA32F CPU storage. Flutter presets provide the native HDR decoder
before a view attaches. The core asset service remains optional and independent
of Flutter and geospatial. See [HDR assets](design/hdr-assets.md) for the supported
file profile and explicit float16 upload API.

The native decoder covers all eight axis orientations, flat and both RLE forms,
strict header/run/payload validation, exponent extremes, byte limits and C-buffer
ownership. Seven decoder tests include 512 reproducible input mutations. CPU
half-float tests cover all 31,744 nonnegative finite half values, subnormals,
ties, overflow and an upload-scale double-rounding regression. Mixed byte/HDR
loads share float-byte admission, and cancellation cannot publish late results.

Checks pass: 269 core/glTF/geospatial, 59 native Dart, 68 Flutter facade, two
shader-lab layout and 15 independent effects tests, 413 Dart/Flutter tests in
all. The full Rust run passed 98 tests; the final seven-test HDR suite adds the
mutation regression, bringing covered Rust tests to 99. Strict Clippy, analysis,
formatting, package boundaries and C-header syntax pass.

Metal and Pixel Vulkan integrations exercise CPU decode, RGBA16F upload, linear
mip generation, compute sampling and resource cleanup alongside existing PBR,
material-map and tone-mapping probes. The Metal app integration also exercises
its existing controls and zero-readback presentation checks. It could not bring
its window to the foreground. Manual release-window inspection and Apple
compositor pixels remain unverified, with no lock polling or bypass attempted.
No new iOS, Windows, Linux or Adreno qualification is claimed.

The first GPU fixture omitted its imported graph input and exposed only one
sampled mip. Correcting both declarations made the probe read the intended mip.
The default Flutter HDR test must run from `packages/flutter_zyren`, whose
dependencies activate native build hooks; the workspace root's test invocation
did not resolve the HDR FFI symbols. The corrected package run passes. The
initial generated RGBE fixture had incorrect exponents and was fixed against
the format's numeric conversion before GPU checks.

Environment prefiltering, BRDF integration, PBR environment bindings and shadows
remain open in Task 5. The full Three.js and Takram port is still in progress.

Both release builds pass: macOS 51.9 MB and Android arm64 23.3 MB. The updated
Pixel release demo is running under runner 55363, process 17208, with no
error-level process logs at verification. Previous runner 60768 was stopped
before the Flutter test/build cycle. The release scene retains its existing
lighting; HDR asset decoding is qualified through the integration probes above.

## Native environment lighting, 2026-09-28

`EnvironmentLighting` now prepares an HDR panorama and lights ordinary standard
materials through the native renderer. Its core implementation uses scoped
resources and compute graphs for diffuse convolution, GGX specular filtering and
a correlated-Smith BRDF lookup. Geospatial remains an optional consumer. See
[environment lighting](design/environment-lighting.md) for the API and supported
profile.

The GPU probes check constant HDR values within one half-float rounding step and
directional gradients against their analytic Lambert convolution, including the
seam and poles. BRDF samples agree with an independent angular quadrature.
Material pixels cover rotation, roughness, occlusion, emission, a missing map
and composition with custom mesh shaders and frame effects.

Lifecycle tests cover failed replacements, publication between frames,
independent view settings, retained ownership, foreign devices, disposal during
preparation and cleanup errors after successful filtering. Native envelope
tests reject truncated data, invalid keys, reserved bytes, nonfinite intensity
and invalid rotations. The sphere-grid demo adds a generated HDR studio image
and compact intensity/rotation controls.

Checks pass: 276 core/glTF/geospatial, 63 native Dart, 68 Flutter facade, two
shader-lab layout and 15 independent effects tests, 424 Dart/Flutter tests in
all. All 100 Rust tests pass with GPU tests enabled. Strict Clippy, analysis,
formatting and the package/ABI boundary guard pass.

The macOS Metal bridge and physical Pixel Vulkan integrations pass the same
numerical and composition probes. These are explicit readback checks, separate
from interactive presentation. The 768 by 512 native sphere-grid render was
inspected; the desktop and narrow widget layouts pass. The Mac integration
could not foreground its window. Interactive inspection of the updated native
windows, Apple compositor pixels and additional platform qualification remain
open.

This checkpoint uses a single-scattering split-sum environment model. Shadows,
standard glTF qualification, advanced physical materials and full Three.js or
Takram parity remain unfinished.

Release builds pass for macOS (52.1 MB) and Android arm64 (23.4 MB). The updated
Pixel release is running as `dev.zyren.shader_lab`, PID 19311 at verification,
with runner 46635 retained and no error-level process logs. Runner 55363 was
stopped before this test/build cycle.

## Native shadows, 2026-09-28

Directional cascades, spotlight maps and six point-light faces now render into
native depth atlases. The public API uses typed light settings and per-mesh
`castShadow`/`receiveShadow` flags. Geospatial uses the same core path. See
[native shadows](design/shadows.md) for the supported profile and limits.

Numerical probes check all six point faces, cascade blend intervals, transformed
casters, geometry patches, mirrored alpha masks, opacity and emission. A scene
translated to a planet-scale origin keeps its expected shadow. Atlas diagnostics
verify unchanged-frame reuse, explicit invalidation, per-view release, the 64 MiB
device limit and successful retry after another view closes. Native packet tests
reject malformed shadow tables and every truncated message. Randomized packing
checks cover admitted mixed map sizes and over-budget requests.

Checks pass: 284 core/glTF/geospatial, 65 native Dart, 68 Flutter facade, two
shader-lab layout and 15 independent effects tests, 434 Dart/Flutter tests in
all. All 103 Rust tests pass with GPU tests enabled. Strict Clippy, analysis,
formatting and package/ABI boundaries pass.

The macOS Metal bridge and physical Pixel Vulkan integrations pass the same
shadow probes alongside existing PBR, HDR, environment and composition checks.
These integrations use explicit readback. The 768 by 512 native PBR preview at
`artifacts/native-shadows-pbr.png` was inspected. The example adds a receiving
backdrop and a header toggle, with layout checks at 320, 390 and 1100 pixels.
The initial header overflow at 320 pixels was corrected before the layout rerun.

The first shadow regression observed the original lit receiver after casting
was enabled. Implementing depth rendering made it pass. Initial WGSL compilation
caught an entry-point call and a reserved identifier; both were corrected before
GPU qualification. An initial combined Dart command used the wrong geospatial
package path; the corrected command above includes `zyren_geospatial`.

Release builds pass for macOS (52.5 MB) and Android arm64 (23.6 MB). The Mac
integration could not foreground its window. Interactive native-window checks,
Apple compositor pixels, iOS and other desktop/mobile GPU qualification remain
open. No lock polling or bypass was attempted. This checkpoint does not complete
Task 5's glTF gates or the full Three.js and Takram port.

The Pixel release is running as `dev.zyren.shader_lab`, PID 21415 at verification,
with runner 33022 retained and no error-level process logs. Runner 46635 was
stopped before the serialized Flutter test/build cycle. The release app uses
native Vulkan rendering; interaction with its visible controls remains unverified.

## glTF PBR and punctual-light checkpoint

Checked 28 September 2026. The standard loader publishes `StandardMaterial`
triangles with base color, normal, metallic/roughness, occlusion and emissive maps.
Authored tangents reach native buffers. `KHR_lights_punctual` imports independent
light instances, validates references and bounds light counts per scene.
`KHR_materials_unlit` keeps its lighting-independent path. See the
[import profile](design/gltf-materials.md) for the remaining static-subset limits.

The checked suites pass 295 core/glTF/geospatial tests, 66 native Dart tests,
68 Flutter facade tests and three model-viewer widget tests, including compiled
worker coverage. Analyzer, formatting and package/Apple ABI boundaries pass.
Native Rust code did not change in this checkpoint.

Metal and physical Pixel Vulkan pass independent glTF pixel probes for PBR
factor defaults, light units, inverse-square falloff, range, rotated spots,
all five maps, alpha masks, emission, occlusion and tangent handedness. The viewer
passes bundle/HTTP loading, relative dependencies, repeated reloads, authored
PBR lights and its explicit studio toggle on both platforms. Presentation reports
zero readback bytes. Desktop and 320/390-pixel widget layouts pass.

An initial macOS reload test waited for a statistics event after an action inside
the stream's 200 ms sampling interval. The demand-rendered frame could finish
without another statistic, so the test now spaces load actions before observing
them. The isolated rerun passes. A subsequent test in the original batch also
failed to attach to the app; its isolated native-pixel run passes. macOS still
reports an inability to foreground the window, so these results do not establish
interactive desktop or compositor inspection.

Release builds pass with `ZYREN_MODEL=pbr.glb`: macOS 55.4 MB and Android arm64
24.9 MB. The Pixel release process launched without error-level logs, but its
final screen capture showed the lock screen. Interactive visual inspection of
that release remains unverified. `artifacts/native-gltf-pbr.png` is a Metal readback preview
of the authored three-part PBR fixture. This checkpoint does not qualify full
glTF conformance, iOS/Windows/Linux runtime parity, or the remaining Three.js and
Takram feature set.

## MikkTSpace normal-map checkpoint

Checked 28 September 2026. Normal-mapped glTF primitives without usable authored
tangents now use the core `TangentGenerator` service. Flutter supplies the native
MikkTSpace implementation. It runs on a CPU isolate, splits tangent seams and
preserves all vertex attributes. See [tangent generation](design/tangent-generation.md)
for the public API, limits and cancellation behaviour.

Checks pass: 320 core/glTF/geospatial tests, 72 native Dart tests, 69 Flutter
facade tests and three viewer widget tests, 464 Dart/Flutter tests in total.
All 109 Rust tests pass, including GPU cases and the bounded tangent regressions.
Analyzer, strict Clippy, formatting and package/Apple-header boundaries pass.
The initial combined Dart command used the wrong geospatial directory; the
corrected suite uses `packages/zyren_geospatial/test`.

The curved mirrored fixture matches an unmodified pinned MikkTSpace build within
1e-6, including reversed face order. Tests also cover mirrored handedness, UV1,
flat-normal regeneration, unused vertices, attribute formats, uint16 promotion,
output budgets, serialized asset admission, cancellation and field diagnostics.
The native stack-depth regression rejects a high-valence fan and verifies that a
subsequent job can run.

A deterministic 1,000-mesh C harness passes address, undefined-behaviour and
float-cast sanitizers with recovery disabled. It exposed the reference sort's
shift-by-32 case, which now uses a defined rotate. Zero-extent position hashes
also avoid a NaN-to-int cast. The vendor note records both changes. Reproduce the
sanitizer check from the workspace root:

```sh
clang -std=c11 -O1 -g -fsanitize=address,undefined,float-cast-overflow \
  -fno-sanitize-recover=all packages/zyren_native/native/src/tangents.c \
  packages/zyren_native/native/tests/tangent_sanitize.c -o /tmp/zyren-tangent-check
/tmp/zyren-tangent-check
```

Metal and physical Pixel Vulkan pass the glTF pixel probes, including generated
normal-map bases. Both platforms pass viewer bundle/HTTP/reload tests and the new
Normal map sample with zero presentation readback bytes. Desktop and 320/390-pixel
widget layouts pass. macOS could not foreground its integration window, so those
results do not establish interactive desktop inspection.

The bundled release capture CLI ran from `/tmp` and rendered the normal-map
sample through Metal: three draws, 36 triangles. The inspected output is
`artifacts/native-mikktspace-aot.png`. Normal-map ribs affect shading while the
box geometry stays unchanged. This checkpoint leaves broader material reference
coverage, instancing/deformation/animation, antialiasing, geospatial parity and
remaining platform qualification open.

Release builds pass for macOS (55.6 MB) and Android arm64 (25.5 MB). The Pixel
release launched with `ZYREN_MODEL=normal-map.glb` and no error-level process
logs at verification. Interactive release-screen inspection remains unverified.

## Linear material reference checkpoint

Checked 28 September 2026. Direct and environment lighting now blend dielectric
and metal responses correctly at intermediate metallic values. The GGX
distribution also uses a stable cross-product denominator at glossy peaks.
The new linear HDR tests exposed both defects before the fixes. See
[material reference checks](design/material-reference-checks.md) for the oracle,
sample matrix and independently chosen tolerances.

Checks pass: all 73 native Dart tests, five Rust PBR tests on Metal, scoped Dart
analysis, strict Clippy, formatting and package/Apple-header boundaries. The
new helper checks 150 direct-light patches against a double-precision CPU oracle
and 45 environment patches for linear metallic interpolation. Every direct
sample is within the larger of 0.3% or 2e-5 linear radiance per channel. The glTF
and Rust fixtures also check a half-metallic material after SDR conversion.

The shared reference helper passes on macOS Metal and physical Pixel Vulkan.
Both platforms pass sphere-grid controls and model-viewer bundle/HTTP/reload
lifecycle checks with zero presentation readback bytes. The Pixel also passes
the updated glTF reference-pixel integration. These seven integration tests
qualify the current static material profile; they do not add animation or certify
full glTF conformance.

The native PNG capture at `artifacts/native-pbr-reference.png` was generated and
inspected: 13 draws, twelve mapped spheres and a shadow-receiving backdrop.
macOS integration windows still could not be foregrounded. GPU pixel and lifecycle
results pass, but interactive desktop inspection remains unverified.

The Android arm64 PBR release builds at 24.2 MB and starts with no error-level
process logs. The device capture shows its lock/ambient screen, so release-screen
inspection remains unverified. The release process is left running for inspection
on the device.

Plan 03 Task 5's baseline gates are now checked. Instancing, morph targets,
skinning and animation are next. Advanced physical materials, area lights,
antialiasing, full Takram parity and the remaining native platforms stay open.

## Core transform animation checkpoint

Checked 28 September 2026. `AnimationClip`, typed vector/quaternion tracks,
`AnimationMixer` and `AnimationAction` now animate ordinary scene transforms.
Clips are immutable; each mixer resolves stable target IDs to its own nodes.
Playback supports pause, seek, reverse speed, weighted actions and once/repeat/
ping-pong loops. See [animation](design/animation.md) for the API and limits.

Checks pass: 335 core/glTF/geospatial tests, 74 native Dart tests, 69 Flutter
facade tests and three shader-lab widget tests, 481 tests in those suites.
The final camera-fit change also passes the focused animation widget test.
Analyzer, formatting and package/Apple-header boundaries pass. Rust renderer
code did not change.

The tests pin Hermite tangent scaling, quaternion short arcs and cubic sign
handling, weighted rest poses, reverse/loop boundaries, independent instances,
admission limits and atomic rejection of invalid poses. Scheduler checks verify
that pause, completion, speed zero and detach release frame demand, and that
resume excludes idle time. Attachment scopes prune disposed registrations when
new registrations arrive, keeping repeated play/pause demand changes bounded.

Metal and physical Pixel Vulkan pass the animation integration. Playing or
seeking one model preserves the other model's pose; after both pause, frame
statistics settle. Native presentation reports zero readback bytes. Explicit
pixel captures also prove that old submissions retain their transforms and that
new animated poses do not upload geometry again.

The initial 320-pixel widget check exposed a header overflow. The header now
wraps, with tests at 320, 390 and 1100 pixels, and the camera fits both models to
the available canvas. Both device integrations pass after that change. macOS
could not foreground its integration window, so interactive desktop inspection
remains unverified.

The bundled native capture executable runs from `/tmp` and produces
`artifacts/native-animation-aot.png`: six draws showing independent 0.8-second
and 2-second poses from one shared clip. That image was inspected.
Task 6 remains open for GPU instancing, skinning, morph targets, glTF animation
import and broader animation features. Full Three.js/Takram and remaining
platform qualification are still open.

The Android arm64 animation release builds at 24.1 MB and launches on the Pixel
without error-level process logs. It is left running with the animation entrypoint.
Interactive release-screen inspection remains unverified.


## glTF transform animation and runtime mixer registration

Checked 28 September 2026. The optional glTF loader now imports translation,
rotation and scale channels with STEP, LINEAR and CUBICSPLINE sampling. Imported
instances expose source-indexed nodes, scene-filtered clips and independent
mixers. `AnimationSystem` accepts mixers after view initialization and releases
frame demand when their registrations are disposed.

All 500 tests in the checked suites pass: 349 core/glTF/geospatial, 75 native
Dart GPU, 69 Flutter facade, four model-viewer widgets and three shader-lab
widgets. Compiled glTF worker tests exercise imported clips. Analyzer, formatting,
package boundaries and the Apple ABI header check pass. Rust renderer code did
not change, so the Rust suite was not repeated for this checkpoint.

Import tests cover sparse outputs, normalized integer rotations, cubic tangent
magnitudes, duplicate names/channels, matrix targets, malformed time bounds,
scene selection, release lifetime and admission budgets. The vendored, unmodified
[Khronos BoxAnimated fixture](../test_assets/gltf/khronos/README.md) also checks
that its 2.5-second rotation channel holds while translation continues to about
3.70833 seconds. The whole clip repeats on one clock.

Metal and physical Pixel Vulkan pass the imported-animation integration. Pixel
checks prove independent instance motion, frozen captured transforms and zero
geometry reuploads on seek. Interactive controls exercise play, pause, seek and
replacement through native presentation with zero readback bytes. Frame statistics
settle after pausing or replacing the animated model. The existing Metal viewer
integration also passes bundle/HTTP loading, repeated reloads and all material
examples after the compact Examples menu change.

Widget checks at 320, 390 and 1000 pixels preserve a canvas taller than 240 pixels
with playback controls visible. The first layout exposed excessive example-button
rows; the final menu removes those rows. Tests wait for menu transitions before
selecting another example, preventing taps on a closing overlay.

Native captures `artifacts/native-gltf-animation.png` and
`artifacts/native-khronos-box-animated.png` were rendered at 1.5 seconds and
inspected. The latter uses Box Animated by Cesium, copyright 2017,
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode), with viewer
lights added. Model data and source attribution are retained in the fixture folder.

The Android release builds at 25.7 MB and launches with
`--dart-define=ZYREN_MODEL=animated.glb`. macOS integration tests pass but their
windows could not be foregrounded. Interactive desktop and release-screen
inspection remain unverified. GPU instancing, skinning, morph deformation, the
full Three.js/Takram port and remaining platform qualification are still open.

## Native GPU instancing checkpoint, 28 September 2026

`InstancedMesh` now reaches native instance vertex buffers, material pipelines,
draw ranges and shadow passes. The 10000-copy Rust GPU test checks the actual
color-pass draw count and pipeline cache: one draw, one pipeline variant. The
scene occupies 1121104 bytes including its shared box geometry. A single edited
instance uploads 112 bytes; camera, parent and count changes upload zero.

Verification passed:

- 355 core, glTF and geospatial Dart tests; 80 native Dart GPU tests; 69 Flutter
  facade tests; four model-viewer widget tests; three shader-lab widget tests.
- 113 Rust tests including opt-in native GPU cases. Targeted protocol/admission
  tests passed again after the final ownership guards. Clippy, analysis,
  formatting, package boundaries and Apple ABI checks passed.
- Metal and physical Pixel Vulkan integration checks cover 10000 copies, partial
  edits, material pixels, reflected/nonuniform transforms, normal maps with
  tangent/color streams, global transparent ordering and shadow invalidation.
  Shared native views preserve independently captured versions through teardown.
- Native presentation reports zero readback. The macOS integration also checks
  1000x700 and 320x640 layouts after resize, with a usable canvas and no overflow.
- The Android release entry point `lib/instancing.dart` built and launched on the
  Pixel. The retained runner's process was confirmed, with no error-level output
  in the process log checked after launch.

The same scene was saved and visually inspected through explicit native Metal
readback at `artifacts/native-instancing.png`. The repeatable benchmark lives at
`packages/zyren_native/benchmark/instancing.dart`; its measured scope and local
results are recorded in [renderer benchmarks](../benchmarks/renderer/README.md).

The macOS runner could not foreground the application. Interactive desktop and
release-screen inspection remain unverified. This checkpoint does not qualify
Windows, Linux or physical iOS. Custom shader instancing, per-copy colors,
skinning, morph targets, picking and full Three.js/Takram parity remain open.

## Native skin and morph checkpoint, 28 September 2026

`MorphTarget`, `Skin`, `Bone` and `SkinnedMesh` now reach native vertex-stage
GPU deformation. Each mesh owns its morph weights and palette while geometry
stays shared. Color and shadow passes use the same deformation function. Pose
changes update a small buffer; source bounds and joint-index validation are
cached by geometry revision. See [the API](design/deformation.md).

Verification passed:

- 363 core, glTF and geospatial Dart cases, including the final focused tests
  for capability limits, source-edit invalidation, immutable poses and bounds.
- 84 native Dart cases with `RUN_NATIVE_GPU=1` and `--concurrency=1`; 69 Flutter
  facade cases; six model-viewer and three shader-lab widget cases.
- The 116-case Rust suite with opt-in GPU tests, followed by the new bounded
  deformation-packet test. All four deformation Rust cases passed again after
  the source-cache change. The numeric GPU oracle compares positions, normals
  and tangents with an independent CPU calculation to an absolute error below
  `1e-5`, including reflected and nonuniform joint transforms.
- Native material comparisons cover unlit, diffuse and standard shading,
  normal maps, tangent/color attributes, alpha masks and blending. Morphs on
  instanced meshes, updated transparent depth, shadow invalidation, rejection
  recovery and independently retained view poses pass.
- macOS Metal and physical Pixel Vulkan integrations present with zero readback.
  Each changed two-joint pose uploads 400 bytes. The second mesh retains its
  pose, and frame demand stops after pausing. Pixel integration passed again
  after the final cache change.
- Widget checks at 1000x700 and 320x640 preserve a usable canvas and working
  playback, seek and morph controls. Clippy, Dart analysis, formatting, package
  boundaries and Apple ABI checks pass.

The release entry point `lib/deformation.dart` built as a 24.2 MB APK and
launched on the Pixel. Its process was confirmed after launch, with no
error-level output in the process log checked then. The native Metal readback
at `artifacts/native-deformation.png` was visually inspected and shows two
independent deformed ribbons and their shadows.

The first native Dart suite was run concurrently and hit the existing
process-global renderer-count assertion in the HDR decoder test. Running the
suite with its documented `--concurrency=1` setting passed all 84 cases.

The macOS app could not be foregrounded. Interactive desktop and release-screen
inspection remain unverified. This checkpoint does not qualify Windows, Linux
or physical iOS. glTF skin/morph import, morph-weight animation, the remaining
animation semantics, custom shader deformation and full Three.js/Takram parity
remain open. Task 6 stays unchecked.

## glTF skin and morph import, 28 September 2026

The optional loader imports four joint influences per vertex, inverse bind
matrices, position/normal/tangent morph deltas and animated weights. Instances
share geometry and clips while retaining independent joint objects, weights and
mixers. Node overrides, default identity inverse binds, sparse morph accessors,
normalized animation outputs and cubic scalar grouping pass loader tests.
Implicit flat normals get target deltas from each displaced triangle. Errors
retain field paths for malformed bindings, attributes, bounds and limits.

Core `MorphWeightKeyframeTrack` supports step, linear and cubic interpolation.
The mixer can bind one node to several primitives, blend against each primitive's
rest weights, and validate all sampled values before publishing a pose. Tests
cover independent instances, weighted mixing, restoration and atomic rejection.

The final Dart run passed 377 core, glTF and geospatial cases, including compiled
worker and encoder paths. The serial native GPU suite passed 85 cases. Seven
viewer tests passed, covering desktop/narrow layouts and deformed camera framing.
Analyzer, formatting, package boundaries and Apple ABI checks passed. This change
has no Rust source changes.

The imported native pixel fixture matches explicit CPU position queries and
preserves frozen frames after playback and template release. One two-joint pose
edit uploads 400 bytes. The viewer's authored `deformation.glb` uses two ribbons
with shared geometry and independent skins; its clip animates one ribbon's joint
rotation and width. Native integration checks presentation readback of zero,
seeking, independent state and pause-to-idle behavior.

Normal-mapped morphs require authored base tangents. Generated tangent seams
across morph targets, additional joint sets, color/UV morph deltas and singular
inverse binds remain unsupported. Completion events, additive mixing, finite
repetition counts, broader renderer work and full Three.js/Takram parity remain
open. Windows, Linux and physical iOS qualification remain outstanding.

The standalone Metal image `artifacts/gltf-deformation.png` was visually checked.
The capture tool's explicit `--studio` option supplies lighting for PBR models
that have no authored lights. The first capture lacked lights and showed black silhouettes;
the lit capture shows both displaced ribbons. This image is an explicit readback,
not evidence of an inspected Flutter desktop window or Android release screen.

The final macOS Metal and physical Pixel Vulkan integration runs passed. A macOS
recheck exposed a test race: clearing collected frames after selecting a paused
model could discard its only frame. The test now clears first and waits for the
expected draw count. Both targets passed with that fix. macOS still reported a
foreground failure, so desktop interaction and Android release-screen inspection
remain unverified. The final Pixel release build was 25.9 MB and launched the imported deformation
example. Its error-level process log was empty when checked.


## Generated morph tangents, 28 September 2026

Normal-mapped glTF morphs no longer require authored base tangents. The native
CPU worker runs MikkTSpace for the base and each changed position/normal pose,
preserves seams introduced by any target, and writes tangent XYZ deltas. The
loader checks that a custom generator returns every target's tangent stream.
The base handedness remains fixed, matching glTF's three-component morph format.

The working limit includes FFI attribute arrays and retained corner streams,
with the remainder reserved for native scratch. Iteration limits are shared
across the pose passes. Zero-delta targets reuse the base stream. Tests cover
normal-only targets, invalid poses, output bounds and recovery after failures.
Input/output geometry copies and remapping tables remain outside this payload
budget. This is not a process-memory ceiling.

Checks passed: 379 core, glTF and geospatial Dart cases, 88 serial native GPU
cases, seven viewer cases, analysis, formatting, package boundaries and the
Apple ABI header check. There are no Rust source changes in this checkpoint.
The native pixel test compares a full morph weight with independently generated
absolute-pose tangents, covers UV0/UV1 and generated flat normals, and confirms
that omitting morph tangent deltas causes a visible mismatch. Intermediate and
negative weights match explicit CPU reference geometry.

Metal and physical Pixel Vulkan integration checks pass for both imported
ribbon samples. The new Skin + normal map sample has width and twist targets,
generated tangents and independent skins. Presentation reads back zero bytes,
a changed two-joint pose uploads 400 bytes, and pausing releases frame demand.
Both authored GLB fixtures regenerate byte-for-byte. The standalone Metal
capture at `artifacts/gltf-morph-normal.png` was visually inspected; it shows two
displaced, shaded ribbons and uses explicit readback.

macOS still reports a foreground failure. Desktop interaction and Android
release-screen inspection remain unverified. Windows, Linux and physical iOS
qualification, the remaining animation semantics, broader core rendering and
full Three.js/Takram parity remain open. Task 6 stays unchecked.

The 26.0 MB Android release launched the normal-mapped deformation sample on
the Pixel. Its process was confirmed and the error-level process log was empty
when checked. The release remains running for inspection.


## Animation lifecycle, 28 September 2026

You can set a finite traversal count when playing an action or through its
`repetitions` property. Ping-pong counts each leg, reverse repeat finishes at
zero, and completed actions hold their final pose. Changing loop settings or
seeking resets the count. Restarting a finished action begins a fresh run.

Typed `AnimationLoopEvent` and `AnimationFinishedEvent` snapshots are delivered
asynchronously after pose validation and publication. Large steps emit one
event per action; the loop event carries its crossed-boundary count. Invalid
poses preserve times, counters and completion state and emit nothing. Tests
also cover zero-duration clips, event-driven replacement, reverse direction
changes, invalid limits and counter overflow. A split-step test caught missed
fractional endpoints in reverse playback; roundoff handling now covers once,
repeat and ping-pong modes.

The final core, glTF and geospatial suite passed 389 cases. The native GPU suite
passed 88 cases with serial execution, and all three shader-lab widget cases
passed. The final focused animation run passed 27 cases after the one-shot
roundoff fix. Analysis, formatting, package boundaries and Apple ABI checks
passed. No native ABI or Rust source changed.

The native pixel fixture retains completed and frozen poses without geometry
uploads. Metal and physical Pixel Vulkan integration pass for independent
playback, seeking, finite completion, frame-demand release and zero-readback
presentation. The animation lab adds run-count selection and completion status;
its widget checks retain a canvas over 250 pixels high at 320x640 and cover
390x700 and 1100x700 layouts.

macOS could not foreground the test app, so manual desktop interaction remains
unverified. Windows, Linux and physical iOS qualification are still open.
Additive blending, fades/warping, custom shader deformation and other core and
Takram parity work remain. Task 6 and the full implementation goal stay open.

The 24.3 MB Android release launched `lib/animation.dart` on the Pixel. Its
process was confirmed and its error-level process log was empty when checked.
The release app remains running; its screen was not inspected.


## Additive animation, 28 September 2026

You can play an ordinary clip as an additive layer using a reference time,
without rewriting its shared keys. The mixer applies weighted numeric offsets
and local quaternion offsets after its normal weighted/rest blend. Layers keep
independent weights and clocks. Each morph primitive retains its own rest pose,
and stopping the final owner restores that pose.

Eight focused cases cover play order, multiple layers, local rotation order,
antipodal quaternions, cubic reference sampling, separate clocks, primitive and
instance isolation, reference validation and atomic rejection. Singular combined
scales and an overflowing morph primitive leave every channel and playhead
unchanged. Completion events still follow committed updates.

The final core, glTF and geospatial suite passed 397 cases. All 89 serial native
GPU cases and three shader-lab widget cases passed. Analysis, formatting,
package boundaries and the Apple ABI header check passed. The implementation
changes Dart animation sampling and mixing; native shader code and ABI are
unchanged.

The native pixel fixture compares layered skin rotation, scale and morph weights
with explicit reference poses. A layer-weight edit uploads 400 bytes, and
captured frames retain their earlier poses. The demo's Lean layer slider affects
only the selected model; its held layer contributes without continuous frame
demand. Narrow and desktop widget layouts pass.

The standalone Metal capture `artifacts/additive-animation.png` was visually
inspected and shows both independently posed models using six native draws.
This image uses explicit readback. It does not establish inspection of a Flutter
window or the Android release screen.

Fades, time warping, custom shader deformation, per-instance colors, later core
work and full Three.js/Takram parity remain open. Task 6 stays unchecked.

Metal and physical Pixel Vulkan integration checks passed with the native
reference fixture and the layer-strength control. Editing a paused layer changes
only its model, presentation reads back zero bytes, and pausing or naturally
finishing the main action releases frame demand. macOS could not foreground the
app, so manual desktop interaction remains unverified. Windows, Linux and
physical iOS qualification remain open.

The 24.3 MB Android release launched the updated animation lab on the Pixel.
Its process was confirmed, with no error-level process-log entries when checked.
The app remains running for inspection; its release screen was not inspected.
## Animation transitions, 28 September 2026

You can fade held poses, cross-fade clips and change playback speed over time.
Each action owns one replaceable fade and one speed transition. Cross-fades
commit both actions together and can match traversal rates across different
clip durations. Invalid poses preserve the previous weights, clocks and
transition progress. Speed integration splits reversals and respects fade-end
pause boundaries, including a single large elapsed step.

Core coverage includes irregular frame partitions, reverse completion events,
transition replacement and cancellation, stopped/foreign actions, bounded
durations and speeds, idle-time skipping, reattachment and demand release.
All 408 core, glTF and geospatial Dart cases and 90 serial native GPU cases pass.
Analyzer, formatting, package boundaries and Apple ABI headers pass.

The native transition fixture compares cross-faded skin rotation, scale and
morph output against independently constructed poses and CPU-deformed geometry.
The maximum allowed pixel difference is two byte levels. Each transition step
uploads 400 bytes of pose data while the geometry stays resident. Frozen frame
captures retain their original pixels.

The animation lab reuses Swing and Reach actions and adds layer fades and a
slow-to-stop control. Widget checks cover 320 by 640, 390 by 700 and 1100 by 700
layouts with more than 250 pixels of canvas height. Vulkan integration on the
physical Pixel and macOS Metal integration pass. Both verify native reference
pixels, independent model controls, transition completion and settled frame
demand, with zero presentation readback bytes.

The standalone Metal capture `artifacts/animation-transitions.png` was visually
inspected at the midpoint of a cross-fade. It uses explicit readback for
validation. The macOS runner still reports that it cannot foreground the app;
manual desktop interaction remains unverified. Windows, Linux and physical iOS
qualification, custom shader deformation/instancing, per-instance colors and
the remaining implementation-plan gates are open.

## Custom shaders for animated geometry, 28 September 2026

You can compile mesh shaders for rigid geometry, instancing, deformation or
shared deformation across instances. The public WGSL helpers expose the same
skin and morph kernel that native materials use, plus instance transforms and
face orientation. Six vertex layouts cover UVs, tangents and colors. Dart
capture and native preparation reject profiles or attributes that do not match
the mesh. Deformed programs reserve binding group 2 for the engine.

The native fixture checks all 24 profile/layout combinations against rigid
reference geometry, including skinning, shared morphs, nonuniform scale and
mixed instance winding. It also checks all three material sides, group-3
resources, author-scope closure, frozen captures and final resource release.
A shared morph edit uploads 272 bytes; one instance transform uploads 112 bytes.
Neither edit compiles another pipeline.

All 412 core, glTF and geospatial Dart cases, 91 serial native GPU cases,
118 Rust cases (including the GPU cases) and 15 plugin cases pass. The four
shader-lab widget cases pass at narrow and desktop sizes. Analyzer, strict
Clippy, formatting, package boundaries and Apple ABI checks pass.

The animated material demo renders one skinned ribbon and twelve instances in
two draws. Its Metal integration passes the reference fixture and checks pose,
width and stripe controls, settled frame demand and zero presentation readback.
The standalone Metal capture `artifacts/mesh-shader-geometry.png` was visually
inspected. That capture uses explicit readback and does not establish inspection
of a Flutter window.

The Pixel integration built and installed, then timed out while Android reported
the test app as cached and frozen. That run does not qualify these shaders on
Android. The macOS test runner could not foreground its window, but the 53.3 MB
release app subsequently launched. Its actual window was inspected at desktop
and narrow widths. Pausing settled uploads to zero; the pose, width and stripe
controls changed the rendered ribbons; resuming restored animation and
400-byte pose updates. The release app remains running. Windows, Linux and
physical iOS qualification are open.

Custom shader shadow passes, separate skeletal palettes per instance,
per-instance colors and the remaining core and Takram parity work are still
open. Task 6 remains unchecked.

## Per-instance colors, 28 September 2026

You can tint individual copies with `InstancedMesh.setColor` or update a range
with `setColors`. White preserves the original material. Invalid channels reject
the whole range, and captured frames retain their colors after later edits.
The native record now occupies 128 bytes, including its padded RGB tint.
Scene opcode 26 carries the tint; older instance packets decode with white.

The native fixture compares 22 built-in material/deformation combinations with
ordinary meshes whose material colors are set independently. It covers texture
and vertex color products, normals, masks, transparency and reflected transforms.
Custom shader fixtures exercise every vertex layout with instance tints. Shared
views retain their original pixels, frozen captures survive edits, and one tint
change uploads 128 bytes without recompiling material pipelines.

All 415 core, glTF and geospatial Dart cases, 92 serial native GPU cases,
120 Rust cases including GPU tests, 15 plugin cases and four shader-lab widget
cases pass. Analyzer, strict Clippy, formatting, package boundaries and Apple ABI
checks pass. The first broad Dart command used a nonexistent geospatial test
directory; the corrected command passed all 415 cases.

Metal integration passes the material references and the live palette control.
Changing all twelve ribbon tints uploads 1536 bytes and retains two scene draws.
Presentation uses zero readback bytes, and pausing releases frame demand. The
standalone `artifacts/instance-colors.png` capture was visually inspected; its
explicit readback is separate from the native presentation check.

The 53.3 MB macOS release app launched and its desktop window was inspected.
The palette button visibly changes all twelve tints while paused, with the
display reporting two draws and 1536 uploaded bytes. Resuming playback restores
400-byte pose updates. The app remains running with the palette enabled. Narrow
layouts for this control pass the 320x640 and 390x700 widget checks; an attempted
live window resize did not change the window size.

The macOS benchmark retains one draw and stable residency at 1000 and 10000
instances. At 10000 copies, a single tint edit uploads 128 bytes and measured
3.184 ms median and 5.893 ms p95 over 20 samples after warmup. These are complete
128 by 128 readback timings, including Dart, the worker, GPU wait and pixel copy.
They are not presentation FPS or GPU timestamps. The raw results are saved in
`artifacts/instance-colors-benchmark.json`.

The Android arm64 release APK builds at 23.2 MB. Device verification is pending
after the previous Pixel run froze in the background. Windows, Linux and physical
iOS qualification, custom shader shadow passes, separate skeletal instance
palettes and full core/Takram parity remain open.

## Accelerated picking, 28 September 2026

Picking now uses immutable geometry and scene BVHs by default. You can retain a
raycaster across queries, inspect its build/refit and traversal counters, or use
linear traversal for comparison. Geometry and posed surfaces refit after edits;
scene refits reuse model inverses for unchanged instances. Frozen requests remain
valid after later edits, removal and cache resets.

The release benchmark exposed a cold-cache crash that JIT tests did not catch.
The macOS arm64 disassembly showed a cached-list load before its null guard in
the recursive visitor. Capturing a non-null baseline list outside that visitor
fixed the reproducer. The AOT regression now covers cold and warm captures,
scene and geometry refits, morph edits, instances, empty scenes and cache resets.

All 437 core, glTF and geospatial Dart cases, 93 serial native GPU cases,
78 Flutter facade cases, 15 effects-plugin cases and four Shader Lab widget
cases pass. The macOS geometry integration also passes, including native pixel
comparisons, projection switching, triangle selection and zero presentation
readback. Rust source is unchanged in this checkpoint.

Analysis is clean for packages, examples and tooling. Root-wide analysis reports
nine informational import lints in two pre-existing ignored artifact scripts.
Changed-file formatting, package boundaries, Apple ABI and diff checks pass.

The [CPU benchmark](../packages/zyren/benchmark/README.md) records release costs
on the Apple M3 Max. The dense grid query tests eight of 32,768 triangles.
The 10,000-instance query visits four candidate records; editing one instance
requires one model inverse and measured 2.013 ms median capture plus traversal.
Refitting the dense grid for one query costs more than its linear scan.

The Android arm64 release APK builds at 23.3 MB. This does not qualify picking
on a physical Android device. The 53.4 MB macOS release app runs on Metal. Its
narrow window was inspected while selecting the skinned ribbon and reflected
instance 7, then changing projection and pose and selecting the updated skin.
The outline matched each selected triangle. The app remains running, paused
with triangle 19 selected. Desktop and narrow widget layouts also pass.

Windows, Linux and physical iOS qualification,
renderer frustum culling, orbit/framing tools, the optional inspector and the
remaining core/Takram parity work stay open.

## Native frustum culling, 28 September 2026

You can now pan past built-in triangle meshes without submitting their offscreen
color draws. Camera-relative bounds account for skin/morph poses and aggregate
instance transforms. Unknown custom-shader and expanded-primitive bounds stay
visible. `Mesh.cullingBounds` accepts an explicit conservative override, and
`Mesh.frustumCulled` lets you disable culling for a mesh.

Scene opcode 27 adds a validated color-visibility flag. The native draw queue
skips those color records while retaining shadow participation and resource
ownership. A pixel regression first showed a red box still rendered after Dart
culled it, then passed after the flag reached the native queue. Another native
fixture places a caster outside the camera view and confirms its shadow still
darkens a visible receiver. Clearing that caster flag restores the lit pixels.
Its first run had an incorrectly aimed light; the corrected fixture follows
`PunctualLight.lookAt`'s emitting-axis convention.

All 443 core/glTF/geospatial Dart cases, 95 serial native GPU cases, 121 Rust
cases including GPU tests, 78 Flutter facade cases, 15 effects-plugin cases and
five Shader Lab widget cases pass. The release scene-encoder fixture exercises
culling and restoration without geometry uploads. Packet tests reject malformed
visibility flags and truncation, and check that older versions enable color draws.
Packages, examples and tooling analysis, strict Clippy, Dart/Rust formatting,
package boundaries and Apple ABI checks pass.

The new culling lab shares one box geometry across 61 meshes. Desktop and narrow
widget checks cover panning, projection changes and the culling toggle. Its macOS
integration passes with zero presentation readback: disabling culling restores
61 color draws, and panning or toggling culling does not re-upload the geometry.

The 53.0 MB macOS release app runs on Metal. Live inspection covered compact and
expanded windows, panning and both projections. The compact perspective view
reported five draws with culling enabled and 61 with it disabled, with the same
visible image. Panning changed the count to six; the expanded view drew 13.
Orthographic projection drew nine in the expanded window and five after returning
to the compact window. Every settled view reported zero uploaded bytes.

The Android arm64 release APK builds at 23.1 MB. Physical Android culling and
selection remain unverified; this build does not qualify Vulkan interaction.
Windows, Linux and physical iOS qualification also remain open.

Culling currently skips whole mesh or instance-batch draws. It does not compact
individual instances, discard offscreen resources, defer their initial uploads,
or perform occlusion culling. Orbit/framing controls, the optional inspector and
the remaining core/Takram and platform work stay open.

## Camera framing, 28 September 2026

You can fit world bounds with `camera.frameBounds`, including a selected mesh or
a union of model bounds. Perspective fits account for the depth of each corner;
orthographic fits preserve zoom. Both preserve viewing direction, target the
bounds center and fit the clip planes. Empty bounds leave the camera unchanged,
and invalid or unrepresentable fits fail before mutation.

Six new core cases cover perspective aspect/depth, orthographic zoom, oblique
views at Earth-scale coordinates, flat/point bounds, invalid inputs and clip
range changes. They first failed because the API was absent. All 449
core/glTF/geospatial Dart cases pass, alongside 78 Flutter facade cases and five
Shader Lab widget cases. Analysis, formatting, package boundaries and Apple ABI
checks pass. Rust source is unchanged in this checkpoint.

A native Metal pixel fixture frames three colored boxes under both projections
at wide and narrow aspects, then checks their rendered center pixels. The macOS
culling integration also passes: framing all 61 boxes and then a tapped selection
retains uploaded geometry and reports zero presentation readback. The widget
regression first failed on the missing framing buttons. A later pan check found
that the close view inherited the fitted clip range; restoring the close camera
configuration fixes that regression.

The 53.1 MB macOS release app runs on Metal. Live inspection confirmed that
framing all boxes shows the complete row with 61 color draws. Selecting Box 30
and framing it reduces the count to three; switching to orthographic projection
and resizing between desktop and compact windows keeps that box inside the
viewport. The settled frames report zero uploaded bytes. The app remains running
in the compact window with Box 30 selected.

The Android arm64 release APK builds at 23.1 MB. Physical Android framing remains
unverified, along with Windows, Linux and physical iOS qualification.

The demo retains a fit through projection changes and desktop/narrow resizing.
Framing uses explicit caller-supplied bounds and does not animate camera moves.
Orbit controls, the optional inspector, full core/Takram parity and remaining
platform qualification stay open.

## Orbit controls, 28 September 2026

You can attach `OrbitControls` to a view for orbit, pan and zoom with either
built-in camera projection. The plugin supports arbitrary up vectors, custom
drag bindings, distance/zoom/polar limits, programmatic movement and saved-state
reset. Exponential damping uses elapsed time and releases frame demand when
movement settles. Cancellation, suspension, disablement, camera replacement and
external pose edits discard pending movement.

Flutter supplies logical viewport dimensions and won gestures with pointer
count, device and button metadata. Mouse, touch and trackpad navigation use the
local gesture arena. Overlay hit testing, keyboard focus and competing scroll
parents have regression coverage. Controls do not install global input handlers.
Disabling them returns wheel and scale interests to the surrounding widgets.

Ten new core cases cover navigation, independent shared-scene views, limits,
invalid poses, damping at different frame intervals, reset and lifecycle cleanup.
Four Flutter cases cover mouse buttons, wheel, touch, trackpad, cancellation,
focus, overlay controls, parent scrolling and DPR/render-scale independence.
The initial failures established the absent plugin and viewport-input contract;
a pole regression caught an unrepresentable pose before mutation. Widget teardown
needed a bounded real-async/fake-clock drain for stream cancellation, with no
production engine lifecycle change.

All 459 core/glTF/geospatial Dart cases, 82 Flutter facade cases and five Shader
Lab widget cases pass. Both macOS integrations pass. The culling integration
checks orbit settling, zero geometry re-upload, zero presentation readback and
reset; the geometry integration retains native selection coverage. Packages,
examples and tooling analysis, changed-file formatting, package boundaries,
Apple ABI header and diff checks pass. Native Rust implementation is unchanged
since the culling checkpoint, so its full suites were not repeated here.

The 53.2 MB macOS release app runs on Metal. Live checks covered perspective
dragging, wheel zoom, reset, orthographic dragging and compact/expanded windows.
Perspective orbit changed five color draws to seven, dollying out showed 21,
and reset restored five. The expanded orthographic view showed 11 draws. Settled
frames reported zero uploaded bytes. The app remains running in the compact
perspective view.

The Android arm64 release APK builds at 23.2 MB. Physical Android interaction
remains unverified, along with Windows, Linux and physical iOS qualification.
Flutter reports that the macOS plugin still needs Swift Package Manager support;
the current CocoaPods release build succeeds.

Clip planes remain caller-owned during navigation. Zoom-to-cursor, keyboard
navigation, the optional inspector, full core/Takram parity and remaining platform
qualification stay open. The [controls API](design/orbit-controls.md) documents
the current input and lifecycle contract.

## Optional scene inspector, 28 September 2026

You can add `SceneInspector(controller:)` or `SceneStatsOverlay(controller:)`
from the optional `zyren_inspector` package. The inspector searches object names,
retains matching ancestors, shows mesh/transform details and reports controller
status and the latest observed issue. It borrows the controller and uses public
facade imports. Package checks reject private core/facade imports and native or
geospatial dependencies in the inspector.

The overlay samples statistics without acquiring frame demand or intercepting
pointers. `SceneController.latestFrameStats` supplies the last presented frame
when inspection opens on an idle scene. Failure and disposal clear that snapshot
before status listeners run. Unknown GPU timing and residency remain unavailable,
and the UI makes no pixel-visibility or FPS claim. The model viewer and inspector
use the same `ZeroState` widget from the Flutter facade.

Five inspector cases cover late attachment, trailing samples, pointer passthrough,
hierarchy search/collapse, read-only selection, scene changes, controller
replacement, pending timer cancellation and listener cleanup. A facade regression
checks real controller snapshot retention while idle and clearing on failure.
The demo tests open, search and close inspection at desktop and narrow widths.
All 100 facade, inspector, Shader Lab and model-viewer cases pass. The first
model-viewer run used the wrong working directory for its asset fixtures; the
correct example directory passes. Analysis, formatting, public package boundaries,
Apple ABI headers and diff checks pass.

The native macOS integration verifies unchanged frame IDs while opening,
searching and closing inspection, with zero presentation readback. Four serial
Metal pixel fixtures also pass for offscreen shadows, resource-preserving
culling, camera framing and deformed/instanced selection. No Rust implementation
changed in this checkpoint.

The 56.2 MB macOS release app runs on Metal. Live inspection identified the
Apple M3 Max, five draws, 60 triangles, zero upload/readback bytes and unavailable
GPU/residency measurements. Search and selection retained frame 2. The expanded
desktop window remained usable and displayed 13 draws; framing the inspected
Box 30 reduced that to five. The app remains running with that box selected.

The Android arm64 release APK builds at 24.5 MB. A first build with `--no-pub`
retained the integration-test plugin registrant and failed Java compilation;
normal release preparation regenerated it and passed. Physical Android inspector
interaction, Windows, Linux and physical iOS remain unverified. Swift Package
Manager adoption for the Apple plugin also remains open.

This closes task 7's camera, picking, controls and inspector acceptance gates.
HDR effects/antialiasing, remaining asset and core breadth, full Takram plugin
parity, platform qualification and release packaging remain in scope.

## Inspector modal follow-up, 28 September 2026

The culling lab hosts inspection in a nonmodal panel over the canvas. Its close
button, Escape and back navigation return keyboard focus to **Inspect scene**.
Selection status stays on one line so an initial selection does not resize the
viewport. Inspection keeps the current presented frame; framing is explicit.

Live macOS inspection found AXTree errors after selecting an object and closing
the original drawer. A minimal Flutter drawer passed, but the actual inspector
reproduced the error with its native view removed. Excluding native-view semantics
and adding a body semantics boundary did not resolve it. Those experimental
changes were discarded; this follow-up changes the demo host only.

All 100 facade, inspector and demo cases pass, including desktop/narrow layouts,
close/Escape/back navigation, focus restoration and stable viewport dimensions.
Semantic traversal keeps the main content available while inspection is open.
The native Metal integration passes with semantics enabled and checks unchanged
frame IDs when selecting a different mesh through inspection. Camera framing now
compares against the full-scene draw count because wider windows can legitimately
show more neighboring meshes. Analysis, formatting and package boundaries pass.

The macOS release builds at 56.1 MB and the Android arm64 APK at 24.5 MB.
The Mac locked before manual verification of the revised panel, so repeated live
open/select/close cycles and the final AXTree log check remain pending. The native integration does not establish that result.

## PNG allocation audit, 28 September 2026

PNG decoding reserves output/conversion memory before constructing the decoder.
The pinned image adapter does not propagate later allocation-limit changes to
its PNG reader. A regression first reproduced successful decoding under an
allowance that covered pixels but omitted inflate workspace; it now returns
`LimitExceeded`, and a sufficient allowance still preserves the reference pixels.

All 349 core cases and 87 nonignored Rust cases pass. The native image, image-ABI,
geometry-update and texture-packet suites also pass, along with seven Dart native
PNG/JPEG/HDR isolate cases. The HDR GPU case was skipped in that CPU-only run.
Strict Clippy passes. Task 2's remaining allocation gate is closed; this audit
does not change the recorded device-qualification limits or establish an RSS cap.

## 28 September: MSAA, bloom and renderer budgets

`ColorPipeline(sampleCount: 4)` and `PostProcessing` pass seven serial Rust
postprocess cases, five native resource cases and five Dart native HDR/effect/
budget cases on Metal. The core suite passes 352 tests; Rust's ordinary suite,
strict Clippy and Dart/Flutter analysis pass. Five Shader Lab widget tests and
both the post-processing and PBR macOS integrations pass. Surface integration
checks use no presentation readback and cover 320/960-pixel layouts.

The new budget fixture fills the 256 MiB shared resource allowance, verifies
that the next allocation fails, then confirms complete release. Individual
allocations and transfers retain their 64 MiB limit. This fixes effect graph
replacement with environment lighting while preserving the previous graph on
failure. Standalone HDR frame statistics now include the terminal tone-map draw.

The native AOT benchmark renders 400 instanced spheres at 640×360 and 1280×720
across five color/effect profiles. Every steady frame uploads zero scene bytes;
resource residency stays stable and returns to zero after each view. Timings and
accounting boundaries are recorded in `benchmarks/renderer`. GPU timestamps stay
unknown. Windows, Android and iOS device qualification remain open, as does manual
visual inspection because the app could not foreground on the sleeping display.

## 28 September: procedural geometry and curves

Eight additional surface factories pass analytic bounds, winding, unit normal,
UV layout, cap and seam checks. Line, quadratic/cubic Bézier and Catmull-Rom
curves pass endpoint, tangent and arc-length cases; 24 interior Catmull-Rom
samples match Three.js 0.184.0 across all parameterizations and closure modes.
The full core suite passes 362 tests. A native Metal fixture compares front-face
pixels with CPU ray hits for every new surface, including a swept Bézier tube.
Android device discovery found no connected target for this checkpoint.

The geometry gallery also passes both macOS surface cases through MSAA/effect
toggles and viewport resize. Capsule normals now match the analytic hemispheres
and cylinder, including their join. Android's release APK builds at 66.4 MB and
the unsigned iOS simulator app builds successfully. These build results do not
substitute for physical-device rendering or Windows qualification.

## 28 September: frame rejection, history and phone layout

Native attachment admission now precedes scene revision changes and dynamic
geometry uploads. A review reproduced a failed large frame leaving Dart and Rust
on different revisions. Four binary regressions cover rejected HDR/MSAA edits,
old and new capture retries, shared ownership and unchanged resource residency.
All ten focused Dart native cases pass, along with seven Rust postprocess cases
and three shadow packet/admission cases. Strict Clippy and analysis pass.

Lathe pole normals follow the profile slope. Both cone directions now have
normals perpendicular to their straight flanks; capsule normals keep their
analytic implementation. The full core suite passes 363 tests. The ordinary Rust
suite passes 88 cases, with 36 GPU/platform cases ignored in that command.

The first iOS simulator run rendered successfully but failed the narrow canvas
height assertion. Two-column sliders, compact effect chips and a canvas legend
preserve working space with phone safe areas. The widget regression checks a
320×640 view with 62/34-pixel top/bottom insets. Both gallery integrations now
pass on the iPhone 17 Pro simulator (iOS 26) and macOS Metal, with effect toggles,
resize and zero presentation readback.

Four history/effects qualification cases pass on native Metal, including combined
HDR/MSAA/bloom/spatial effects, independent history for shared scenes and clean
reattachment of the same plugins to a replacement device. Exposure changes retain
linear history; projection changes, explicit cuts and resize seed fresh history.
All graph resources and programs retire. This verifies application reconstruction,
not injected GPU/driver loss or temporal antialiasing.

The existing Metal effects/history surface integration and bundled/HTTP glTF
viewer integration pass. Running both Shader Lab entrypoints in one Flutter test
command failed to launch the second app; its separate invocation passed. The
sleeping display still prevents foregrounding and manual visual inspection.

All six native multi-view cases pass, including independent cameras/teardown,
physical resize/visibility, texture sampler edits, image decoding, explicit
capture and 100 managed-view cycles. The cycle test returns sessions, renderers,
retiring resources and held drawables to zero, without presentation readback.
Two stale texture-demo assertions were corrected: six uint16 indices use 12
bytes, and the loaded-image label includes dimensions before its mip count.

The extended AOT benchmark warms 30 frames and measures 300 per profile. Across
all ten profiles, resource residency stays constant and disposal returns it to
zero. At 1280×720, bloom plus spatial AA measures 1.057 ms median, 1.258 ms P95
and 1.814 ms P99 including explicit readback. The earlier 20-frame result is
retained. Different warm-up and system conditions prevent treating this timing
difference as a renderer optimization; GPU time, power and thermal state remain
unknown in the recorded results.

The final macOS release gallery builds at 54.9 MB and launches with native Metal.
Computer-use inspection reports that the Mac is locked, so final manual visual
verification remains pending. The release runner is left active for viewing
after unlock. All changes are committed locally; no push or merge was performed.
