# Camera framing

Fit a mesh with either built-in camera:

```dart
final bounds = mesh.bounds.transformed(mesh.worldMatrix);
camera.frameBounds(bounds, aspect: logicalWidth / logicalHeight);
```

`frameBounds` accepts a world-space `Bounds3`. It returns `true` when it applies
a fit and `false` for empty bounds. You can combine bounds with `union` to
fit a selection or an entire model. Mesh bounds include the current skin and
morph pose; an instanced mesh includes all active instances. Supply your own
bounds for vertex-shader displacement or expanded line/point footprints.

The fit keeps your viewing direction and up vector. Perspective framing moves
the camera so all eight corners fit, accounting for each corner's depth and the
viewport aspect. Orthographic framing changes `verticalSize` while retaining
`zoom`, and moves the camera back if the bounds would cross it. Both projections
target the center and fit new near/far planes around the bounds.

```dart
camera.frameBounds(
  selectionBounds,
  aspect: logicalWidth / logicalHeight,
  padding: 1.2,
  minimumExtent: .01,
);
```

Padding scales the projected half-extents. At `1.2`, each lies within `1 / 1.2`
of the viewport half-extent. The default is `1.15`, and the minimum is `1`.
`minimumExtent` gives point and thin bounds a usable size in your scene units.
It defaults to `.01` and must be positive and finite, as must the aspect.

Invalid options, invalid camera poses and unrepresentable fits raise
`ArgumentError` before changing the camera. Custom camera projections raise
`UnsupportedError`; the helper implements the built-in perspective and
orthographic projection conventions. It does not animate the move or expand
the clip planes for objects outside the bounds you supplied.

Use the viewport's logical aspect, independent of DPR and render resolution.
Call the helper again when a resize changes that aspect or the selected geometry
changes. The [culling lab](../../examples/shader_lab/README.md#culling-lab) shows
framing a tapped box, fitting all boxes and retaining the fit across projection
changes and window resizing.
