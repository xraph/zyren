# Game runtime implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let you build and ship a native game with reusable actors, controllers,
rules, saved state and project assets.

**Architecture:** Keep the game data and simulation in `zyren_game`. Put native
engine adapters in `zyren_game_native` and Flutter input/HUD/lifecycle in
`flutter_zyren_game`. Compile Studio data into a runtime artifact before play.

**Tech Stack:** Dart, Flutter 3.47.5 through FVM, existing Zyren/Rapier packages.

**Spec:** [design.md](design.md), especially R01-R09, R14 and R32.

## Global constraints

- Native Metal, Vulkan and DX12 remain the rendering backends.
- `zyren_studio` stays Dart-only.
- Training calls `step`, never a render callback.
- Stay on the active branch and preserve concurrent work.
- Use Flutter 3.47.5 through FVM and commit only owned, checked files.
- New game APIs below are proposals. Existing APIs and their owners are listed in the [reuse audit](reuse-audit.md).

## Review focus

- A pooled entity reuses an ID while an old command is queued: reject the old generation (G1).
- A rendered frame and training loop both request physics: advance exactly once (G2).
- A controller disconnects while throttle is held: clear intent and apply the authored brake fallback (G3/G5).
- A compiled spawn template references another entity inside itself: instantiate independent references (G1/G7). Studio owns authored prefab expansion.
- A save references a removed item or incompatible model: retain the active session and report the incompatible references (G7).

## File responsibilities

`zyren_game/lib/src/project` owns serialized records and codecs. `runtime` owns
session, entities, phases and events. `gameplay` owns interactions, inventory,
abilities and objectives. Keep these modules separate from `zyren_game_native`
controllers and `flutter_zyren_game` widgets. Each task creates its own tests and
updates its package README/API exports alongside the working feature.

### G1: project, entity and component contracts

Files: create `packages/zyren_game/pubspec.yaml`, `lib/zyren_game.dart`,
`lib/src/project/{project,component,registry,spawn_template}.dart`,
`lib/src/runtime/{entity,command_queue}.dart`, `test/project_test.dart`,
`test/entity_test.dart` and `README.md`. Modify root `pubspec.yaml` and
`tool/check_package_boundaries.dart` under the shared lock.

Interfaces: `GameEntityHandle(String id, int generation)`;
`GameComponentRecord(String type, int version, Map<String,Object?> data)`;
`GameRegistry.registerComponent(GameComponentCodec codec)`;
`GameProject.decode(String source, GameRegistry registry)`;
`GameProject.encode()`; `GameSpawnTemplate.instantiate(String instanceId)`.
`GameComponentCodec` declares type/version, validate, migrate, local references
and factory. `GameCommandQueue` admits a bounded typed command with its target
handle and application tick. `GameEntityTable` owns spawn/despawn/generation.
`GameSpawnTemplate` is a flat compiled recipe for runtime spawning. It contains
no authored inheritance, nested prefab resolver or editor overrides. G7 compiles
existing `StudioPrefab` instances through `StudioDocument.expandedNodes` and
`prefabOwners`; G1 can test flat recipes without depending on Studio.

- [ ] Add round-trip, duplicate-ID, dangling-reference and version migration tests. Use a two-entity compiled spawn recipe with a local target link and instantiate it twice. Its target IDs must differ across instances. G7 tests Studio prefab validation and compiler remapping.

```dart
final table = GameEntityTable();
final old = table.spawn('guard');
table.despawn(old);
final next = table.spawn('guard');
expect(next.generation, old.generation + 1);
expect(table.isAlive(old), isFalse);
expect(table.isAlive(next), isTrue);
```

- [ ] Run `fvm dart test test/project_test.dart test/entity_test.dart` in `packages/zyren_game`; confirm the missing contracts fail.
- [ ] Implement immutable records and bounded registry validation. Begin with limits of 10,000 runtime entities, 64 components/entity and 4,096 queued commands, all configurable downward. Resolve compiled local references through an instance map before constructing entities. Reuse `ScenePlugin` services and scopes for scene attachment; game system phases only govern simulation work.

```dart
String instantiatedId(String instance, String local) => '$instance/$local';
bool acceptsTarget(GameEntityHandle target, GameEntityTable entities) =>
    entities.isAlive(target);
```

