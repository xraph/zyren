# Studio game development implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give you a complete game authoring workflow inside the existing Studio
editor, including game components, play sessions and AI tools.

**Architecture:** Add a general document extension contract to Dart-only Studio,
then extract a reusable Flutter contribution host from the current example.
`zyren_game_studio` contributes game features through those public contracts.

**Tech Stack:** Flutter 3.47.5, existing Studio/tools/inspector/Pipeline packages.

**Spec:** [design.md](design.md), R02 and R10-R14, R28-R29.

## Global constraints

- `zyren_studio` stays Dart-only.
- Studio must not depend on Pipeline, which already depends on Studio.
- Native Metal, Vulkan and DX12 remain the rendering backends.
- Use shared `ZeroState`, modest padding, horizontal controls, wrap at narrow widths and existing focus/semantics patterns.
- Stay on the active branch and preserve concurrent work.

## Review focus

- A missing editor plugin must not erase its document payload on save (S1).
- Deleting a prefab child with a component reference must produce a repairable diagnostic (S3).
- Stopping play after a failed model load must preserve the authored document and release resources (S4).
- An older evaluation arrives after a model selection changes: retain its original model identity (S6).
- A remote edit arrives while apply-back is open: reject the stale commit and show the changed revision (S4/S7).

## File responsibilities and existing owner

The active Studio workstream owns `packages/zyren_studio` and `examples/studio`.
Coordinate the exact source changes below before implementation and re-read those
files under the shared lock. The game work owns the new contribution package and
its fixtures. Do not replace `examples/studio/lib/mock/main.dart` or treat its
mock state as saved authoring support.

### S1: versioned document extensions and component history

Files: modify `packages/zyren_studio/lib/{zyren_studio.dart,src/document.dart,src/authoring.dart,src/history.dart,src/scene.dart}`;
create `lib/src/extensions.dart` and `test/extensions_test.dart`. Extend schema
fixtures in `test/authoring_test.dart`. Coordinate the payload shape with G1.

Interfaces: `StudioExtensionRecord(namespace, schemaVersion, required, data)`;
`StudioExtensionCodec.validate`, `migrate`, `referencedNodeIds`, `remapNodeIds`,
`applyOverrides`; `StudioExtensionRegistry`; `StudioDocument.extensions`;
`StudioAuthoring.updateExtension(StudioDocument, StudioExtensionRecord)`.
Record payloads remain JSON-compatible immutable values with byte/depth limits.
The current document implementation uses schema 3. Plan schema 4, preserve those
primitive kinds and re-read the version before implementation under the shared lock.

- [ ] Test schema 1/2/3 migration, schema 4 round-trip, unknown optional/required codecs, oversized payloads, invalid node links and extension edits through undo/redo. Include the schema-3 sphere/cylinder/cone/torus/plane kinds.

```dart
final encoded = document.encode();
final restored = StudioDocument.decode(encoded);
expect(restored.extensions['vendor.optional']!.data,
    document.extensions['vendor.optional']!.data);
expect(restored.extensions['zyren.game']!.schemaVersion, 1);
```

- [ ] Run `fvm dart test test/extensions_test.dart test/authoring_test.dart` in `zyren_studio`; verify current schema rejects the new contract before implementation.
- [ ] Add the next agreed schema version while preserving schema 1/2/3 readers. Validate envelope structure without executing a codec, preserve unknown payloads, and let required unsupported records block runtime compilation. Include extensions in authored history and capture. Ask codecs to validate/remap references during node and prefab edits; block unsafe structural edits when an unknown extension could contain affected references.

```dart
final next = document.copyWith(extensions: {
  ...document.extensions,
  record.namespace: record,
});
registry.validateDocument(next);
return next;
```

- [ ] Run current Studio/package/example regression tests and save/reopen an old scene. Undoing a component change must also restore related prefab overrides in one transaction.
- [ ] Commit as `feat(studio): preserve versioned document extensions`.

### S2: reusable editor contribution host

Files: create `packages/flutter_zyren_studio/pubspec.yaml`,
`lib/flutter_zyren_studio.dart`, `lib/src/{host,registry,contribution,context,panels,commands}.dart`,
`test/contribution_test.dart`, `test/host_regression_test.dart`;
modify `examples/studio/lib/{studio_editor.dart,main.dart}` incrementally.
Extract existing shared composition with its tests before adding game UI.
The concurrent `studio_workspace.dart` already supplies dockable panes and keeps
the native canvas mounted. Re-read its current implementation and tests with the
Studio owner before extraction. S2 adds contribution registration around that
workspace, preserving its docking, theme, agent panel and responsive layout.

