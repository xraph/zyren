# Run Planet after device tests

If Planet ignores your taps, drags or trackpad gestures after a test, restore the
normal app from the workspace root:

```sh
python3 tool/qualification/geospatial_stories.py launch --preset tokyo --device macos --provider-config /path/to/private-provider.json
```

Use your connected device ID for Android or iOS. Add `--ios` for an iPhone and
`--flutter /path/to/flutter` if Flutter isn't on your PATH. Your existing signing
configuration still applies. The preset selects the atmosphere or cloud lab;
you can choose the city inside the app.

The command builds `lib/google_tiles_lab.dart` and leaves it running. It uses
Flutter's normal input binding. Device tests use an integration-test binding
that drops physical input by default, even though injected test gestures work.
Keeping that test app installed does not make it interactive.

The `run` command now restores the normal app after qualification, including
failed tests. It saves test evidence before restoring the app, then records the
launch result separately in `interactive-app.json` and `interactive-app.log`.
A successful launch does not certify gesture behavior or change the test result.
If restoration fails, the command exits with an error and you can retry with
`launch` once your device is available.

For a batch of tests, you can pass `--leave-test-app` between runs. Run `launch`
after the last one. If you invoke `flutter drive` directly, you also need to
restore the normal app yourself before handing the device back.

Keep physical input disabled during automated tests so an accidental touch
cannot alter their results. Check real input separately in the normal app:
switch cities, drag the scene, pinch on a phone and scroll on a trackpad. Watch
the camera move; an injected gesture test alone cannot verify this path.

# Live navigation timing

Run the Google cloud lab with the normal Flutter binding in profile mode. You
need the same private provider configuration as the interactive lab. From
`examples/planet`, start a connected native device:

```sh
fvm flutter run --profile -d macos --target=lib/google_navigation_benchmark.dart --vmservice-out-file=/tmp/planet-navigation-vm.json --dart-define-from-file=/path/to/private-provider.json
```

Keep that process attached. From the workspace root, collect a run into an empty
directory:

```sh
fvm dart run tool/qualification/navigation_benchmark.dart /tmp/planet-navigation-vm.json /tmp/planet-navigation-macos-auto auto
```

Use your device ID for Pixel, iPhone or iPad. iOS still uses your signing and
device trust settings. Keep the device unlocked, the app visible and its thermal
state stable. Run devices sequentially so builds do not compete with the Mac's
measurement. Record the source revision, viewport and device with each run.
The collector rejects a run when Flutter reports that the app lost foreground
focus. Give each device to one test at a time. An inactive or interrupted run
can help diagnose a failure, but cannot qualify navigation performance.

Each run waits for live Tokyo tiles and cloud history to settle, then measures
12 seconds each of stationary rendering, orbit, surface drag and wheel zoom.
Motion follows elapsed wall time through the same globe controls used by the
app. These injected inputs measure control and renderer work; they do not
measure touch latency or certify physical gesture handling. Each phase resets
the Tokyo camera and requires rendered geometry at its pivot. Settling also
requires the native upload candidate to be ready. Frame records include upload
backlog and published-cover metadata; selected tile counts alone do not prove
that the replacement has reached the GPU.

`summary.json` contains presentation FPS, nearest-rank median/p95/p99 frame
intervals, stalls, CPU timings and available GPU timings. `frames.json` retains
the individual frames, tile requests, uploads and cloud history. Missing GPU
timings stay null. Presentation FPS measures frames accepted by the native
presenter, not the display's physical scanout. GPU timings cover the backend's
reported submission; they cannot account for every upload or effect graph wait.
The app's current frame cap is recorded in the report.
The collector saves both reports before requesting an optional CPU profile.
That request covers at most the final 30 seconds and times out after 10 seconds;
its recorded window may include loading or settling. A missing CPU profile does
not discard frame results. Check `cpuProfileStatus` and `cpuProfileError` before
using the profile, and keep partial frame results separate from complete phases.
Failed phases retain their available samples and carry `completed: false`.
Do not compare their FPS with a full phase. A new run retries a failed renderer
and resets the Tokyo camera before collecting data.

The `auto` variant keeps device defaults. You can also run `low`, `medium`,
`high`, `shadowsOff` or `sparse` (75% sparsity) to identify cloud costs. These variants change image
quality or content. Keep those tradeoffs explicit when comparing results, and
repeat `auto` after an experiment to check for cache or thermal drift. Different
device defaults and viewport sizes are different workloads.

Add `fixed` as a fourth collector argument for a comparison with stationary
clouds. This disables cloud animation and zeros weather and shape velocities,
so loading time cannot shift the cloud coverage before measurement. Camera
movement and tile streaming still run. The default is `animated`; keep the two
modes separate in reports. Each run records the weather mode, moonlight and
density, and rejects changes to scene settings during collection. Use `medium`
to reproduce the former phone default after Auto changed to Low.

The target uses the normal app binding, so it accepts physical input. Avoid
touching the view during collection. When finished, restore your usual launch
with the `launch` command above.

### Device export without a VM connection

If the VM service cannot connect, build the same profile target with a fresh
`--dart-define=PLANET_NAVIGATION_RUN_ID=ipad-run-1`. The target starts one route
after launch and writes its raw result to
`tmp/planet-navigation/ipad-run-1.json` inside the app container. Optional defines
`PLANET_NAVIGATION_VARIANT` and `PLANET_NAVIGATION_WEATHER` use the same values as
the collector. Reports retain foreground checks, interrupted samples and native
timings. VM CPU samples remain unavailable. Use a new run ID for each build;
existing reports are preserved, and export only publishes a completed file.

On an attached iOS device, retrieve and import it from the repository root:

```sh
xcrun devicectl device copy from --device DEVICE_ID \
  --domain-type appDataContainer --domain-identifier dev.twinos.planet \
  --source tmp/planet-navigation/ipad-run-1.json \
  --destination /tmp/ipad-run-1.json
fvm dart run tool/qualification/import_navigation_report.dart \
  /tmp/ipad-run-1.json /tmp/ipad-run-1
```

The importer requires an empty output directory and produces the same
`frames.json` and `summary.json` as the VM collector. A missing report is an
unmeasured run, not a pass. Remove the autorun define when restoring normal use.