- [ ] Run the package tests, analyzer and boundary check. Unknown required components must preserve their JSON while preventing activation; they must never be silently removed on save.
- [ ] Inspect branch, status and staged diff; commit the package and exact shared registration changes as `feat(game): add versioned projects and entity contracts`.

### G2: fixed-step session and native driver

Files: create `packages/zyren_game/lib/src/runtime/{session,system,clock,events}.dart`,
`packages/zyren_game/lib/src/project/compiled_project.dart`,
`packages/zyren_game/test/session_test.dart`, `packages/zyren_game_native/pubspec.yaml`,
`packages/zyren_game_native/lib/zyren_game_native.dart`,
`packages/zyren_game_native/lib/src/{simulation,scene_plugin,physics_driver}.dart`,
`packages/zyren_game_native/test/driver_test.dart` and
`packages/zyren_game_native/test/support/native_game_fixture.dart`. Modify
`packages/zyren_physics/lib/src/plugin.dart` and `test/plugin_test.dart` minimally.

Interfaces: `CompiledGameProject` is a validated runtime recipe with project ID,
levels, fixed Hz, component/system registry versions, artifact hashes and capability
requirements. Its in-memory constructor is part of this task; G7 adds artifact
encoding and the Studio compiler. `GameSession({required CompiledGameProject project, required int seed,
int fixedHz = 60})`, `step()`, `advance(double seconds)`, `pause()`, `resume()`,
`Future<void> close()` and `tick`; `GameSystem` with ID, dependencies, phase and
lifecycle; `GameSimulation` with `step()` and `close()`.
Add `PhysicsPlugin.externallyDriven` and keep its current behavior as the default.
`GameScenePlugin` requests frames and renders state without owning a second clock.
The native test fixture exposes `renderOneFrame()` through the real scene engine,
plus its world/body handles and physics-step counter.

- [ ] Test phase order, pause, catch-up limits, events from every substep, removal during callbacks and close after partial attach. Add a native fixture that counts physical steps while rendering at 30/60/120 Hz.

```dart
final plugin = PhysicsPlugin(world: world, externallyDriven: true);
plugin.advance(world.fixedStep);
final before = world.body(ball.id).state.pose;
await fixture.renderOneFrame();
expect(world.body(ball.id).state.pose, before);
```

- [ ] Run `fvm dart test test/session_test.dart` in `zyren_game` and `fvm dart test --concurrency=1 test/driver_test.dart` in `zyren_game_native`; verify the new external-driver test fails before the physics change.
- [ ] Implement the phase order from the design and external ownership checks. Runtime clocks use integer ticks; call `PhysicsPlugin.advance(1.0 / fixedHz)` exactly once per tick and invoke character root motion through `beforeStep`. Training uses this same driver without a renderer.

`PhysicsPlugin.advance` already contains the physics accumulator. Retain it.
`CharacterMotor.advance` currently accepts `Duration`, while `beforeStep` supplies
seconds. Convert at that boundary and test the existing fixed-step tolerance;
never feed rounded microseconds back into the physics clock. If animation drift
needs a more precise API, extend `zyren_characters` in that task with its owner.

```dart
if (!externallyDriven) {
  advance(frame.delta.inMicroseconds / Duration.microsecondsPerSecond);
}
```

- [ ] Run game/native/physics tests sequentially, then analyze touched packages. At 120 rendered frames/sec with a 60 Hz game clock, assert 60 physics advances for one simulated second. Realtime overload must report dropped time.
- [ ] Commit the driver and clock as `feat(game): drive native simulation from one game clock` after inspecting all shared-file changes.

### G3: input, lifecycle and HUD bindings

Files: create `packages/zyren_game/lib/src/input/{action_map,intent,action_state}.dart`,
`packages/flutter_zyren_game/pubspec.yaml`, `lib/flutter_zyren_game.dart`,
`lib/src/{game_binding,input_adapter,gamepad_adapter,lifecycle,hud}.dart`,
`test/input_test.dart`, `test/lifecycle_test.dart` and platform gamepad bridge
sources under `macos/`, `ios/`, `android/`, `windows/`, `linux/` as required by
the selected audited controller backend. Record the exact backend before adding it.