Interfaces: `StudioEditorContribution` exposes ID/version and `attach`;
`StudioEditorContext` provides command/history, selection, asset, viewport,
capability and play-session services. Registration methods are
`registerPanel`, `registerInspector`, `registerAssetKind`, `registerCommand`,
`registerCreationTool`, `registerOverlay`, `registerValidator`,
`registerPlayFactory`, returning `Registration`. Widgets stay in this package;
document codecs stay in `zyren_studio`.
Compose `StudioAgentExtension` and `StudioAgentExtensionContext` for runtime
provider/plugin attachment. Do not create a second competing provider lifetime.
The editor registry uses the existing `AttachmentScope.keep` for registrations.
Use `AgentRegistryPlugin` and `AgentProviderPlugin` for scene provider attachment.
Panel/inspector registrations are the editor-specific gap; provider lifecycle,
permissions, transport and command review stay in Agents and Studio.

- [ ] Test duplicate IDs, dependency cycles, attach failure rollback, detach with an open panel, keyboard shortcut conflicts and focus restoration. Preserve the example's current review and collaboration behaviors.

```dart
final registration = host.register(contribution);
expect(host.panelIds, contains('game.problems'));
registration.dispose();
expect(host.panelIds, isNot(contains('game.problems')));
expect(host.commandIds, isNot(contains('game.play')));
```

- [ ] Run new host widgets and existing `examples/studio/test/studio_editor_test.dart`; establish regression fixtures before moving composition.
- [ ] Extract narrow reusable services and widgets, then change the example to consume them. Commands declare enabled state, shortcut and handler; scoped registration cleanup removes all contributed UI and callbacks. Keep the existing native viewport, asset resolver and shared widgets.

```dart
scope.keep(context.registerPanel(panel));
scope.keep(context.registerCommand(command));
scope.keep(context.registerInspector(inspector));
```

- [ ] Verify the ordinary Studio opens without the game contribution and exposes the same workflows. Check desktop/narrow layouts, focus traversal, accessibility names and detach/re-attach.
- [ ] Commit as `feat(studio): expose reusable editor contributions`.

### S3: components, prefabs and game authoring

Extend `StudioPrefab`, `StudioAuthoring` and document history with component
overrides through S1's codec. Keep one authored prefab format and one undo stack.
G1's flat spawn recipes are compiler output, not a second editor prefab system.

Files: extend `packages/zyren_game_studio/pubspec.yaml` from G7;
create `lib/zyren_game_studio.dart`,
`lib/src/{contribution,game_extension,game_commands}.dart`,
`lib/src/inspectors/{component,character,vehicle,camera,input,interaction,inventory,ability,objective}.dart`,
`lib/src/panels/{game_outline,problems}.dart`,
`test/component_authoring_test.dart`, `test/prefab_override_test.dart`.

Interfaces: `GameStudioContribution` registers G7's `GameDocumentCodec`;
`GameAuthoring.addComponent/removeComponent/setField`,
`GameAuthoring.overridePrefabComponent` return a complete immutable document;
`GameAuthoring.validate` returns node/component/field diagnostics with repair
commands. Consumes G1 codecs, S1 extension records and S2 host services.

- [ ] Test component addition/removal, missing dependencies, units/ranges, prefab inherited versus overridden fields, copy/paste reference remapping and one-step undo for multi-field edits.

```dart
final next = GameAuthoring.setField(document,
    nodeId: 'guard-model', component: 'game.character', field: 'radius', value: .4);
scene.apply(next);
expect(scene.canUndo, isTrue);
scene.undo();
expect(scene.document.encode(), document.encode());
```

- [ ] Run new authoring tests and the current Studio prefab suite. Confirm broken component references are visible and prevent play/export.
- [ ] Build inspectors from typed field descriptors with sensible specialized controls for rigs, wheel placement, input bindings and target selection. Send every UI/agent change through the same validated authoring command and history. Show inherited, overridden and missing values distinctly.

```dart
final next = GameAuthoring.addComponent(document, nodeId, component);
final issues = GameAuthoring.validate(next);
if (issues.any((issue) => issue.blocksEdit)) throw GameAuthoringException(issues);
scene.apply(next);
```

- [ ] Author a character and vehicle prefab, duplicate both, save, restart Studio and verify independent stable identities and correct controllers. A visual inspector alone does not establish persisted support.
- [ ] Commit as `feat(studio): author game components and prefab overrides`.

