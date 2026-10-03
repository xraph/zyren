# AI and local training

Import `ai.dart` for the Flutter contribution, `training.dart` for local processes,
`model_library.dart` for policy validation, and `training_agents.dart` for the
existing scoped registry. Core Studio does not acquire these dependencies.

Create one `GameAiWorkspace` per editor. Register its `GameAiStudioContribution`
with the shared editor host. You own the runtime policy group, model cache and
sensor lifetimes. Publish the active group, selected actor, permitted sensor
profile and completed NPC camera observations, then call `refresh()`. Clear them
before stopping play. The workspace closes only its local runner and UI listeners;
await `close()` before `dispose()`.

Use `createGameAiDevelopmentAuthoring` to compose the standard catalog and
character animation rig with `game.ai`. Standalone hosts call
`registerGameAiCodecs` from `zyren_game_ai`. Guard and vehicle bindings reuse the
same observation/action contracts as the native training worker. Learned and
hybrid modes require a model SHA256. A pin is not a quality receipt.

Set `ModelImport` to the existing cache and selected actor's observation/action
schema. It verifies model loading without changing the active brain. Field order,
units, normalization, cadence, action branches and tensor bindings matter.
Activation is a separate `ModelActivation` command. Its host callback must recheck
revision and authority and commit through the editor or play command. Only a
matching accepted evaluation can activate a candidate. T4/T5's verified artifact
reader supplies evaluation records; callers must not fabricate an accepted flag.

Configure your installed training executable and prepared worker through
`TrainingToolchain.configure`. Template, configuration and run paths belong to an
explicit project directory. The configure command returns a config hash, and the
runner additionally pins exact config-file and worker bytes. It uses argument
arrays with `runInShell: false`.

`TrainingRunner.start` publishes a handle with queued/running/stopping/completed/
failed/cancelled/unavailable states. Actual process receipts drive progress.
Receipts retain their Python canonical bytes, including floating point notation,
and have a verified sequence/hash chain. A completed process requires a final
receipt, worker closure and a matching hashed checkpoint. An exited trainer with
no final receipt fails. Stop sends SIGTERM and waits for the toolchain's update
boundary, with a bounded grace period before forced termination. Resume verifies
the existing checkpoint first. Training completion does not accept a policy.

Logs retain at most 128 entries of 2,048 characters. Run history has 64 entries,
receipt views retain 256 records, and concurrent local processes default to one.
The trainer's receipt file is bounded to 16 MiB; checkpoint bytes to 96 MiB.
Native arena bytes remain unknown. No cloud execution or pretrained download is
provided by this contribution.

Register training tools through the existing provider lifecycle. Inspection,
start and stop have independent `training.inspect`, `training.start` and
`training.stop` scopes. Tools select a host-registered request, not arbitrary
paths. Host revision and permission are checked again before process launch.

Merge `workspace.tours.registrations` into your existing `OnboardingProvider`.
Attach the start/play keys to real authoring and play controls and provide each
prepare callback to reveal the required panel. Brain and training panel anchors
are already keyed. Tour buttons appear only for registered IDs.

Qualification: macOS arm64 actual ONNX import, corrupt-byte rejection, real T3
configure/cancel/resume and local failure fixtures passed. Flutter tests covered
1440/1024/396/328 widths, both themes, 200% text and four live tour anchors. The
standalone Mac is locked, so interactive rendered Studio UI is not qualified here.
A6's Metal camera qualification is separate. Other devices remain unqualified.

The pure `ai_authoring.dart` catalog is available to offline export scripts.
`workspace.inspectActor` and `availableActors` can bind scripted or hybrid NPCs
without a learned policy group. The callback returns only permitted diagnostics.
The chooser defaults to 64 actors and supports an explicit bounded ceiling of256.

Use the shared AI `artifact.dart` reader for accepted T5 resources in both Studio
and standalone hosts. `prepareArtifact(path, cancellation)` lets the host prepare
those resources through the existing asset resolver and shared model cache.
The Training panel can also verify a pinned T4/T5 report through its thin file
adapter. The reader checks every held-out slot and fixed acceptance gate, and
requires the evaluated model SHA. It preserves the evaluated fixed rate. A
checkpoint receipt is not an ONNX acceptance receipt.

The local configuration dialog registers its verified request as `studio.local`,
so scoped tools and UI select the same runner. Scenario/reward edits save a new
template. Configure a new pinned run to consume it. Demonstration recording calls
the real T2 worker and verifies replay and chunk hashes before displaying success.
Player recordings require an actual controller action trace. The scripted option
records the established baseline, not a human demonstration.
