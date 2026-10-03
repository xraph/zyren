# Flutter interaction overlays

Wrap your `SceneView` in `SceneInteractionOverlay` and pass the same controller
and interaction router. Register focus labels and actions with `router.focus`.
Tab traverses the objects, Shift-Tab reverses, Enter or Space activates, and
Escape clears object focus. Selection still belongs to your tools plugin.

```dart
router.focus.register(pump, label: 'Cooling water pump', onActivate: () {
  tools.select(pump);
});
SceneInteractionOverlay(
  controller: controller,
  router: router,
  labels: [SceneLabel(
    id: 'pump-label', anchor: SceneAnchor(pump), child: Text('Pump'),
  )],
  surfaces: [SceneWidgetSurface(
    id: 'pump-note', anchor: SceneAnchor(pump),
    child: Material(child: TextField()),
  )],
  child: SceneView(controller: controller),
);
```

A surface is a Flutter screen overlay. You can use text fields, buttons and normal
Flutter semantics; it does not become a texture on a 3D mesh. Use stable, unique
IDs for labels and surfaces. A surface owns its focus scope and input-blocking
registration, while you retain ownership of the controller, router and any
controllers passed to its children.

Object or ancestor removal, hidden anchors and clipped anchors unmount surfaces.
Focus or an active press on a surface cancels scene gestures and blocks new ones
until that focus or press ends. Labels pass pointer events through to the scene.

Projection uses logical pixels and the current camera. Optional occlusion checks
CPU triangles; alpha masks and custom GPU displacement remain unknown. Widget
tests exercise semantics actions and text focus. Native screen-reader traversal
and physical mobile keyboards still need platform qualification.
