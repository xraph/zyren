# Game AI training implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give you a reproducible local setup to train, evaluate and export small
character and vehicle policies, including visual and multi-agent policies.

**Architecture:** Python owns optimization and datasets. Dart workers execute the
same compiled project, sensors, controllers and native physics as the game.
Studio starts configured runs and reads their versioned artifacts.

**Tech Stack:** Python 3.11 baseline, locked PyTorch/Gymnasium/SB3-Contrib/ONNX
dependencies, PettingZoo for simultaneous multi-agent environments, FVM Dart.
Select exact compatible versions from the A1/T1 probes and commit the lockfile.

**Spec:** [design.md](design.md), R23-R28, R32 and the simulation contract.

## Global constraints

- Training calls `step`, never a render callback.
- These are adapters to Zyren's worker, not replacement Python physics.
- Test and validation scenarios cannot enter training or distillation data.
- CPU training must work for protocol and small policy checks.
- No cloud resource, paid run or model download is authorized by this plan.
- Stay on the active branch and preserve concurrent work.

## Review focus

- A worker dies mid-episode: report failure and preserve a resumable run, not success (T1/T3).
- A time limit ends a task: bootstrap as truncated, not a terminal success/failure (T1/T3).
- Normalization fitted on held-out maps creates leakage: fit only training partitions (T2/T4).
- Recurrent state survives reset or maps to another actor after batching: reset/reorder explicitly (T1/T5).
- A policy gains reward by repeating a trigger or ending early: evaluate task outcomes and exploit cases (T3/T4).

## File responsibilities and setup

Create `tool/zyren_train/pyproject.toml`, `uv.lock`, `src/zyren_train`, `tests`,
`configs`, `schemas`, `scripts`, `README.md` and `.gitignore`. Keep generated
checkpoints, private demonstrations and large evaluation outputs in a selected
run directory outside tracked source. Commit only small licensed fixtures and
their provenance. Python never ships in the Flutter runtime artifact.

Initial local commands after T1 creates the CLI:

```sh
cd tool/zyren_train
uv sync --locked
uv run zyren-train doctor --project ../../examples/game_lab/game/project.json
uv run zyren-train benchmark --config configs/guard-structured.yaml --steps 10000
```

`doctor` checks the configured FVM worker, pinned native assets, writable output,
model runtime/export compatibility and requested CPU/GPU availability. It changes
no system SDK, driver or global Python environment. CUDA is an optional profile;
the CPU profile remains available for tests and small runs. Record simulation
steps/sec separately from learner updates/sec before estimating training time.

### T1: environment worker and versioned protocol

Files: create `examples/game_lab/bin/train_worker.dart`,
`packages/zyren_game/lib/src/training/{environment,protocol,supervisor}.dart`,
`tool/zyren_train/src/zyren_train/{cli,protocol,worker,gym_env,vector_env,doctor}.py`,
`schemas/protocol-v1.json`, `tests/{test_protocol,test_env,test_worker_failure}.py`
and Dart protocol/reset tests. Consumes G2/G7 and A3/A4.

Interfaces: Dart `GameTrainingEnvironment.reset(seed, scenario)` and
`step(actionByActor)`; Python `ZyrenEnv.reset(seed=None, options=None)` returns
`(observation, info)`, `step(action)` returns
`(observation, reward, terminated, truncated, info)`; `ZyrenVectorEnv` multiplexes
independent environment IDs. Worker operations: hello/reset/step/snapshot/restore/close.

- [ ] Test version negotiation, truncated frame input, oversized lengths, invalid dtype/shape, duplicate sequence IDs, invalid actions, reset while busy and a killed worker. Check every output retains run/environment/episode/actor/tick identities.

```python
obs, info = env.reset(seed=7)
next_obs, reward, terminated, truncated, info = env.step(env.action_space.sample())
assert info["tick"] > 0
assert info["observation_schema_hash"] == env.observation_schema_hash
assert not (info["worker_failed"] and info["success"])
```

- [ ] Run `uv run pytest tests/test_protocol.py tests/test_env.py tests/test_worker_failure.py`; confirm failure against the absent worker contract.
- [ ] Define wire v1: unsigned little-endian 32-bit header length, UTF-8 JSON metadata, then raw little-endian tensor blocks with declared offsets/lengths. Initial bounds: 64 KiB header and 16 MiB total message, negotiated downward. Stderr carries logs. Launch one prepared Dart supervisor through `fvm dart run bin/train_worker.dart`, then create isolate-owned environments after native hooks finish; do not start concurrent native builds.

