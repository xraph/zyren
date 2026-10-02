# Interaction

You can use this package to route viewport pointers to scene objects while the
existing tools package owns selection and transforms. Rendering stays native.

## Source audit and decisions

- `ViewportInputSource` supplies logical dimensions and pointer events. Input is
  broadcast, so object propagation cannot consume camera input.
- `Raycaster.captureFromCamera` handles camera clipping, layers, visibility,
  transforms and triangle hits. We use the closest surface, including surfaces
  without handlers. Those surfaces occlude objects behind them.
- `Object3D.changes` reaches the scene in a microtask. The router checks membership
  before each dispatch and also listens for edits, so removal needs no new input.
- `Registration` and `AttachmentScope` supply explicit ownership and cleanup.
- `SceneToolsPlugin.select` owns selection. The example disables its independent
  tap picker and selects through object handlers.
- `SceneView`, `SceneController` and `ZeroState` are public Flutter contracts.
  The active declarative owner retains its files and facade. No changes there.
- Core CPU picking covers triangles. Alpha masks, custom vertex displacement,
  lines and points need later picking adapters with explicit coverage rules.

## Milestones and acceptance

1. Implement a Dart router and a scene plugin adapter. Register one handler per
   object, resolve the nearest registered ancestor, bubble events through its
   registered parents, track hover per pointer and capture active pointers.
   Cancel and release on pointer cancel, target removal, unregister, disconnect
   and disposal. Test overlapping meshes, groups, multiple pointers, outside
   drags, callback mutation and cleanup with actual CPU raycasts.
2. Build a compact native Flutter example with selection, hover, captured dragging
   and object removal/reset. Reuse shared tools and ZeroState. Test desktop and
   narrow layouts with a substituted viewport, and test the public input adapter
   without a GPU. Native presentation and device input need a separate live run.
3. Add gesture arbitration with camera controls. Define a shared per-pointer claim
   contract, priority between tools and objects, multi-touch camera takeover and
   cancellation on arena loss. Claims must be decided before camera motion. Test
   both plugin attachment orders, Flutter scroll parents, pinch and trackpads.
4. Add object keyboard focus through `KeyboardInputSource`, including focus
   traversal, Escape, focus loss and removal. Agree on Tab/Enter key additions
   with the input owner. Keep application shortcuts outside the renderer.
5. Add semantics through a Flutter adapter with stable object identity, labels,
   actions and focus order. Verify accessibility traversal on native platforms.
6. Add anchored labels using `Camera.projectPoint` and logical viewport metrics.
   Test clipping, behind-camera anchors, viewport resize, camera replacement and
   optional occlusion. Keep projection and native scene resources separate.
7. Add widget surfaces with explicit ownership of overlay hit testing, focus,
   pointer cancellation and render resources. Define whether each surface is a
   screen overlay or a native texture before implementing it. Verify lifecycle
   and text input on desktop and touch devices.

## Contracts and dependencies

`SceneInteractionRouter` owns handlers and pointer state for one scene. Camera
and viewport getters read the current host values. `SceneInteractionPlugin`
connects public input for its attachment lifetime. Hosts dispose the router after
removing the plugin. The router owns neither scene objects nor tools.

Capture is exclusive within this router and continues beyond viewport bounds.
Hover follows the actual nearest surface while a mouse drags. Touch hover ends
on up. A host must clear hover on viewport exit because current input has no
exit phase. Reentrant input dispatch is rejected; handlers can edit/remove
objects and release their registrations. Handler errors reach an error callback.

For the first example, the camera is fixed so object capture has an unambiguous
owner. Camera arbitration is milestone 3, not an implied capability of capture.

## Shared-file requests

- `pubspec.yaml`: append this package and its package-local example under the
  shared lock, preserving all other entries. No dependency version changes.
- `pubspec.lock` and generated package resolution: run workspace pub resolution
  under the same lock. Inspect the result and preserve other owners' additions.
- No core, Flutter facade, declarative or native API changes are required for
  milestones 1 and 2. Later arbitration and keyboard changes need owner agreement.

## Evidence and remaining work

Implementation and checks are in progress. No native/device check or publication
has been claimed. Milestones 3 through 7 remain in the backlog.

## Runtime agent access, required work

The shared specification now assigns this chat `packages/zyren_agents`, viewport
queries and the optional existing devtools transport adapter. Provider support is
part of completion for interaction and the existing core/tools/inspector adapters.

The public contract is in `packages/zyren_agents/lib/zyren_agents.dart` and
`lib/src/contract.dart`. Other owners can implement these signatures now:

```dart
abstract class AgentProvider {
  String get id;
  String get version;
  String get instanceId;
  int get revision;
  List<AgentTool> get tools;
  Map<String, Object?> get capabilities;
  List<Map<String, Object?>> get resources;
  FutureOr<AgentResult> invoke(
    String tool, Map<String, Object?> arguments, AgentCallContext context);
}
```

Use `AgentTool(name:, description:, inputSchema:, outputSchema:, readOnly:,
requiredScopes:)`. Tool names are local to the provider instance. Successful
results use `AgentResult(AgentStatus.ok, data:, revision:, affectedIds:)`. Return
explicit empty, unsupported, unavailable, denied, stale, cancelled, failed or
invalid status where applicable. Schemas describe the result's `data` object.
All payloads must be JSON-compatible. IDs allow letters, digits, dot, underscore
and hyphen, up to 96 characters. Providers can extend `AgentProvider` to inherit
empty resources/capabilities.

`AgentRegistry(grantedScopes:)` owns host permission scopes. It registers providers
with `register(provider)` returning core `Registration`, exposes
`discover({offset, limit})`, and calls
`call(providerId:, instanceId:, tool:, arguments:, expectedRevision:,
idempotencyKey:, cancellation:, onProgress:)`. Mutations require the declared
host scopes, an expected provider revision and an idempotency key. A provider
must use normal domain commands and return the resulting revision/affected IDs.
`context.checkCancelled()` and `context.reportProgress(fraction, message)` support
bounded cooperative jobs. Providers must recheck consistency before asynchronous
mutations commit. Registration cleanup cancels in-flight calls.

Next checks: registry discovery/schema conformance; scoped/retried/stale calls;
viewport and rich triangle queries across cameras, DPR and revisions; optional
core/tools/inspector provider; MCP adapter preserving all diagnostics annotations;
then native/MCP evidence. No registry runtime check is claimed yet.

Agent contract checkpoint: 13 Dart tests pass for discovery, schema rejection,
host permission denial, exact retries, concurrent commands, cancellation,
detachment, bounded ledgers, stale reads, viewport identity, perspective and
orthographic picking, DPR/resize, clipping, provenance and frame correlation.
The implementation uses the repository-pinned Flutter 3.47.5 Dart runtime.
The shell's default Flutter uses Dart 3.9.2 and cannot resolve this workspace.
