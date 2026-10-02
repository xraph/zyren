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

The package-local example loads a self-contained glTF robot with animated rigid
limbs, queries an L-shaped floor and submits targets to a native Rapier capsule.
It advances physics once per 20 ms tick before sampling animation. The floor is
empty, so this example does not implement character collision or obstacle avoidance.

```sh
cd packages/zyren_characters
# Use the workspace Flutter SDK's dart so native hooks resolve correctly.
dart test --concurrency=1
dart run example/walkthrough.dart /tmp/zyren-character-walkthrough.ppm
```

The executable uses the native renderer and writes a PPM readback after arrival.
The integration test uses real native Rapier with a test renderer; it establishes
physics and animation behavior, not GPU presentation. Root motion, character
collision, IK, retargeting and skinned-character device qualification remain in
`plans/zyren-plugins/characters-navigation.md`.

## Runtime agent tools

Import `package:zyren_characters/agents.dart` to register a
`CharacterAgentProvider` with your shared `AgentRegistry` and attachment scope.
The provider exposes paginated state/clip inspection and transition, pause and
resume commands. `describeObject` supplies character context for shared viewport
hits. It returns host-bound source identity separately from runtime object IDs.

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
