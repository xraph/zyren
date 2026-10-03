# Zyren Game

You can save versioned game projects and prepare flat spawn recipes with this
Dart package. Register your component codecs first, then decode a project and
check whether its required components can activate.

```dart
import 'package:zyren_game/zyren_game.dart';

final registry = GameRegistry();
// Register your GameComponentCodec implementations here.
final project = GameProject.decode(source, registry);
project.requireActivation();
final saved = project.encode();
```

`GameProject` schema 1 stores project identity, startup level, scene pins, entity
components, input maps, component schemas, behavior/model references, build
profiles and capability requirements. Decoding validates the project without
calling component factories. You can save an unknown required component, with
its version and nested JSON intact, while `canActivate` remains false and
`activationProblems` tells you which components are missing or too new.
Unknown optional components stay in the saved project too.

Each `GameComponentCodec<T>` declares a stable `type` and current `version`.
Implement `validate(data)`, `migrate(fromVersion, data)`,
`localReferences(data)` and `factory(data)`. Migration converts an older record
directly to the current version. Keep validation, migration and reference
inspection free of side effects. A project captures a frozen registration
snapshot, so registering another codec won't change that project's activation
result. Reopen it with the new registry when you want to apply those codecs.

## Spawn compiled recipes

Studio owns prefab authoring and expansion. You give `GameSpawnTemplate` a flat
list of entities whose component references name other local entity IDs.
`GameLocalReference` records the JSON path to each reference, using string keys
and integer list indices. The template validates those paths and rejects dangling
references before you can instantiate it.

```dart
final recipe = GameSpawnTemplate(
  id: 'guard',
  entities: compiledEntities,
  registry: registry,
);
final spawned = recipe.instantiate('guard-1');
for (final entity in spawned) {
  final components = recipe.construct(entity);
  // Attach these components through your existing ScenePlugin host.
}
```

Instantiation maps each local ID to `instanceId/localId` and rewrites only the
fields your codecs declare as references. It leaves the compiled recipe intact.
Choose a unique instance ID for each live instance. Factories run when you call
`construct`, which accepts only entities produced by this template's
`instantiate` call. Authored node bindings retain their separate `nodeId`.
Your scene adapter resolves those bindings through the existing scene graph.

Use `ScenePlugin`, `PluginContext` services and the attachment scope when you
attach runtime components to a scene. The package contains data and runtime
identity contracts; simulation phases and native scene adapters belong to the
session and adapter packages.

## Entity lifetime and commands

```dart
final entities = GameEntityTable();
final old = entities.spawn('guard');
entities.despawn(old);
final current = entities.spawn('guard');
assert(current.generation == old.generation + 1);
assert(!entities.isAlive(old));

final commands = GameCommandQueue<String>();
commands.enqueue(GameCommand(current, 1, 'move-forward'), entities);
final due = commands.drain(1, entities);
```

Handles belong to their entity table. Keep a queue with the same table for its
lifetime. The queue checks generations both when you enqueue a command and when
you drain its application tick. It preserves admission order within a tick and
discards missed ticks. Drain ticks must increase, and command payloads should be
immutable values defined by your host.

Generation history retains at most `maxEntities` IDs. A retained ID respawns at
its previous generation plus one. If history evicts a retired ID, its next spawn
uses a generation above every generation previously issued by that table, so
old handles remain stale without keeping an unbounded set of tombstones.

## Limits and checks

`GameLimits` defaults to 10,000 entities, 64 components per entity and 4,096
queued commands. You can reduce each limit. The registry permits at most 1,024
component types and projects permit at most 256 levels. A project's total
entity count uses the same entity limit.

Component and metadata JSON is copied and frozen recursively, with limits of
32 nesting levels, 4,096 values/keys per JSON object graph and 65,536 UTF-8 bytes
per string. Cycles, non-JSON objects and non-finite numbers fail validation.
Project sources and encoded output are limited to 16 MiB.

Run these from the package directory with the workspace's FVM SDK:

```sh
fvm dart test test/project_test.dart test/entity_test.dart
fvm dart analyze .
```

The root boundary check also covers this package:

```sh
fvm dart run tool/check_package_boundaries.dart
```

These checks cover Dart contracts. Studio compilation, scene attachment,
fixed-step sessions and native device qualification have separate integration
work and tests.

## Run a session

Compile a validated `GameProject` into `CompiledGameProject`, then create a
`GameSession` with a seed and your registered systems. `step()` advances one tick.
`advance(seconds)` admits realtime elapsed time with a bounded catch-up budget.
Read `droppedSeconds` when the host cannot keep up. The compiled recipe pins the
fixed rate, component versions, required system versions and artifact hashes.

Systems run in commands, decisions, controllers, physics, rules, sensors and
diagnostics order. Dependencies must exist and cannot point to a later phase.
Startup failures still receive reverse-order disposal when you call `close()`.
Removing a system stops its callbacks immediately; its resources remain owned
until session close. A system with active dependents cannot be removed.

Queue structural changes through `enqueueMutation`. Changes enqueued from a
mutation run on the next tick. Pause and resume clear pending commands and
increment the session epoch so asynchronous consumers can reject old results.
Drain the bounded event journal after each host frame or training step. Every
catch-up tick keeps its events, including events raised by another listener.

Use `zyren_game_native` when the session needs Rapier. Its driver reuses the
existing physics accumulator and root-motion hook. Pure project tools and game
rules do not need a renderer or native library.
