# Native plugin qualification, 2026-10-01

Qualification remains partial. You can use the recorded macOS checks to assess
the tested source snapshots. Android and iOS builds do not establish runtime
support, and the native narrow-window visual check remains blocked.

## Source and tooling

All work ran in the shared checkout on `main`. The other chats committed and
edited source throughout this session. `results.json` records each command's
starting and ending commit, source digest, dirty paths and changed source paths.
A passing run with source changes is provisional. Even an unchanged source
snapshot can contain uncommitted work; its result does not qualify HEAD alone.

The workspace pins Flutter 3.47.5 with Dart 3.13.4. The default `flutter` command
resolved to 3.35.7, so qualification used the pinned SDK directly. Rust's package
toolchain is 1.97.1. Xcode 27.0, Android SDK 36.1, JDK 25 and Android NDKs are
installed. No toolchains or signing settings were changed.

The renderer enables Metal, Vulkan and DX12 in
`packages/zyren_native/native/Cargo.toml` and `native/src/renderer.rs`.
`packages/flutter_zyren/pubspec.yaml` registers presentation plugins for Android,
iOS and macOS. It has no Windows or Linux registration. The workbench selects
Android's native runtime or Apple's Metal runtime and requires native
presentation. A Windows or Linux runner directory does not supply that missing
presentation integration.

## Checks and limits

| Area | Evidence | Remaining limit |
| --- | --- | --- |
| Metal outlines | Six serialized native tests cover both depth strategies, coverage, clipping, materials, mask resize and independent views, resource round trips, scoped cleanup and worker finalization. | macOS only; exact snapshots are in `results.json`. |
| Effects | Eight tests pass from `packages/zyren_effects`, including native blur, Hald grading and source dithering comparisons. | Other platforms remain untested. |
| Plugin suites | Native-enabled combined run passes all 151 tests, including GPU inspection and CLI/MCP process tests, on an unchanged source snapshot at `5bc6f00`. | Later edits need their own checks. |
| Timeline and markers | Native macOS runs exercise authored mixing, playback, markers and disposal with zero readbacks. | Source stability is recorded per run. |
| Native editing | Final isolated macOS run passes selection, outline selection, gizmo edits, undo, scrub, playback and disposal, with 30 samples, 14 draws and zero readbacks on an unchanged source snapshot. | Dirty source is recorded separately from the starting commit. |
| Native review | Latest isolated macOS run passes annotation rendering, application-support save, fresh-scene reload and controller disposal, with 12 samples and zero readbacks. Only an unrelated effects test changed during that run. | This verifies local persistence, not the new remote store integration. |
| Widget layouts | Workbench timeline tests pass at 1100, 390 and 320 logical pixels, alongside workbench/review/section tests. | The wider widget run fails the image-demo test described below. Widget metrics do not prove an OS window resize. |
| Android | Android arm64 debug APK builds. SDK, NDK, JDK and Rust Android targets are installed. `adb devices -l` reports no device. | No Vulkan device smoke, visual, persistence or disposal qualification. |
| iOS simulator | Debug simulator builds pass without signing. An installed iOS 26.5 simulator boots but stalls during initial migration; install/launch does not finish. The simulator was shut down after the attempt. | No simulator rendering or layout pass. Xcode also reports that its matching iOS 27 simulator runtime is absent. |
| Physical iOS | A wireless iPhone on iOS 27 and one existing signing identity are available. The existing team signs a device build. | The VM service was not discovered after 75 seconds. The attempt was interrupted after about five minutes. No device test completion was reported. |
| Windows | Flutter rejects `build windows` on this macOS host. | No Windows host or registered Flutter presentation plugin. |
| Linux | Flutter rejects `build linux` on this macOS host. | No Linux host or registered Flutter presentation plugin. |
| Native narrow window | CUA reads the already-running Zyren Timeline Mix window and its rendered assembly. Resize drags at screenshot and logical coordinates, plus the exposed zoom action, leave the window unchanged. | Automation failure. The existing binary's source revision was not established, and no current native narrow-window visual pass is claimed. |

The installed Android emulator offers host OpenGL emulation or software modes.
It was not used as a substitute for a physical native Vulkan qualification.
No browser renderer was used.

## Failures found during the audit

Early runs hit missing `timeline_actions.dart` and `merge.dart` while their
owning chats were creating those files. A later compile failure at
`packages/zyren/lib/src/plugins/engine.dart:96` involved calling `inspectGpu` on
a nullable `RenderBackend`; its owner fixed it. These were shared-edit failures,
not accepted qualification results.

The first parallel native run failed
`packages/zyren_native/test/finalization_test.dart:13`: it expected one live
renderer but saw three. Other suites were creating renderers at the same time.
All six native tests pass with `RUN_NATIVE_GPU=1` and `--concurrency=1`.

The tools audit initially failed
`packages/zyren_tools/test/gizmo_visibility_test.dart:44`, returning
`GizmoPlane.xz` instead of `GizmoAxis.x`. The later combined plugin suite passes
after its owner's changes. The failed run remains in the
evidence history.

The image-demo failure remains reproducible in isolation:
`examples/multiple_views/test/api_examples_test.dart:227` expects one
`Decoding PNG…` label but finds none. You can reproduce it with:

```sh
fvm flutter test examples/multiple_views/test/api_examples_test.dart \
  --plain-name 'image demo keeps its texture on decode failure and retries'
```

Running three macOS integration files in one Flutter invocation passed timeline
but failed to launch the subsequent apps. Running each file in its own Flutter
invocation allowed editing and review to pass. The launch errors were
`The log reader stopped unexpectedly, or never started` and
`Unable to start the app on the device`. Foregrounding also returned an error
even in passing runs, so an automated pass does not establish visible focus.

`flutter test` cannot launch the wirelessly tethered iPhone. Its error recommends
`--publish-port`, which is exposed by `flutter drive`. The dedicated
`examples/multiple_views/test_driver/qualification.dart` uses Flutter's
integration driver for that attempt, with the existing signing configuration.
The drive process returned zero after interruption without running the test.
Its evidence is classified as cancelled, not passed. An exit code alone does
not establish test completion.

## Repeat a check

Use the runner from the repository root. Choose a new output directory for each
run so you retain the earlier evidence. Full logs and file manifests from this
session are local at `/tmp/zyren-qualification-20261001`.

```sh
python3 tool/qualification/run_check.py \
  --output /tmp/zyren-qualification-repeat \
  -- env RUN_NATIVE_GPU=1 fvm dart test --concurrency=1 \
  packages/zyren_native/test/outline_test.dart \
  packages/zyren_native/test/resource_test.dart \
  packages/zyren_native/test/finalization_test.dart
```

The runner's success and failure paths were checked with commands returning
zero and seven. It preserves the exit code, writes the log and JSON evidence,
and hashes tracked and untracked, non-ignored source files. The qualification
driver passes Dart analysis. Reports live outside the ignored `docs` directory.

## Remaining qualification

- Run Android on a connected Vulkan device, including native editing, timeline,
  review persistence and disposal.
- Run iOS after VM discovery works over USB or the installed simulator finishes
  migration. The signed wireless build has not completed a test.
- Supply Windows and Linux native presentation integration and their host
  environments before treating their runners as supported workbench targets.
- Verify the real native workbench at a narrow OS window width. Repair or
  replace the blocked resize automation without substituting widget metrics.
- Resolve the image-demo widget failure in its owning feature area, then rerun
  that test. It was not patched by qualification work.
