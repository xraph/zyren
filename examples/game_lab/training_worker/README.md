# Native training worker

Prepare the worker once, then run Python environments against the resulting executable. Each environment owns a Dart isolate, a Rapier world and a `GameSimulation`. Structured runs use no renderer or window.

From this directory:

```sh
fvm dart build cli \
  --target=../bin/train_worker.dart \
  --root-package=zyren_game_lab_training_worker \
  --output=.dart_tool/native_worker
```

Keep the complete `bundle` directory. Its executable uses the native libraries in `bundle/lib`. Plain `dart compile exe` does not prepare these code assets. You can also run `fvm dart run bin/train_worker.dart` during local development, after the coordinated native build window; training clients should launch the prepared bundle so environment creation never starts another native build.

From `tool/zyren_train`, use the prepared executable:

```sh
ZYREN_WORKER_EXE=/absolute/path/to/bundle/bin/train_worker \
  uv run pytest tests/test_protocol.py tests/test_env.py tests/test_worker_failure.py

uv run zyren-train fixture \
  --worker /absolute/path/to/bundle/bin/train_worker \
  --cwd /absolute/path/to/examples/game_lab/training_worker \
  --steps 1000 --seed 7 --output /tmp/zyren-throughput.json
```

The `native-body` fixture applies two continuous movement values through the game command queue, steps the native simulation and returns A3 `BodySensor` observations through `ObservationAssembler`. The validity mask remains part of the tensor. A4 `ScriptedBrain` supplies an authored-route baseline action through the same action schema. Snapshot restore uses G7 staging to restore the body pose, velocity and last applied action, then resets brain state and rebinds the new actor generation.

For your own scenarios, supply `GameTrainingScenario` factories and `GameTrainingInstance` adapters. Select controllable actors explicitly through `actors`; ground, keys and gates can remain ordinary level entities. The provider must resolve current live handles after restore. Register live state codecs for every system you need to snapshot, and use `beforeStep` to await actual inference before advancing to its due tick. A policy host must call its shared scheduler's `flush`, await the staged request, and retain the A5 identity, legality, target and exact due-tick checks when applying it.

The Gymnasium wrapper returns separate termination and truncation flags, as required by the [environment contract](https://gymnasium.farama.org/api/env/). A killed or timed-out worker truncates the episode with `worker_failed=true` and `success=false`. Vector environments use separate environment IDs and isolates. Training, validation and test scenarios have separate catalog membership; the worker rejects a reset into another split.

Wire v1 uses a little-endian uint32 header length, UTF-8 JSON metadata and little-endian tensor blocks. Initial limits are 64 KiB of metadata, 16 MiB for the whole frame, metadata depth 64 and 8,192 nodes. Negotiation only lowers the byte limits. Requests and responses carry run, environment, episode, actor generations, sequence and tick identities. Snapshots use a raw `u8` block so saved state does not consume the JSON header budget. Logs go to stderr.

Qualification on 2026-10-03: nine Dart tests and 22 Python tests passed, including actual native process reset/step/restore, independent vector environments, graceful EOF shutdown, a killed worker, pipe backpressure, out-of-order responses and 1,000 accepted action/tick/position records matching the direct game runtime. The final local CPU fixture processed 1,000 steps in 0.864285 seconds (about 1,157 steps/second). This measures the small body fixture only. It does not qualify game task learning, a trained recurrent policy in this host, physical devices or visual offscreen observations. No model downloads or paid runs were used.

## Record and replay

The supervisor also registers `guard` and `vehicle`. Guard uses the shared
character motor, vision and captured observer poses. Vehicle uses the shared
ray-wheel controller. Both expose their generated observation schema and shared
action space. The clock-only renderer attaches animation plugins and throws if
you call render. It creates no GPU backend.

Use `--scenario-specs` on the prepared executable to obtain pinned scenario JSON.
The record command checks those pins against the live host before appending data:

```sh
uv run zyren-train record --worker /absolute/path/to/train_worker --cwd /absolute/path/to/training_worker --scenario-spec guard.json --source scripted --session-id guard-7 --output recordings/guard-7
uv run zyren-train replay --worker /absolute/path/to/train_worker --cwd /absolute/path/to/training_worker --recording recordings/guard-7
```

For player input, add `--source player --actions trace.json`. That file is an
array of controller actions, with integers for the character branches. A trace
fixture proves controller-path reuse; it does not establish physical keyboard,
gamepad or touch qualification. The recording metadata keeps its input source.

Chunks are append-only, at most 8 MiB and 1,024 records. Final manifests hash the
chunks and carry episode, scenario, build, schema, asset and recording identities.
Interrupted recovery retains the bytes and marks the last chunk incomplete.
Replay compares observed inputs, proposed/applied controller actions, fallback,
legality masks, reward terms and outcomes. Split scenarios and recording sessions
before fitting. `ObservationNormalizer.fit(train_partition)` verifies the source
chunk hashes and cannot fit a validation or test partition.

The guard and vehicle adapters require an explicit reset boundary for resume.
Their full animation/controller state is not snapshot-qualified, so they reject
snapshot and restore. The original native body fixture retains its tested G7
snapshot support.
