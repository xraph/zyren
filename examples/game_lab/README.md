# Zyren Game Lab

You can play the authored exploration and vehicle examples in a standalone native
Flutter app. Pick a game and press Play. Use WASD to move, Space to jump and E to
interact. E returns you to the character when you are driving. The overlay also
provides touch controls through `flutter_zyren_game`.

The app reads the committed `games/*.zygame` Pipeline bundles. Its runtime does
not import Studio or start Python, a model server or a network asset loader.
The editable source documents are in `projects/`. Open those documents in Studio
to change components, rules, prefabs or geometry, then export a new bundle.

Exploration includes a trained guard, an occlusion wall and audible footsteps.
The vehicle playground adds a trained driver and a moving obstacle. The HUD
shows completed learned decisions and fallback ticks. Save pauses the game and
drains pending model work before capturing physics, gameplay and committed brain
state. Restore replaces entity generations and stays paused until you resume.

Both models run at their evaluated 50 Hz simulation rate. Each actor owns its
hidden/cell state while the native cache shares immutable model weights. The
authored hybrid controller can use the scripted baseline when a required sensor
is unavailable. Masked observations behind an occluder remain valid model input.
These are small structured policies, not dialogue or RGB camera models.

From this directory:

```sh
fvm flutter pub get
fvm flutter run -d macos
```

To regenerate the reference documents and bundles from the templates, run this
from the repository root. It replaces the generated reference files, so retain
any authored changes separately first.

```sh
fvm dart --packages=.dart_tool/package_config.json \
  packages/zyren_game_studio/tool/export_game_lab.dart \
  examples/game_lab examples/game_lab/models
```

Omit the final argument only when you want to generate scripted reference games.
The accepted directories in [models](models/README.md) each contain nine files.
The exporter verifies their hashes, evaluation and controller schema before
passing them to Pipeline. The generated document retains the model asset pin.
When opening it in a new Studio cache, import the same accepted model directory
before play or export so the host can resolve that pin.

Run the host, native policy and checkpoint checks with:

```sh
fvm flutter test --no-pub --concurrency=1
```

The trained-runtime tests execute native physics and ONNX inference against the
committed offline bundles. Their clock fixture does not render and supplies no
GPU, input-device or frame-budget evidence. Actual rendered qualification remains
separate from those tests.

Use [the device benchmark runner](BENCHMARKS.md) for native lifecycle checks and
sustained capacity measurements. It keeps the 50 Hz reference policies separate
from the proposed larger loads and retains failed receipts.

`training_worker/` provides the separate native training process and its authored
character fixture. See its README and `tool/zyren_train` for recording, training
and evaluation commands. A passing runtime or rendering check does not establish
policy quality. Trained model receipts and device qualification are recorded
separately.
