# Build and export your first game

Start with the repository examples. Studio authors the scene; GameLab opens the exported Pipeline bundle without Studio, Python or a network loader.

From `examples/studio`, resolve the workspace with `fvm flutter pub get` and run `fvm flutter run -d macos`. Open Level tools and create Exploration or Vehicle playground. The replacement is one undoable command. Select an actor, open its game components and change a field. Save, reload and check that the value survives before entering Play.

Play owns a separate native scene. Pause before inspecting a checkpoint, Step advances one fixed tick, and Stop releases the play owner so you can launch again. Runtime movement never edits authored transforms automatically. Apply-back compares the authored revision and asks you to review proposed changes; concurrent authoring must be resolved before applying them.

The primitive templates work without imported animation. For a glTF character, import the asset through the existing Studio asset workflow and add a valid character rig mapping. The moving clip, optional idle clip and root-motion node must exist in that model. Correct the component and retry when the inspector reports missing clips. Imported assets retain their Pipeline identity and byte pins.

## Components and prefabs

Register the shared component codecs before decoding a game project. `GameProject` retains unknown component payloads, but an unavailable required codec blocks activation. Your codec must validate, migrate and identify local entity references without performing runtime work.

Use the existing Studio prefab command for reusable authored actors. Game components stay in prefab extensions; instances retain separate overrides. A duplicated prefab remaps only declared local entity references. The inspector shows inherited values and overrides, including malformed saved values that need repair. An invalid base definition needs the explicit prefab-definition repair command; changing one instance cannot repair its base.

Runtime `GameSpawnTemplate` accepts an expanded flat recipe. It is not a second authoring format. Node IDs bind those entities to objects supplied by the host. See the native [pool guide](../zyren_game_native/TOPOLOGY.md) for preparation, bounded activation and retirement.

## Input and visible state

Create semantic actions such as `move.x`, `move.z`, `jump` and `interact` in `GameInputMap`. Bind native controls to those names. Dead zones, device count and event timestamps are validated before application. Keep actions attached to the current entity generation.

Use [GameSceneBinding](../flutter_zyren_game/README.md) with your existing SceneController, GameSession and GameActionState. It composes SceneView and the shared interaction overlay. Its touch controls and HUD use the same action state as keyboard and controller input. Text fields, editor capture and modal scopes retain input ownership. A release, background transition or possession change clears held input; a new gesture or key press is required afterward.

A rendered widget fixture proves focus and lifecycle behavior. Physical controller, touch and screen-reader checks remain separate qualification gates.

## Vehicles, rules and checkpoints

The vehicle template includes physical chassis and paired wheel definitions. Edit wheel radius, suspension, mounting points and steering/driven flags through the component inspector. Duplicate mount points reject. Input maps to steering and signed movement while possessed; returning to the character validates a capsule-sized exit and places the character there. The current vehicle controller is an arcade profile with raycast suspension, traction and braking, not a high-fidelity tire simulator.

Level tools author objectives, inventory, abilities, interactions, rule graphs and state machines. Registered predicates and actions must exist in the shared rule library before compiling. Cycles, missing operations and invalid links reject before history changes. Native gameplay revalidates interaction reach and live targets before execution. Historical NPC memory is not fresh visibility.

Use native [checkpoints](../zyren_game_native/CHECKPOINTS.md) for visible games. A pure GameSave alone does not capture arbitrary host plugin state or Rapier solver caches. Restoring regenerates entity handles, releases held input and rebinds native controllers and queries. Prepare compatible pooled recipes before restoring them into a new host.

## Export and offline loading

Open the game export panel after saving. Resolve reported assets through the existing import flow, then Export to a host-selected path. Build jobs retain document revision, compiler identity and asset pins; stale or unauthorized jobs cannot publish. Retry allocates a new UI request, while exact external retry keys remain idempotent. Connected collaboration blocks unsupported component edits explicitly rather than pretending to synchronize them.

GameLab reads `examples/game_lab/games/*.zygame`. From that directory, run `fvm flutter run -d macos`. The committed exploration and vehicle bundles include accepted structured guard/driver policies. Save drains pending inference; Restore remains paused until you resume. See the [GameLab guide](../../examples/game_lab/README.md) and [accepted model provenance](../../examples/game_lab/models/README.md).

To regenerate repository reference documents and bundles, use the tested exporter from the repository root:

```sh
fvm dart --packages=.dart_tool/package_config.json \
  packages/zyren_game_studio/tool/export_game_lab.dart \
  examples/game_lab examples/game_lab/models
```

This command replaces generated reference files. Keep your edited documents separately. Imported model directories must contain their pinned manifest, schemas, normalization, recurrent contract and accepted evaluation before activation.

## Checks and remaining qualification

The following commands exercised the actual failure and checkpoint paths on the development Mac:

```sh
cd packages/zyren_game_native
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1 \
  test/renderer_failure_receipt_test.dart test/save_test.dart \
  test/gameplay_topology_test.dart test/topology_test.dart
```

Eighteen tests passed. Run native packages sequentially because process-wide allocation counters are shared. This fixture covers real Metal surface loss and recreation, not physical GPU removal or every host platform. The [release ledger](../../plans/zyren-plugins/game-ai/completion.json) keeps incomplete device, visual learning, sustained capacity, accessibility and publication checks visible.

For training, sensors, memory and model import, use [AI tools](../zyren_game_studio/doc/ai-training.md), [game AI](../zyren_game_ai/README.md) and [the training operator guide](../../tool/zyren_train/README.md). Python belongs to the training toolchain and never to the exported Flutter runtime.
