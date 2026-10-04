# Multi-agent TRAIN inputs

You can replay all 48 recordings with the frozen worker named in `corpus-v3/recording-plan.json`. `record_corpus.py` uses the existing native parallel environment and demonstration recorder. It records TRAIN only, then replays both typed controllers, observations, reward and terminal flags before any optimization.

The corpus contains 12 cooperative joint-teacher episodes and 12 episodes for each competitive source: joint teacher, stationary pursuer and stationary evader. All 12,150 native steps replayed exactly. Contacts were zero, and the worker exited with code 0. These are teacher traces, not learned quality evidence.

Competitive learner labels contain 24 sequences per role: 5,011 pursuer rows and 7,656 evader rows. The joint teacher won 11 of 12 pursuit episodes as the pursuer; the two stationary-opponent sources preserve successful examples for both roles. Cooperative labels contain 12 sequences and 2,339 rows per actor.

`optimization-plan.json` pins the approved schedule, source bytes, corpus manifests and separately frozen worker libraries. `prepare_training.py` validates those inputs and writes the four configs. The earlier plan draft is retained because fixed comparison-controller pins were added before optimization. It has no execution claim.

The two withheld competitive actors use optimizer seeds 2001 and 2003, four or six cloning epochs and 256 native PPO steps. Their completed weights must be frozen without DEV selection and excluded from student training and the historical pool. Main cooperative training is 16 cloning epochs plus 8,192 native steps. Main competitive training is 16 epochs plus 16,384 native steps, with distinct historical actors from epochs 4, 8, 12 and 16. Every run keeps its optimizer, RNG, source and checkpoint receipts.

DEV selection uses only the recorded candidate schedule and seeds 30000 through 30019. Final TEST is blocked until candidate bytes, opponent bytes and the exact evaluation plan are frozen. None of the data here establishes an accepted multi-agent model.

The traces and comparison controllers were authored in this repository. No external recordings, downloaded weights or paid infrastructure were used. Model provenance retains `LicenseRef-Repository-Authored`; native dependency licenses remain with their existing packages.

## Completed first schedule and DEV selection

Both main runs completed their pinned budgets: cooperative 8,192 native steps and 145 actual updates; competitive 16,384 steps and 286 updates. Their final actor candidates remain under `actors/`. The cooperative PPO actor lost the route behavior learned during cloning. Don't treat completion of training as model quality.

You can inspect all 780 validation episodes in `dev-selection/`. The complete Python source inventory remained unchanged during execution, and the worker exited with code 0. The preregistered selector chose cooperative BC4, which won 20 of 20 joint DEV episodes without contacts, and competitive BC8, which won 40 of 80 slots without contacts. Competitive pursuer wins were 0 of 40; evader wins were 40 of 40. That candidate does not establish readiness for the independent role gates.

`selected-candidates/` contains those exact DEV-selected, unaccepted ONNX actors. `freeze_dev_selected.py` verifies their checkpoint receipt chain and exports the actor without a critic or optimizer. The full original training checkpoints, optimizer/RNG state, historical actors and receipt chains are copied byte-for-byte into `frozen-main/`. The original local run directories remain unchanged.

All these results used worker `1e74c220adce` and its pinned native libraries. A later Rapier repair requires a separate engine pin and exact policy re-evaluation. This evidence does not verify that repaired engine. Final TEST remains untouched while we audit the pursuer's action labels and pressured evasion coverage before freezing any corrective training schedule.

## Cloning order diagnosis

You can inspect `training-diagnostics/pursuer-label-fit.json` for the checked TRAIN label counts and BC8/12/16 predictions. The pursuer learned the stationary-evader source well, but predictions on joint pursuit increasingly collapsed toward that source's constant X action. The original loader visits joint episodes first and stationary-evader episodes last in every epoch. This audit supports testing source-order forgetting; it does not establish that shuffling restores native pursuit.

Set the optional multi-training field `cloning_order` to `seeded-per-epoch-v1` to visit every actor sequence once in a reproducible shuffled order. Existing configs keep their original order and hashes. The local shuffle RNG leaves global RNG state unchanged, and an interruption after sequence 17 of the actual 48-sequence TRAIN corpus resumes with identical model weights, optimizer state and later epoch orders. Corrective optimization remains blocked on the native floor investigation and a separately frozen schedule.

## Pressure teacher audit source

`audit_pressure_coverage.py` prepares 24 TRAIN episodes comparing the original observed-route evader with an audit-only escape controller against the same observed-route pursuer. It reuses the native slot adapter, which requires every applied action to match its proposal before the next actor call. No episodes have been executed with this controller.

The actor receives no route cursor or exact own pose. Its public waypoint bounds and unclipped displacement define a conservative position interval; a direction is admitted only when its projection stays safe for that whole interval. Visible opponent direction uses heading inferred from the last emitted movement, with acceptance checked by the host. Sight loss retains direction only for at most 100 ticks. This is source and pure-test evidence, not a successful native survival teacher.
