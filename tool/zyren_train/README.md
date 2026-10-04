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

You can fine-tune a compatible actor in a new run with optional `initial_actor`:
its four fields are `config`, `config_sha256`, `checkpoint` and
`checkpoint_sha256`. Pin the raw source config and checkpoint bytes with full
SHA256 digests. Paths resolve from the runner's working directory.

We verify the source observation, action, encoder, timing and TRAIN lineage
before changing actor tensors. The first affine layer is rebased to preserve
its raw-input function under the new TRAIN means and scales; camera
normalization stays identity. The `initial-actor` receipt records both source
hashes and the reset of optimizer, critic, RNG and recurrent state. Subsequent
resume continues the new run's checkpoint and optimizer.

Guard and vehicle resume at an explicit reset boundary because their complete
controller/animation state snapshots are not qualified. Model and optimizer
steps continue; environment and recurrent state reset. Numerical reproduction
of an uninterrupted trajectory is not claimed. A CPU smoke run proves the
training path, not policy quality, exported-model parity or device gameplay.

## Held-out evaluation

You can run the selected evaluation plan against verified guard and vehicle checkpoints:

```sh
zyren-train evaluate --plan configs/evaluation.yaml \
  --worker /absolute/path/to/prepared/train_worker --cwd /absolute/path/to/training_worker \
  --guard-config /absolute/path/to/guard-config.json --guard-run /absolute/path/to/guard-run \
  --vehicle-config /absolute/path/to/vehicle-config.json --vehicle-run /absolute/path/to/vehicle-run \
  --output /new/learned-evaluation.json --baseline-output /new/scripted-evaluation.json \
  --comparison-output /new/comparison.json
```

The plan pins the prepared executable, copied native libraries, full test scenarios and fixed episode seeds. Select it before evaluating. A rebuilt worker changes the plan hash; earlier receipts retain their embedded plan. You must not move test scenarios or observations into training data.

Every requested slot remains in the report, including failed and cancelled episodes. Reward and physical task success have separate aggregates. The release gate requires 200 episodes per family across at least 20 layout seeds, guard success of 90% with a Wilson lower bound of 85%, vehicle success of 95% with a lower bound of 90%, and vehicle collisions in at most 2% of requested episodes. Paired hidden worlds, reward exploit checks and the listed stress distributions must all run. Missing evidence fails the gate.

Delayed sensor receipts and missed decisions use the shared fallback without advancing recurrent state. Evaluation runs the real Rapier, character motor and ray-wheel vehicle paths. It does not initialize a renderer. A failed quality receipt cannot authorize model activation, even when every episode completed and unit tests passed.


## Native policy export

You can export a verified checkpoint to a new candidate directory:

```sh
zyren-train export --config /absolute/config.json --run /absolute/run \
  --schema-info /absolute/native-schema-info.json --output /new/candidate
```

The schema info is the worker's observation schema, action schema and action space. Export checks those hashes against the training config. The actor graph contains the observation normalization and carries hidden/cell state through explicit inputs and outputs. Reset both to zero for a new episode. The value head, optimizer and exploration variance stay in the training checkpoint.

A candidate cannot activate. First run the immutable held-out plan against its ONNX hash, then compare at least 1,000 recorded recurrent steps through the native runtime and shared controller decoder. Publish only after both checks pass:

```sh
zyren-train publish --candidate /absolute/candidate \
  --evaluation /absolute/onnx-evaluation.json --native-parity /absolute/native-parity.json \
  --output /new/accepted-policy
```

The accepted directory has eight hashed resources and `bundle.json`. Extra files, missing normalization, changed schemas, incompatible controller mappings and tampered resources fail validation. Pipeline owns archive building and import. We do not add a second archive format.

`quantize_candidate` creates a separate int8 QDQ candidate from an accepted float directory. Calibration reads verified training recordings only. Run the same held-out plan again, retain the original collision and integrity gates, and reject more than two percentage points of success loss against the accepted float model. Quantization reports model bytes separately. App binary and working-memory deltas remain unknown until measured in the target host.

For int8 publication, pass `--precision int8 --baseline-bundle /absolute/accepted-float-policy`. The publisher embeds and verifies the float baseline manifest and full evaluation receipt, then recomputes success loss against the exact candidate report. A quantized model cannot borrow the float model's acceptance marker. Host support must validate this proof before activation.
