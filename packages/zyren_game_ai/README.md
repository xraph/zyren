# Zyren Game AI

Build observations from the game sensors phase, then send the frame's immutable
float32 tensor to your policy. You get ordered schema hashes, bounded slots and
validity masks. Physics stays in Rapier.

```dart
final profile = SensorProfile(range: 20, maxEntities: 8);
final sensors = SensorRegistry()
  ..register(VisionSensor(profile))
  ..register(BodySensor())
  ..register(HearingSensor(profile));
final assembler = ObservationAssembler(registry: sensors, profile: profile);

final snapshot = SensorSnapshot.fromSimulation(
  episodeId: episodeId,
  simulation: simulation,
  worldRevision: revision,
  bindings: liveBodies,
  characters: characterControllers,
  colliders: sensorColliderMetadata,
  sounds: gameplaySoundEvents,
  currentRevision: () => revision,
  geometryLoaded: loadedQueryDomain,
);
final frame = assembler.build(snapshot, observer);
// Pin assembler.spec.hash in the policy manifest.
// frame.tensor contains normalized values, followed by their validity masks.
```

Use `GamePerceptionSystem` to capture once per tick after physics and rules. Pass
a closure for its simulation reference when constructing the system before the
simulation. Every observer samples the same captured body states. The capture
callback must return the current game tick; live entity generations are checked
before publication, and the simulation adapter removes retired body bindings.

Your revision callback must change whenever query geometry changes. Capture
collider classifications, sound events and body mappings from that same revision,
and keep the native world stable until synchronous assembly finishes. A mismatch
invalidates readings. `geometryLoaded` must conservatively cover the entire query
domain: the ray segment, or the grid cell's bounding volume. Missing streamed
geometry produces unknown data with zero validity, including when a native ray
finds no collider.

Vision reserves independent ray quotas against a stable catalog sorted by entity
ID and generation before applying actor-local cone and range checks. Hearing
reserves against its timestamp/ID catalog before checking hidden source range or
attenuation. Unused quotas are not reassigned. Hidden motion therefore cannot
consume a visible or audible peer's quota. Slots contain visible targets only. Catalog caps and small per-slot budgets
produce partial coverage. A reading stays unknown while any catalog entry remains
unobserved, with a generic partial-coverage reason; actual query failure details
remain service diagnostics. Empty
slots are zeroed and masked. You can inspect an unknown reading without gaining
the hidden candidate's identity or transform. This is structured collider
visibility; it does not establish rendered pixel visibility.

Classify every relevant collider. Opaque surfaces block by default. Glass,
foliage, smoke and unclassified hits are unknown until you declare a block or pass
rule. Pass-through surfaces consume extra queries, including their exit surface.
Layer filtering follows Rapier collision groups, and sensor colliders are
excluded. Moving doors use the current physical pose. Visual smoke, deforming
meshes and other effects need matching authored sensing geometry or conservative
unknown coverage. An absent collider is not optical visibility evidence.

`RaySensor` reports native hit distances. `GridSensor` uses native overlap
queries for authored local cells. Neither builds an acceleration structure.
`BodySensor` reports local velocity and the controller's captured grounded flag;
missing grounding stays invalid. `AffordanceSensor` consumes the observing
controller's declared legality values. Navigation remains with the existing
character controller and follower. Supply only allowed route knowledge when you
turn navigation state into an affordance.

Hearing consumes `GameSoundEvent` independently of speaker playback. Muting audio
doesn't remove gameplay events. `SensorSoundSample.fromEvent` drops source entity
identity before sampling. The service computes range attenuation and a declared
obstruction gain, then emits category, local bearing sector, distance band, event
age and obstruction. Exact source positions and continuous amplitudes never enter
the frame. `HeardSound` includes the bearing uncertainty and distance interval.
There is no source ID or position field in the result.

`LastSeenSensor.remember(frame)` keeps one bounded prior visible frame. Its
coordinates remain in the observer's local frame at capture, with the original
observation tick. They never follow hidden target movement. Episode changes,
observer generation changes and TTL expiry invalidate that history. This small
adapter keeps a prior frame. [Per-actor memory](doc/memory.md) adds bounded
beliefs, goal commitment and scripted skills.

Observation and action schemas encode field order, units, bounds and affine
normalization. Sensor configuration hashes also pin cone/material/layer rules,
cadence, hearing bins, ray directions and grid layout. Frames carry episode,
entity generation, tick, world revision and schema identity. Action schemas include
continuous controller bounds, discrete choices, legality masks and a validated
fallback. You still enforce an action in its controller when applying it.

You can register a custom `GameSensor` with its schema, cadence and query budget.
The registry rejects duplicates, changed schemas and malformed readings. Extension
code is trusted host code and must respect its declared query budget and knowledge
rules. Diagnostics report actual built-in query counts, candidate counts, state
and unknown reasons for tooling; diagnostic candidate counts are excluded from
policy tensors. Rebuild the assembler after changing registrations.

