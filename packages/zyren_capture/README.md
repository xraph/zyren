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

Jobs run one at a time, with at most 720 frames, 4096 pixels per dimension and
32 retained job records by default. Each image is written before the next native
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

Seven tests cover deterministic sampling, cancellation, scene changes, unsupported
capture, sink/close failures, PNG conversion and job admission. A macOS Metal
fixture produced two matching four-frame sequences. High-resolution tiling,
video encoding, depth and object-ID passes remain later milestones. No other
device capture path has been qualified here.

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
normal scene render settings, with guarded undo. Effect-chain resource controls
are inspection only in this checkpoint.

`dart run example/agent_scene.dart` starts the existing devtools MCP protocol on
stdio with configurator, audio, capture, effects and a named viewport provider.
It creates no network listener. A live MCP check discovered all five providers,
picked the stable `body` target, applied a color choice and captured changed PNG
bytes through Metal. Audio controls used the real offline mixer. The example is
a headless view, so presented-frame correlation and Flutter overlay handling
remain unknown. Eight capture tests and two agent/effects tests pass.
