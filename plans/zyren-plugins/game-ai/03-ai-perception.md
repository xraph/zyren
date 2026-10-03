# Native ML and game perception implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let characters and vehicles observe their surroundings, remember events
and act through small locally executed models, with actual camera perception.

**Architecture:** `zyren_ml` executes generic tensor models through a native
bridge. `zyren_game_ai` owns observation/action schemas, sensors, memory and
policy scheduling over the game simulation. The renderer only provides generic
offscreen sensor resources and receipts.

**Tech Stack:** Dart FFI, ONNX Runtime C API, existing native renderer/Rapier,
PyTorch export fixtures supplied by the training toolkit.

**Spec:** [design.md](design.md), R15-R22, R26-R30 and R32.

## Global constraints

- Native Metal, Vulkan and DX12 remain the rendering backends.
- `zyren_ml` can execute a non-game model without importing the scene engine.
- Unknown visibility stays unknown; it is never converted to a clear ray.
- CPU is the qualification baseline.
- Weights are immutable and shared by compatible actor batches.
- Stay on the active branch and preserve concurrent work.

## Review focus

- A batch finishes after an actor respawns: discard its output and hidden state (A2/A5).
- A hidden target moves: its last known position must remain unchanged without new evidence (A3/A4).
- A model returns NaN, a missing tensor or an illegal action: select the declared fallback (A1/A5).
- An offscreen camera changes while a GPU copy is pending: preserve the original tick/camera receipt or reject the result (A6).
- Quantization changes recurrent behavior despite similar single-step outputs: evaluate complete sequences and game outcomes (A5/T5).

## File responsibilities

`zyren_ml` contains manifests, tensors, native bridge, sessions and scheduling.
`zyren_game_ai/src/perception` contains sensors and observation assembly;
`src/brain` contains memory, goals and policies. `zyren_capture` owns reusable
camera capture scheduling and pools. Renderer changes are confined to missing
generic output/readback capabilities. No ML dependency enters `zyren`,
`zyren_capture` or `zyren_native`. See the [reuse audit](reuse-audit.md).

### A1: manifest, real native inference and export feasibility

Files: create `packages/zyren_ml/pubspec.yaml`, `lib/zyren_ml.dart`,
`lib/src/{manifest,tensor,result,session,runtime,native_bindings}.dart`,
`native/include/zyren_ml.h`, `native/src/zyren_ml.cc`, `native/CMakeLists.txt`,
`hook/build.dart`, `test/{manifest,native_inference}_test.dart`,
`test/fixtures/{linear,lstm_step,cnn_step}.onnx` and fixture manifests.
Add a pinned binary/build-source manifest with hashes and license notices.
This task also bootstraps `tool/zyren_train/pyproject.toml` and `uv.lock` for the
export probe. T1 expands that same lock and CLI setup after the probe succeeds;
T5 extends the existing probe script. Those files have one owner at a time.

Interfaces: `MlModelManifest.decode/encode`, `MlTensor(dtype, shape, bytes)`,
`MlTensorMap`, `MlRuntime.load(MlModelManifest, ModelAssetResolver)`,
`MlSession.run(MlTensorMap, MlRunOptions)`, `MlSession.close()`;
`MlRunResult` distinguishes ok/invalid/unsupported/unavailable/cancelled/failed.
`MlRunOptions` supplies deadline, request ID and cancellation; no native pointer
escapes the owner. Start with float32/int64/bool tensors and bounded batch shapes.
Existing `AgentModel.complete` and `HttpAgentModel` execute external text/tool
workflows. They do not supply this tensor/session ABI. Keep their provider clients,
conversation history and approval flow in Agents; add only native tensor inference
here. Load model bytes through the injected resolver instead of another asset cache.

- [ ] Generate tiny linear, one-step LSTM and CNN fixtures with known inputs/outputs in `tool/zyren_train/scripts/export_probe.py`. Verify actual PyTorch-to-ONNX export and native loading before fixing the opset/runtime pins. Record those exact versions in a probe receipt.