```python
header_length = struct.unpack("<I", read_exact(stream, 4))[0]
if header_length > 65536:
    raise ProtocolError("header exceeds limit")
header = json.loads(read_exact(stream, header_length))
```

- [ ] Implement the Gymnasium adapter, vector reset and deterministic fixture runner. Verify 1,000 accepted steps match game-runtime action/tick logs on the same engine build and seed. Structured runs require no GPU or window. Visual runs request an explicit native offscreen capability.
- [ ] Commit as `feat(training): run Zyren environments through a versioned worker` with the exact dependency locks and throughput report format.

### T2: scenarios, demonstrations and dataset lineage

Files: create `tool/zyren_train/src/zyren_train/{scenario,dataset,demonstration,split,normalize}.py`,
`schemas/{scenario-v1,dataset-v1}.json`, `tests/{test_dataset,test_split,test_scenario}.py`;
create `packages/zyren_game/lib/src/training/demonstration.dart` and
`examples/game_lab/game/scenarios/{guard,vehicle}.json`.

Interfaces: `ScenarioSpec`, `DemonstrationRecorder`, `DatasetManifest`,
`split_by_scenario`, `ObservationNormalizer.fit(train_partition)`;
scenario callbacks and reward terms are registered game IDs, not serialized code.
Each sequence stores observed input, proposed action, applied action, fallback,
delay, reward terms, done/truncated flags and all schema/build/model pins.

- [ ] Test interrupted recording, unsupported version, actor joins/leaves, changed sensor profile, zero-length episodes and duplicate scenario hashes across partitions. Demonstrations from the same recording session stay in one partition.

```python
assert set(train.scenario_hashes).isdisjoint(test.scenario_hashes)
assert set(train.session_ids).isdisjoint(validation.session_ids)
normalizer = ObservationNormalizer.fit(train)
assert normalizer.source_partition == "train"
```

- [ ] Run dataset/split tests and a Dart recording fixture before adding player recording UI in S6.
- [ ] Record player input through the same observation and controller path used by policies. Use append-only bounded chunks plus a finalized hash manifest; recovery marks an interrupted last chunk incomplete. Include asset license/provenance, recording settings, seed, control cadence and simulated latency.

```python
manifest = {
    "schema_version": 1,
    "partition": partition,
    "observation_schema_hash": observation_hash,
    "action_schema_hash": action_hash,
    "game_build_hash": game_build_hash,
    "episodes": episode_receipts,
}
```

- [ ] Record guard pursuit/investigation and vehicle braking/turning from both player and scripted baseline through the game example. Replay samples through the worker and compare observations/applied actions. S6 consumes this recorder and replay contract in Studio.
- [ ] Commit as `feat(training): record scenarios and versioned demonstrations`.

### T3: behavior cloning, recurrent PPO and resumable runs

Files: create `tool/zyren_train/src/zyren_train/{train,checkpoint,curriculum,rewards,run_manifest}.py`,
`src/zyren_train/policies/{structured,masked_recurrent,cloning}.py`,
`configs/{guard-structured,vehicle-structured,cpu-smoke}.yaml`,
`tests/{test_training,test_reward_exploits,test_resume,test_action_distribution}.py`.

Interfaces: trainer registry `train(TrainingConfig, WorkerPool, RunDirectory)`;
`TrainingConfig` pins scenario splits, network, optimizer, seed, observation/action
schema, rewards, budgets and evaluation schedule; `TrainingCheckpoint` restores
optimizer, model, RNG, normalization and curriculum. Run state is append-only
receipts plus atomic checkpoint files.

- [ ] Start with the structured network `schema-sized input -> MLP(128,128) -> LSTM(128) -> action heads`. Compute input width from the generated schema. Unit-test sequence masks, episode resets, behavior-cloning loss and a short PPO update through the real environment.

```yaml
schema_version: 1
seed: 7
device: cpu
algorithm: recurrent_ppo
network:
  hidden_sizes: [128, 128]
  lstm_hidden_size: 128
rollout:
  environments: 8
  steps: 128
checkpoint_every_steps: 10000
```

