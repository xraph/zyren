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

You can share a `SensorSampleCache` between assemblers that build from the same
`SensorSnapshot`. Pass it as `build(snapshot, actor, cache: cache)`. The game
runtime does this within its sensors phase so an identical Body/Vision capture
can serve both learned input and scripted awareness.

Reuse requires the same snapshot object and actor generation, complete built-in
sensor configuration, and unchanged native world revision and closed state.
Vision rechecks the geometry availability of every segment visited by the saved
sample. A changed range, cone, layer, material rule, catalog bound, cadence or
query budget samples freshly. Team-filtered snapshots cannot borrow a global
catalog reading, and custom sensors always execute with their registration and
schema drift checks intact.

The defaults retain at most 512 readings, 131072 values (with their validity
entries), and 4096 geometry checks. These are logical retention bounds; they do
not measure Dart heap allocation. Overflow samples normally without retaining
the result. A new or stale snapshot clears the retained readings. Reused service
diagnostics set `reused: true` and report zero new native queries and candidate
admissions, while the immutable reading keeps its original provenance, unknown
masks and partial-coverage reason. This optimization does not establish a frame
budget or target-device capacity result.

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

`RaySensor` reports native hit distances. Profiles without passable materials
batch their admitted rays through the physics plugin. Each ray still consumes
one query, and unloaded or unknown geometry keeps its invalid mask. Transparent
profiles retain sequential queries so crossing a surface cannot change budget
allocation for later rays. `VisionSensor` uses the same batch API while preserving
each catalog candidate's query quota. Each batch fits the remaining visible slots,
so it stops querying where the scalar path stops. `GridSensor` uses native overlap
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

Prepare pooled actors through `GameLevelRuntime.prepareSpawn`. AI validation
runs before the host allocates their native objects and again before activation.
`warmup()` loads the bounded registered policy catalog, so adding an actor never
loads weights inside a simulation tick. An incompatible learned-only recipe is
rejected before its preparation callback runs.

Spawning joins the existing policy group. Despawning removes only that actor's
control lease, pending inference and memory; other actors retain their committed
recurrent state. Await `flush()` at an offline boundary to drain retired work.
Reusing a pool slot creates fresh entity generations and zeroed actor state.
AI checkpoint version 2 restores a different active pool configuration when all
its recipes have been prepared in the native host. Model, profile and brain
definitions are checked before the candidate world replaces the live bindings.
`observation(handle)` exposes the actor's latest immutable permitted frame for
inspection. A retired handle cannot read a replacement actor's observations.

The native regression exercises 144 actors sharing one model across batches of
at most 64 slots. Each actor retains private recurrent state. The optional actor
and queue ceiling is 256, with the existing 32 MiB queue and state budgets.
This capacity check does not establish a sustained frame rate or device profile.
The ONNX fixture used by that regression is deterministic test data, not a trained
or accepted gameplay model.

## Multi-agent authoring contract

You can store a `multiTask` of `cooperative-search` or `competitive-pursuit` in
`game.ai` with the `guard` controller profile, `teamId` and `multiRole`. Cooperative
roles are `scout` (+1) and `searcher` (-1); both require an authored `goalEntityId`
that the codec remaps with local entity references. Competitive roles are
`pursuer` (+1) and `evader` (-1), with opposing role identity supplying the goal.
The competitive definition cannot carry a separate goal entity.

`authoredRoute` is an optional list of at most 32 `[x, y, z]` waypoints. Coordinates
must be finite and within 100,000 units. The definition copies each point and
exposes an immutable list. `TrainingMultiProfiles` supplies the exact task
observation and discrete action hashes. Camera and multi-task modes are mutually
exclusive.

`GameLevelAi` now binds these tasks to the existing native character controllers
and shared policy scheduler. Cooperative teams contain one scout and one or two
searchers with the same goal. Competitive teams contain one pursuer and one
evader. The pursuer has no authored route; the evader loops its route. Admission
checks those references, roles, team bounds and the registered 50 Hz clock before
loading models or allocating prepared spawn resources.

The service samples only its team members and authored goal as observation
candidates. Other world colliders still occlude rays. Every five ticks, a member
can send its actually visible goal through `TeamChannel`, with a two-tick delay,
100-tick expiry and the shared profile's limits. The adapter rebases that bearing
with the captured sender pose, then encodes it in the recipient's observation
frame. Competitive message planes remain zero. Route input uses only the actor's
own pose and authored waypoints. Jump requires grounding; interaction is disabled.

Each actor owns its route cursor, historical sighting and recurrent policy state.
Members share model weights through `PolicyGroup`. Pause, membership changes and
retirement cancel pending messages; checkpoints retain committed route/history
and remap fresh entity generations. Retiring a required role suspends the team
until its covered topology returns. There are at most eight retained team IDs,
three members per cooperative team, for at most 24 live multi actors. The global
64-observer guard remains an additional upper bound. Each channel
retains its eight-message queue and 256-event ledger for the episode; exhausting
that ledger stops new messages until a new episode.

The scripted baseline uses the existing follow-route skill, then a currently
visible goal or delivered historical sighting. It does not query an unseen goal.
Visible slots retain the shared sensor's handle-ID ordering. The native rename
regression proves goal/message provenance across slot reordering, not invariant
learned decisions. A model's qualification must cover its supported identity
permutations before that deployment scope can be accepted.

Hosts bind a decoded accepted artifact with
`GameRuntimePolicy.fromArtifact(artifact)`. A handwritten contract cannot enable
a learned multi task. The accepted multi-plan registry remains empty, so no
learned multi model can currently activate. Native lifecycle and scripted tests
do not establish trained model quality or multi-agent capacity.

`ModelEvaluation.decode` also reads v2 team receipts. Joint episodes, held-out
role results, each pinned opponent and historical role aggregates retain separate
denominators. `roleMetrics` exposes immutable held-out competitive metrics;
`successRate` is the smaller of the two role win rates. Historical seeds cannot
fill a gap in held-out layout coverage, and contact confidence gates apply to
each role aggregate rather than its 50-episode opponent rows.

Multi artifacts use the same eight files with an exact `multiProfile` header,
full embedded normalization and character discrete actions. Cadence and latency
are one tick, with a two-tick hold limit at 50 Hz. The accepted multi-plan registry
is empty. A valid codec receipt does not establish trained model acceptance or
team deployment, and import stays closed until an exact plan is registered and
its ONNX and native parity receipts pass.
