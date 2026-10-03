# Guard and vehicle policy qualification

You can inspect the exact training inputs, final checkpoints and evaluation receipts here. These are locally trained repository assets. No weights were downloaded, and no cloud or GPU training ran.

`training/guard` contains the guard config, checkpoint pointer, final checkpoint and append-only run receipts. `training/vehicle` contains the vehicle equivalents. The guard run used four authored controller traces, 100 cloning epochs and 128 PPO steps. The vehicle run used 12 scripted native-controller demonstrations across obstacle and hazard stages, then the same cloning and PPO counts. Recorded input traces are not physical device qualification.

`sources.json` maps the historical absolute paths in the exact config bytes to the copied `demonstrations` directories. We preserve the config hash rather than rewriting a completed run. Export can read these checkpoints with their saved configs and the matching native schema info in `../../tests/fixtures/policy-schemas.json`. A new training run must resolve the copied sources, pin its own prepared executable and write a new config hash.

The original evaluation plan is `original-plan.json`, SHA `70293bb2509acec9f3626a87423f5a077d496e75cad3dc734f6fff853af763c4`. Its frozen executable was overwritten during the sequence-probe rebuild. We could not recover matching executable bytes. The original receipts remain here.

`revised-plan.json`, SHA `deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd`, explicitly supersedes that plan. Cases, seeds, partitions and thresholds are byte-canonical identical. Only the worker artifact pins and revision metadata differ. Both Torch and exported ONNX repeated all 400 cases under the revised plan. The integrity receipts show unchanged executable and library hashes before and after each run.

Both families passed 200/200 episodes, with no collisions, worker failures, invalid actions, hidden-state leakage or detected reward exploit. Their Wilson lower success bounds are 98.115%. The guard target remains 90% success with an 85% lower bound. The vehicle target remains 95% success with a 90% lower bound and at most 2% collisions. No threshold was relaxed.

The ONNX quality run used Python ONNX Runtime 1.23.2 CPU inference and the actual native Rapier, character and ray-wheel vehicle task adapters. `guard-parity.json` and `vehicle-parity.json` separately record 1,000 steps through the Dart/native ML C ABI and shared typed controller decoder, including fresh guard masks, pedal priority and recurrent reset/carry. Native sessions and results return to zero. The earlier recurrent probe was checked first.

The parity executable is pinned separately from the evaluation executable. Its renderer library changed during concurrent renderer work, but neither qualification path creates a renderer. ML, ONNX Runtime and physics library pins are recorded. These receipts do not qualify GPU rendering, mobile devices, physical controllers or policy performance outside the selected distributions.

The int8 QDQ trial calibrated 1,000 verified training steps per policy. It repeated the same 400-case plan with 200/200 successes per family and no collisions, for zero percentage-point loss against float. Native int8 parity also passed 1,000 typed steps per family. Guard model bytes fell from 616,135 to 185,262; vehicle bytes fell from 604,425 to 182,480. App binary and working-memory deltas were not measured and remain null.

`failed-checkpoint-evaluation-v3.json` retains the earlier vehicle collision failure. `passed-checkpoint-evaluation-v4.json` records the later float checkpoint result against the original plan. Neither is an evaluation receipt for an exported ONNX hash.

The frozen executables and copied platform libraries are local qualification artifacts, not source-controlled binaries. Rebuilding produces a new artifact identity. You must select and lock a new plan revision before claiming new evaluation evidence. Root-owned GameLab policy resources live in `examples/game_lab/models`; their bundle and evaluation hashes identify the accepted exports.