Limits are explicit: 64 sensors, 4096 aggregate declared queries per observer,
4096 candidates per sensor, 256 entity slots, 256 rays/grid cells, 64 hearing
slots, 16384 snapshot entities and 4096 sound inputs. Defaults are smaller.
Schemas cap field width at 65536 and total tensor width at 131072; the assembler
includes its validity fields in that schema. Configure actor cadence and budgets
for your host. These bounds are not a measured frame-time guarantee.

[Policy execution](doc/policy.md) uses the native ML scheduler with per-actor
recurrent state, exact application ticks, controller decoders and bounded fallback.
The real exported LSTM probe is execution evidence. Trained-policy acceptance and
behavior qualification belong to the training and qualification tasks.

Run package checks with FVM:

```sh
fvm dart analyze packages/zyren_game_ai
cd packages/zyren_game_ai
fvm dart test --concurrency=1
```

The native perception tests use real Rapier queries on macOS arm64. They cover
physical occlusion and compare identical policy tensors while hidden actor
positions change. Native guard and vehicle fixtures also exercise memory and policy outputs.
The 1,000-step recurrent trace matches exported action/hidden/cell values through
both controller decoders. Native camera RGB/depth and real CNN execution are qualified on Metal.
See [camera observations](doc/camera.md) for profile pins, due-tick controller
execution and measured latency. Class masks and unqualified desktop/mobile
backends retain their separate gaps.

Paused sessions can preserve committed recurrent tensors with
`brain.synchronize(..., preserveCommittedState: true)`. Use this only for a
host-owned pause or resume. Normal ownership and episode changes reset state.
Held actions and queued decisions always clear.

Await `brain.quiesce()` before `snapshotCommitted(tick: ...)`. Quiescence pauses
admission and waits for invalidated inference to finish. A checkpoint refuses
pending or staged work. `PolicyBrainCheckpoint.encode/decode` caps its JSON and
little-endian tensor storage, and `restoreCommitted` validates the contract,
model, memory profile and fresh actor mapping before changing state. Seed the
restored game and control epochs through that call, then preserve state when
resuming. Historical belief positions retain their observation frame and age.
You must retain the captured observer pose when translating them to world space.

Scripted checkpoints retain historical memory and rebuild the bounded runner on
its next decision. They do not serialize a custom selector or behavior runner's
program counter. Restore each known hybrid child first, then call
`restoreActiveSkill(identity: ..., activeSkill: ...)` so the first decision in the
same learned skill keeps its recurrent state. Custom hybrid skills need their
own explicit checkpoint contract.

The optional `artifact.dart` entry provides a shared byte-only
`ModelArtifact.decode(bundleJson, files)` reader. It accepts the exact eight
T5 resources with matching hashes and sizes, structured observation/action
bindings, embedded normalization, recurrent state, provenance and a passing
report for the exact ONNX SHA. It owns immutable copies under a 32 MiB aggregate
budget. Native graph loading remains with your shared `MlModelCache`.

`ModelEvaluation.decode` verifies canonical receipt bytes, full episode slots,
fixed acceptance gates and the declared plan. `fixedHz` comes from every case in
the selected family. A host must use that rate, or reject the model for its current
runtime. Cadence and latency are one tick. An audited plan revision retains its
superseded hash and checks the unchanged case-content hash. A checkpoint report
cannot qualify a different exported ONNX artifact.

## Native game actors

Import `package:zyren_game_ai/runtime.dart` to bind authored `game.ai` components
through `GameLevelAi`. Register its `systems` with `GameLevelRuntime`, then await
`warmup()` before attaching the scene engine. The host supplies evaluated policy
contracts keyed by model SHA256, the fixed simulation rate from each acceptance
receipt, and one shared `MlModelCache`. The AI owner drains and closes that cache.
Use `manifestResolver` when several model artifacts contain `actor.onnx`.

The adapter reads native physics snapshots after the simulation step. Its next
decision goes through the existing character or vehicle controller lease.
Inactive entities do not produce fresh observations. Hearing produces approximate
historical beliefs; the brain inspector does not read hidden target positions.
User possession, deactivation and entity replacement revoke NPC control.

You can author a scripted, learned or hybrid brain. A hybrid actor can use its
scripted baseline when a model is missing or incompatible, and inspection reports
the model failure and fallback counters. A learned-only actor rejects that launch.
`ModelArtifact` in the optional `artifact.dart` entrypoint validates accepted
export bytes before the host constructs a `GameRuntimePolicy`.

Call `await ai.save()` or `await ai.restore(save)` at the host boundary. These
operations pause the game and drain inference. Resume explicitly after inspection.
Checkpoints preserve committed recurrent tensors and bounded memories, remap live
references to fresh entity generations, and rebuild the scripted runner from its
beliefs. Custom behavior interpreter program counters are outside this codec.
Native scene topology must satisfy the native runtime's checkpoint contract.

The native regression exercises 144 actors sharing one model across batches of
at most 64 slots. Each actor retains private recurrent state. The optional actor
and queue ceiling is 256, with the existing 32 MiB queue and state budgets.
This capacity check does not establish a sustained frame rate or device profile.
The ONNX fixture used by that regression is deterministic test data, not a trained
or accepted gameplay model.
