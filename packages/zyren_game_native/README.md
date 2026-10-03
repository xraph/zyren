# Zyren Game Native

Run game sessions through the existing Rapier world and PhysicsPlugin. The game
session owns the fixed clock. PhysicsPlugin must use `externallyDriven: true`.
A world belongs to one GameSimulation until that simulation closes.

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
