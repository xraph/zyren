# Flutter game bindings

Use `GameSceneBinding` to put a configured `SceneController`, a `GameSession` and
semantic input in one Flutter view. You keep ownership of the controller, session
and optional `AudioFocusSession`. Close them after unmounting the view.

The binding composes `SceneView` and `SceneInteractionOverlay`. Register
`PhysicsPlugin` and `GameScenePlugin` on your controller before play. Their shared
fixed clock drives simulation; the widget does not add another update loop.

```dart
GameSceneBinding(
  controller: controller,
  session: simulation.session,
  actions: actions,
  autofocus: true,
  enableGamepads: true,
  audioFocus: audioFocus,
  onGamepadError: showInputFailure,
  hud: GameHud(
    actions: actions,
    session: simulation.session,
    builder: (context, state) => Text('Tick ${state.tick}'),
  ),
)
```

`GameActionButton` and `GameAxisPad` provide touch, keyboard and semantic actions.
They release held controls on cancellation or removal. `GameInputMap` handles
bindings and dead zones. Global releases and rebinding also discard the widgets'
held keys and pointers. An interrupted drag needs a new pan start before it can
move again. Disabled controls ignore new input. Consumed events,
old timestamps and excess device/control counts are rejected by the game layer.

Editor tools and object interactions retain priority through the existing
`InputRouter`. Text entry takes keyboard focus. Modal router blocks clear held
input even if the game owns no pointer. Nested blocks stay active until their last
registration closes. Backgrounding pauses the session, clears controls and
invalidates pending decisions. This also works for games without audio.

When you supply audio focus, use the shared `AudioFocusSession.play()` policy.
A permanent native focus loss waits for a new Play request. Returning to the app
cannot override an explicit game pause, and stale focus grants cannot resume a
newer background session. Returning to the app also preserves active modal blocks.

## Controller backend

The adapter pins [gamepads 0.1.12](https://pub.dev/packages/gamepads/versions/0.1.12).
Its [native implementation](https://github.com/flame-engine/gamepads) supplies
Android, iOS, macOS, Windows and Linux transport. Zyren owns semantic mapping,
focus, cancellation and bounded connection state. No second native controller
transport is introduced.

Controls use the backend's normalized names, such as `axis.leftStickX`,
`axis.leftStickY`, `button.a` and `button.leftShoulder`. Bind these in your input
map. Listen to `GamepadAdapter.events` errors or provide `onGamepadError`; device
failures clear held values and remain visible. The adapter stamps events with its
own monotonic microsecond clock on receipt, preserving arrival order across the
backends' different native clocks.

Android hosts must forward input from a `GamepadsCompatibleActivity`. The
repository's Game Lab `MainActivity.kt` contains that host integration. Follow the
backend's Android setup when embedding the binding in another app. The remaining
native platforms use their registered Flutter plugins. Windows builds require a
Windows SDK with GameInput headers.

## Evidence

Widget fixtures cover visible play with focused text entry, editor capture,
nested modal blocks, touch cancellation, accessible keyboard activation,
controller disconnect and stale discovery, immutable HUD updates, background
suspension, silent games and late audio focus grants. Capture Lab's compatibility
test also exercises the extracted shared audio policy.

Regressions cover modal blocks across foreground restoration, global releases
while keys or pointers remain down, ignored disabled button presses, interrupted
drags, and fresh controller releases after a backend clock moves backwards.

Physical controller connect/disconnect, touch devices and native accessibility
checks are pending device qualification. Mocked events prove adapter behavior;
they do not establish that each platform's hardware bridge works on a device.
