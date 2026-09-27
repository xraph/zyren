# Scene workbench checkpoint

Run `fvm flutter run -d macos -t lib/scene_workbench.dart` from
`examples/multiple_views`. On Android, replace `macos` with your device ID.
The example selects native Metal views on Apple platforms and Vulkan textures
on Android. It requires native presentation.

## Implemented

| Package | Current behavior |
| --- | --- |
| `gpu3d_tools` | Tap or direct selection, temporary material highlighting, local transform edits, grid snapping, bounded undo/redo with conflict detection, fixed world-point measurements |
| `gpu3d_devtools` | Immutable hierarchy and transform snapshots, stable inspector IDs, live object resolution, bounded frame history and backend capabilities |
| `gpu3d_timeline` | Absolute transform and camera tracks, quaternion interpolation, step visibility, play/pause/seek, looping and scoped frame demand |

The example combines the three plugins with the existing orbit controls. You can
select a part from the canvas or assembly list, move it along X in quarter-unit
steps, rotate around Y, scale it, and undo or redo the edit. The timeline scrubs
an exploded assembly. Seeking or starting playback clears manual edit history
because the timeline becomes the pose writer.

Choose the ruler and pick two surface points to create a measurement. Anchors
stay fixed in world space. The line and label are Flutter overlays, with no depth
occlusion, and distances use scene units. Clear measurements with the adjacent
button. The inspector moves below the canvas at narrow widths and has its own
scroll area.

Empty selection and renderer errors use the shared `ZeroState` from
`package:flutter_gpu3d/widgets.dart`. Loading remains a separate state. The
planet example's error component is a thin adapter around the same widget.

## Verification on 2026-09-27

- Core Dart suite: 263 tests passed, run from `packages/gpu3d`.
- Geospatial Dart suite: 17 tests passed, run from `packages/flutter_geospatial`.
- Plugin suites: 19 tests passed. They cover selection cleanup, clip-aware picking,
  invalid transforms, undo conflicts, bounded history, immutable diagnostics,
  deterministic seeking, loop overshoot and frame-demand teardown.
- Flutter facade and example suites: 73 tests passed. The workbench checks edits,
  undo/redo, part selection and playback at 1100, 390 and 320 logical pixels wide.
- Workspace analysis and package-boundary checks passed. CI includes the plugin
  tests and checks that the packages depend only on the Dart core.
- macOS Metal integration passed. The native workbench selected parts, edited and
  undid transforms, scrubbed and played the assembly, and disposed its controller.
  Reported frames contained three draws and zero readback bytes.
- Physical Pixel 9 Pro, Android 17 / Vulkan: the same integration test passed
  with shared-texture presentation, three draws and zero readback bytes.
- The macOS app was also inspected visually at narrow and desktop sizes. Selecting
  the cover updated its visible material and the inspector's selection and pose.

The core reference tests load fixtures relative to their package directories.
Running those suites from the workspace root produces missing-fixture errors;
the package-local runs above passed. The workbench widget test also flushes real
stream-cancellation completions and Flutter's simulated microtask queue before
checking disposal. The native integration test awaits actual disposal directly.

## Remaining scope

Transform gizmos, section clipping, postprocessing outlines, skeletal animation,
morph targets, event tracks and engineering metadata persistence are not included.
Transform editing in the example uses toolbar actions. The plugins do not replace
the renderer or implement a second material system.

The inspector reports unavailable GPU timings and residency as unavailable. It
does not expose the native allocation registry or claim total GPU memory usage.
This workbench has not been qualified on iOS, Windows or Linux. No Rust renderer
code changed in this milestone; the checks above are not a new renderer-wide GPU
qualification.