### S4: isolated play, debugging and apply-back

Files: create `packages/zyren_game_studio/lib/src/play/{session,controls,inspector,apply_back}.dart`,
`test/play_session_test.dart`, `test/apply_back_test.dart`;
integrate through the existing `examples/studio/lib/studio_preview.dart` ownership
pattern and S2's play factory rather than a parallel preview implementation.

Interfaces: `GamePlaySession.start(CompiledGameProject)`;
`pause`, `step`, `stop`, `runtimeSelection`, `inspectEntity`;
`GameApplyBack.prepare(authoredRevision, runtimeSnapshot)` produces a field diff;
`GameApplyBack.commit(expectedRevision, selectedFields)` creates one history entry.

- [ ] Test play/stop document identity, model/asset/native initialization failure, repeated sessions, pause/step, audio suspension and applying an outdated diff. The play session owns a separate model-memory store and scene.

```dart
final authored = scene.document.encode();
await play.start(compiled);
play.pause();
final before = play.tick;
play.step();
expect(play.tick, before + 1);
await play.stop();
expect(scene.document.encode(), authored);
```

- [ ] Run play/apply-back tests with a native resource fixture as well as pure document tests; only the native fixture establishes actual disposal behavior.
- [ ] Add compact play/pause/step/stop controls, runtime selection and debug overlays. Freeze the authoring revision at launch, enforce one session owner, and dispose native work before asset scopes. Apply-back initially supports selected transforms and explicitly editable component fields, excluding runtime IDs, health and neural state.

```dart
if (scene.revision != diff.authoredRevision) {
  throw const StaleApplyBack();
}
scene.apply(diff.applySelected(scene.document, selectedFields));
```

- [ ] Verify three repeated native sessions, a cancelled launch and apply-back with undo/redo. During play, save continues to mean save the authoring document; runtime saves use a separately labeled game action.
- [ ] Commit as `feat(studio): add isolated game play sessions`.

### S5: levels, templates and rule authoring

Files: create `packages/zyren_game_studio/lib/src/panels/{project_settings,level_tools,rule_graph,input_map,templates}.dart`,
`lib/src/templates/{exploration,vehicle_playground}.dart`,
`test/template_test.dart`, `test/rule_graph_test.dart`.

Interfaces: `GameTemplate.create(projectId)` returns a validated document and
asset requirements; `GameRuleAuthoring` edits the G6 graph through typed ports;
`GameLevelAuthoring` manages level links, spawn groups, checkpoints, navigation
bake requests, collider bindings and build profiles.

- [ ] Test each template through save/reload/compile/play, rule cycle validation, illegal port connections, undo after node deletion and input rebinding persistence.

```dart
final created = explorationTemplate.create(projectId: 'demo');
expect(GameAuthoring.validate(created).where((x) => x.blocksPlay), isEmpty);
final reloaded = StudioDocument.decode(created.encode());
expect(reloaded.id, created.id);
```

- [ ] Run authoring tests against the real compiler introduced by G7, not a mock success receipt.
- [ ] Implement compact level tools over existing selection/gizmos and navigation bake. Provide state-machine/behavior-tree editing with a text/list fallback for narrow layouts. Graph actions are selected from registered code, never evaluated source strings. Track bake source hashes and invalidate stale navigation.
- [ ] Build the key/gate/vehicle/objective loop entirely through editor fields and registered rule actions. Test missing template assets with `ZeroState` and a working import/retry action.
- [ ] Commit as `feat(studio): add game templates levels and rule tools`.

### S6: perception, models and training workspace

Files: create `packages/zyren_game_studio/lib/src/ai/{sensor_inspector,brain_inspector,model_library,observation_overlay}.dart`,
`lib/src/training/{scenario_editor,reward_editor,run_controller,run_panel,evaluation_panel,demonstrations}.dart`,
`lib/src/walkthroughs.dart`, `test/ai_workspace_test.dart`,
`test/training_process_test.dart`, `test/walkthrough_test.dart`.
Add `lib/training_agents.dart` and its scoped provider tests in this task.

