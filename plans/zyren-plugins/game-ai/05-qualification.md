# Game and AI qualification implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish which game development, editor and learned-AI workflows work
on each target, with repeatable tests and explicit remaining limits.

**Architecture:** Use the same two reference games across Studio, exported apps
and training. Collect artifact/build/device receipts and distinguish source,
automated, trained-model and physical-device evidence.

**Tech Stack:** FVM Flutter/Dart, native Metal/Vulkan/DX12 devices, Python training
tests and existing MCP/diagnostics/CI infrastructure.

**Spec:** [design.md](design.md), R01-R32 and the proposed capacity profiles.

## Global constraints

- A missing or invalid model activates the authored scripted controller only if that fallback is part of the game definition.
- Build success alone is not device evidence.
- Unknown metrics remain null.
- Python never ships in the Flutter runtime artifact.
- Stay on the active branch and preserve concurrent work.
- Never push, merge, publish packages or start paid infrastructure without a request.

## Review focus

- A visually correct demo can still run a scripted substitute: record the active policy hash and inference counts (Q1).
- Thermal throttling after a few minutes can invalidate a short benchmark: use sustained runs (Q4).
- Empty, denied, failed and unsupported states must remain different in the editor and tools (Q2/Q3).
- A renderer/device recreation can leave sensor textures or model workers alive: verify repeated recovery (Q2/Q4).
- An exported game can accidentally require Studio/Python or network assets: run it offline without either toolchain (Q1/Q5).

### Q1: reference games and the complete authoring-to-training workflow

Files: create `examples/game_lab/lib/{main,exploration_game,vehicle_game}.dart`,
`examples/game_lab/game/{project,exploration,vehicle_playground}.json`,
`examples/game_lab/integration_test/{game_workflow,policy_workflow}_test.dart`,
`examples/game_lab/test/runtime_artifact_test.dart`,
`packages/zyren_game_studio/integration_test/author_train_export_test.dart` and
small licensed fixture assets. Reuse the worker added by T1.

Interfaces: `GameQualificationReceipt` pins project/build/model/schema/device
identities, action counts, inference counts, assertions and output artifacts.
Fixture scenes expose stable entity IDs and expected checkpoints through game
APIs, not screen-coordinate guesses.

- [ ] Build two reference games. Exploration includes a playable character, an NPC with occlusion/memory/hearing, an interaction gate, inventory and an objective. Vehicle playground includes a drivable vehicle, a learned driver, moving obstacles and entry/exit possession.
- [ ] Test the complete persisted flow: create from template, edit components, save/restart, play/stop, record demonstrations, start a real short training run, evaluate, import, activate, export and open the game offline. The quality gate uses a fully trained accepted artifact, separate from the short pipeline smoke run.

```dart
expect(receipt.activeModelHash, acceptedBundle.modelHash);
expect(receipt.inferenceCount, greaterThan(0));
expect(receipt.scriptedFallbackTicks, lessThanOrEqualTo(profile.fallbackBudget));
expect(receipt.completedObjectives, contains('exit-yard'));
```

- [ ] Repeat accepted action logs through realtime play and the T1 worker with the same seed, tick schedule and engine build. Test visual observations against native capture receipts; verify RGB policy results were generated from RGB inputs.
- [ ] Run `fvm flutter test integration_test/game_workflow_test.dart -d macos --no-pub` and the corresponding policy workflow from `examples/game_lab`, then target physical devices in Q4. Run Studio's integrated author/train/export test with the configured local worker.
- [ ] Commit as `test(game): verify authoring training and exported play` and record output hashes. A placeholder model or mocked worker must be labeled as a test fixture and cannot satisfy the learned-behavior gate.

### Q2: failure, identity and lifecycle qualification

Files: create `packages/zyren_game/test/failure_matrix_test.dart`,
`packages/zyren_game_ai/test/leakage_matrix_test.dart`,
`packages/zyren_ml/test/recovery_test.dart`,
`packages/zyren_game_studio/test/transaction_failure_test.dart`,
`tool/qualification/game_ai_failure_matrix.json` and
`tool/qualification/verify_game_ai_failures.py`.

