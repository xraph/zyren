# zyren_capture

You can capture a still or turntable PNG sequence through native GPU readback.
Run `dart run example/capture.dart` for a small native fixture that captures four
frames twice and checks that the corresponding PNGs match byte for byte.

Import `native_capture.dart` and create `nativeCapture` with your scene, source
scene/document IDs and an existing output parent directory. Start a job with a
`CapturePlan`; its default frame count is one. Await `job.done` for the artifact
and manifest, or call `job.cancel()` while it runs.

The manager opens and closes an isolated native backend for each job. It creates
a private output directory and removes that directory if the job fails or is
cancelled. Completed files belong to you and survive manager disposal. It never
deletes a caller-selected directory. Keep the output parent private to your host.

Jobs run one at a time, with at most 720 frames, 4096 pixels per untiled dimension
and 32 retained job records by default. Each image is written before the next native
frame starts. Cancellation waits for an in-flight render or file write, then
cleans up. `close` cancels active work and waits for cleanup.

Camera poses and frame times are deterministic. You can seek an owned animation
in `prepareFrame` before each submission. Keep unrelated scene edits out of that
job: capture rejects a revision change while the native backend is rendering.
The manifest records scene/document identity, camera pose, native frame ID,
renderer and parameters. These are scene pixels from an isolated camera, without
Flutter overlays or correlation to the user's presented viewport.

The first output format is PNG from RGBA8 sRGB readback, including conversion
from premultiplied alpha. Other readback formats fail explicitly. A backend must
report capture support; the Flutter Android presenter currently does not.

Package tests cover sampling, cancellation, scene changes, unsupported capture,
scoped cleanup, PNG conversion, job admission and shared agent tools. Opt-in
native tests cover Metal effects and tiled images. `RUN_FFMPEG=1` enables the
real encoder test; `RUN_NATIVE_GPU=1` enables native rendering tests.

## Runtime agents and effects

Import `agents.dart` and create `CaptureAgentProvider` with your host-owned
manager. Use `provider.register(registry)` so disposing that registration also
cancels jobs started by the provider. Grant `capture.write` in the registry for
`start` and `cancel`. `jobs` reports progress and completed artifact paths.
Agents cannot select output directories. Their default limits are 1024 pixels
per dimension and 120 frames; the host can lower them.

Jobs start on the next event turn. The initial command acknowledges admission,
then you query progress. Cancellation waits for the current native operation and
cleanup. Retry keys avoid duplicate starts. A backend close failure remains a
failed job even if cancellation was also requested.

Import `effects_agents.dart` for an optional `EffectsAgentProvider`. It inspects
existing scene effects and, when supplied, the `ScreenEffectsController`. The
`effects.write` scope permits exposure, tone mapping and HDR changes through
normal scene render settings, with guarded undo. The `chain` tool also rebuilds
resources through that controller.

`dart run example/agent_scene.dart` starts the existing devtools MCP protocol on
stdio with configurator, audio, capture, effects and a named viewport provider.
It creates no network listener. A live MCP check discovered all five providers,
picked the stable `body` target, applied a color choice and captured changed PNG
bytes through Metal. Audio controls used the real offline mixer. The example is
a headless view, so presented-frame correlation and Flutter overlay handling
remain unknown in that headless example.

## Tiled output and video

Set `CapturePlan.tileDimension` to render a large image with cropped native
perspective frusta. You can request up to 8192 pixels on either axis, subject to
a 32 megapixel output budget, with tiles from 16 to 2048 pixels. Each tile checks
cancellation and scene revision. The manifest records all native tile frame IDs.
Tiled jobs reject screen-space effects, bloom, spatial AA and outlines because
those passes need overlap or a full-resolution composition step to avoid seams.

Transparent PNG output preserves the backend's alpha. On Metal, a nine-tile
fixture matched its full render byte for byte and preserved background alpha.
The test also exercised a 4097-pixel-wide output. Depth and object-ID capture have
no public readback capability yet and remain unsupported.

Import `video.dart` for `VideoExport`. You supply a completed PNG artifact, an
output parent, a frame rate and an installed FFmpeg executable with libx264.
The adapter uses FFmpeg's [image sequence input](https://ffmpeg.org/ffmpeg-formats.html#image2)
and writes H.264 in MP4 with yuv420p pixels. It requires even dimensions and drops
alpha; audio muxing is not implemented. Encoder progress, bounded diagnostics,
timeouts and cancellation are explicit. Failed exports remove only their own
private directory and leave the PNG sequence intact.

`video_agents.dart` exposes this adapter through `VideoAgentProvider`. Register
it with `provider.register(registry)`, grant `capture.video`, and start exports
by completed capture ID. The host chooses the executable and paths. Disposal
cancels outstanding exports; `forget` drops history while retaining files.

Supply a `ScreenEffectsController` to enable the effects provider's `chain` tool.
You can change SMAA, dithering, lens enable/intensity/threshold, and grading
intensity/interpolation. Omitted fields and the host LUT are preserved. The
controller builds replacement GPU resources before publishing them; guarded
undo restores the preceding settings. Concurrent scene color edits are preserved
if they arrive during a chain undo. Closed owners and failed rebuilds report
errors through the shared registry.

For a displayed fixture, see [the Flutter lab](example/flutter/README.md).