Interfaces: `GameAiStudioContribution` consumes A1 model manifests, A3 sensor
profiles, A4/A5 brain diagnostics and T1-T6 run artifacts;
`TrainingRunner.start(TrainingRunRequest)` returns `TrainingRunHandle` with
state/logs/checkpoint/stop; `ModelImport.validate` and `ModelActivation.commit`
are separate commands. States: unavailable/queued/running/stopping/completed/
failed/cancelled. Status comes from process receipts, not a UI timer.
`TrainingAgentProvider` uses the shared registry with independent scopes for
inspect/start/stop, current revisions and retry keys. It calls this same runner.
Reuse `StudioAgentPanel`, `AgentWorkflow`, `AgentModelConfiguration` and
`HttpAgentModel` for external assistant conversations. This task adds policy
artifact, sensor and training views; it does not add another chat client or LLM
provider SDK. Register training tools through the existing provider lifecycle.

- [ ] Test a missing worker, incompatible model, reordered observation schema, process crash, lost subprocess connection, stale evaluation, failed checkpoint resume and cancelled import. Add a tour-start test resolving each live anchor.

```dart
final oldModel = inspector.selectedModelHash;
await library.import(candidate);
expect(inspector.activeModelHash, oldModel);
expect(candidate.compatible, isTrue);
// Activation is a separate explicit editor command after validation.
```

- [ ] Run UI tests and a real short training subprocess integration test from T3. A simulated progress sequence is permitted in widget tests but cannot close the integration gate.
- [ ] Implement model/schema comparisons, semantic versus rendered visibility labels, memory age, deadline/fallback diagnostics and per-NPC camera preview. Launch configured processes with argument arrays, project output paths and bounded logs. Show actual checkpoint lineage, evaluation cases and exact model hashes.

```dart
final process = await Process.start(executable, arguments,
    workingDirectory: projectDirectory, runInShell: false);
```

- [ ] Register the four walkthrough IDs in the design through `OnboardingProvider`; test 1440, 1024, 396 and 328 logical widths, keyboard focus, screen-reader names and 200% text scale. Zero states distinguish no model, filter-empty, denied, unavailable and failed.
- [ ] Commit as `feat(studio): add AI perception and training tools` only after the available runtime/training integration paths work; keep visual sensor support explicitly unavailable until A6 qualifies it.

### S7: export, collaboration and external tools

Files: create `packages/zyren_game_studio/lib/src/{build_panel,build_commands,collaboration_adapter}.dart`,
`lib/agents.dart`, `test/build_test.dart`, `test/collaboration_test.dart`,
`test/agents_test.dart`; extend `examples/studio` registrations through S2.

Interfaces: `GameBuildCommands` calls G7's compiler/exporter;
`GameCollaborationAdapter` uses the existing collaboration epoch and conditional
operation protocol; `GameStudioAgentProvider` uses the shared `AgentRegistry`.
Build start requires its own host scope and current document revision. S6 owns
model activation and training tools when those features become available.
Build jobs use `PipelineBuildRuntime`; authored persistence uses
`PipelineStudioStore` and `StudioPersistenceAgentProvider`. Preserve the Agents
provider registration identity as well as expected revision during review, so a
replacement provider cannot receive a previously approved command.

- [ ] Test conflicting component fields, structural edits during a session, lost grants, duplicate build requests and agent disposal. A denied command must not create a build job or output directory.

```dart
expect(await commands.startBuild(expectedRevision: staleRevision),
    isA<StaleBuildResult>());
expect(runner.activeJobs, isEmpty);
```

- [ ] Run build/collaboration/agent tests against actual file artifacts and the existing local authority. Record remote-protocol limitations independently.
- [ ] Extend the existing collaboration authority/protocol for component patches with atomic revision checks and inverse history, or require leaving collaboration for those edits and show the limitation. Current transform/visibility operations do not establish component support. Reuse its offline queue, presence and history. Show Pipeline build validation, dependency pins, native capabilities and output path together. Reuse current MCP job/cancellation support.
- [ ] Export a game, close Studio, load the artifact offline in the Flutter example and perform an external MCP inspect/edit/undo/build sequence with denied and stale variants.
- [ ] Commit as `feat(studio): export game projects and expose guarded tools`.

## Shared requests and acceptance

S1 owns the general Studio schema extension. S2 owns the reusable Flutter editor
host. Those must land before game-specific code depends on them. The Studio owner
reviews preservation of existing review, asset, history and collaboration behavior.
Avoid broad formatting of the large current `studio_editor.dart` during extraction.

Run `fvm flutter test --no-pub` in each new Flutter package after resolution,
existing Studio/example tests, scoped analysis and the package-boundary checker.
Native checks use actual Metal/Vulkan/DX12 sessions with independent play scopes.
Q3 owns device and accessibility evidence. Full editor support requires persisted
components, functioning play/export and the actual training integration, not just
panels or a mock.