Interfaces: one machine-readable case record has ID, injected condition, expected
status, preserved identities, cleanup counters, recovery action and result.
The runner must fail if a required case is missing or skipped without a recorded
blocker. Use actual native backends for lifetime cases.

- [ ] Enumerate cases for malformed/oversized project data, cyclic prefabs, removed entities, stale actions, model schema/hash/operator errors, unknown sensors, queue saturation, cancellation, worker crash, failed save, renderer loss and conflicting edits.
- [ ] Add regressions that compare the complete preserved document/session receipt before and after rejected operations. Check model, tensor, sensor target, physics and asset owners return to baseline after bounded cleanup.

```python
assert after["authored_hash"] == before["authored_hash"]
assert result["status"] == "failed"
assert result["recovery_action"] == "retry_model_load"
assert after["active_native_jobs"] == 0
```

- [ ] Run paired-world leakage cases for hidden positions, hearing uncertainty, stale nav obstacles, teacher-only inputs and memory after loss of sight. Repeat with batching, pooling and actor replacement.
- [ ] Test live MCP discovery, reads, guarded mutations, retry keys, cancellation and disposal. External developer access cannot silently alter runtime gameplay authority or expose data the host denied.
- [ ] Commit as `test(ai): cover failure recovery and observation boundaries` after all required cases report a truthful status.

### Q3: editor, input and accessibility checks

Files: create `packages/zyren_game_studio/test/{layout,semantics,onboarding}_test.dart`,
`packages/flutter_zyren_game/integration_test/input_device_test.dart`,
`examples/studio/integration_test/game_editor_test.dart`, and screenshots/receipts
under an owned qualification output directory. Keep only selected approved gallery
images and small receipts in tracked source.

Interfaces: `EditorQualificationProfile` names viewport, text scale, input mode,
theme and walkthrough ID. Test IDs refer to registered commands and semantic
labels. This task consumes working S2-S7 contributions.

- [ ] Test widths 1440, 1024, 396 and 328 logical pixels at normal and 200% text scale. Verify the viewport and next actions remain usable, controls wrap, dialogs scroll and no content is clipped. Use the current Studio theme and shared density conventions.
- [ ] Check keyboard-only creation/edit/play/stop, visible focus, pointer capture/release, touch cancellation, physical gamepad connect/disconnect, text input priority and app background/resume.

```dart
expect(find.byType(ZeroState), findsOneWidget);
expect(find.bySemanticsLabel('Import model'), findsOneWidget);
expect(tester.takeException(), isNull);
```

- [ ] Start every registered game/AI walkthrough, including a narrow layout where its panel must open first. Test missing required anchors as an explicit failure. Check empty/filter-empty/loading/denied/failed/unavailable states separately.
- [ ] Inspect the actual native accessibility tree and perform a screen-reader pass on the available desktop/mobile platforms. Automated semantics checks do not establish assistive-technology usability.
- [ ] Commit as `test(studio): qualify compact game and AI workflows`, recording untested hardware/input modes separately.

### Q4: native providers, sustained performance and capacity

Files: create `examples/game_lab/lib/benchmark.dart`,
`examples/game_lab/integration_test/benchmark_test.dart`,
`tool/qualification/game_ai_profiles.json`,
`tool/qualification/run_game_ai.py`,
`packages/zyren_ml/QUALIFICATION.md`,
`packages/zyren_game_ai/QUALIFICATION.md`,
`packages/zyren_game_native/QUALIFICATION.md`.

Interfaces: benchmark receipt fields include device/OS/build, renderer/provider,
game/model/schema hashes, actor/camera counts, sensor/decision Hz, p50/p95/p99,
deadline misses, invalid/fallback actions, tracked bytes, RSS, readback bytes,
thermal/power availability and cleanup results. Missing metrics serialize as null.

- [ ] Execute the four design profiles for at least ten minutes each, three repetitions per device/provider configuration. Include warmup, camera movement, spawn/despawn, pause/resume and native renderer recreation. Benchmark release/profile builds; record the exact mode.

```python
assert receipt["duration_seconds"] >= 600
assert receipt["applied_stale_actions"] == 0
assert receipt["actor_count"] == requested_profile["actor_count"]
assert receipt["completed_decisions"] + receipt["missed_decisions"] == receipt["due_decisions"]
```