Interfaces: `GameInputMap`, `GameActionState`, `GameIntent`,
`GameActionState.releaseAll(String deviceId)`, `GameSceneBinding`, `GameHud`,
`GamepadAdapter.events`; `GameLifecycleBinding` translates host focus/background state.
Input events carry device, action, value, timestamp and consumed status.
`GameActionState` maps accepted device input into semantic actions. The existing
`InputRouter.forSource` owns pointer arbitration, blocking and cancellation;
`SceneInteractionRouter` owns object capture and focus. Compose `SceneCanvas` or
`SceneView`, `SceneInteractionOverlay` and ordinary Flutter HUD widgets. Keep
renderer lifecycle and scene asset caching in their current packages.
For native audio focus, extract/reuse the Capture Lab's `LabAudioSession` and
platform interruption bridges with the audio owner. The game binding translates
that state into pause and input release without another focus policy.

- [ ] Test rebinding, dead zones, held-button release, pointer capture, touch cancellation, device disconnect and text-field focus. Add a fixture where a text field consumes WASD while play is visible.

```dart
actions.setAxis(deviceId: 'pad-1', action: 'throttle', value: 1);
actions.releaseAll('pad-1');
expect(actions.axis('throttle'), 0);
expect(actions.pressed('jump'), isFalse);
```

- [ ] Run `fvm flutter test test/input_test.dart test/lifecycle_test.dart --no-pub` in `flutter_zyren_game` after locked dependency resolution; confirm the new cases fail.
- [ ] Register the game input adapter with the existing router and focus scopes so modals/text and editor tools retain precedence. Use its `block`, `cancelAll` and registration disposal rather than a second pointer owner map. On pause/background, release semantic actions, invalidate queued decisions, suspend audio and stop frame demand. Resume from fresh input state. HUD listens to bounded immutable game state; scene-derived overlays reuse `SceneSelector` where applicable.

```dart
if (!hasGameFocus || lifecyclePaused) {
  actions.releaseAll(deviceId);
  return;
}
```

- [ ] Run widgets and native device smoke checks for controller connect/disconnect, touch and keyboard. Unavailable hardware remains an explicit qualification gap in Q3.
- [ ] Commit as `feat(game): add Flutter input lifecycle and HUD adapters` with platform evidence recorded separately.

### G4: character, cameras and interactions

Files: create `packages/zyren_game_native/lib/src/{character,character_intent,camera_rig,interaction_query}.dart`,
`test/character_test.dart`, `test/camera_test.dart`, and character fixtures under
`examples/game_lab/assets/`. Reuse the existing Character Lab's lawful asset
provenance and add its notices if copied.

Interfaces: `CharacterIntent(moveX, moveZ, lookYaw, lookPitch, jump, interact)`;
`GameCharacterController.apply(CharacterIntent intent)`;
`GameCameraRig` modes firstPerson/thirdPerson/vehicle;
`InteractionQuery.available(GameEntityHandle actor)` returns bounded candidates.
`GameCharacterController` adapts the existing `CharacterMotor`; it never animates
physics-owned transforms directly.
Reuse `CharacterAnimationPlugin`, root motion, IK, retargeting and the existing
kinematic controller. Camera adapters reuse orbit/fly/trackball controls where
appropriate, framing helpers and Timeline `CameraTrack`. New work is actor
following, chase constraints and collision handling. `CameraTransitionManager`
only supplies perspective/orthographic transitions; it is not a generic pose
blend. Object interaction uses the existing interaction router and physics queries.

- [ ] Test slopes, stairs, moving platforms, collision-blocked root motion, jumps, possession changes, camera obstruction and a target disappearing between selection and interaction.

```dart
expect(controller.grounded, isTrue);
controller.apply(const CharacterIntent(jump: true));
simulation.step();
expect(controller.grounded, isFalse);
expect(controller.lastIntent.jump, isTrue);
```

- [ ] Run the character fixture with native Rapier; a missing native asset is a setup failure, not a skipped passing case.
- [ ] Implement control intent > motor > physics pose > animation presentation. Convert movement through camera yaw, cap speeds from the component definition, resolve camera collision with physics queries and recheck interaction reach/line of sight when executing it.

