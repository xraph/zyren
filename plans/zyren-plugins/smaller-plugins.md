# Configurator, audio and capture

You can track the first implementation of these three packages here. We build
them in order and commit each package after its checks pass. None is published.

## Source audit and shared dependencies

The checkout had no configurator, audio or capture package at the start. The
current branch is `main`. Other chats own the declarative Flutter API, native
qualification and the other plugin directories listed in the program README.

`Object3D.id` lasts within one isolate. You supply durable source IDs when you
bind configuration targets, so a saved selection can survive a model reload.
`Mesh.material`, `Object3D.visible` and their scene revisions already provide
the required mutation path. The plugin does not own your materials or nodes.

Audio has no registered workspace dependency. The local pub cache contains an
older audioplayers package, but no spatial engine is installed in this workspace.
We use miniaudio 0.11.23 through a package-local C wrapper and Dart native assets.
Its [manual](https://miniaud.io/docs/manual/index.html) documents listener and
sound transforms, attenuation, native device playback and offline engine reads.
The pinned [license](https://github.com/mackron/miniaudio/blob/0.11.23/LICENSE)
offers a public domain dedication or MIT No Attribution. We retain that file.
The first backend exposes decoded PCM buffers and owns each native allocation.
It must report device initialization errors, with no null-device fallback.

`NativeBackend` supports explicit RGBA8 sRGB readback through `RenderBackend`,
`FrameSubmission.capture` and `ReadbackOutput`. The model viewer already writes
PNG from that output. The Flutter Android presenter rejects explicit capture;
that restriction must remain visible. Capture uses its own backend session.

Shared changes requested: append these packages to root `pubspec.yaml` and
resolve `pubspec.lock` under `/tmp/zyren-plugin-expansion.lock`. Preserve entries
from other chats. No shared renderer or scene API changes are required.

## Configurator

1. Implement a catalog of stable option and target IDs, material/component
   selections, requires/excludes rules and a versioned saved configuration.
   Validate the entire selection and all bindings before applying mutations.
   Reapplying a selection restores the baseline for deselected properties.
2. Add imported material variants, camera presets and hotspots. Catalog pricing,
   permissions and remote persistence remain application responsibilities.
3. Add optional pipeline and interaction adapters when their public APIs exist.

Acceptance: reload into newly created scene objects using the same source IDs;
round-trip saved JSON; reject wrong catalog versions, missing IDs, incompatible
options and conflicting writes without partial scene changes; preserve original
materials and visibility on reset. Include an executable usage example.

## Audio

1. Vendor the pinned engine and license, compile a native asset, and connect a
   scene listener plus bounded PCM emitters to world transforms. Implement
   distance attenuation, playback controls, removal and deterministic cleanup.
   Offline tests must exercise the real native mixer and inspect sample energy.
2. Verify native output-device initialization separately. Qualify audible spatial
   playback, suspend/resume and interruptions on each target device before
   claiming platform support.
3. Add streaming/asset decoding, occlusion, timeline synchronization, Doppler
   and additional backend adapters. Keep credentials outside this package.

Acceptance: transformed parent/listener positions reach the native mixer;
distance lowers measured output energy; removal and close release voices;
malformed PCM and invalid settings fail; unavailable device initialization throws.
An explicit offline mode is a test/export capability, never a playback fallback.

## Capture

1. Implement stills and deterministic turntable PNG sequences with explicit
   dimensions and frame times, cancellation between native frames, sequential
   backpressure and scoped output cleanup. Own an isolated camera and backend.
   Save a manifest with capture parameters and completed frame names.
2. Qualify real native readback with repeated small fixture captures. Verify
   cancellation and output ownership separately from GPU presentation.
3. Plan high-resolution tiling, alpha conversion and color handling beyond the
   initial RGBA8/sRGB path. Video encoding needs an optional encoder adapter and
   explicit frame-rate/container/error handling. Depth and object-ID output need
   capability-gated render passes, stable identity mapping and native API work.

Acceptance: identical input yields identical frame poses/timestamps and PNGs on
the same backend; no duplicate end pose; cancellation closes the owned session
and removes only the current incomplete job; sink failures also close it; reject
unsupported capture capabilities and pixel formats. Never delete preexisting
output directories. Include a native CLI example.

## Runtime agent access

Agent access is required for each package. The interaction owner supplies
`zyren_agents`; these packages will expose optional adapters through its versioned
registry. Configurator exposes catalogs, rules, selections and apply/reset.
Audio exposes listener/emitter state and playback. Capture exposes bounded jobs,
progress, cancellation and artifacts. An optional effects provider will inspect
and control existing scene effect settings through the same contract.

Mutations require host scopes, expected revisions and retry identities. Adapters
must use ordinary package APIs and preserve undo where supported. Tests must
cover discovery, schemas, real actions, stale targets, denied scopes and unload.
Screen/raycast identity and evidence come from the shared host context. These
providers must not infer rendered pixel visibility from scene geometry.

The shared `zyren_agents` contract is now available and all three packages have
optional `agents.dart` providers. Configurator and audio expose metadata callbacks
for shared rich hits. Capture uses a registration wrapper that cancels its jobs
on detach. The optional effects adapter lives in
`packages/zyren_capture/lib/effects_agents.dart`; it inspects the existing chain
and controls scene exposure, tone mapping and HDR with guarded undo. Rebuilding
chain resources through agent tools remains pending.

Direct registry tests and an actual stdio MCP session now pass. The native MCP
fixture is a headless view. Active Flutter viewport/overlay integration and a
matching presented-frame screen-to-action flow remain unverified.

## Current evidence

Configurator first slice is implemented. Seven tests passed with Flutter
3.47.5's Dart SDK: new-object reload, baseline restoration, invalid choices,
schema/catalog mismatch, duplicate/dangling rules, conflicting writes and binding
validation. The executable example saved and restored its selection. Analysis
passes after resolving two brace lint findings. The later native MCP check
verified a material color change in actual Metal readback.
Configurator commits: `cd0df35` for the domain slice and `e676caf` for runtime
agent tools, metadata and guarded undo.

Audio now has a real pinned miniaudio backend, native-asset hook, listener and
bounded PCM emitters. Five native mixer tests pass on macOS. Measured energy was
0.00499534 at distance 1 and 0.0000500186 at distance 10, then 0.00500610 after
moving the listener. Stereo orientation, pause, buffer ownership, detached-node
cleanup, invalid PCM and budgets passed. Analysis is clean. The native device
probe initialized and closed `Core Audio` successfully without emitting sound.
Audible playback and non-macOS device checks remain unverified. Capture
implementation has passed its first checkpoint. Audio commits: `52f4681` for
the native backend and `fdd87ec` for runtime state and playback tools.

Capture: seven tests pass for sampling, cancellation before/after render, scoped
cleanup, missing capabilities, stale scene revisions, sink/close failures, PNG
alpha/padding conversion and job limits. Analysis is clean. The native CLI made
two matching four-frame 64x64 PNG sequences on macOS Metal (Apple M3 Max).
The first PNG was inspected and contains the fixture geometry. Manifests:
`/var/folders/5l/q5f0v6j11y357pv60hxyng0m0000gn/T/zyren-capture-orbit-a-RCBjSd/manifest.json`
and `zyren-capture-orbit-b-7MYQBl/manifest.json` in the same temporary parent.
The existing planet app remained running; this check used an independent
headless native session and did not alter that app or a connected device.

Disk space briefly blocked the Flutter launcher stamp write. Capture tests and
the native CLI completed; subsequent Dart checks use the installed SDK binary
directly. Shared build caches were left intact.

Capture commits: `41382fe` for native capture jobs and `9e331f7` for runtime
job/effects tools, MCP example and cancellation failure handling.

Runtime providers: configurator has eight passing tests, audio has six, and
capture has ten (eight capture lifecycle/PNG checks plus capture-agent and effects
checks). Shared-interface tests cover discovery, schemas, ordinary actions,
denied scopes, expected revisions, retries, stale targets and deregistration.
Capture additionally cancels its owned jobs on detach. Analysis passes across
all three packages. Queries do not change the scene or request continuous frames.

Live MCP: `example/agent_scene.dart` uses the existing devtools stdio protocol.
Twenty-one actual MCP calls discovered configurator/audio/capture/effects and the
shared viewport provider. A logical (32,32) hit at DPR 1 returned source ID `body`
and CPU triangle coverage with pixel visibility unknown. Configurator apply then
changed a native Metal PNG. SHA-256 before:
`c56580739321ad8d51cd373e8f580e730ba705bd1fde77b07008f289fa00b019`.
After: `e5ffbe26a5a144824088369761fdd6454c1621d561debfe7766fea379ad5e8f7`.
MCP also played/paused the real offline native audio emitter and set scene
exposure. Full local transcript: `/tmp/zyren-smaller-mcp-evidence.json`.
This is native readback and MCP evidence, not a displayed Flutter screen check.

The global package-boundary check currently reports two dependencies in the
interaction owner's in-progress devtools adapter (`io.dart` and `agents.dart`
import `zyren_agents`). No owned package failed that check. Shared edits stay with
that owner. Workspace dependency resolution subsequently passed after the XR
owner registered its example. No dependency lockfile changes belong to this
batch. The milestones above retain the remaining scope.

The shell's default Flutter uses Dart 3.9.2 and cannot resolve this workspace.
Use `/Users/rexraphael/fvm/versions/3.47.5/bin/flutter` and its matching Dart SDK.


## Checkpoint and remaining work

All three first slices and their shared runtime providers are committed locally.
No package is published or complete. The full phased scope above remains open.

| Package | Domain commit | Agent commit | Passing tests | Live evidence |
| --- | --- | --- | --- | --- |
| Configurator | cd0df35 | e676caf | 8 | MCP selection changed native Metal pixels |
| Audio | 52f4681 | fdd87ec | 6 | Native mixer energy and stereo checks; silent Core Audio startup |
| Capture | 41382fe | 9e331f7 | 10 | Repeated Metal PNG sequences and real stdio MCP capture jobs |

You can run package checks with the installed Dart SDK at
`/Users/rexraphael/fvm/versions/3.47.5/bin/cache/dart-sdk/bin/dart`:
`test --no-chain-stack-traces` from each package, and `analyze` with the three
package paths from the root. The native examples are `example/native_audio.dart`
in audio and `example/capture.dart` in capture. The MCP example is
`packages/zyren_capture/example/agent_scene.dart`.

Remaining qualification: audible playback and interruption handling; physical
mobile and Windows audio/capture; active Flutter viewport, overlays and presented
frame correlation. The native MCP fixture has no displayed UI. The effects
retrofit reads the chain but only changes scene exposure, tone mapping and HDR;
chain editing and native verification of those controls remain pending. Video,
depth/object-ID output, high-resolution tiling, streaming audio, occlusion and
configurator import/hotspot adapters remain separate milestones.

## Continuation plan (2026-10-03)

The next checkpoint extends the existing packages in the same order. The prior
commit IDs above describe the starting point, not this continuation's results.

### Configurator acceptance

- Import `KHR_materials_variants` mappings through explicit source primitive and
  material bindings. Preserve variant indices as stable IDs, reject malformed or
  ambiguous mappings before changing a scene, and restore unmapped primitives.
- Add validated camera presets and source-bound hotspots. Project hotspots with
  the active camera and viewport; do not claim pixel visibility from projection.
- Verify saved variant selection against a reconstructed model and exercise the
  public tools in a displayed Flutter fixture with blocking overlay state.
- Application catalog hooks remain host-owned catalogs, bindings and persistence.
  No pricing, credential or permission service belongs in the renderer.

### Audio acceptance

- Keep the pinned miniaudio backend. Add explicit native engine suspend/resume,
  file streaming/decoding with bounded voices, deterministic seeking, and host
  occlusion gain. Cover cleanup and failed file opens with the real native mixer.
- Add transform-derived velocity/Doppler and a deterministic timeline helper.
  Bound invalid time steps and reset velocity after suspension or seeking.
- Exercise low-volume spatial output and lifecycle recovery on available native
  devices. Record device initialization, playback progress and human audibility
  separately. Mobile audio focus/route interruptions need platform event wiring.
- Additional backend adapters remain a separate compatibility milestone until a
  second backend is needed and its device matrix can be qualified.

### Capture and effects acceptance

- Rebuild the existing ScreenEffectsController through agent tools. Preserve
  host-owned LUTs, support bounded lens/SMAA/dither settings, guarded undo,
  denied/stale requests and resource cleanup. Verify native pixels and resources.
- Add an optional local FFmpeg video adapter for completed image sequences, with
  explicit frame rate, cancellation, exit diagnostics and private output cleanup.
  Keep encoding outside the renderer and report alpha/container limitations.
- Inspect native projection and readback APIs before high-resolution tiling or
  depth/object-ID work. Implement only outputs backed by existing native passes;
  record exact shared API proposals for unsupported outputs.
- Build a compact macOS/Android/iOS Flutter qualification example under
  zyren_capture. Correlate submitted scene/camera snapshots with presentation
  callbacks, then verify viewport hit, configuration action, effects edits and
  overlay reporting through the shared registry and live MCP bridge.

### Dependencies and device occupancy

No shared core mutation is planned. The example needs a workspace entry in root
pubspec.yaml; acquire the shared lock, re-read current entries and resolve once.
All code and fixture changes stay in the three assigned packages. Shared effects
and viewport APIs are consumed without editing their owners' files.

At audit, character and pipeline Flutter drivers targeted the connected iPhone.
Studio had a running macOS process. Leave those sessions alone. The connected
Pixel 9 Pro can be used only after checking its foreground app and active drivers.
Free disk space was about 2.2 GiB, so native build capacity may limit qualification.

Configurator continuation: added validated glTF variant metadata import with
bounded mapping counts, per-instance source bindings and baseline fallback;
validated perspective presets; world-space hotspot projection; optional provider
queries and a separately scoped camera action. The glTF loader does not expose
variant material resources, so direct ModelAsset decoding integration remains a
shared dependency. This adapter consumes host-provided decoded bindings.

Configurator checks: 11 package tests passed; package analysis reports no issues.
Displayed verification will use the combined fixture after the audio/capture work.

Configurator continuation commit: `06b74ce`.

Audio continuation: native device suspend/resume preserves voice intent; local
WAV/FLAC/MP3 streaming uses bounded miniaudio pages; cursor/duration, seeking,
timeline synchronization, host occlusion gain and explicit Doppler velocities
are implemented. Agent tools expose suspend/resume, seeking and occlusion gain.
Eight native tests pass, including 24 kHz stream decoding into a 48 kHz engine,
failed opens, stream cleanup, PCM timeline seeks, gain energy and suspension.
Analysis is clean. Run tests from the audio package directory so its native build
hook is included; a root test invocation cannot resolve this package's asset.

The Core Audio qualification command emitted a quiet left/right test signal.
Cursors reached 410000 us on both sides, stayed at 410000 us through suspension,
and reached 560000 us after resume. Human audibility remains unverified. Stream
seeks are asynchronous and may briefly emit silence while pages refill; use PCM
for reproducible offline export. Automatic velocity estimation, geometric
occlusion/filtering, Android audio focus, iOS interruptions/route changes and
additional backends remain later work. The shared Flutter fixture will wire app
lifecycle to the explicit engine methods.
