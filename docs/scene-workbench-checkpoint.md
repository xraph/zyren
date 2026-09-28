# Scene workbench checkpoint

Run `fvm flutter run -d macos -t lib/scene_workbench.dart` from
`examples/multiple_views`. On Android, replace `macos` with your device ID.
The example selects native Metal views on Apple platforms and Vulkan textures
on Android. It requires native presentation.

## Implemented

| Package | Current behavior |
| --- | --- |
| `zyren_tools` | Tap or direct selection, temporary material highlighting, local/world transform gizmos and translation planes, optional screen-size handles, reversible section sessions, transactional drag history, snapping, bounded undo/redo with conflict detection, fixed world-point measurements |
| `zyren_devtools` | Immutable hierarchy and transform snapshots, stable inspector IDs, live object resolution, bounded frame history and backend capabilities |
| `zyren_timeline` | Absolute transform and camera tracks, quaternion interpolation, step visibility, play/pause/seek, ordered playback markers, looping and scoped frame demand |
| `zyren_engineering` | Stable host IDs, immutable metadata and object-local annotations, temporary isolation, validated JSON, asynchronous host storage and atomic file replacement |

The example combines these packages with the existing orbit controls. You can
select a part from the canvas or assembly list, choose Move, Rotate or Scale, and
drag a colored axis or a translation plane. Choose Local or World beside the mode
selector. Enable the grid button or hold Shift for quarter-unit moves,
15-degree rotations and 10-percent scale steps. A whole drag produces one undo
entry. Escape or pointer cancellation restores its starting pose, provided another
writer has not changed the object or its ancestors. Toolbar edits remain available.
The timeline scrubs an exploded assembly. Seeking or starting playback clears manual edit history
because the timeline becomes the pose writer.

Playback delivers Assembled, Separating and Exploded markers at 0, 1.5 and 3
seconds. You can see the last marker beneath the elapsed time. Pause keeps it;
scrubbing clears it and emits no markers. See [timeline events](design/timeline-events.md)
for loop ordering, asynchronous delivery and the event limit.

Handles use native unlit meshes and respect scene occlusion. The workbench uses a
nominal handle radius of 96 logical pixels, capped at a third of the shorter
viewport edge for small canvases. The radius stays steady as you zoom. Axes still
foreshorten in depth, and the object's own scale does not
stretch its handles. Local axes follow the object's rotation. World axes cancel
parent transforms, including nonuniform scale and reflection, so movement and
plane snapping follow world coordinates. XY, XZ and YZ pads move two coordinates
at once. They use the color of the perpendicular axis.

The plugin also supports fixed scene-unit handles when you omit `screenSize`.
Local screen-size handles preserve the parent's scale and shear proportions,
normalizing the longest basis vector to the requested radius. Screen sizing
changes the helper meshes without changing translation or snapping units. Visual
size freezes during a drag and updates on release. If the model hides a handle,
zoom out or orbit to reach it. See [screen sizing](design/gizmo-screen-size.md).

Scaling stays local. The workbench retains your chosen space when you return to
Move or Rotate. World rotation requires an accumulated parent transform with
uniform scale and orthogonal axes. Otherwise the canvas explains why its rotation
handles are hidden and directs you to Local. See [gizmo spaces](design/gizmo-spaces.md).
Handles hide during playback, measurement and note placement, and stay out of
the assembly list. Dragging a handle pauses orbit input. Drag empty canvas to
orbit, or scroll to zoom.

Choose the ruler and pick two surface points to create a measurement. Anchors
stay fixed in world space. The line and label are Flutter overlays, with no depth
occlusion, and distances use scene units. Clear measurements with the adjacent
button. The inspector moves below the canvas at narrow widths and has its own
scroll area.

