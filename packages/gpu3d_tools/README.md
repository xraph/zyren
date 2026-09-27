# gpu3d_tools

Select scene objects, edit local transforms and measure world points through the
public `gpu3d` API. Register one plugin per engine or Flutter controller.

```dart
final tools = SceneToolsPlugin();
controller.use(tools);
await controller.ready;
tools.select(mesh);
tools.transform(mesh, position: const Vec3(1.24, 0, 0), grid: .5);
tools.undo();
tools.redo();
final distance = tools.measure(Vec3.zero, const Vec3(3, 4, 0)).distance;
```

Tap selection works when the host provides `ViewportInputSource`. You can also
call `pick` with logical viewport coordinates, or select an object directly.
Selection temporarily changes a mesh's material color. Clearing selection or
detaching restores the original material unless your application replaced it.

Transform commands validate all components before editing. Undo and redo reject
intervening pose changes, removal and reparenting; call `clearHistory()` when you
deliberately hand control to animation or another editor. History is bounded by
`historyLimit`, which defaults to 100 edits. Position snapping uses local units.

For a drag, call `beginTransform(object)` and send preview poses to the returned
session's `update` method. `commit()` records the whole gesture as one edit.
`cancel()` restores the starting pose while the session still owns it. A changed
parent transform, reparenting or an external pose edit ends that ownership, so
cancellation leaves the other writer's values intact. Selection changes, history
clearing and teardown cancel any active preview. Finish a session before issuing
another transform command or using undo and redo.

Measurements retain fixed world anchors in scene units. They do not follow a
moving mesh or convert to metres. Your host supplies labels and drawing.
Selection outlines need a separate rendering pass.

## Canvas handles

Register `TransformGizmoPlugin` after tools and before orbit controls. The handles
use native unlit triangle meshes, so your renderer draws and depth-tests them with
the scene. Picking respects that depth: you cannot grab a handle through a part.

```dart
final orbit = OrbitControlsPlugin();
final gizmo = TransformGizmoPlugin(
  onDragChanged: (dragging) => orbit.controls?.enabled = !dragging,
);
controller.use(tools);
controller.use(gizmo);
controller.use(orbit);
gizmo.mode = GizmoMode.rotate; // translate, rotate or scale
gizmo.snapEnabled = true;
```

Drag a colored axis to edit it. Hold Shift or enable snapping for quarter-unit
translation, 15-degree rotation and 10-percent scale increments. You can set the
increments in the constructor. Release to commit one undo entry. Escape, pointer
cancellation, changing modes or hiding the selected object cancels the preview.
Camera, viewport and external transform changes also end a gesture safely.

The axes follow the object's local rotation. `size` defaults to 1.5 parent units;
the object's own scale does not stretch its handles. Rotated and nonuniformly
scaled parents work through the public scene matrices. Scaling changes one local
component and preserves its sign, with a minimum factor of 0.05 per gesture.
An axis aimed directly at the camera cannot provide a stable drag direction;
orbit the view before dragging it.

Your host pauses camera input through `onDragChanged`. Disable auto-rotation and
damping during editing, and cancel any earlier camera gesture before handing a
pointer to another editor. The workbench uses the default undamped orbit controls.
Keep the callback valid during teardown, when camera controls may already be gone.
Disable the gizmo during measurement or playback. Use `gizmo.owns(object)` to omit
helper nodes from assembly lists and exports; normal tools picking already skips
them. The gizmo releases its input registrations and helper geometry on detach.

Use the exported `sceneTools` service key from a dependent plugin, declaring
`gpu3d.tools` in its dependencies. Cancel your `changes` subscription when its
consumer closes. Engine teardown clears selection, history and measurements.
