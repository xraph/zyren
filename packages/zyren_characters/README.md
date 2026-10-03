# zyren_characters

Give imported animation clips names and explicit transitions. You keep the
existing glTF loader and timeline mixer. This package owns timeline actions and
pauses looping actions when their fade reaches zero.

```dart
final timeline = SceneTimelinePlugin.mixed(
  duration: const Duration(seconds: 1),
  base: modelRestClip(instance),
);
final character = CharacterAnimationPlugin(
  timeline: timeline,
  states: [
    CharacterState.rest('idle', instance),
    CharacterState.animation('walk', instance, instance.animations.first),
  ],
  transitions: [
    CharacterTransition('idle', 'walk'),
    CharacterTransition('walk', 'idle'),
  ],
  initialState: 'idle',
);
// Register both in SceneEngine.plugins, then request a state:
character.transitionTo('walk');
```

Import `zyren`, `zyren_gltf_timeline`, `zyren_timeline` and `zyren_characters` for
this example. Use `instance.animations` to bind clips to the imported instance.
Transitions have positive durations and follow the directed edges you provide.
A repeated state request does nothing. An interrupted transition fades all other
contributors from their current weights, and the destination resumes its clock.

`pause()` freezes clip clocks and settles fades at their current weights.
`resume(fadeDuration: ...)` resumes the selected state and finishes its blend over
that duration. The default is 200 ms. Detach releases the character's actions;
the timeline retains ownership of its own resources and clock.

For physics, bind a unit-scale outer group to a body, then place the imported
model below it. The model's joints animate in local space. Don't bind the model
or its animated joints to physics too.

## Root motion and collision

Create `RootMotion(model, root: sourceNodeId)` for a top-level imported root. Pass
its stable `process` closure to the timeline base and every state clip. For an IK
chain, use one shared processor that calls `rootMotion.strip(pose)` first, then
your solvers. Tracks blend before this processor runs, and skinning runs once
afterward. A processor must not write scene objects while preparing a pose.

Set `timeline.externallyDriven = true` before attachment. Import
`package:zyren_characters/physics.dart`, create a `CharacterMotor`, and call
`motor.advance(step)` from `PhysicsPlugin.beforeStep`. The motor extracts signed
travel from the existing action clocks, including loop crossings and reverse
playback. Seeks do not create movement. Crossfades average endpoint weights over
each fixed step. Root turning unwraps authored yaw keys; cubic curves use 32
subsamples per key interval, so pathological cubic spins need denser authored keys.

The native controller resolves an upright capsule against the real Rapier world.
It supports sliding, slope limits, step height, ground snap and moving platforms.
Collision groups and sensors retain their physics meaning. `jump` requires a
grounded character. Bind only the outer group to physics, keep its scale at one,
and leave rotation to upright yaw. The world remains owned by your host.

## Rig solving

`CharacterRig` maps your names to imported node IDs and captures their bind pose.
Joint ancestry must retain positive uniform scales. `TwoBoneIk` solves a direct
upper/lower/end chain analytically with a pole and bend limits. It returns reach
error and a limit flag. `LookAtIk` clamps swing while preserving existing roll.
Both return immutable poses and accept blend weights. Ground targets belong in
model coordinates; the example transforms real physics ray contacts into them.

`RigRetargeter` requires an explicit source-to-target node map, top-level roots,
metres-per-unit values and optional joint-axis corrections. It transfers rotations
relative to the bind frames and preserves the target's authored bone lengths.
Root translation uses the unit ratio. Apply IK after retargeting when you need
contact placement on a rig with different proportions. Morph expressions are not
part of the rig mapping.

## Native example and checks

`example/app` contains Character Lab for macOS, Android and iOS. It loads an
actual glTF skin, follows generated navigation with root motion, replans around
a collision obstacle, applies foot IK and retargets onto longer legs. Controls
cover pause/resume, obstacles, IK and retargeting. The earlier rigid-limb
`example/walkthrough.dart` remains a small authored-route example.

Run tests from this package with Flutter 3.47.5's Dart. Native hook manifests are
shared by the workspace, so run package test commands sequentially. The MCP test
compiles its host against a private snapshot of this run's native asset manifest,
then uses bounded RPC waits without starting a second native build.

```sh
dart test --concurrency=1
cd example/app
flutter run -d macos
flutter test integration_test/character_test.dart -d macos --no-pub
```

See [QUALIFICATION.md](QUALIFICATION.md) for actual device results and remaining
hardware gates. A substituted renderer test establishes CPU behavior only.

## Runtime agent tools

Import `package:zyren_characters/agents.dart` to register a
`CharacterAgentProvider` with your shared `AgentRegistry` and attachment scope.
The provider exposes paginated state/clip inspection and transition, pause and
resume commands. `describeObject` supplies character context for shared viewport
hits. It returns host-bound source identity separately from runtime object IDs.

`locomotion_agents.dart` adds root/controller/rig inspection and host-gated goals,
look-at, foot targets, retarget control and grounded jumps. Commands require
`characters.locomotion`. Only operations with supplied host callbacks are exposed.
The generated-navigation provider lives in `zyren_navigation/world_agents.dart`.

The optional adapters use the same contract:

| Entry point | Provider | Tools |
| --- | --- | --- |
| `zyren_navigation/agents.dart` | `NavigationAgentProvider` | Bounded flat-mesh path query |
| `zyren_timeline/agents.dart` | `TimelineAgentProvider` | Main clock inspection, play, pause, seek |
| `zyren_gltf_timeline/agents.dart` | `ModelAnimationAgentProvider` | Imported node/clip pages and source-node hit enrichment |
| `zyren_physics/agents.dart` | `PhysicsAgentProvider` | Exposed body inspection and kinematic position targets |
| `zyren_particles/agents.dart` | `ParticleAgentProvider` | Cached emitter measurements, pause and resume |

You supply `readRevision`, `isAvailable` and a command gateway for mutation.
The gateway applies the ordinary plugin operation, records your application's
command history and increments its revision. Update that revision for host edits
and simulation/animation ticks too, and serialize asynchronous particle commands
with those updates. Undo belongs to the host; the small walkthrough example has
no undo history. The registry checks scopes, expected revisions and retry keys.

Call `provider.register(registry, context.scope)` during attachment. Closing the
scope removes discovery and cancels pending registry calls. Keep a separate
registration lifetime for a replaced immutable navigation mesh. A disconnected
route, removed target, missing gateway and denied scope produce distinct results.

`example/walkthrough_agents.dart` registers all five domain providers used by the
robot plus the shared viewport provider. The example names its scene, document
and viewport, and combines imported node provenance with character actions.
Offscreen rendering does not establish a presented display frame, so presentation
correlation stays unknown. CPU triangle hits do not establish alpha coverage,
shader displacement or exact rendered visibility.

The MCP qualification test launches a real stdio subprocess through the existing
`zyren_devtools` transport. It uses native Rapier and a substituted renderer.
The particle GPU test requires `RUN_NATIVE_GPU=1`; a skipped test is not device
qualification.