```dart
final intent = possession.intentFor(actor);
character.apply(intent);
// CharacterMotor.advance is invoked by the shared physics beforeStep hook.
simulation.step();
```

- [ ] Verify the imported animation, IK and actual capsule path in the native game example. Run existing character tests and new camera tests, including narrow viewport input targets.
- [ ] Commit as `feat(game): integrate characters cameras and interactions`.

### G5: wheeled vehicles and possession

Files: create `packages/zyren_game_native/lib/src/vehicle/{definition,wheel,controller,telemetry}.dart`,
`packages/zyren_game/lib/src/gameplay/possession.dart`,
`packages/zyren_game_native/test/vehicle_test.dart`, and
`examples/game_lab/assets/vehicles/buggy.json` with a simple authored chassis.

Interfaces: `VehicleDefinition`, `WheelDefinition`,
`VehicleIntent(steer, throttle, brake, handbrake, gearRequest)`;
`VehicleController.apply`, `VehicleTelemetry`; `GamePossession.transfer` validates
seat occupancy, reach, exit clearance and current actor generation atomically.

- [ ] Test suspension rest height, braking distance, traction limits, reverse, airborne wheels, rollover/reset, driver deletion, blocked exits and two actors entering one seat. Fix units in the fixture to metres/kg/seconds/radians.

```dart
final extension = (restLength - contactDistance).clamp(0.0, travel);
final force = (springRate * extension - damping * compressionSpeed)
    .clamp(0.0, maxSuspensionForce);
expect(force.isFinite, isTrue);
```

- [ ] Run `fvm dart test --concurrency=1 test/vehicle_test.dart` in `zyren_game_native` before implementing the controller.
- [ ] Cast each suspension ray excluding the chassis, derive contact-relative longitudinal/lateral velocity, cap tire force by normal load/friction and apply impulses at contact points. Validate steering geometry and wheelbase. Update wheel visuals from solved state. Use authored braking on lost control.
- [ ] Run level-ground, slope, obstacle and split-friction fixtures at fixed 60 Hz, plus rendered 30/60/120 Hz presentations. Report the actual arcade/physical handling profile and numerical tolerances.
- [ ] Commit as `feat(game): add native wheeled vehicles and possession`.

### G6: reusable gameplay systems

Files: create `packages/zyren_game/lib/src/gameplay/{interaction,trigger,inventory,ability,objective,state_machine,behavior_tree}.dart`,
`test/gameplay_test.dart`, `test/behavior_graph_test.dart`,
`packages/zyren_game_native/lib/src/{audio_events,effect_events}.dart` and tests.

Interfaces: `GameActionRegistry`, `GamePredicateRegistry`, `GameRuleGraph`,
`Inventory.transfer`, `Ability.tryActivate`, `ObjectiveTracker`, `GameTrigger`;
`BehaviorStatus` = running/succeeded/failed; `BehaviorContext` provides only
declared services and bounded action/event queues. Registries validate typed ports,
graph references, step budgets and cancellable running actions.

- [ ] Test duplicate trigger credit, full inventory, interrupted abilities, cooldown restore, cyclic/oversized graphs and disposed audio/effects. A rule cannot read arbitrary engine state through an unregistered callback.

```dart
expect(inventory.transfer(item: 'key', count: 1, to: fullBag), isFalse);
expect(inventory.count('key'), 1);
expect(fullBag.count('key'), 0);
```

- [ ] Run focused game/native tests and confirm failed transfers leave both inventories unchanged.
- [ ] Implement validate-then-commit actions. Emit typed events once per command receipt; schedule cooldowns in ticks and cancel graph actions on entity removal. Bind audio and particle effects through their existing engines and scopes.

Gameplay rule graphs are separate from the existing character animation graph
and Timeline clips. Reuse those for animation and cutscenes. Route cosmetic
material/visibility variants and authored viewpoint presets through Configurator
when a game uses them; inventory quantities and ability effects remain game data.
Keep streaming, spatial attenuation, Doppler and playback suspension in Audio,
and fixed-step particle simulation in Particles.