Choose the scissors button to section the assembly. Select X, Y or Z, move the
offset slider in scene units, and flip the retained half when needed. Clear
restores the earlier planes. Sections cut native surfaces, shadow casters and
triangle picks. Handles stay available even if the selected part is fully cut
away. The example uses double-sided materials so you can see the remaining
interior faces. It does not fill the cut with a cap. See
[section clipping](design/section-clipping.md) for the core and plugin contracts.

Open Review to edit a part's name, tag and material. Isolate the selected part,
then restore the previous visibility when you're done. Add a surface note and
pick its location on the model. Pink pins render as native meshes and follow
their part through transforms; they stay out of picking and the assembly list.
You can edit a note by selecting its text, or remove it with the trash button.

Save writes metadata and notes to `gpu3d-workbench/pump-review-v1.json` inside
the application's support directory. The workbench loads that file on startup.
Reload asks before replacing unsaved edits, and invalid files leave the current
review intact. The status beside Save shows whether edits remain unsaved.
Renderer recovery rebinds records and pins without reloading over your edits.
Transforms, measurements, isolation and geometry are not saved in this file.
The file adapter supports one writer; it doesn't provide cross-process locking
or collaborative editing. Read the [package guide](../packages/zyren_engineering/README.md)
for the storage contract and document limits.

Empty selection and renderer errors use the shared `ZeroState` from
`package:flutter_zyren/widgets.dart`. Loading remains a separate state. The
planet example's error component is a thin adapter around the same widget.

## Verification on 2026-09-27

- Core Dart suite: 264 tests passed, run from `packages/zyren`. Normalized rotations
  retain their exact values when restored, so undo/redo does not report a false
  external edit from normalization rounding.
- Geospatial Dart suite: 17 tests passed, run from `packages/zyren_geospatial`.
- Plugin suites: 73 tests passed. They cover selection cleanup, clip-aware picking,
  invalid transforms, undo conflicts, bounded history, immutable diagnostics,
  deterministic seeking, loop overshoot and frame-demand teardown. Gizmo cases
  cover local axes, nonuniform parent scale, orthographic views, snapping, rotation
  across the angle seam, camera exclusion, pointer ownership and cancellation.
  World and plane cases cover nested shear, reflected parents, transformed scene
  roots, two-coordinate snapping, edge-on planes and safe space changes.
  Screen-size cases cover perspective and orthographic zoom, field of view,
  viewport resizing, small-canvas limits, display density, transformed parents,
  scale sensitivity, frozen drag size, depth clipping, occlusion and an idle
  scene's revision.
  Engineering cases cover stable ID rebinding, anchor transforms, visibility
  ownership, malformed documents, file round trips, stale reads and failed writes.
- Flutter facade and example suites: 77 tests passed. The workbench checks edits,
  touch dragging, undo/redo, scaling, part selection and playback at 1100, 390 and
  320 logical pixels wide. Review checks include save failure, cancelled and
  malformed reloads, fresh-scene persistence and unsaved notes surviving renderer
  retry. Touch and mouse taps also work with the viewport's eager drag recognizer;
  drags, cancelled pointers, secondary clicks and multi-touch do not emit taps.
  A startup regression checks that plugins receive logical viewport dimensions
  during attachment and the first render, before any pointer input.
- Workspace analysis and package-boundary checks passed. CI includes the plugin
  tests and checks that the packages depend only on the Dart core.
- macOS Metal integration passed with local move, rotate and scale drags, world
  movement and rotation on a tilted part, snapped XY plane movement, single-step
  undo, pointer cancellation, camera isolation, assembly playback and disposal.
  The screen-size revision also checks wheel zoom followed by picking, dragging
  and undo. Its 24 reported samples contained twelve draws with move handles and
  planes visible, and zero readback bytes.
- The earlier local-axis gizmo workbench passed on a physical Pixel 9 Pro, Android 17 / Vulkan,
  using shared-texture presentation. The run covered move, rotate and scale drags,
  undo, pointer cancellation, camera isolation, part selection, assembly playback
  and disposal, with nine draws and zero readback bytes. Its assembly selection
  scrolls the list before tapping a row outside the narrow panel's visible area.
  The world/plane and screen-size revisions have not been rerun there because
  another checkout is using the device for its native material demo.
