# Android XR

You need Android API 27 or later, Google Play Services for AR, camera permission,
and a Vulkan 1.1 device with Android hardware-buffer imports, foreign queue
ownership, sampler YCbCr conversion and `VK_EXT_swapchain_maintenance1`. The
last extension supplies presentation fences for safe surface retirement. Its
instance dependencies must also be available. The plugin checks these capabilities
on the renderer's actual device. ARCore can still reject the requested camera
configuration.

Create the session, start it, then create the presenter. `cameraPresentation`
becomes true after the native presenter probes its device. `availability` reports
ARCore's availability enum, including missing or outdated Play Services.
`installRequested` means you must finish the system install flow and explicitly
retry start. Permission denial also requires an explicit retry. Backgrounding or
detaching the Activity pauses the session and invalidates retained frames. Returning
to the Activity does not resume it.

## Camera and scene ownership

ARCore runs with `EXPOSE_HARDWARE_BUFFER`. The plugin acquires the Java camera
buffer before the next `Session.update`, imports the same allocation as a Vulkan
image, and keeps a native reference until GPU completion. It creates no OpenGL
camera texture and copies no camera pixels to the CPU.

The serial worker owns the ARCore session, Vulkan queue and shared Zyren renderer.
Scene packets and GPU resource commands use the Dart-loaded native runtime, found
by its runtime token. Camera and transparent scene color are composed on that
same Vulkan device. Foreign queue ownership transfers bracket camera sampling;
the completion fence precedes buffer release. Only one camera frame is retained.
Each swapchain image owns its render-finished semaphore and presentation fence.
An acquisition fence also covers failures before the first queue submission.
An unexpected retirement error retains the surface, swapchain and frame resources
and makes disposal retryable. Device idle alone does not retire presentation.

The Activity's default display supplies rotation because Flutter may host the
SurfaceView in a virtual display whose rotation remains zero. Calibration uses
ARCore's display-oriented pose and display geometry. Android rotations 0, 90,
180 and 270 map to the shared orientation values 1, 3, 2 and 4. Projection depth
is converted to the native zero-to-one convention before scene rendering.
Viewport generation and session revision checks reject stale publication and
placement. Native surface changes must retire before the next surface is used.

## Depth and lighting

Request depth explicitly. ARCore must support automatic depth, and each retained
camera frame must have raw depth and confidence images with the exact same native
timestamp. Missing or older data returns `depthUnavailable` or `staleDepth`.
The camera observation is at most 250 milliseconds old when acquired and is
checked again before depth compute and scene submission. This measures time since
the plugin first observed that raw sensor timestamp, not camera exposure latency.
Repeated sensor frames keep their original observation time. `timestamp` and
`depthTimestamp` use the host monotonic clock; `sensorTimestamp` and
`depthSensorTimestamp` preserve the raw ARCore clock separately. Raw timestamp
equality is checked in integer nanoseconds before either value is converted.

Raw depth and confidence use a bounded CPU staging path. It packs each millimetre
depth value and confidence byte into one 32-bit value and reports the upload size
as `depthUploadBytes`. Camera pixels still use hardware-buffer import. A compute
shader projects depth into the view's D32Float target using the same calibrated
projection and ARCore's view-to-image mapping. Confidence below 128, zero depth
and values outside the calibrated clipping range leave far depth. The shared
renderer loads this target for scene occlusion. Effects, temporal rendering,
transmission and MSAA remain unavailable with externally initialized depth.

ARCore ambient intensity is a relative gamma-space value. The snapshot labels it
`relative-gamma`, includes the four color-correction values, and leaves color
temperature null because ARCore does not report a measured temperature here.

## Checks

From the example's Android directory, run `./gradlew :zyren_xr:testDebugUnitTest`
with Android Studio's Java runtime. The geometry tests cover rigid transforms,
handedness and invalid anchor input. Lifecycle tests cover pause/resume leases,
stale view callbacks, repeated frame age and invalidation after scene rendering. Run the example's `presentation_test.dart`
on an unlocked Pixel for camera, rotation, resize and disposal checks.
`native_agents_test.dart` covers native placement through the shared agent tools;
set `XR_TEST_DEPTH=true` for its depth path. Use `depth_test.dart` to check depth
presentation and stale-lease recovery independently of native plane detection.
Both probes keep Flutter frames running so the native camera view stays live.
You need a lit scene with trackable surfaces, and raw depth may require moving
the device.

The permission probe is `android_permissions_test.dart`. Revoke Camera for the
probe app, deny its first system prompt, then grant Camera after the
`XR_PERMISSION_DENIED_CONFIRMED` marker. It checks an explicit successful retry
and pause. This changes permission only for the probe package.

Regenerate the checked-in SPIR-V header with
`python3 tool/build_shaders.py /path/to/ndk/shader-tools/host/glslc`.
Add `--check` to verify that the header matches the GLSL source.

The Pixel now passes portrait/landscape presentation, Flutter/native viewport
sizes, resize, bounded leases and zero camera/native readback. It also passes a
fresh permission grant, denial followed by explicit retry, and backgrounding
with a retained frame followed by explicit restart. The native rotation fix
defers swapchain creation while window and calibration dimensions disagree.

Native placement and depth remain unqualified. The native-hit run found no plane
in 90 seconds. Its live feed showed a plain ceiling and ARCore reported
`insufficient_features`. The independent depth run also returned
`depthUnavailable` after 90 seconds because raw depth and confidence were absent.
Shared MCP discovery, inspection and mutation denial passed. Visual alignment,
foreground occlusion, Play Services installation, Activity/engine teardown and
sustained performance still need
physical checks. See the [qualification record](../qualification/2026-10-03.md).

The build enables flexible page sizes. All eight arm64 APK libraries pass 16 KB
ELF and zip alignment checks, but the available Pixel uses 4 KB pages. You still
need a 16 KB device to qualify that runtime configuration.

ARCore documents the native buffer ownership contract in its
[Vulkan guide](https://developers.google.com/ar/develop/c/vulkan) and the depth
acquisition methods in the [Frame reference](https://developers.google.com/ar/reference/java/com/google/ar/core/Frame).

Presentation ownership follows the Vulkan [semaphore reuse guide](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html).
Camera imports always use the [external format capabilities](https://docs.vulkan.org/refpages/latest/refpages/source/VkAndroidHardwareBufferFormatPropertiesANDROID.html)
reported for the hardware buffer, including when a concrete format is also reported.
