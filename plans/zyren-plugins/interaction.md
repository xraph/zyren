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

Milestones 1 and 2 have an implementation checkpoint. The evidence below records
automated checks, native Metal/MCP results and remaining qualification.
Milestones 3 through 7 remain in the backlog. Neither package is published.

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
then native/MCP evidence. Current results are recorded below.

Agent contract checkpoint: 13 Dart tests pass for discovery, schema rejection,
host permission denial, exact retries, concurrent commands, cancellation,
detachment, bounded ledgers, stale reads, viewport identity, perspective and
orthographic picking, DPR/resize, clipping, provenance and frame correlation.
The implementation uses the repository-pinned Flutter 3.47.5 Dart runtime.
The shell's default Flutter uses Dart 3.9.2 and cannot resolve this workspace.

Shared devtools edits requested after ownership inspection: add an optional agent
bridge in `packages/zyren_devtools/lib/agents.dart`; extend `lib/io.dart`,
`lib/src/mcp.dart`, `bin/zyren.dart` and `pubspec.yaml` compatibly. Default diagnostics
remain read-only and retain their tool definitions and annotations. Hosts opt in
with a registry; CLI MCP exposure also requires `ZYREN_AGENT_TOOLS=1`. The registry
alone grants command scopes. Existing loopback token, origin, byte and rate limits
remain in force. No other plan claims these transport files.

Shared contract committed as `5ddc7ea`. Initial native occupancy inspection found
`examples/planet/build/macos/Build/Products/Profile/planet.app` running (PID 35013).
Do not change that session. CPU/widget checks use this package's own outputs.

Additional compatible introspection requests: `SceneToolsPlugin.undoTarget` and
`redoTarget` identify the object a history command affects; agent results must not
substitute the currently selected object. `SceneDevtoolsPlugin.sceneRevision`
reads the current scene revision without building an inspection snapshot. Status
and plan inspection found no owner editing those Dart files. These getters expose
existing state and do not change command behavior or ownership.


## Current checkpoint, 2026-10-02

Implemented:

- Object dispatch to the nearest registered target, ancestor bubbling, direct
  enter/leave, per-pointer hover and exclusive capture. Removal, hidden ancestors,
  reparenting, handler disposal, input detachment and router disposal clean up
  capture. Captured drags continue outside the logical viewport.
- A compact macOS Flutter example with native Metal, real tools selection,
  undoable dragging, remove/reset, shared ZeroState and a shared scene inspector.
  Its host reports pointer coordinates and the inspector's blocking overlay.
- `zyren_agents` schema 1.0, a typed provider registry, paginated discovery, bounded
  payloads, host scopes, expected provider revisions, exact mutation retries,
  cooperative cancellation/progress and a shared read conformance harness.
- Named viewport context and CPU triangle picking with source/runtime identity,
  geometry, approved semantic/provenance fields, action references and explicit
  coverage. Perspective/orthographic cameras and logical pixels are tested.
- Existing tools and inspector/diagnostics adapters. Selection, transforms,
  undo/redo go through SceneToolsPlugin. History target getters report affected
  IDs accurately even when another object is selected.
- Optional agent discovery/query/command tools through the existing loopback,
  CLI and MCP transport. Default diagnostics retain their read-only annotations.

Automated evidence:

- 70 Dart tests pass across `zyren_agents/test`, `zyren_interaction/test`,
  `zyren_tools/test/tools_test.dart` and devtools agent, I/O, diagnostics and
  plugin tests. This includes 19 interaction tests and 14 shared-agent tests.
- Three Flutter widget tests pass: 1200x800 and 360x640 controls keep more than
  half the viewport height available, and real public SceneView input exercises
  hover, capture, transform history and the shared inspector. The widget renderer
  is substituted; these checks do not establish GPU presentation.
- `dart analyze` for zyren_agents, zyren_interaction, zyren_devtools and zyren_tools
  reports no issues. The relevant diff passes whitespace checks.

Live native and MCP evidence:

- `example/integration_test/native_interaction_test.dart` passed on macOS using
  nativeView presentation and zero readback bytes. It exercises hover, capture,
  dragging, agent undo, rich picking and disposal against the native renderer.
- The external `example/tool/native_mcp_probe.py` passed through the real CLI
  stdio MCP session and authenticated loopback connection to that native app.
  It verifies discovery, preserved diagnostics annotations, rich picking, permitted
  selection, exact retry and stale-command rejection.
- `packages/zyren_interaction/qualification/macos-metal-mcp.json` contains the
  credential-free result: wgpu-native, Metal, Apple M3 Max, 1600x1000 render size,
  three registered providers and the final selected runtime ID.
- FrameStats exposes the presented frame ID/time but not captured scene/camera
  revisions. The example leaves that correlation unknown. CPU hits leave rendered
  pixel visibility unknown. The registry does not manufacture exact pixels.

Remaining work and blockers:

- Desktop visual inspection is blocked by the locked Mac. CUA could not unlock
  it. Native automated presentation passed, but no screenshot or physical pointer
  check is claimed. The workstream preview app was closed after the attempt.
- iOS/Android/Windows runners, real touch input and mobile lifecycle checks remain
  unverified. The supplied runner is macOS only.
- Gesture arbitration with cameras, keyboard focus, semantics, anchored labels
  and widget surfaces remain milestones 3 through 7 with the acceptance criteria
  above. Native GPU object/depth queries, frame-matched image capture, normalized
  or image coordinate conversions and projected object bounds remain additional
  agent context work.
- The direct registry supports cancellable jobs and progress. The optional MCP
  adapter currently exposes request/response calls; cancellation/progress events,
  resource subscriptions and durable retry records across registration lifetimes
  remain transport work. Hosts must keep long operations bounded until then.
- Plugin-specific providers and existing-plugin retrofits belong to their owners.
  This checkpoint supplies the shared contract and adapters for core viewport,
  interaction, tools and inspector/diagnostics. It does not claim every plugin is
  integrated or that the complete interaction plugin is ready for publication.

Commit evidence: `5ddc7ea` contains the first checked shared agent contract and
viewport slice. `828955b` contains object interaction, tools/inspector adapters,
the native example, optional devtools transport, lifecycle fixes and verification
fixtures. Both are local commits on the existing main branch. Nothing was pushed
or merged. The remaining root workspace ordering diff belongs to concurrent work
and was left untouched.