- [ ] Define trainer action spaces explicitly. Character v1 uses MultiDiscrete `[5,5,5,3,2,2]` for local move X/Z, yaw/pitch bins, jump and interact. Vehicle v1 uses Box for steer/throttle/brake; brake wins when both pedals are requested. Physical mapping belongs to the shared `ActionSpec`. Gear changes are initially controller-owned. Do not assume stock recurrent PPO supports mixed continuous/discrete heads or legality masking.
- [ ] Implement the masked recurrent distribution adapter only for the discrete policy. Apply identical masks before sampling, log-probability and entropy during training/export; guarantee one legal fallback per branch. Keep vehicle output continuous with the same deterministic validation in training and play. Test all-but-fallback-masked cases and stale masks at execution.

```python
masked_logits = logits.masked_fill(~legal_mask, torch.finfo(logits.dtype).min)
distribution = torch.distributions.Categorical(logits=masked_logits)
action = distribution.sample()
assert legal_mask.gather(-1, action.unsqueeze(-1)).all()
```

- [ ] Train behavior cloning from T2, then recurrent PPO with curriculum stages: empty arena, static obstacles, occlusion, moving hazards and task combinations. Rewards are registered terms with caps; count success/collision/progress outside reward. Run `uv run pytest tests/test_training.py tests/test_reward_exploits.py tests/test_resume.py tests/test_action_distribution.py` and a CPU smoke run. No policy-quality claim follows from a smoke run.
- [ ] Save/resume a real training run after stopping the worker supervisor. Resume either restores a compatible environment snapshot or explicitly resets environments/recurrent state at a recorded boundary. Test that optimizer and training steps continue, and record whether numerical reproducibility was preserved.
- [ ] Commit as `feat(training): train resumable character and vehicle policies` once the CLI and worker run receipts agree on completed/failed/cancelled states. S6 consumes those receipts directly.

### T4: held-out evaluation and policy acceptance

Files: create `tool/zyren_train/src/zyren_train/{evaluate,metrics,confidence,regression,report}.py`,
`configs/evaluation.yaml`, `tests/{test_evaluation,test_leakage,test_metrics}.py`,
`examples/game_lab/game/evaluation/{guard,vehicle,occlusion,recovery}.json`.

Interfaces: `EvaluationPlan`, `evaluate(model_bundle, plan)` and
`EvaluationReport`; reports pin game/model/schema/provider versions and every
episode seed. Test partitions stay immutable after they are selected. A changed
test suite gets a new identity and does not silently replace earlier evidence.

- [ ] Test no train/test overlap, incomplete runs, missing metrics, denominator errors, failed workers and selection bias from excluding bad episodes. Reward and task success are separate metrics.

```python
assert report.completed + report.failed + report.cancelled == report.requested
assert report.success_denominator == report.requested
assert report.model_hash == bundle.model_hash
if report.failed:
    assert report.status != "passed"
```

- [ ] Implement baseline comparisons and at least 200 held-out episodes per scenario family across at least 20 level/layout seeds for the first quality gate. Report Wilson 95% intervals for success/collision rates. Keep a fixed seed list in the evaluation manifest.
- [ ] Initial quality targets: guard task success >=90%; vehicle route success >=95% with collisions in <=2% of requested episodes; zero hidden-state leakage failures in the paired-world suite; no repeatable reward exploit. Require success-rate lower confidence bounds >=85%/90% respectively. These are targets; record failures and tune training, not the test set.

```python
passed = (
    guard.success_rate >= 0.90
    and guard.success_lower95 >= 0.85
    and hidden_state_leaks == 0
    and worker_failures == 0
)
```

- [ ] Evaluate unfamiliar maps, target speeds, obstacle layouts, friction, delayed sensors, missed decisions and fallback recovery. Include variants requiring memory after losing sight. Report exactly which task distributions were tested; do not infer general human-like intelligence.
- [ ] Commit as `feat(training): qualify policies on held-out game scenarios` with small deterministic metric fixtures; keep large run outputs outside Git.

### T5: export, quantization and native parity

Files: create `tool/zyren_train/src/zyren_train/{export,bundle,quantize,parity}.py`,
`schemas/model-bundle-v1.json`, `tests/{test_export,test_bundle,test_parity}.py`,
`scripts/export_probe.py` from A1, and sequence fixtures consumed by
`packages/zyren_ml/test/native_inference_test.dart` and A5's policy tests.

