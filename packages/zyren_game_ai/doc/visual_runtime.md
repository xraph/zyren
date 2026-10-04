# Visual policies in native play

You can author `cameraMode: rgb`, `depth` or `combined` on `game.ai`. Leave it absent to keep the structured profile. `profile: guard` still selects the character controller; `profile: vehicle` still selects the vehicle controller. Visual model families include the mode, for example `guard-visual-depth`.

Use `TrainingVisualProfiles.forFamily` for training and deployment. It pins the 84x84 camera, +Z forward, +Y up, actor offset, field of view, clip distances and normalized CHW layout. The eight trailing body values are captured local velocity XYZ, world angular velocity Y, height, forward goal 1, lateral goal 0 and validity 1. Target transforms are not part of this input. The model embeds TRAIN-derived body normalization. You supply raw body values once.

`GameLevelAi` takes `openCameraBackend(actor, profile)` and owns the returned backend through its A6 `CameraSensor`. GameLab and Studio use `NativeBackend.create()` for these dedicated readback backends. The main scene and presentation renderer remain host-owned.

The default `GameVisualRuntimeLimits` admit four camera owners and two capture jobs, with a global 2 MiB output-payload budget and a 16 ms capture-plus-inference deadline. The payload budget covers requested RGBA/depth output bytes, not physical GPU residency, backend allocations or all temporary Dart copies. Camera owners also count while retired generations drain. Keep these limits small until you have measured your scene and target device.

Each request snapshots the scene, actor pose and body state during the authoritative sensors phase after physics. A completed capture must still match its actor generation, episode, tick, world revision, game epoch and control generation. Late captures stay unknown. Unsupported outputs stay unavailable. Pending captures keep their admission slot until the real render completes, including after cancellation.

Visible play keeps its fixed clock. `flush()` is for a host that can await work between ticks, including native tests and offline workers. Pause clears pixels and queued actions; checkpoint preparation drains capture and inference before saving committed recurrent state. Restore creates fresh handles and checks the authored camera mode. `cameraObservation(actor)` exposes only the last completed permitted pixels and clears on pause, restore or retirement.

The native integration tests use an authored deterministic ONNX probe. They verify actual Metal depth pixels, the flat camera/body tensor, due-tick recurrent action, deadline rejection and native close/drain. They do not qualify a learned visual policy or the default 16 ms capacity on a production scene. Visual artifacts still need their exact registered held-out plan, accepted ONNX evaluation and typed native parity before import or activation.