```dart
final output = await session.run(inputs, options);
expect(output.status, MlRunStatus.ok);
expect(output.tensors['action']!.shape, [1, 2]);
expect(output.tensors['action']!.float32Values.every((v) => v.isFinite), isTrue);
```

- [ ] Run the native fixture test before implementation and confirm it cannot pass through a substitute backend. Also test integer-overflow shape products, file hash mismatch, unsupported opset, external-data path traversal and missing recurrent tensors.
- [ ] Implement an exception-safe C ABI over ONNX Runtime with owned handles, error codes and explicit release. Use the official C API and a checksum-pinned artifact/build process. Reject custom operator libraries and external tensor paths outside the bundle. The build hook reports unsupported targets clearly.

```cpp
enum ZyrenMlStatus { ZYREN_ML_OK = 0, ZYREN_ML_INVALID = 1,
  ZYREN_ML_UNSUPPORTED = 2, ZYREN_ML_FAILED = 3 };
// Exported boundary functions return status codes; C++ exceptions stay inside.
```

- [ ] Run `fvm dart test --concurrency=1 test/manifest_test.dart test/native_inference_test.dart` inside `zyren_ml`. Exercise repeated load/run/close and native memory diagnostics. Probe macOS first, then build and run the same fixtures on the target matrix during Q4.
- [ ] Commit as `feat(ml): execute versioned models through native ONNX Runtime`. Record any recurrent export blocker before dependent policy tasks begin; a feed-forward fixture alone does not close the recurrent probe.

### A2: workers, batching and model resource lifetime

`MlModelCache` retains loaded native sessions and in-flight references. Pipeline
already caches artifact bytes, and Flutter caches scene assets. Reuse those at
their boundaries; do not create another download, disk or decoded scene cache.

Files: create `packages/zyren_ml/lib/src/{worker,scheduler,model_cache,provider,diagnostics}.dart`,
`test/{scheduler,lifetime,provider}_test.dart`.

Interfaces: `MlScheduler.submit(MlRequest)`, `MlRequest` carries model hash,
ordered tensors, deadline and opaque actor token; `MlBatchMap` maps every slot to
its request ID; `MlModelCache.acquire/release`; `MlProviderProbe` reports actual
provider, unsupported operators, allocation limits and timing. Cancellation is
cooperative; releasing buffers waits for native completion.

Initial configurable limits are 64 queued requests, 32 MiB queued tensor payload,
64 batch slots, eight resident model sessions and 64 MiB total model weights.
Report native arenas and recurrent/sensor memory separately; these admission
limits do not cap total process RSS. A model that exceeds a limit fails admission
before the current model is evicted.

- [ ] Test queue exhaustion, expired requests, cancellation during inference, duplicate model pins, cache eviction with an in-flight job and out-of-order completions. Include three actor slots with one cancelled middle request.

```dart
expect(batch.slotRequestIds, ['a', 'c']);
expect(results.keys, unorderedEquals(['a', 'c']));
expect(results.containsKey('b'), isFalse);
```

- [ ] Run scheduler/lifetime tests with delayed deterministic test backends, then repeat cancellation/disposal with the real native fixture.
- [ ] Keep session handles inside dedicated workers; transfer bounded tensor blocks. Bound queue count, tensor bytes and batch wait time. Share immutable loaded sessions only through the defined worker/thread policy. Default to CPU; expose opt-in provider selection after an operator and numerical probe.

```dart
if (request.deadlineTick < currentTick) return MlOutcome.expired(request.id);
if (queuedBytes + request.byteLength > byteBudget) {
  return MlOutcome.capacity(request.id);
}
```

- [ ] Check inference does not block the Flutter UI/render thread and backpressure does not grow RSS indefinitely. Measure model load, warm/cold run and queue latency separately. Qualify CoreML/other native providers only where the exact graph works; retain CPU as an explicit supported choice.
- [ ] Commit as `feat(ml): schedule bounded native model inference`.

### A3: observation schemas and structured sensors

Files: create `packages/zyren_game_ai/pubspec.yaml`, `lib/zyren_game_ai.dart`,
`lib/src/contracts/{observation,action,sensor_profile,frame}.dart`,
`lib/src/perception/{registry,snapshot,vision,rays,grid,hearing,body,affordance,assembler}.dart`,
`test/{schema,perception,hearing}_test.dart`.