Interfaces: `export_actor(checkpoint, output_dir)`, `ModelBundleManifest`,
`compare_sequence`, `quantize_candidate`; artifact files include actor ONNX,
observation/action schemas, normalization, recurrent-state layout, manifest,
license/provenance and evaluation receipt. Hash every file and reject extras.
`ModelBundleManifest` describes the policy files and their semantics; it is not
a new archive format. Python exports a validated directory. The G7/S6 host adapter
imports it as Pipeline resources and uses the existing bundle builder, limits,
cache and offline resolver. Reuse Pipeline archive validation for shipped bundles;
Python validates its own export paths and model manifest.

- [ ] Test actor-only export, dynamic batch bounds, reset/carry state, tensor ordering, missing normalization, incompatible controllers and export path traversal. Exercise malformed archives through the existing Pipeline importer in G7/S6. Compare at least 1,000 recorded recurrent steps with Python/native float inference.

```python
np.testing.assert_allclose(native_action, torch_action, atol=1e-5, rtol=1e-4)
np.testing.assert_allclose(native_hidden, torch_hidden, atol=1e-5, rtol=1e-4)
assert "optimizer" not in bundle.files
assert "critic" not in bundle.output_names
```

- [ ] Run export/parity tests first on A1's recurrent probe, then on the actual trained policies. Fail on an unsupported operator instead of substituting a different model architecture without a new schema/artifact.
- [ ] Export single-step inference with explicit recurrent inputs/outputs; keep action masks and preprocessing identical to T3. Use ONNX shape inference/checking and native load before publishing the local bundle. Try int8 or float16 only as separately identified candidates, calibrating exclusively from training data.
- [ ] Re-run T4 on each candidate and require no more than two percentage points success loss against the accepted float model, no increase beyond collision limits and no new leakage/invalid-action failures. Measure app binary, model and working-memory deltas separately.
- [ ] Load the bundle through the real runtime importer, reject a tampered copy and repeat native parity/gameplay checks offline. S6 supplies Studio import/activation and Q1 verifies the full editor/export workflow.
- [ ] Commit as `feat(training): export evaluated native policy bundles`.

### T6: camera learning, multi-agent tasks and run scaling

Files: create `tool/zyren_train/src/zyren_train/{pettingzoo_env,self_play,opponents,distill,runner}.py`,
`src/zyren_train/policies/visual.py`,
`configs/{guard-visual,vehicle-visual,cooperative,competitive}.yaml`,
`tests/{test_multi_agent,test_visual_inputs,test_opponent_pool}.py`.

Interfaces: `ZyrenParallelEnv` implements PettingZoo's parallel API;
`OpponentPool` pins policies and sampling weights; `RunnerBackend` has
local-process and explicitly configured remote implementations;
`VisualPolicy` combines a small CNN, body/goal features and LSTM.

- [ ] Test per-agent done/truncated/reset state, agents entering/leaving, dead-agent actions, centralized training-only data exclusion and opponent-version pinning. Run the API checker against the actual worker adapter.

```python
from pettingzoo.test import parallel_api_test
parallel_api_test(env, num_cycles=1000)
assert set(actor_inputs).isdisjoint(training_only_fields)
```

- [ ] Train real 84x84 camera profiles from A6 with randomized textures, lighting and camera noise. Record RGB-only, depth-only and combined results separately. A structured teacher can provide actions for distillation, but held-out inputs and privileged labels cannot enter the student's observation tensors.
- [ ] Train a cooperative search task with limited team messages and a competitive pursuit task with frozen opponent checkpoints. Use a bounded historical opponent pool; evaluate against fixed baselines and withheld opponents to detect cycling or overfitting.
- [ ] Profile worker count, GPU camera contention and learner utilization. Scale local runs within explicit CPU/GPU/memory/disk budgets, then implement resumable remote execution through the same artifact/protocol contract only when a runner is configured. A native-rendered visual environment cannot be replaced by Python-generated images.
- [ ] Run T4/T5 acceptance and parity for each visual/multi-agent artifact. Benchmark the counts/cadences in the design and publish actual supported profiles through Q4.
- [ ] Commit as `feat(training): train visual and multi-agent game policies`.

## Training acceptance record

Every run records configuration hash, game/native build, dependency lock, seed,
training duration, environment throughput, learner throughput, episode outcomes,
checkpoint lineage and known interruptions. Every accepted model links to a full
held-out evaluation and native export receipt. A learning curve alone is not an
accepted game brain.

The first resource estimate follows T1's 10,000-step benchmark and T3's short
learning run. Budget arithmetic is explicit: requested environment steps divided
by measured aggregate steps/sec, plus learner/evaluation overhead and an observed
convergence range. Do not promise a fixed training cost before those measurements.
