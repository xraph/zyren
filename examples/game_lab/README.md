# Zyren Game Lab

You can play the authored exploration and vehicle examples in a standalone native
Flutter app. Pick a game and press Play. Use WASD to move, Space to jump and E to
interact. E returns you to the character when you are driving. The overlay also
provides touch controls through `flutter_zyren_game`.

The app reads the committed `games/*.zygame` Pipeline bundles. Its runtime does
not import Studio or start Python, a model server or a network asset loader.
The editable source documents are in `projects/`. Open those documents in Studio
to change components, rules, prefabs or geometry, then export a new bundle.

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
  packages/zyren_game_studio/tool/export_game_lab.dart examples/game_lab
```

`training_worker/` provides the separate native training process and its authored
character fixture. See its README and `tool/zyren_train` for recording, training
and evaluation commands. A passing runtime or rendering check does not establish
policy quality. Trained model receipts and device qualification are recorded
separately.
