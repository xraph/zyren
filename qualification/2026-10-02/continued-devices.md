# Completed Pixel checks and Apple launch blockers

You can now repeat the native phone workflow on the Pixel 9 Pro. The layout,
selection, editing, undo, mixed timeline playback, marker delivery and persisted
review checks pass with zero scene pixel readbacks. The tests wait for controller
disposal. Their source digests stayed unchanged during each Android run.

| Check | Result |
| --- | --- |
| Real phone layout, first completed run | Passed at 426.7 by 952 logical pixels; 22 frame-stat samples |
| Native editing and undo | Passed; 34 samples and 14 draws |
| Review save and fresh-scene reload | Passed; annotation pin rendered, 9 samples |
| Phone layout with inspector-position assertion | Passed; 19 samples |
| Focused image decode-failure/retry widget test | Passed; the earlier failure did not reproduce |
| Signed iPad layout profile build | Passed; device runtime remains untested |
| Wireless iPhone layout | Installation blocked by the free developer profile app limit |
| Native macOS narrow window | Unverified after another visual attempt |

## Real layout checks

The shared native layout check keeps the device's actual viewport. It requires
native presentation, selects a hittable inspector row, checks the selection
outline, exercises timeline weights and markers, and waits for disposal. Phones
must be at most 500 logical pixels wide with the inspector below the canvas.
The tablet entry point requires at least 700 logical pixels and places the
inspector beside the canvas. Neither check substitutes a test surface size.

Formatting and Dart analysis pass for both entry points. The phone check passes
on hardware; the tablet entry point has a signed profile build only. From
`examples/multiple_views`, you can repeat the Pixel test with:

```sh
fvm flutter test --no-pub integration_test/qualification_native_layout_test.dart \
  -d <android-device-id>
```

For an unlocked Apple device with a free signing slot, use profile mode over the
existing wireless connection:

```sh
fvm flutter drive --profile --no-pub --driver=test_driver/qualification.dart \
  --target=integration_test/qualification_native_tablet_layout_test.dart \
  --publish-port -d <ipad-device-id>
```

Use `qualification_native_layout_test.dart` as the target on the iPhone.

## Apple device blockers

Xcode displays `Unable to Install Multiple Views` and reports that the iPhone
has reached its maximum number of installed apps using a free developer
profile. Shader Lab, Planet and TwinOS occupy the slots. The qualification
launcher was cancelled without a test result. Its zero exit code is not a pass.
No installed app was removed. Choosing a development app to uninstall is pending
because removal also deletes its local data. The iPhone remains on wireless as
requested.

The iPad is now reachable and has only TwinOS among the inspected development
apps. Apple still reports `passcodeRequired: true`. The signed tablet build is
ready, but its runtime check needs an unlocked device. The Watch is unavailable.

## Native macOS visual attempt

The current workbench builds and launches with its required native Metal path.
The first wide capture shows the assembly, outline and gizmo. Native window
menu commands change the window height, but later captures are black; neither
pixel-coordinate nor logical-coordinate edge dragging establishes a narrow
width. These observations do not establish a renderer defect or a passing
narrow layout check. The qualification launcher was stopped after the attempt.

## Source evidence

`continued-devices.json` records eight commands with source digests, dirty file
hashes, outcomes and local log paths. The four passing Android runs preserve
their source snapshots, starting at `3b9da8d` and `2235296`. Those snapshots
include shared uncommitted work, so the results do not qualify a clean commit.
Sources changed during the cancelled iPhone run, macOS visual attempt and focused
widget test. Full local manifests and logs remain under
`/tmp/zyren-qualification-20261002`.

Windows and Linux native Flutter presentation remain unverified. The earlier
[report](README.md) retains the failed and interrupted attempts that led to this
rerun.
