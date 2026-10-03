# Zyren training export probe

You can reproduce the local linear, LSTMCell and 84x84 CNN exports with Python
3.11 or 3.12 and uv. No pretrained models are downloaded.

```sh
uv sync --locked
uv run --locked python scripts/export_probe.py \
  --output ../../packages/zyren_ml/test/fixtures
```

Run these commands from `tool/zyren_train`. The lock pins PyTorch 2.8.0, ONNX
1.19.1, ONNX Runtime 1.23.2 and NumPy 2.3.4. The exporter uses the explicit
TorchScript path (`dynamo=False`) with opset 17 and embedded tensor data. PyTorch
prints a deprecation notice for that exporter; the pin and export receipt keep
this probe reproducible while the newer exporter is evaluated separately.

You get model manifests, known inputs/outputs, a 1,000-step recurrent reference
sequence and `export-receipt.json`. The LSTM sequence varies observations and
resets state at step 500. A small ONNX Identity graph also exercises native int64
and bool storage. These fixtures establish export and inference feasibility.
They do not establish learned game behavior or rendered visual-policy quality.

After the Dart build hook has bundled the host runtime and bridge, you can check
the C ABI directly:

```sh
uv run --locked python scripts/native_probe.py \
  --bridge ../../.dart_tool/lib/libzyren_ml.dylib \
  --runtime ../../.dart_tool/lib/libonnxruntime.dylib \
  --fixtures ../../packages/zyren_ml/test/fixtures
```

Those library names are for macOS. The probe performs ten load/run/close cycles
for each exported model, checks a malformed tensor and confirms that no session
or result handles remain live. T1 extends this Python project with the training
environment and CLI. T5 extends the export/parity checks.

## Local controller training

You can train separate structured character and vehicle policies through the
prepared native worker. The schema supplies the input width. Both networks use
MLP(128,128), LSTM(128), an action head and a value head. Character branches use
captured legality for sampling, probability and entropy. Vehicle actions use a
censored Normal distribution with exact probability mass at the action bounds; the shared native decoder gives braking
priority. Physical mappings stay in TrainingActions.

Start with the CPU smoke configuration after building the worker as documented
in `examples/game_lab/training_worker/README.md`:

```sh
uv run zyren-train configure --template configs/cpu-smoke.yaml \
  --worker /absolute/path/to/train_worker --output /tmp/zyren-cpu.json
uv run zyren-train train --config /tmp/zyren-cpu.json \
  --worker /absolute/path/to/train_worker \
  --cwd /absolute/path/to/examples/game_lab/training_worker \
  --run /tmp/zyren-cpu-run --stop-after-updates 1
uv run zyren-train train --config /tmp/zyren-cpu.json \
  --worker /absolute/path/to/train_worker \
  --cwd /absolute/path/to/examples/game_lab/training_worker \
  --run /tmp/zyren-cpu-run --resume
```

Configs use JSON, a YAML1.2 subset, so no separate YAML parser is needed. The
configure command pins the prepared executable and copied native asset hashes and exclusively creates the
resolved config. A rebuilt executable or changed native asset needs a new run and config.

For cloning followed by PPO, record a scripted or player dataset first. The
structured recipes expect `recordings/guard-scripted` or
`recordings/vehicle-scripted`; replace those paths with your verified recording
paths before configuring. The loader checks source partitions, chunk hashes,
episode membership and schema/build pins. Normalization fits only training data.
It is included in the model buffers and checkpoint. Held-out data cannot enter
cloning, normalization or the curriculum.

The full recipes progress through empty arenas, static obstacles, occlusion,
moving hazards and combined tasks at episode boundaries. Each stage resolves to
a registered native scenario with its own build and content pins. Thresholds,
seeds, network, optimizer, rewards and worker bytes and policy distribution identity belong to the run config.
Reward terms are capped; success, collision and progress counters remain
separate. Evaluation-due receipts require the T4 held-out evaluator and carry no
acceptance result.

Run receipts append a hash chain to `receipts.jsonl`. `checkpoint.json` points to
an atomic hash-verified checkpoint containing model, optimizer, RNG,
normalization, source hashes, curriculum and cloning epoch/sequence progress. A run has one active trainer. Stop
requests save a checkpoint, close the supervisor and report `cancelled`.
Cloning checks cancellation at sequence and epoch boundaries. Resume continues
its optimizer from the next unfinished sequence. An immediate resumed stop
reuses the verified checkpoint when no optimization occurred.
Completion reports `completed` only after worker cleanup succeeds. Worker or
storage failures report `failed` when receipt storage remains available.

Guard and vehicle resume at an explicit reset boundary because their complete
controller/animation state snapshots are not qualified. Model and optimizer
steps continue; environment and recurrent state reset. Numerical reproduction
of an uninterrupted trajectory is not claimed. A CPU smoke run proves the
training path, not policy quality, exported-model parity or device gameplay.
