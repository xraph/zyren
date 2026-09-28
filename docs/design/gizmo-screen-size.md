# Screen-size transform handles

Set `screenSize` on `TransformGizmoPlugin` to keep a nominal handle radius in
logical pixels as you zoom or resize the view. The workbench requests 96 pixels.
The radius is capped at a third of the viewport's shorter edge to leave room for
arrow tips and canvas controls in small views.
Omit it to keep the existing `size` in scene units.

The plugin measures a camera-facing span at the selected object's depth through
the public projection API. This works with perspective and orthographic cameras.
Display density and render resolution do not affect the requested radius. The
radius describes the axis reference length; arrow tips extend to 1.12 times that
length, and axes pointing into the view remain foreshortened.

Local handles retain the parent's scale and shear. A uniform visual scale divides
out the longest transformed basis vector, so changing a parent's uniform scale
does not enlarge the controls. World handles already cancel the parent transform.
The selected object's own scale does not affect either mode.

Only the handle meshes receive this visual scale. Translation and snapping keep
their coordinate-space units. Scaling uses the handle radius captured on pointer
down, so dragging by half that radius multiplies the selected component by 1.5.
Visual size stays fixed during a gesture, including movement toward the camera,
and updates on release. Rotation keeps its angular behavior.

The plugin reads logical dimensions from `ViewportInputSource`. A host without
that input capability calls `updateViewport` before rendering and after a resize;
direct hit testing and pointer routing also supply dimensions. Physical frame
dimensions are not a substitute for logical viewport dimensions. A missing or
unusable viewport, or a pivot outside the camera's depth range, hides screen-sized
handles. A viewport or camera change cancels an owned drag before resizing it.

Handles remain native, depth-tested meshes. Screen sizing does not make a handle
visible through the model. Tests cover projection, zoom, resize, display density,
transformed parents, edit distances, snapping, history and cancellation. Native
workbench checks cover zoomed picking, plane movement and layout on narrow views.