- Engineering integration passed again on macOS Metal with thirteen draws for
  the parts, move handles, planes and review pin, and zero readback bytes. It
  edited metadata, isolated and restored a part, created a surface note, saved to
  application storage and loaded the note onto a fresh scene. The earlier
  revision passed the same workflow on the physical Pixel using Vulkan shared
  textures, with ten draws before plane handles were added.
- Native macOS visual inspection confirmed the review panel at desktop and
  narrow window sizes, surface-note placement, the pink pin, note scrolling and
  saved status. The world/plane revision was also checked at both window sizes:
  the space selector works, plane handles render and the inspector moves beneath
  the canvas in the narrow layout. Automated layout checks cover 1100, 390 and
  320 logical pixels. The screen-size revision was visually checked during zoom
  and at a short, roughly 398-pixel-wide native window. Its handles shrink to fit
  the shallow canvas while the toolbar and inspector retain their narrow layout.

The core reference tests load fixtures relative to their package directories.
Running those suites from the workspace root produces missing-fixture errors;
the package-local runs above passed. The workbench widget test also flushes real
stream-cancellation completions and Flutter's simulated microtask queue before
checking disposal. The native integration test awaits actual disposal directly.
Controller diagnostics sample at most every 200 ms. The integration test requests
one frame after that interval to verify the paused scene's final draw count.

The section milestone passed 417 core tests, 56 tools tests, all 66 native Dart
tests with GPU execution enabled on macOS Metal, and 62 Rust tests. Native Rust
tests marked for explicit GPU execution were not part of that count; the
material-sidedness GPU test also passed. Rust formatting, Clippy, package
boundaries and analysis of the changed packages and example passed.

The section workbench passed all 14 widget tests, including controls at 1100,
390 and 320 logical pixels. Its macOS native integration produced seven samples,
twelve draws and zero readback bytes while enabling, moving, flipping and
clearing a section. A native-window failure exposed an implicit HDR allocation
in the new packet version. Opcode 28 now carries an explicit postprocessing
flag; a GPU regression checks that section planes alone allocate no HDR targets.
Desktop visual inspection confirmed both retained halves, visible interior
faces and usable transform handles in the native view. Narrow section controls
were checked by the widget suite; a separate native narrow-window visual check
has not been completed for this revision.

## Timeline event verification on 2026-09-28

The timeline event milestone passed 26 package tests and all 15 example widget
tests. Cases cover equal-time ordering, repeated frames, loop endpoints and
overshoot across several loops, silent seeking, replay, detached reuse, failed
samples and bounded event delivery. The workbench exercises all three markers,
pause/resume, silent scrubbing and replay at 1100, 390 and 320 logical pixels.
Analysis, formatting and package-boundary checks passed. The macOS Metal
integration passed with twelve native frame samples and zero readback bytes.
It exercised the same marker workflow through native-view presentation and
awaited controller disposal. Native visual inspection confirmed the completed
pose and Exploded label at desktop width and in a roughly 396-pixel-wide window.
The narrow playback row stayed visible, and a slider click cleared the marker
while updating the pose. Timeline events have not been rerun on Android, iOS,
Windows or Linux.

## Remaining scope

Section caps, custom-shader clipping, postprocessing outlines, clip mixing,
skeletal animation, morph targets, imported animation events, CAD import and
collaborative review are not included. Handles remain depth-tested, including
with screen sizing enabled.
The plugins do not replace the renderer or implement a second material system.

The inspector reports unavailable GPU timings and residency as unavailable. It
does not expose the native allocation registry or claim total GPU memory usage.
This workbench has not been qualified on iOS, Windows or Linux. Section clipping
changes the Rust renderer and remains unverified on Android, iOS, Windows and
Linux. Earlier platform checks above apply to their recorded revisions.