```dart
if (!costs.available(actor) || tick < nextAllowedTick) return false;
costs.consume(actor);
nextAllowedTick = tick + cooldownTicks;
events.add(AbilityActivated(actor, abilityId, tick));
return true;
```

- [ ] Play the key/gate/objective loop and verify inventory/cooldown snapshots through their component codecs. Q1 adds the G5 vehicle and G7 disk save/restore workflow. Check sound events serve gameplay hearing even when speaker playback is muted.
- [ ] Commit as `feat(game): add reusable rules inventory and abilities`.

### G7: project compilation, level lifetime, saves and diagnostics

Files: extend `packages/zyren_game/lib/src/project/compiled_project.dart` from G2;
create `packages/zyren_game/lib/src/project/build_profile.dart`,
`lib/src/runtime/{level_manager,pool,save_game,replay,diagnostics}.dart`,
`lib/agents.dart`, `test/save_replay_test.dart`, `test/level_lifetime_test.dart`;
create `packages/zyren_game_studio/pubspec.yaml`, `lib/compiler.dart`,
`lib/src/compiler/{compile,export_manifest,game_document_codec}.dart`, `test/compiler_test.dart`.
S3 extends this package's manifest with editor dependencies and S7 supplies build
UI; keep these compiler libraries Dart-only. Consume S1's extension records without
depending on S3 widgets or commands.

Interfaces: `CompiledGameProject.decode/encode`, `GameDocumentCodec` implements
S1's Studio extension codec for G1 component records; `GameProjectCompiler.compile`,
`GameBuildResult`, `GameSave.decode/encode`, `GameSession.save/restore`,
`GameReplay`, `GameLevelManager.load`, `GamePool`, `GameAgentProvider`.
`GameBuildResult` has ready/failed/cancelled status, diagnostics and an optional
artifact only for ready. `GameSave` pins schemas, project/model/build identities.
The artifact is a typed game recipe inside an existing `PipelineBundle` resource.
Register compiler work through `PipelineBuildRecipe`/`PipelineBuildRuntime` and
reuse incremental transforms, hashes, file cache, limits and asset references.
The compiler expands Studio prefabs and remaps component references through S1's
codec. Authored saves use `PipelineStudioStore`; runtime saves remain game state.
Inject an asset resolver into the game runtime so it need not import the editor
or Pipeline. Native ML session caching is distinct from Pipeline's byte cache.

- [ ] Test interrupted level loads, asset hash mismatch, partial native initialization, save migration, missing items/models, restore after pooling and 50 load/unload cycles. Compare play/training accepted action logs using the same build and seed.

```dart
final before = session.save().encode();
expect(() => session.restore(incompatibleSave), throwsStateError);
expect(session.save().encode(), before);
```

- [ ] Run game, compiler and native lifetime tests sequentially. Capture baseline resource counts before the repeated unload fixture.
- [ ] Compile existing expanded Studio nodes, resolved asset references and component data into the game recipe. Package it through Pipeline and validate capabilities before activation; atomically swap prepared levels. Save runtime state by staging and rename. Reset pooled components, beliefs, input and physics handles; increment entity generations. Publish game counters through existing Devtools diagnostics/history and attach `GameAgentProvider` through shared scoped registration and transport.

```dart
final candidate = await levelManager.prepare(reference);
candidate.validateCapabilities(capabilities);
await levelManager.activate(candidate);
```

- [ ] Verify disk restart, failed-save recovery, offline runtime load and a live MCP inspect/pause/step flow. Inspectors must distinguish paused, failed, missing and running states.
- [ ] Commit as `feat(game): compile projects and preserve runtime state` with native/platform blockers recorded in package qualification files.

## Shared changes and checks

The physics external-driver switch is the only required shared physics behavior
change identified by this audit. Root package registration and boundary allowlists
must preserve other workstreams. S1 owns Studio schema changes. S2 owns editor host
extraction. A6 owns renderer sensor changes; this plan must not preempt them.

After each task, run its focused tests and `fvm dart analyze` on the affected Dart
packages, or `fvm flutter analyze` for Flutter packages. Run
`fvm dart run tool/check_package_boundaries.dart` from the root after registration
or dependency changes. Native package tests run from their own directories with
`--concurrency=1`, using the workspace FVM SDK. Do not race native hook builds.
