# Multi-agent TRAIN inputs

You can replay all 48 recordings with the frozen worker named in `corpus-v3/recording-plan.json`. `record_corpus.py` uses the existing native parallel environment and demonstration recorder. It records TRAIN only, then replays both typed controllers, observations, reward and terminal flags before any optimization.

The corpus contains 12 cooperative joint-teacher episodes and 12 episodes for each competitive source: joint teacher, stationary pursuer and stationary evader. All 12,150 native steps replayed exactly. Contacts were zero, and the worker exited with code 0. These are teacher traces, not learned quality evidence.

Competitive learner labels contain 24 sequences per role: 5,011 pursuer rows and 7,656 evader rows. The joint teacher won 11 of 12 pursuit episodes as the pursuer; the two stationary-opponent sources preserve successful examples for both roles. Cooperative labels contain 12 sequences and 2,339 rows per actor.

`optimization-plan.json` pins the approved schedule, source bytes, corpus manifests and separately frozen worker libraries. `prepare_training.py` validates those inputs and writes the four configs. The earlier plan draft is retained because fixed comparison-controller pins were added before optimization. It has no execution claim.

The two withheld competitive actors use optimizer seeds 2001 and 2003, four or six cloning epochs and 256 native PPO steps. Their completed weights must be frozen without DEV selection and excluded from student training and the historical pool. Main cooperative training is 16 cloning epochs plus 8,192 native steps. Main competitive training is 16 epochs plus 16,384 native steps, with distinct historical actors from epochs 4, 8, 12 and 16. Every run keeps its optimizer, RNG, source and checkpoint receipts.

DEV selection uses only the recorded candidate schedule and seeds 30000 through 30019. Final TEST is blocked until candidate bytes, opponent bytes and the exact evaluation plan are frozen. None of the data here establishes an accepted multi-agent model.

The traces and comparison controllers were authored in this repository. No external recordings, downloaded weights or paid infrastructure were used. Model provenance retains `LicenseRef-Repository-Authored`; native dependency licenses remain with their existing packages.
