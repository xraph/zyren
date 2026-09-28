# Scene workbench plugins

You can build selection, inspection and playback on the public Dart scene API.
This milestone stays on `main` and adds three optional packages:

- `zyren_tools`: selection and material highlighting, reversible local transforms,
  grid snapping and point-to-point measurements in scene units.
- `zyren_devtools`: immutable scene inspection snapshots and bounded frame history.
- `zyren_timeline`: transform and camera tracks with play, pause, seek and looping.

The Flutter workbench example combines them in a compact assembly inspector.
You can select a part, edit it, undo the edit and scrub an assembly sequence.
It uses the native Metal or Android Vulkan runtime. Flutter owns the controls;
all scene rendering stays in the existing native renderer.

## Ownership and behavior

Each plugin registers a typed service during attachment. Subscriptions and frame
demand belong to the attachment scope. Detaching stops input and playback and
restores any temporary selection material without overwriting an external edit.
Commands reject objects outside the scene. Undo checks for intervening transform
edits and reparenting before applying an old value.

Transforms and camera tracks use absolute keyframes. Seek produces the same pose
whether you arrive from playback or from the slider. Playback uses the engine's
capped frame delta, requests frames only while playing and stops at the end unless
you enable looping. Rotation interpolation follows the shortest quaternion arc.

Inspector snapshots copy transforms and hierarchy information. Frame history is
bounded; unavailable GPU timings and residency stay unavailable. The inspector
does not claim to expose the native allocation registry.

## Canvas transform gestures

The tools package also provides `TransformGizmoPlugin`. Its X/Y/Z arrows,
rotation rings, scale boxes and translation planes use unlit triangle meshes
through the public scene API. You can grab the frontmost visible handle. Hidden
handles do not intercept clicks, and ordinary tools picking skips all gizmo
geometry.

A transform session previews pointer movement and records one undo entry on
release. Cancellation restores the starting pose only while the session still
owns it. External edits, reparenting and changed ancestor transforms take
precedence. Mode, selection, camera and viewport changes cancel active gestures.
Rotation accumulates across the angle seam; scale preserves the component's sign
and clamps the gesture factor above zero. Movement and rotation support local
and world axes. Scaling stays local. See [gizmo spaces](gizmo-spaces.md) for
transformed-parent behavior and the world-rotation restriction.

The host pauses camera input through the gizmo's drag callback and disables
handles during playback and measurement. Register the gizmo before orbit controls
so it receives the pointer first. The workbench keeps toolbar edits as an
alternative to dragging. You can keep a fixed radius in scene units or opt into
[screen-size handles](gizmo-screen-size.md), as the workbench does. Always-visible
rendering remains outside this milestone.

## Scope and verification

This first version does not include render-pass effects, section clipping, native
line primitives, skeletal animation, CAD import or physics. Engineering-specific
metadata and annotation persistence remain a separate plugin milestone.

Behavior tests cover selection cleanup, command conflicts, invalid transforms,
measurement units, immutable diagnostics, timeline interpolation and teardown.
The example needs desktop and narrow layout tests plus a real native integration
run exercising selection, edit, undo, scrub and disposal. Record any platform
checks that could not run. Run the existing Dart and Flutter suites before the
final commit.
