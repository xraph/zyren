# Native multi-agent course audit

These are TRAIN and development pilots. No held-out quality slot was used, and no trained model is accepted.

`occluded-pursuit-1.json` retained the wall-blocked course. Cooperative teachers reached the joint goal, but the pursuer stopped after losing sight. `occluded-pursuit-memory-2.json` added permitted historical sightings; it still failed pursuit and produced solid contacts. Both failed pilot records remain here.

The final course uses an open bounded competitive arena and keeps the wall, delayed messages and occluded teammate in cooperative search. `open-arena-train-dev.json` records 36 actual Rapier episodes across three seeds and two partitions. Cooperative teachers won all six joint episodes, while stationary teams lost all six. Pursuit against a stationary evader captured in every pilot. Legal evaders survived against stationary pursuers. Teacher cross-play produced one pursuer win and two evader wins in each partition, with zero solid contacts across the final pilot.

You get exclusive win/draw/loss outcomes. A legal capture credits the pursuer alone; an eight-second timeout credits the evader only while both actors remain inside the physical arena. Floor contacts do not fail the collision audit. Wall contacts and actual capsule penetration do. Shaped distance rewards do not define success.

The exact source is multi_agent_scenario.dart and multi_audit.dart. Run `fvm dart run bin/multi_audit.dart` from examples/game_lab/training_worker to repeat the TRAIN/development audit. Seven focused native tests passed before this checkpoint, including guest activation and retirement of physical control. The immutable final evaluation plan and independently frozen withheld policies are still pending.