Interfaces: `ObservationSpec` and `ActionSpec` encode ordered fields/units/bounds
and expose a canonical hash; `SensorProfile`, `SensorSnapshot`, `ObservationFrame`;
`GameSensor.sample(SensorSnapshot, GameEntityHandle)` returns `SensorReading` with
known/unknown/unavailable state, provenance and tick; `ObservationAssembler.build`.
`SensorRegistry` allows custom sensors with declared budget, cadence and schema.

- [ ] Test field-of-view edges, occluders, glass/foliage policy, unloaded geometry, moving doors, sensor range and target disappearance. Test hearing without exact hidden-source coordinates and stable ordering of variable-length entity slots with masks.

```dart
expect(frame.visibleIds, isNot(contains('behind-wall')));
expect(frame.entities.length, maxEntities);
expect(frame.entityMask.where((v) => v == 1).length, frame.visibleIds.length);
expect(frame.schemaHash, spec.hash);
```

- [ ] Run perception tests against real Rapier queries where occlusion is physical. Pure math tests cover cone/range boundaries independently. Include a paired-world fixture whose observable geometry is identical but hidden actor positions differ.
- [ ] Capture one consistent post-physics snapshot. Use spatial filtering, local transforms and sorted bounded candidates before ray queries. Apply explicit sensor material/layer rules; return unknown when required geometry or query budget is unavailable. Hearing uses game events and its declared uncertainty; ambient playback does not grant world knowledge.

Use existing Physics ray/shape/overlap queries and Navigation surfaces/followers.
The new work defines observation limits, cadence, uncertainty and knowledge
filtering. Interaction ray hits and label visibility can aid tooling but are not
proof of rendered visibility. Do not duplicate collision acceleration structures,
navigation baking or the spatial audio mixer for perception.

```dart
final local = inverseSensorPose.transformPoint(target.position);
final inside = local.length <= profile.range &&
    local.normalized().dot(profile.forward) >= profile.cosHalfAngle;
```

- [ ] Assert identical permitted observation tensors in the paired hidden-world fixture. Verify a visible target, audible hidden target and last-seen target have distinct provenance. Export sensor diagnostics for S6.
- [ ] Commit as `feat(ai): add bounded game perception sensors`.

### A4: memory, goals and scripted brains

Files: create `packages/zyren_game_ai/lib/src/brain/{memory,belief,goal,brain,scripted,skill,utility}.dart`,
`test/{memory,goal,scripted_brain}_test.dart`.

Interfaces: `GameBrain.observe(ObservationFrame)`,
`GameBrain.decide(BrainContext)`, `reset(BrainReset)` and `close()`;
`BrainContext` exposes only permitted observations/beliefs/goals/actions;
`BeliefStore.observe`, `atTick`, `forget`, `snapshot/restore`;
`GoalSelector`, `GameSkill` and `UtilityGoalSelector` provide typed extension points.
Skill execution uses G6's graph/actions; memory budgets are explicit in the profile.

- [ ] Test TTL expiry, last-seen locations behind walls, independent actor memory, model/episode reset, bounded eviction and permitted team communication. Verify a goal referring to a despawned entity cannot control its replacement.

```dart
beliefs.observe(target: 'runner', position: seenPosition, tick: 10);
final remembered = beliefs.atTick(20).single;
expect(remembered.position, seenPosition);
expect(remembered.ageTicks, 10);
expect(beliefs.atTick(10 + ttlTicks + 1), isEmpty);
```

- [ ] Run memory and scripted scenario tests before learned policies are introduced. Establish a baseline guard and driver behavior for training comparison.
- [ ] Implement bounded beliefs with observation source, confidence and expiration. Select goals using explicit priorities/utility inputs and a minimum commitment period to avoid oscillation. Register investigate/follow-route/interact/idle skills and expose their cancellation behavior. Do not synthesize new target positions while out of view.

```dart
final valid = beliefs.where((b) => tick - b.observedTick <= b.ttlTicks);
final nextGoal = selector.choose(valid, actorState, currentGoal);
```

