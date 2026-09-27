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

Measurements retain fixed world anchors in scene units. They do not follow a
moving mesh or convert to metres. Your host supplies labels and drawing.
The package does not yet draw transform gizmos or selection outlines.

Use the exported `sceneTools` service key from a dependent plugin, declaring
`gpu3d.tools` in its dependencies. Cancel your `changes` subscription when its
consumer closes. Engine teardown clears selection, history and measurements.
