# Measure Game Lab on a native device

Start with the short lifecycle check from the repository root:

```sh
python3 tool/qualification/run_game_ai.py \
  --device YOUR_FLUTTER_DEVICE_ID --profile reference-guard --smoke
```

You get the Flutter driver log, the native receipt and a summary under
`build/qualification/game-ai/`. Supply a new `--output` directory to keep a
named run. The runner refuses to overwrite an existing receipt.

The smoke check warms the host for three seconds and measures ten seconds. It
requires real native presentation, active inference and cleanup after camera
movement, a pooled actor, pause/resume and renderer recreation. Its receipt
deliberately fails the duration gate. It cannot qualify a capacity profile.

Remove `--smoke` for qualification. The runner builds in profile mode, warms the
host for thirty seconds, then measures three ten-minute repetitions. You can
select `--mode release` where the Flutter driver supports that target. Debug
measurements do not pass. Emulators and browser targets are rejected.

## Loads and policy identity

The accepted structured reference games use 50 Hz simulation and policy
decisions. Use `reference-guard` for exploration or `reference-vehicle` for the
vehicle playground. The runner selects the matching exported asset.

The four proposed capacity profiles remain separate: mobile structured uses
32 guards at 10 Hz and four vehicles at 20 Hz; desktop structured uses 128 and
16. The visual profiles use four or sixteen 84x84 cameras at 10 Hz. All four
require a 60 Hz compiled game and policies evaluated at those exact rates.
The existing 50 Hz reference bundle rejects those profiles. Changing its label
or simulation rate cannot establish compatibility.

`--asset` selects another asset registered in the Game Lab manifest. The host
verifies the exported recipe, accepted model resources, controller schemas,
cadences and actor counts before measuring. Regenerate
`tool/qualification/game_ai_profiles.json` from the Dart constants when you
change a profile:

```sh
fvm dart examples/game_lab/tool/benchmark_profiles.dart \
  > tool/qualification/game_ai_profiles.json
```

## What the receipt measures

The native frame sample begins at the first scene preparation hook and ends
when the platform presenter accepts the frame. Presentation intervals and
Flutter `FrameTiming.totalSpan` are recorded separately. None of these measures
physical display scanout. The full fixed-step CPU sample includes mutations,
controllers, physics, perception and state observers before timing delivery.
That is a conservative application of the game/perception scheduling budget.

Every expected decision settles once as completed or missed. The host reads
actual policy receipts, rejected output counters, fallback ticks and scripted
ticks. A late accepted action fails. Scripted fallback does not count as a
completed learned decision.

The host verifies every declared NPC has a live native brain with its exact
accepted contract after warmup and renderer recreation. Hybrid load failure
cannot reduce the measured actor count. A missing current observation still
owes its scheduled decision. The recorder also requires sustained simulation,
decision and inference counts at the declared rates, so a paused simulation
cannot pass by presenting its last frame.

Raw samples remain in the receipt, with p50, p95 and p99 summaries. We record
the actual native output dimensions and frame count at each size, plus renderer
CPU build and submission times. GPU time remains null when the renderer does not
provide it. These output dimensions describe the displayed scene; the 84x84
sensor images have their own profile. Compare timing only at matching output
sizes, load and device conditions. All three repetitions must share the recorded
source, game, model, device and output-size identities to qualify together. A
sustained run must keep one output size throughout measurement; mixed-size smoke
runs remain diagnostic only.

We record
model bytes, peak process RSS, queued/in-flight tensor bytes and recurrent state
bytes separately. Native allocator arenas, physical GPU residency, power,
thermal state and application-size delta remain null unless measured. The model
file's size is not the process memory cost.

Cleanup compares native renderer, presentation, ML and Rapier owners with the
pre-run baseline. The host allows ten seconds for asynchronous native retirement.
An absent counter cannot pass cleanup. Renderer recreation closes the old world
and restores a checkpoint into a fresh native host, then resumes actual play.

Keep failed runs. A build failure, unsupported policy cadence, missing platform
presenter or missed frame budget remains visible in `summary.json`. Passing a
short integration run establishes its lifecycle checks only; it does not
establish ten-minute performance or the larger design profiles.

## Platform setup

Game Lab selects the existing Metal view presenter on macOS/iOS and the Vulkan
surface presenter on Android. Its Android host requires API29; the standalone
ML plugin requires API24. The iOS host and workspace hook declaration use iOS16.
Apple device installation also needs a valid signing identity and provisioning
profile. Simulator ML execution remains separate from physical device evidence.