- [ ] Run guard loss-of-sight, sound investigation and vehicle obstacle scenarios through the native game fixture. T1 adds the training worker adapter and S6 adds Studio inspection. Verify memory snapshot/restore retains ages relative to the saved game tick.
- [ ] Commit as `feat(ai): add per-actor memory goals and scripted brains`.

### A5: learned policies and controller actions

Files: create `packages/zyren_game_ai/lib/src/brain/{policy,policy_state,decision_scheduler,action_decoder,hybrid}.dart`,
`test/{policy,action,decision_latency}_test.dart`; extend model contract fixtures
through T5's exported sequence files.

Interfaces: `PolicyBrain` implements `GameBrain`; `BrainDecision` carries episode,
entity generation, model hash, observation tick, apply tick, action and next hidden
state; `DecisionScheduler.accept`; `ActionDecoder.decode` produces G4/G5 intents;
`HybridBrain` composes a goal selector and registered scripted/learned skills.

- [ ] Test per-actor hidden state in compacted batches, stale model/episode outputs, illegal discrete branches, NaN/Inf, continuous limits, pause/resume and missed decision ticks. Sample full recurrent sequences, not only zero-state inputs.

```dart
expect(scheduler.accept(oldGenerationDecision), isFalse);
expect(scheduler.accept(wrongModelDecision), isFalse);
expect(controller.activeIntent, fallbackIntent);
expect(memory.forActor(currentActor), currentMemory);
```

- [ ] Run tests with both a deliberately faulty fixture model and A1's real recurrent model. A valid scripted baseline does not satisfy learned-policy execution.
- [ ] Map normalized actions to controller units, apply legality masks and validate targets at execution. Accept hidden state only together with the matching action result. Simulate the declared decision latency in both deployment and training. Limit hold-last-action time; characters stop and vehicles brake when their configured fallback requires it.

```dart
if (decision.episodeId != episodeId ||
    decision.entity != currentHandle ||
    decision.modelHash != activeModelHash ||
    decision.applyTick != tick) return false;
```

- [ ] Run A1's real recurrent fixture through both character and vehicle action decoders, with recorded sequence receipts and latency jitter. T3/T5 produce trained policies; Q1 verifies their task behavior in the exported game. This task establishes the learned-policy execution path without claiming policy quality.
- [ ] Commit as `feat(ai): run learned policies through game controllers`.

### A6: native camera sensors and visual policies

Files: create `packages/zyren_game_ai/lib/src/perception/{camera,image_preprocess}.dart`,
`test/{camera_contract,camera_native}_test.dart`;
extend `packages/zyren_capture` with `lib/sensors.dart`,
`lib/src/sensor_capture.dart` and `test/sensor_capture_test.dart`;
modify `packages/zyren/lib/src/rendering/{capabilities,frame_output}.dart`,
`packages/zyren_native/lib/src/{native_renderer,backend}.dart`,
`packages/zyren_native/native/src/{renderer.rs,render_graph/frame.rs}` minimally;
create `packages/zyren_native/native/src/renderer/sensor_capture.rs`.
Update the native ABI headers and Apple copies together if the public protocol changes.

Interfaces: `SensorCaptureRequest` pins scene snapshot/tick/camera/output format;
`SensorCaptureReceipt` contains request/frame IDs, camera matrices, tick, dimensions,
color/depth conventions and resource lifetime; `SensorCapturePool.capture` returns
bounded typed image/depth buffers from `zyren_capture`, without ML tensor types.
Reuse `FrameSubmission.capture`, its immutable camera/scene snapshots and the
existing `ReadbackTarget`/`ReadbackOutput` and native backend. Extend these contracts
only for missing outputs. Capabilities report RGB/depth/class separately.
`CameraSensor` implements A3's sensor interface and never reads the user's display.
Its preprocessing adapter converts capture buffers into A1 tensors. Existing PNG,
turntable, tiled and video capture stays in Capture. XR depth is physical
environment input and cannot substitute for a virtual NPC camera's depth output.

- [ ] Run an early feasibility probe for offscreen RGB/depth on each renderer before committing training architecture to a particular format. Add known-plane depth, occluded colored object, skin deformation, resize, cancelled capture and renderer recreation tests.

