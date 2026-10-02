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

Current dependency: the shared registry contract is being implemented. Local
helpers alone do not establish integration. Real native screen-to-action and MCP
checks remain required and separate from direct API tests.

## Current evidence

Configurator first slice is implemented. Seven tests passed with Flutter
3.47.5's Dart SDK: new-object reload, baseline restoration, invalid choices,
schema/catalog mismatch, duplicate/dangling rules, conflicting writes and binding
validation. The executable example saved and restored its selection. Analysis
passes after resolving two brace lint findings. Rendered appearance is unverified.
Audio and capture implementation remains pending. Commit IDs follow after each
focused package commit. The milestones above retain the remaining scope.

The shell's default Flutter uses Dart 3.9.2 and cannot resolve this workspace.
Use `/Users/rexraphael/fvm/versions/3.47.5/bin/flutter` and its matching Dart SDK.