- [ ] Qualify macOS Metal, physical Android Vulkan and physical iPhone/iPad Metal, then Windows DX12 and Linux Vulkan. Each target needs model load/run, controllers, actual presentation, visual sensor formats and cleanup. Unsupported capability and missing device are separate statuses.
- [ ] Compare CPU with supported native accelerated providers using the exact recurrent/visual graphs. Record model load time and operator partitioning. Include copy/preprocessing/capture cost; kernel time alone cannot justify enabling acceleration.
- [ ] Enforce the proposed frame/deadline gates. When a profile fails, preserve the failing receipt and establish a lower supported profile through new runs. Report total app-size delta, model bytes and working memory separately; model size alone does not prove a small game.
- [ ] Commit as `test(game): record native AI capacity and device qualification` with a truthful platform matrix. Tests/builds for one backend cannot qualify the others.

### Q5: CI, documentation, examples and release preparation

Files: create `.github/workflows/game-ai.yml`,
`tool/qualification/verify_game_ai_release.py`,
`plans/zyren-plugins/game-ai/completion.json` during implementation;
update all new package READMEs, changelogs, licenses/notices, API exports,
`README.md`, `tool/check_package_boundaries.dart` and
`tool/generate_api_reference.dart` where registration is needed.

Interfaces: `completion.json` tracks each R01-R32 requirement and task with
implemented, automated, native, trained-artifact and documentation evidence.
Its release evaluator accepts passed/failed/blocked/notApplicable statuses,
requires a reason for notApplicable, and treats absent records as incomplete.

- [ ] Add CI jobs for pure Dart contracts, Flutter editor/widgets, native ML fixtures, Python protocol/training/export smoke checks, package boundaries and artifact parity. Run native package tests sequentially within a shared workspace; use isolated CI jobs for platforms.
- [ ] Recheck the [reuse audit](reuse-audit.md) against the implementation diff. Keep authored prefabs/history in Studio, pointer ownership in Input/Interaction, rendering in existing Flutter scene widgets, bundles/cache/build jobs in Pipeline, agent workflows in Agents and reusable camera capture in Capture. New types must identify their game/ML responsibility or extend the existing owner.
- [ ] Run the affected existing suites as integration gates: Studio authoring/history and editor workflow, input/interaction arbitration and Flutter overlays, Pipeline bundles/cache/build runtime, character/physics/navigation, Capture and Agents workflow/provider guards. Record exact commands and results. This planning audit inspected source and test cases but did not run these suites.
- [ ] Keep device/performance jobs explicit and opt-in where hardware is required. They must upload receipts on failure. A skipped native job cannot satisfy a required target in the completion evaluator.

```python
for requirement in required_requirements:
    evidence = completion[requirement]
    assert evidence["implemented"] == "passed"
    assert evidence["automated"] == "passed"
    assert all(evidence["targets"][target] == "passed" for target in claimed_targets)
```

- [ ] Write practical guides for first game, Studio components/prefabs, input/HUD, vehicles, save games, sensors/memory, model import, training setup, reward debugging, visual learning, multi-agent tasks, export and performance tuning. Document exact commands from tested runs and error recovery. Keep repository docs in tracked package files; coordinate the existing website documentation import separately before claiming publication.
- [ ] Validate examples in a fresh dependency-resolved checkout and load exported games without Studio, Python or network access. Inspect dependency/license closure, native ABI/binary packaging, model/asset licensing and per-platform signing requirements. Run `fvm dart pub publish --dry-run` in publishable Dart packages and the appropriate Flutter equivalent; actual publication needs a separate request and resolved public dependency versions.
- [ ] Make focused documentation/release-preparation commits, update the roadmap completion table, and report implemented/tested/device-qualified/trained/published states separately.

## Program exit criteria

You can create and edit both reference games in Studio, retain all game and AI
components after restart, play without mutating authored state, train and evaluate
new policies, activate them with schema checks, export and run offline. NPCs obey
their sensor and memory limits. Vehicles remain controlled by native physics.
RGB/depth policy evidence comes from actual native camera tensors.

All required workflows have failure/retry behavior and recorded native evidence
for every platform claimed as supported. The program remains partial while a
required capability is a mock, a stub, a skipped test or a missing trained model.
Publication and website availability are separate from local implementation.