```dart
expect(receipt.tick, requestedTick);
expect(receipt.width, 84);
expect(receipt.height, 84);
expect(depth.validAt(center), isTrue);
expect(depth.metresAt(center), closeTo(knownPlaneDistance, .01));
```

- [ ] Verify existing code reports unsupported depth instead of fabricated zeros before implementing the new target/readback path. Record the mobile capture gap separately from macOS color support.
- [ ] Extend Capture with a persistent sensor session using existing frame snapshots, native resources and synchronization. Add target pooling and missing depth/class readback in the owning renderer path without duplicating frame submission or native backend ownership. Define RGB channel order, color space, normalization, metric depth and invalid-depth masks in the manifest. Render actual scene materials for RGB. A separate class-mask pass must reproduce declared coverage rules and expose unsupported shader effects.

```dart
final value = ((channel / 255.0) - mean[channelIndex]) / std[channelIndex];
final depthValue = validDepth ? (metres / maxMetres).clamp(0.0, 1.0) : 0.0;
// A separate validity mask distinguishes sky/unavailable from a near surface.
```

- [ ] Test output correlation under moving agents and asynchronous inference. Measure GPU capture, transfer, preprocessing, inference and total decision latency using A1's real CNN fixture. T6 trains RGB/depth profiles; Q1 verifies their behavior on unseen textures/lighting. CPU semantic queries cannot close the native sensor gate.
- [ ] Commit as `feat(ai): add native camera observations for visual policies`, with separate per-backend capability and qualification records.

### A7: multi-agent coordination and external diagnostics

Files: create `packages/zyren_game_ai/lib/src/brain/{team,communication,policy_group}.dart`,
`lib/agents.dart`, `packages/zyren_ml/lib/agents.dart`,
`test/{team,agents,multi_agent}_test.dart`.

Interfaces: `GameTeam`, `TeamMessage`, `CommunicationProfile`, `PolicyGroup`;
`GameAiAgentProvider` and `MlAgentProvider` use the existing shared registry.
Attach through `AgentRegistryPlugin`/`AgentProviderPlugin` where scene hosted,
or the existing registry registration scope in a renderer-free worker. Reuse
Devtools telemetry/history and current CLI/MCP transport and job handling.
Actor-to-actor messages and external developer tooling are separate capabilities.
Messages carry sender, recipient/team, tick, observation provenance and expiry.

- [ ] Test sender removal, delayed messages, duplicate events, team changes, spoofed target identity and recurrent state isolation for actors sharing weights. External tools need host-granted read/control scopes and current revisions.

```dart
expect(teamMessages.forActor(enemy), isEmpty);
expect(policyGroup.modelCount, 1);
expect(identical(policyGroup.stateFor(a), policyGroup.stateFor(b)), isFalse);
```

- [ ] Run same-team and opponent fixtures through the native game runtime, including actors entering/leaving an episode and a shared reward case. T6 adds the PettingZoo adapter over this contract.
- [ ] Implement bounded team channels with explicit perception/range/delay rules. Expose observations, goals, model versions, deadlines and resource counters through passive tools. Reset/swap/debug actions go through host commands; they never bypass game validation.
- [ ] Verify a live external MCP inspect/reset/model-selection flow plus denied/stale/cancelled calls. Confirm production play needs no MCP server or remote model service.
- [ ] Commit as `feat(ai): add team coordination and model diagnostics`.

## Verification and shared requests

A1 registers `zyren_ml` and its `dart:ffi` exception in the boundary checker. A3
registers `zyren_game_ai`. A6 extends Capture and requests only missing generic
targets/outputs/readback from the renderer owner. Reuse native frame receipts
and snapshots. Keep ML types out of those APIs.
Existing capture jobs remain usable and retain their current ownership semantics.

Run native tests from their owning package directories, sequentially. Compare
float32 exports with initial `atol=1e-5`, `rtol=1e-4`; investigate deviations before
changing tolerances. Quantized models use both recorded numerical error and T4
behavior gates. Q4 records device/provider evidence and resource budgets.
