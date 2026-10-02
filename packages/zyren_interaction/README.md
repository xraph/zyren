# Zyren interaction

You can register handlers on meshes or groups, track hover and capture active
pointers through the public viewport input API. The router uses Zyren's CPU
raycaster. Selection and undo stay with `zyren_tools`.

```dart
final router = SceneInteractionRouter(
  scene: controller.scene,
  camera: () => controller.camera,
  viewport: () => (controller.input as ViewportInputSource).viewport,
);
final objectEvents = router.register(object, (event) {
  if (event.phase == ObjectPointerPhase.down) {
    tools.select(event.currentTarget);
    event.capturePointer();
  }
  if (event.phase == ObjectPointerPhase.move && event.captured) {
    // Update an existing tools TransformSession using event.source.point.
  }
});
controller.use(SceneInteractionPlugin(router));
```

Create the router once for a scene and dispose it when that scene owner ends.
A plugin attachment borrows the router, connects input and releases its gesture
registrations on detach. Handlers survive detach for reconnection. Explicitly
dispose an object's registration when you no longer need it.

## Event rules

The nearest visible triangle surface wins. A mesh without a handler still occludes
objects behind it. The router dispatches to that mesh's nearest registered
ancestor, then bubbles through registered parents. `target` stays fixed while
`currentTarget` identifies the current handler. The hit retains the actual mesh,
instance and triangle, even when a group handles the event.

`stopPropagation()` stops ancestor dispatch within this router. Capture is
exclusive per pointer within the router and can transfer to an ancestor during
down/move handling. Captured move/up events keep arriving beyond the viewport.
When the pointer leaves the target, captured events retain the capture hit;
`source.point` always contains the current pointer observation.

Enter/leave and capture gained/lost notifications go directly to their target.
Hover follows actual geometry while dragging. Touch hover ends on up; call
`router.clearHover()` from a Flutter `MouseRegion.onExit` to clear mouse hover
when it leaves the viewport. Current public input has no exit phase.

Up releases capture. Cancel, removal, hidden or reparented ancestors, unregister, disconnect
and disposal cancel captured gestures and clear hover. Removal checks run on scene
notifications and before input dispatch. Synthetic cleanup retains the last
pointer observation in `source`; `event.phase` identifies the cleanup event.
Callbacks may remove objects or registrations. Nested input dispatch is rejected.
Handler failures go to `onError`, or to the current Dart zone when none is supplied.

The default plugin claims taps. Pass `gestures: {SceneGesture.pointerDrag}` when
your view should claim drags against a parent scroll view. Camera controls are
independent broadcast consumers. Router capture does not arbitrate their gestures;
the example uses a fixed camera. Keyboard focus, semantics, anchored labels and
widget surfaces remain planned work in `plans/zyren-plugins/interaction.md`.

## Runtime agents

Import `package:zyren_interaction/agents.dart` for `InteractionAgentProvider`.
Register it with the shared `AgentRegistry` after the scene tools attach, and
release the registration before detaching them. The provider exposes current
selection, hover, capture, undo/redo availability and these commands:

| Tool | Host scope | Behavior |
| --- | --- | --- |
| `state` | none | Read the current interaction state |
| `select`, `clear_selection` | `tools.select` | Use scene tools selection |
| `translate` | `tools.transform` | Set local position as one undoable command |
| `undo`, `redo` | `tools.transform` | Use the existing transform history |

Mutations require the provider's expected revision and an idempotency key through
the registry. Selection affects provider revision even when material highlighting
is disabled. Commands reject removed runtime objects. Runtime IDs are local to
the Dart isolate; persistent source IDs come from the host's metadata provider.

The package-local Flutter example registers interaction, viewport and existing
inspector providers. The Inspector button opens the shared scene inspector with
the same selection state and reports its blocking overlay to agents. Its integration test verifies native Metal presentation and
can rendezvous with an external CLI MCP process. Geometric hit results explicitly
leave rendered pixel visibility unknown.

## Checks

Use the repository-pinned Flutter SDK:

```sh
fvm dart test packages/zyren_interaction/test
cd packages/zyren_interaction/example
fvm flutter test --no-pub test
fvm flutter test --no-pub -d macos integration_test/native_interaction_test.dart
```

This is an implementation checkpoint. The package is unpublished. Mobile input,
visual inspection on an unlocked desktop, camera arbitration and the later
milestones still need qualification.
