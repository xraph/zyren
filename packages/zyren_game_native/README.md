# Zyren Game Native

Run game sessions through the existing Rapier world and PhysicsPlugin. The game
session owns the fixed clock. PhysicsPlugin must use `externallyDriven: true`.
A world belongs to one GameSimulation until that simulation closes.
Native sessions support 10 through 240 Hz, within Rapier's existing fixed-step
range. Pure GameSession clocks still support 1 through 240 Hz. A supplied
PhysicsPlugin must admit at least one full game step through `maxFrameDelta`.

```dart
final simulation = GameSimulation(project: compiledProject, seed: 7);
simulation.step(); // Headless training and replay use this same method.
await simulation.close();
```

For visible play, attach `simulation.physics` and `GameScenePlugin(simulation)`
to your SceneEngine. The scene adapter admits elapsed time to GameSession. It
never calls PhysicsWorld.step directly. Set `realtime: false` when the host
already advances the simulation, such as a training or replay viewer.

The default simulation creates and owns its world. A supplied PhysicsPlugin
keeps its caller-owned world unless you pass `ownsWorld: true`. Detach the scene
engine before closing the simulation. Close waits for system disposal, clears
render bindings and releases an owned world even if a system fails cleanup.

A supplied plugin can use `beforeStep` for CharacterMotor. Convert seconds to a
Duration only at that animation boundary. Keep the unrounded `1.0 / fixedHz`
value for the physics driver. CharacterMotor already checks its fixed-step
boundary tolerance. Game character adapters build on that hook.

The native fixture verifies 60 physical steps at 30, 60 and 120 rendered frames
per second. It uses real Rapier and a deterministic test renderer. These checks
establish simulation timing, not GPU or device performance qualification.

## Gameplay sound and effects

Emit `GameSoundEvent` through `GameSoundPublisher(session)`. Its tick must match
the running session. The publisher bounds and deduplicates receipts for that tick.
Sound positions use world metres; loudness is in 0..1. Hearing reads the gameplay
event journal even when speaker playback is muted or unavailable.

Import `package:zyren_game_native/audio.dart` when you want speaker playback.
`GameAudioEvents` binds event categories to existing `AudioEmitter` instances.
It borrows your `SpatialAudio` engine, retains its spatial attenuation and native
focus policy, and uses an `AttachmentScope` for its listener lifetime. Supply an
error handler so a removed emitter remains a visible playback failure.

Import `package:zyren_game_native/effects.dart` for `GameEffectEvents`. Bind event
names to your existing `ParticleController` emitters. The adapter deduplicates
burst receipts and bounds pending delivery; Particles still owns fixed-step
simulation and GPU resources. Closing the scope drains queued work and clears
those bound effects without closing the borrowed controller.

The audio fixture ran the real native offline mixer and verified that muting or
closing playback leaves hearing events intact. The effects fixture ran an actual
`NativeBackend` particle burst and verified disposal. These macOS checks establish
the integration paths, not mobile support or a sustained device frame budget.

## Authored levels and imported characters

Import `runtime.dart` for `GameLevelRuntime` and `scene.dart` for
`GameRuntimeScene`. The scene loader reconstructs compiled nodes and asks your
asset loader for each pinned model. Give the runtime those objects and its asset
leases, then attach `runtime.plugins` to your existing engine. Close the engine
before the runtime. Studio play and exported games use this same bootstrap.

For an imported character, add `game.character`, `game.collider` and
`game.character-rig`. The rig names a top-level glTF root node, one moving clip,
an optional idle clip and the model's visual offset from its body. Import
`animation.dart` and pass `createGameCharacterAnimation` as `animationFactory`.
A primitive actor keeps its primitive controller. An imported actor needs an
explicit valid rig mapping before play can start.

Each imported actor gets its own named timeline and character state. Root motion
is stripped from every visual clip and sent through the existing CharacterMotor
and Rapier controller once per game step. A bad clip name reports the available
clips so you can repair the component and retry. Two imported actors, independent
animation clocks, failed rig loading and retry are covered by native tests.
