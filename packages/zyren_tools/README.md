# zyren_tools

Select scene objects, edit local transforms and measure world points through the
public `zyren` API. Register one plugin per engine or Flutter controller.

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
  screenSize: 96, // optional radius in logical pixels
  onDragChanged: (dragging) => orbit.controls?.enabled = !dragging,
);
controller.use(tools);
controller.use(gizmo);
controller.use(orbit);
gizmo.mode = GizmoMode.rotate; // translate, rotate or scale
gizmo.space = GizmoSpace.world; // local by default; scaling stays local
gizmo.snapEnabled = true;
```

Drag a colored axis to edit it, or use an XY, XZ or YZ pad to move in that plane.
Hold Shift or enable snapping for quarter-unit
translation, 15-degree rotation and 10-percent scale increments. You can set the
increments in the constructor. Release to commit one undo entry. Escape, pointer
cancellation, changing modes or spaces, or hiding the selected object cancels the preview.
Camera, viewport and external transform changes also end a gesture safely.

Local axes follow the object's rotation. `size` defaults to 1.5 parent units in
local space and 1.5 world units in world space; the object's own scale does not
stretch its handles. Plane snapping rounds both displacement coordinates in the
chosen space, leaving the perpendicular coordinate unchanged.

Set `screenSize` to keep the nominal radius steady as you zoom or resize. It uses
logical pixels and supports perspective and orthographic cameras. Axis tips
extend beyond that radius, and axes pointing into the view still foreshorten.
The radius is capped at a third of the shorter viewport edge for small views.
Local handles retain parent scale and shear proportions, with the longest basis
vector normalized to the requested radius. The handle meshes resize without
changing translation or snapping units. Their size freezes during a drag and
updates when you release it.

Screen sizing reads dimensions from `ViewportInputSource`. If your host doesn't
provide that input capability, call `gizmo.updateViewport(metrics)` before
rendering and after each resize. Direct hit tests and pointer events also supply
dimensions. Handles hide when the logical viewport is unavailable or unusable,
or the selected pivot is outside the camera's depth range.

World movement works through rotated, reflected, nonuniformly scaled and sheared
parent hierarchies. World rotation needs a uniformly scaled parent transform
with orthogonal axes, since the object's local pose cannot store shear. Check
`unavailableReason` for that restriction; handles hide until you choose local
rotation or change the parent transform. Reflected uniform parents are supported.

Scaling changes one local component and preserves its sign, with a minimum
factor of 0.05 per gesture. `effectiveSpace` reports local while scaling and
returns to your configured `space` in Move or Rotate mode. An axis aimed directly
at the camera or a plane seen edge-on cannot provide a stable drag direction.
Orbit the view before dragging it. With screen sizing, dragging a scale handle
by half its displayed radius still multiplies that component by 1.5.

`hitTest` retains its axis-only result. Use `hitTestHandle` for a `GizmoAxis` or
`GizmoPlane`, and `activeHandle.label` for drag feedback. `activeAxis` is null
during a plane drag; `activePlane` identifies that plane.

Your host pauses camera input through `onDragChanged`. Disable auto-rotation and
damping during editing, and cancel any earlier camera gesture before handing a
pointer to another editor. The workbench uses the default undamped orbit controls.
Keep the callback valid during teardown, when camera controls may already be gone.
Disable the gizmo during measurement or playback. Use `gizmo.owns(object)` to omit
helper nodes from assembly lists and exports; normal tools picking already skips
them. The gizmo releases its input registrations and helper geometry on detach.

Use the exported `sceneTools` service key from a dependent plugin, declaring
`zyren.tools` in its dependencies. Cancel your `changes` subscription when its
consumer closes. Engine teardown clears selection, history and measurements.

## Section cuts

Register `SceneSectionPlugin` to preview a cut and restore the previous planes
when you clear it or detach. You can supply up to six world-space half-spaces.
Points remain visible when they satisfy every plane.

```dart
final sections = SceneSectionPlugin();
controller.use(sections);
await controller.ready;
sections.setPlanes([
  ClippingPlane(normal: const Vec3(1, 0, 0), offset: 2),
]); // Keep x >= 2.
sections.clear();
```

Plane changes affect native rendering, shadow casters and triangle picking.
`Object3D.clippingEnabled = false` exempts a subtree; transform handles already
opt out. Cuts do not generate caps. Use double-sided materials to see interior
surfaces. Custom shader materials must opt out while clipping is active.

`isActive` and `planes` describe the plugin's current session. Subscribe to
`changes` for controls, and cancel the subscription when the consumer closes.
An external assignment to `Scene.clippingPlanes` ends session ownership.
Clearing or detaching then preserves that external state. A subsequent
`setPlanes` starts a new session and saves those planes for restoration.
