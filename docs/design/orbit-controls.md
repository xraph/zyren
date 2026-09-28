# Orbit controls

Attach one controls instance per view:

```dart
final orbit = OrbitControls();
controller.use(orbit);
```

The plugin uses the view's camera and local input. It supports perspective and
orthographic cameras, including arbitrary up vectors. You can replace the
controller's camera or call `camera.frameBounds` while the plugin is attached.
It drops pending movement when it observes an external camera edit or replacement.

## Navigation

| Input | Action |
| --- | --- |
| Primary mouse drag or one finger | Orbit around the target |
| Secondary mouse drag, Shift drag or two fingers | Pan in the camera plane |
| Middle mouse drag | Dolly or change orthographic zoom |
| Wheel or pinch | Dolly or change orthographic zoom |
| Trackpad pan/zoom gesture | Pan and zoom |

Flutter gestures must win their local arena before they move the camera. Overlay
controls keep their normal hit testing and keyboard focus. The plugin registers
scale and scroll interests while enabled. Disable it to return those gestures to
other Flutter widgets:

```dart
orbit.enabled = false;
orbit.enabled = true;
```

It never installs global pointer or keyboard handlers. A vertical scroll parent
can win a competing touch drag through Flutter's normal gesture arena. Registered
wheel input belongs to the scene; disabled controls let the parent handle it.

## Movement and limits

The default damping time constant is 80 ms. Movement decays exponentially with
elapsed frame time; it does not depend on a fixed refresh rate. `Duration.zero`
applies changes immediately. Continuous frame demand lasts through a won gesture
and any pending damping, then stops. Pointer cancellation, background suspension,
disabling controls and detachment discard pending movement.

```dart
final orbit = OrbitControls(
  damping: const Duration(milliseconds: 120),
  rotateSpeed: 1,
  panSpeed: 1,
  zoomSpeed: 1,
  limits: OrbitLimits(
    minDistance: .5,
    maxDistance: 100,
    minZoom: .25,
    maxZoom: 8,
    minPolarAngle: .1,
    maxPolarAngle: 3,
  ),
);
```

Distances apply to perspective dollying; zoom limits apply to orthographic zoom.
Polar angles are radians measured from `camera.up` and must stay strictly inside
zero and pi. Limits constrain subsequent movement. They do not rewrite the
camera when you attach the plugin. Clip planes remain yours to configure; framing
fits them for the supplied bounds and current view, so keep enough depth range
for the navigation your application allows.

After attachment, you can drive the same controls without pointer input:

```dart
orbit.rotateBy(azimuth: .2, polar: -.1);
orbit.panBy(const Vec3(1, 0, 0));
orbit.zoomBy(1.2);
orbit.stop();
```

Positive azimuth rotates about the up axis. Positive polar moves toward its
opposite. Pan offsets use world coordinates. Zoom factors above one move away
in perspective or reduce orthographic zoom. Input speed settings affect gestures;
programmatic offsets and factors use the values you supply.

`saveState()` records the current pose and projection settings. `reset()` stops
movement and restores that state. The initial state comes from attachment, or
from the first observation of a replacement camera. Invalid arguments throw
before changing the camera. An unrepresentable update discards pending movement
and keeps the last valid pose.

## Custom input

You can replace the drag mapping without replacing the plugin:

```dart
final orbit = OrbitControls(
  dragBinding: (event) => event.modifiers.contains(SceneModifier.alt)
      ? OrbitDragAction.pan
      : OrbitDragAction.rotate,
);
```

The binding returns `rotate`, `pan`, `zoom` or `none`. Pinch and wheel zoom remain
independent. Flutter accepts primary, secondary and middle mouse drags.

For another host, implement `ViewportInputSource`, including `logicalWidth` and
`logicalHeight`. Those dimensions precede DPR and render-resolution scaling.
Publish won scale gestures with pointer count, button/device metadata and a
cumulative scale that starts at one for each `scaleStart`. A zero extent cancels
interaction. Raw pointer motion alone does not orbit. Engines without an input
source can use the programmatic methods.

The [culling lab](../../examples/shader_lab/README.md#culling-lab) combines orbit,
selection, framing and projection switching. The general controls contain no
geospatial dependency. Globe/surface navigation and Takram-specific camera
behavior remain separate geospatial plugin work.
