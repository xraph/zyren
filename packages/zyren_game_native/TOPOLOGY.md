# Prepared native spawn recipes

Prepare a `GameSpawnTemplate` once, then activate and retire its pool slot. You supply fresh scene objects and resource leases; the runtime uses the existing collider, primitive character, CharacterMotor and vehicle factories. Studio still owns authored prefab expansion.

```dart
final slot = await runtime.prepareSpawn(
  recipe,
  instanceId: 'guard-1',
  prepare: (records) async => GameRuntimeSpawnResources(
    objects: await buildFreshObjects(records),
    resources: [assetLease],
  ),
);
final spawned = runtime.enqueueSpawn(slot);
// The next game command phase commits the whole instance.
await spawned;
```

Use the remapped node IDs passed to your factory. Each recipe has 1..32 entities with distinct scene nodes; input and camera components belong to the startup level. Prepared slots default to 64, with a configurable limit of 1..256. Each preparation accepts at most 128 objects and 64 fresh leases. Pending preparations count against the pool limit.

`enqueueSpawn` and `enqueueDespawn` run at the next commands phase. Their futures return false when pause, restore or close cancels the queued epoch. You can use `activateSpawn` and `retireSpawn` directly while paused. Activation creates new entity generations and registers current controllers and possession seats. Retirement revokes producer leases, removes controllers and wheel visuals, hides the objects, and excludes their colliders from queries. The Rapier bodies remain owned by the slot. Kinematic bodies stay awake because sleeping them prevents movement after reuse.

Call `releaseSpawn` while paused, after retirement, to remove the native bodies and close the transferred resources. Imported rigs need `attachPlugins` on `GameRuntimeSpawnResources`: attach the supplied plugins to the existing engine and return a fresh lease that releases that attachment. Close callbacks must tolerate an engine that has already been disposed. During whole-runtime shutdown, dispose the engine first; the runtime drains preparation, closes its physics world, and closes adopted resources in reverse order. A preparation cancelled before adoption leaves unadopted resources with your factory.

Register `listenTopology` to reconcile added and removed entity handles. Its immutable change lists identify the committed generations. `registerSpawnValidator` lets a host reject unavailable actor contracts before preparation allocates resources and again before activation mutates the entity table. Validators read the recipe and must not mutate the session. A failed committed host callback faults and pauses play; the runtime remains closable.

`entityDefinition(id)` returns the immutable authored or prepared recipe, including inactive pool records. Released records and closed runtimes return null. Checkpoints contain active logical instances and their native state, rather than every retained pool body. A fresh host must prepare compatible recipes before restore. See [CHECKPOINTS.md](CHECKPOINTS.md).

The native API doesn't construct editor documents, resolve assets, or reconcile AI state for you. Your host provides asset/plugin preparation and topology observers. Authored gameplay and AI codecs must admit saved dynamic actor identities against the prepared definitions before they commit their own state.

`GameLevelGameplay` reconciles interaction queries and authored actors after committed topology changes. Surviving inventory, ability owners, running rule actions and FSM state remain attached to the same entity generation. Retired actors lose pending interaction receipts and behavior owners; a reused slot starts with fresh authored defaults. Interaction IDs are global among live entities, with one profile per collider target. The adapter checks these constraints before your preparation allocates assets and again at activation. Two dormant slots may share an interaction ID, but cannot both activate with it.

The pure `GameAuthoredGameplay` adapter exposes `reconcile()` for hosts that change entity topology directly. Supply its `entityDefinition` lookup when prepared recipes are absent from the startup level. This lookup is also used to validate dormant recipe checkpoints. Authored state codec version 2 records the exact active actor set and rejects changed gameplay definitions; version 1 checkpoints require a compatible older host rather than an implicit migration.
