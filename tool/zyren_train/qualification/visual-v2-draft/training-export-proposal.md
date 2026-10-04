# Guard-combined v2 training proposal

Native course feasibility must pass first. No optimization is authorized by this proposal, and no v2 model or evaluation plan is registered. The six guard/vehicle RGB, depth and combined obligations remain required.

## Actual inputs and supervision

Use the existing A6 capture pool, training protocol, gzip DemonstrationRecorder, DatasetManifest, split checks and replay. Collect seven TRAIN courses, seeds 7 through 13, at most 600 simulation steps each. Keep one supervised example per actual cadence capture, at most 121 captures per course. Cap the cohort at 512MiB, including receipts. Preserve full episode order and captured own-pose provenance.

Student input is exactly the native profile's CHW camera tensor plus body10. It contains no target pose, route cursor, map coordinates, teacher actions or privileged observation. The teacher may read actual native pixels/depth and TRAIN geometry solely to create visible-object supervision and check geometric error. An invisible target must produce an unknown label, never a new hidden target position. Runtime belief retains an earlier permitted measurement independently of the network.

The existing first raster oracle labels target position, confidence and sector clearance but leaves obstacle slots unknown. That is insufficient for the complete visual obligation. Before learning, add actual-capture supervision for visible blue obstacles, with masks that reject clipped or ambiguous contours and uncertainty covering unobserved extent. Prove initial cue and obstacle class dependence on real captures. Moving-hazard, unknown-ground and stopping-distance cases must then be represented in TRAIN data; the present static course alone cannot qualify them.

Record proposed estimates as 74 values and actual applied native controls as six values. The existing recorder supports distinct fixed widths and stores the observation before its proposed action. Pin both schema hashes in recording settings, the capture cadence/start tick, profile/map/controller hashes and teacher version. Derive capture alignment from the authoritative input tick and reject inconsistent repeated frames. Deduplicate only for perception supervision; retain every native control step for exact replay.

## First bounded experiment, subject to approval

Reuse the existing spatial CNN encoder and LSTM128. The combined encoder has convolution widths 8/16/32, a spatial flatten projection to 96 values, and a body10 projection to 32 values. A 74-value estimate head gives 301890 trainable actor parameters. Keep the model below 8MiB. Use bounded output transforms for the exact estimate ABI, explicit hidden/cell inputs and outputs, and separate actor state per episode.

Proposed limit: ten supervised epochs over the seven TRAIN episodes, Adam at 1e-4, gradient norm .5, one complete episode per update. Carry hidden state across every capture of that episode and reset only at its start. Batch CNN feature extraction in at most 32 frames, while retaining one full episode's recurrent graph. Measure the graph's peak memory before the full run; stop above 1GiB process growth or the cohort disk limit. No PPO and no warm start from v1 control weights.

Balance loss by estimand group, not the count of scalar heads. Visible target position uses metre-space Huber loss; visibility and confidence use classification loss. Known clearance uses metre-space loss with a stronger penalty on overestimating free range. Obstacle geometry is masked by native visibility, with uncertainty and confidence trained separately. Report each head group, including velocity heads and empty-slot false positives. Constant absent slots cannot count as successful learning.

Use five DEV seeds, 2007 through 2011, excluded from final TEST. Inspect at most five checkpoints (epochs 2, 4, 6, 8 and 10), for 25 closed-loop DEV episodes total. Select once with the predeclared success/contact/unknown-stop ordering. Then run one selected-model diagnostic with cue and hazard ablations plus the paired hidden history. Do not choose a new cohort, threshold or seed set from final TEST feedback.

## Estimand diagnostics and retained gates

Proposed DEV diagnostics are visible target position RMSE <=.15m and p95 <=.30m, admitted visibility precision >=.99, and at least .95 coverage by the emitted two-sigma position bound. Clearance must not overstate true safe free range by more than .05m at p99, and obstacle bounds must conservatively cover at least .95 of admitted visible extents. These are proposed diagnostic thresholds. They neither replace nor relax the original episode gates.

Report closed-loop legal-course completion, contacts, stopped/scan time, first divergence and uncertainty expiry. Cue ablation must remove goal acquisition; obstacle/clearance ablation must change admission or safe navigation in paired actual camera scenes. Identical permitted hidden histories must preserve estimates, beliefs and controls.

Final qualification still requires the original 200 episodes per family, 20 seeds, eight stress cases, guard .90 success/Wilson .85, vehicle .95/Wilson .90, colliding-episode rate <=.02, actual ONNX evaluation and 1000 typed native continuations with fixed atol1e-5/rtol1e-4 and zero native owners afterward. Fresh final seeds and geometry must be locked before any final evaluation. No v1 receipt qualifies a v2 artifact.

## Runtime and export seams to complete before a budget

The current ActionDecoder produces character or vehicle intents. It cannot safely represent a 74-value estimate. Add a bounded validated-record decoder seam through the existing PolicyContract, PolicyBrain, DecisionScheduler and PolicyState, with VisualEstimate projection validation before action and hidden-state commit. Reuse MlScheduler and model cache. Do not add another inference scheduler or history mechanism. The host invalidates pending work when map, camera or ownership epochs change and passes accepted exact-due estimates to VisualGoalController.

The approved v2 draft has observation, episode_start and rank-three hidden_h/hidden_c inputs, followed by estimate and corresponding hidden outputs. Existing v1 export_actor uses rank-two hidden/cell and no episode_start; it must not silently emit the wrong v2 ABI. PolicyContract also rejects extra non-recurrent inputs today, so the shared runtime needs an explicit bounded episode_start binding rather than arbitrary extra tensors. An additive v2 actor-step export wrapper can reuse ONNX checking, CPU ORT, checkpoint pins, native parity sidecars and bundle publication. Normalization keeps camera identity and fits body10 on verified TRAIN sources only.

The shared artifact reader and GameLevelAi runtime currently admit v1 families. Coordinate their additive v2 profile/plan/estimate branches with A1. Preserve all structured, int8 and visual-v1 readers. Studio must use the same reader and actual actor footprint checks. Until those seams and the native course pass, the model is a candidate with accepted=false.

Safe source work while physics is pending is the new v2 typed config/label loader, bounded supervised network, estimand metrics and exporter wrapper tests. Existing recorder, trainer, multi export, runtime and artifact files need ownership handoff before edits. No executable freeze or learning run is part of that work.
