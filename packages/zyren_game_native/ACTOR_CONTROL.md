# Native actor control

A host decision system can acquire one `GameRuntimeActorControl` for a live NPC. Acquisition returns null for the human input actor, the occupied human target, inactive entities, a paused session, or an actor already held by another external producer.

```dart
final control = runtime.acquireActorControl(actor);
control?.applyCharacter(const CharacterIntent(moveZ: 1));
// A vehicle uses control.applyVehicle(VehicleIntent(...)).
```

Check `isActive` before applying an asynchronous result. The lease exposes its actor, session epoch and monotonically increasing control generation. Pause, restore, despawn, deactivation and human takeover revoke authority. Dispose the lease when your producer retires; vehicle disposal applies the authored lost-control brake.

Primitive motion runs during the controllers phase after decisions. Imported CharacterMotor and vehicle controllers keep their existing hooks before the single physics step. The command phase captures human actions, so NPC decisions can affect the same tick without advancing physics twice.

Character intents control movement and jump. Route interaction commands through your authored gameplay binding and the shared interaction query. `resolveCollider` and `actorGrounded` expose current native identity/state for sensor adapters and return null for stale handles or actors without the requested controller state.

Leases aren't checkpoint state. `listenRestored` lets your host rebuild producer identities and reacquire control against the restored handles before its next decision.
