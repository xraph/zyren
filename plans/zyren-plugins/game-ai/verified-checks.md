# Checked game and AI paths

These records describe checks completed in the shared FVM Flutter 3.47.5/Dart 3.13.4 workspace on 2026-10-03. They do not claim a fresh checkout, CI execution or physical platform parity. Source and receipt pins in completion.json identify the checked regression contracts. Earlier task reports retain RED/GREEN details locally; the durable native failure and trained quality/parity receipts remain tracked.

| Check | Command and recorded result |
| --- | --- |
| Complete synchronous timing | Root: `fvm dart --packages=.dart_tool/package_config.json packages/zyren_game/test/step_measurement_test.dart`, 4 passed; original session suite, 12 passed |
| Physical checkpoint motion | Physics package: `fvm dart test --concurrency=1 test/restore_motion_test.dart test/world_test.dart`, 6 passed; added sleeping admission fixture, 2 passed |
| Metal loss and game restore/pools | Native package: `RUN_NATIVE_GPU=1 fvm dart test --concurrency=1 test/renderer_failure_receipt_test.dart test/save_test.dart test/gameplay_topology_test.dart test/topology_test.dart`, 18 passed |
| Sleeping checkpoint preflight | Native package: `RUN_NATIVE_GPU=1 fvm dart test --concurrency=1 test/save_admission_test.dart test/renderer_failure_receipt_test.dart test/save_test.dart`, 7 passed |
| Native gameplay/AI topology | Three gameplay topology regressions passed; root reported 12 AI native tests including changed actor topology, malformed checkpoint rollback and private recurrent state |
| Studio/native play lifecycle | Studio package play session/widget/gameplay fixture group, 13 passed; async runtime preparation cancellation retains native cleanup ordering |
| Actual Studio workflows | Root verified save/reload/export/reopen and stale-authoring rejection; AI host tests cover accepted artifact import, scoped activation, permitted Metal camera capture and four registered walkthroughs at desktop/narrow widths |
| Core/native failure admission | Pinned game-core, game-studio and game-native receipts prove the named strict failure rows; root ML/perception/pool and worker receipts retain real native execution |
| Exported runtime | Root reported GameLab 8 accepted-model native checks, including same-runtime controllers and checkpoint restore; runtime scene/compiler export tests execute pinned imported glTF without an editor runtime import |
| Structured training/evaluation | Durable revised-plan ONNX report requests 400 episodes, 200 per family, all successful with zero recorded collisions, invalid actions, leakage/exploits or worker failures |
| Native exported parity | Both durable native ML receipts contain 1,000 typed controller/recurrent steps plus complete hash-pinned F32 reference/native tensors and decoded controls |
| Python training foundation | T6 operator reported 108 tests passed with an actual frozen same-runtime worker; accepted visual/multi-agent quality remains incomplete |
| Strict failure evaluator | `python3 -m unittest tool/qualification/tests/test_game_ai_failures.py`, 7 passed; `python3 tool/qualification/verify_game_ai_failures.py`, all 25 cases passed |
| Source integrity | Owned Dart analysis, rustfmt and Git diff checks passed; package boundaries are an existing gate, with foreign shared changes preserved |

The source-only benchmark review found missing native simulation CPU, unused invalid-output counters and incomplete cleanup measurements. Those paths were repaired: full-step timing covers controllers/physics/state observers, real brain/receipt deltas feed invalid/stale metrics, and exact native/ML/Rapier baselines gate cleanup. Android measured timing failed the initial budget and is retained as a failed measurement. No sustained capacity acceptance follows from source review.
