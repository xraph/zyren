# Native level checkpoints

Use `GameLevelRuntime.save()` and `GameLevelRuntime.restore(save)` at a completed tick boundary while the scene engine is attached. Studio exposes the same methods on `GamePlaySession`. You can persist the returned `GameSave` with its existing encode/decode format.

```dart
final checkpoint = runtime.save();
final source = checkpoint.encode();
// Later, with the same compiled project and native level initialized:
runtime.restore(GameSave.decode(source));
```

The required `game.native-level` codec preserves body poses, linear and angular velocities, sleep state, runtime activation and visibility, primitive gravity/jump state, vehicle gear and wheel handling state, and imported CharacterMotor gravity state. Character action clocks retain signed traversal, playing state, weights and the remaining fade. Restore doesn't reset imported animation to idle.

The existing Rapier world stays alive. Body and collider handles remain valid, while entity generations change. Input, possession, cameras and controller registrations rebind to the new generations, and held input is released. A paused checkpoint remains paused; resuming reacquires the saved controlled actor. Vehicles retain wheel rotation and suspension telemetry, but native contact-body IDs are transient and are resolved again by the next query.

Register `runtime.listenRestored(callback)` for host adapters whose queries contain entity handles. It runs after core epoch observers and native controller rebinding. Dispose its registration with the host adapter. A failed host rebind faults and pauses the session, which remains closable.

These checkpoints use a fixed authored entity topology and unchanged native component definitions. Spawn/despawn or collider/controller definition changes are rejected on save and restore. Gameplay inventory, abilities and rule state continue through their own required codecs. Calling `runtime.simulation!.session.restore` directly is rejected because it would skip native generation rebinding.

All replacements are validated before native mutation. If a later state codec rejects its commit, core restores the original entity table and the native codec restores its previous poses and flags. This is a gameplay checkpoint, not a serialization of Rapier solver contact caches or arbitrary host plugin state. Training workers can retain their own qualified full-world snapshot contract.

Dispose the host scene engine first, then close the runtime. Checkpoints don't transfer ownership of the engine, world, assets or resource leases.
