# Persistent sensor capture

Import `sensors.dart` and create `SensorCapturePool(openBackend: yourFactory)`.
You own the pool; it owns one persistent backend session. Construct a
`SensorCaptureRequest` at the desired simulation tick. Construction freezes the
scene and camera through `FrameSubmission.capture`, before any asynchronous GPU
work. Request RGB or RGB plus depth, then await `pool.capture(request)`.

The receipt pairs your request ID and tick with the native frame ID, scene
revision, dimensions, immutable camera matrices, pixel conventions and session
resource generation. Its buffers belong to the receipt. Native targets reuse
allocations at equal dimensions; resize replaces the target after prior work
completes. Old receipts remain valid after resize or pool disposal.

The pool serializes submissions and bounds pending count and requested buffer
bytes, including depth validity. Native workspace memory uses the renderer's
separate limits. Cancellation cannot free or reuse a target under a live GPU
submission. `close` cancels publication and awaits completion before closing the
backend. `recreate` drains cancelled work, closes the old backend and increments
the resource generation. New work is rejected during recreation or after close.
Failed startup can be recreated without producing another unhandled error.

Color is top-down RGBA8 sRGB with declared alpha representation. Depth is
camera-axis metres from the same GPU frame, with a separate validity mask.
Background is invalid, not a near-plane surface. Standard and reversed depth
use the captured inverse projection. MSAA uses nearest-covered scene depth.
Near/far are retained for perspective and orthographic cameras; arbitrary camera
subclasses may provide only their captured matrices. Class masks are unsupported.
Custom screen effects, temporal AA and frame graphs reject depth capture because
their output coverage has not been qualified. Missing depth support fails before
rendering; missing output after rendering fails receipt publication.

Your scene materials, skin deformation and native visibility produce the RGB
pixels. This API does not read a window, display or XR environment depth. PNG,
tiled, turntable and video jobs retain their existing APIs and ownership.

Metal RGB/depth is qualified on Apple M3 Max. Other desktop backends and mobile
capture require their own device and packaging checks. The AI package's
`qualification/camera-backends.json` records those gaps and measured CNN timing.
