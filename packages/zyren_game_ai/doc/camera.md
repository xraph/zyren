# Native camera observations

Create a `CameraSensor` with a `CameraProfile` and an owned backend factory, then
register it with your `SensorRegistry`. `capture` takes a service-side snapshot,
an observer handle and a scene. It builds the camera from the captured body pose,
rotation and configured local eye offset. Await capture before assembling the
observation if your host can hold that simulation tick.

The sensor accepts pixels only for the same episode, entity generation, world
revision and tick. Pending or stale pixels stay unknown. An unsupported output
is unavailable. `invalidate`, `recreate` and `close` discard pending publication;
they wait for the real GPU submission before releasing its resources. The host
must invalidate on episode, ownership or restored-world changes. Captured image
buffers remain valid after target resize, session recreation and disposal.

Use `CameraPolicyEncoder(profile, sensorId: sensor.id)` with a `PolicyContract`
and set `observationInput` to your model's image input. This encoder selects the
permitted camera reading and checks its profile hash, dimensions and validity.
Unknown images never become zero-filled model inputs. Their policy request
returns no candidate, records an invalid observation and uses the controller's
normal fallback. Default structured encoders retain their two-dimensional input
contract; camera encoders use `[batch, channels, height, width]`.

## Format pins

`CameraProfile.toJson()` and its hash pin dimensions, NCHW layout, RGB channel
order, sRGB bytes, affine normalization, eye offset, projection, clipping range,
cadence and latency. RGB normalization is `(byte / 255 - mean) / std`.
Premultiplied color is unassociated first; transparent zero-alpha color is zero.
No resize or color-space conversion happens silently.

RGB/depth profiles have five channels: R, G, B, normalized metric depth and a
separate depth-validity channel. Depth is distance along the camera's forward
axis in metres, rather than Euclidean ray length. Divide by `maxMetres` and clamp
to 0..1. Background and invalid samples carry depth zero and validity zero.
Depth follows fragments that write the actual scene depth attachment; blended
surfaces that do not write depth have no separate depth layer. Four-sample MSAA
uses the existing nearest-covered sample resolve. The receipt preserves the
captured projection, view-projection, origin, forward, near/far where known,
standard/reversed depth convention and native frame ID.

Profiles cap each dimension at 128 and each reading at 65536 values. Structured
observation fields allow 65536 values and a full assembled schema allows 131072,
including its validity fields. These are allocation bounds, not timing guarantees.

## Qualification and limits

The 2026-10-03 Metal probe on Apple M3 Max passed actual material RGB, a plane at
5 metres within 0.01 metres, clear/background validity, reversed depth with
near 0.001 and far 10000, four-sample MSAA, hidden-object pixel/depth equality,
skinning, resize, cancellation and renderer recreation. The A1 CNN executes on
its real native CPU worker. Another test commits that camera policy only at its
declared due tick and sends the decoded intent to the real character controller.
This deterministic probe is execution evidence, not a trained task policy.

Two warm 84x84 decisions measured 7.266 and 8.786 milliseconds end to end; the
cold decision took 488.216 milliseconds. GPU submission timing was 0.344 and
0.266 milliseconds. Native mapping/packing was 9.917 and 6.459 microseconds,
preprocessing 2.062 and 4.092 milliseconds, and native CNN execution 0.485 and
0.510 milliseconds. Worker round trip includes ML transfer and scheduling;
native mapping/packing excludes FFI and isolate copies. Three samples cannot
establish a frame-time guarantee.

Class masks are unsupported. No material-color replacement or shader-only label
pass is claimed as semantic capture. Depth with custom screen effects, temporal
AA or frame graphs fails explicitly. Built-in single-sample and resolved-MSAA
scene depth is qualified. Vulkan, DX12, iOS and Android retain separate device
and packaging gaps; this Metal result does not qualify them. T6 trains visual
profiles and Q1 evaluates their behavior under unseen textures and lighting.

Run `RUN_NATIVE_GPU=1 fvm dart test --concurrency=1` from this package. Serial
execution keeps process-global native ML diagnostic assertions independent of
other tests. See `qualification/camera-backends.json` for the backend record.
