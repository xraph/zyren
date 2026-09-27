# Scene workbench checkpoint

Run `fvm flutter run -d macos -t lib/scene_workbench.dart` from
`examples/multiple_views`. On Android, replace `macos` with your device ID.
The example selects native Metal views on Apple platforms and Vulkan textures
on Android. It requires native presentation.

## Implemented

| Package | Current behavior |
| --- | --- |
| `gpu3d_tools` | Tap or direct selection, temporary material highlighting, native local-axis transform gizmos, transactional drag history, snapping, bounded undo/redo with conflict detection, fixed world-point measurements |
| `gpu3d_devtools` | Immutable hierarchy and transform snapshots, stable inspector IDs, live object resolution, bounded frame history and backend capabilities |
| `gpu3d_timeline` | Absolute transform and camera tracks, quaternion interpolation, step visibility, play/pause/seek, looping and scoped frame demand |

The example combines the three packages with the existing orbit controls. You can
select a part from the canvas or assembly list, choose Move, Rotate or Scale, and
drag a colored axis. Enable the grid button or hold Shift for quarter-unit moves,
15-degree rotations and 10-percent scale steps. A whole drag produces one undo
entry. Escape or pointer cancellation restores its starting pose, provided another
writer has not changed the object or its ancestors. Toolbar edits remain available.
The timeline scrubs an exploded assembly. Seeking or starting playback clears manual edit history
because the timeline becomes the pose writer.

Handles use native unlit meshes and respect scene occlusion. The workbench uses a
two-unit handle radius; the selected object's scale does not stretch it. Axes
follow the object's local rotation, including under a transformed parent. Handles
hide during playback and measurement and stay out of the assembly list. Dragging
a handle pauses orbit input. Drag empty canvas to orbit, or scroll to zoom.

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
- Plugin suites: 35 tests passed. They cover selection cleanup, clip-aware picking,
  invalid transforms, undo conflicts, bounded history, immutable diagnostics,
  deterministic seeking, loop overshoot and frame-demand teardown. Gizmo cases
  cover local axes, nonuniform parent scale, orthographic views, snapping, rotation
  across the angle seam, camera exclusion, pointer ownership and cancellation.
- Flutter facade and example suites: 73 tests passed. The workbench checks edits,
  touch dragging, undo/redo, scaling, part selection and playback at 1100, 390 and
  320 logical pixels wide.
- Workspace analysis and package-boundary checks passed. CI includes the plugin
  tests and checks that the packages depend only on the Dart core.
- macOS Metal integration passed with native move, rotate and scale drags,
  single-step undo, pointer cancellation, camera isolation, assembly playback and
  controller disposal. Reported frames contained nine draws with move handles
  visible and zero readback bytes.
- The earlier workbench passed on a physical Pixel 9 Pro, Android 17 / Vulkan,
  using shared-texture presentation. The gizmo revision has not been rerun there:
  a separate checkout was using the device for its native primitives demo.
- Native macOS visual inspection confirmed the move handles and compact layout
  at a narrow window size. Automated layout checks also cover desktop widths.

The core reference tests load fixtures relative to their package directories.
Running those suites from the workspace root produces missing-fixture errors;
the package-local runs above passed. The workbench widget test also flushes real
stream-cancellation completions and Flutter's simulated microtask queue before
checking disposal. The native integration test awaits actual disposal directly.
Controller diagnostics sample at most every 200 ms. The integration test requests
one frame after that interval to verify the paused scene's final draw count.

## Remaining scope

World-axis and plane handles, section clipping, postprocessing outlines, skeletal
animation, morph targets, event tracks and engineering metadata persistence are
not included. Handles have a fixed size in parent units and remain depth-tested.
The plugins do not replace the renderer or implement a second material system.

The inspector reports unavailable GPU timings and residency as unavailable. It
does not expose the native allocation registry or claim total GPU memory usage.
This workbench has not been qualified on iOS, Windows or Linux. No Rust renderer
code changed in this milestone; the checks above are not a new renderer-wide GPU
qualification.
