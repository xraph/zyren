# Host a compiled native level

You can use the same native runtime from Studio play, GameLab or a headless host. It borrows your scene and owns native bodies, game systems and adopted resource leases. Your renderer remains the existing native backend.

Load the compiled recipe from the Pipeline bundle, then call `GameRuntimeScene.load(project, loadAsset: loader)` from `scene.dart`. The injected loader resolves pinned assets and returns their actual scene objects with close callbacks. It must honor cancellation. The loader validates parent links, required assets and reference pins before constructing the level.

```dart
final data = await GameRuntimeScene.load(project, loadAsset: loadPinnedAsset);
final runtime = GameLevelRuntime(
  project: project,
  scene: data.scene,
  camera: data.camera,
  objects: data.objects,
  animationFactory: createGameCharacterAnimation,
  resources: [GameRuntimeResourceLease(close: data.close)],
);
await runtime.initialize();
// Attach runtime.plugins to your existing native SceneEngine or controller.
```

Import `runtime.dart`, `scene.dart` and `animation.dart` for these types. Inject your authored gameplay or AI systems through `systemFactory`. Assets transfer to the runtime once initialization adopts their leases. An initialization failure closes adopted leases; the host retains anything not adopted. Close the scene engine first, then await `runtime.close()`. Resource close runs in reverse order after native simulation ownership drains.

## One clock and current authority

GameSession owns the integer tick. Visible rendering admits elapsed time through the game scene plugin; training and replay call the same simulation step directly. Native fixed rates are 10..240 Hz. Physics must be externally driven and its frame-delta clamp must admit a full step. Do not add a second PhysicsWorld.step or animation update loop.

Imported characters use the existing CharacterMotor, root motion and timeline. Every rig has independent timeline/action state. Primitive characters use the existing kinematic capsule controller. Vehicles use the same physics world and their motor registry runs before that world's single physical step.

Human control and NPC control are exclusive. `acquireActorControl(handle)` refuses a human-controlled target and returns a generation/epoch-bound lease for character or vehicle intent. Pause, restore, retirement and takeover invalidate it. Acquire a fresh lease before applying new input. `actorGrounded`, `resolveBody`, `resolveCollider` and `isEntityActive` expose current live state without giving an AI policy permission to observe every object.

For performance instrumentation, pass `onStepMeasured(tick, elapsed)`. It includes mutations, native controllers/physics and synchronous state observers, then delivers under the non-reentrant step guard. Use `onSystemMeasured(id, tick, elapsed)` for per-system attribution alongside the full-step gate. There is no stopwatch when the corresponding callback is absent. A throwing callback fails the session closed.

## Save, pool and recover

Use [CHECKPOINTS.md](CHECKPOINTS.md) for native state fidelity and [TOPOLOGY.md](TOPOLOGY.md) for prepared spawns. Saves preserve body motion, active flags, primitive gravity, vehicle handling and imported animation state. Sleeping motion must be zero; malformed checkpoints reject before mutation. PhysicsBody.restoreMotion restores position-driven kinematic derived velocities without replacing body/collider handles or changing the next target's control mode.

Prepare a bounded flat recipe and its assets before queueing activation. Running spawns commit at the next commands phase. Retirement revokes controller/query ownership; retained bodies remain with the pool until release. `GameLevelGameplay` and the AI bridge reconcile fresh entity generations while preserving unaffected actors' state. Global interaction IDs are checked before asset allocation and again before activation.

A native surface can be revoked while a producer owns GPU work. Stop submissions, await the old engine, then close the runtime. Construct a new backend/surface and a compatible level, restore the checkpoint, and resume explicitly. The Metal regression verifies exact logical checkpoint preservation and native owner cleanup through that sequence. Physical GPU/device loss is not an available test injection.

```sh
# From packages/zyren_physics:
fvm dart test --concurrency=1 test/restore_motion_test.dart test/world_test.dart
# From packages/zyren_game_native:
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1 \
  test/save_admission_test.dart test/renderer_failure_receipt_test.dart test/save_test.dart
```

The physics command passed 6 tests. The native checkpoint/renderer command passed 7. Hardware-required tests use the native-gpu tag; excluding them cannot qualify a GPU target. Full device and sustained performance status is recorded in the [release audit](../../plans/zyren-plugins/game-ai/release-audit.md).
