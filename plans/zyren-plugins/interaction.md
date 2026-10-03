# Interaction

The seven implementation milestones are complete. You can route object input,
share gesture ownership with cameras and tools, traverse object focus, expose
semantics, project labels and edit Flutter widget surfaces over a native viewport.
The packages are unpublished. Native qualification has the limits below.

## Milestone status

| Milestone | Implementation | Verification |
| --- | --- | --- |
| Object dispatch | Nearest surface, ancestor bubbling, per-pointer hover, capture and lifecycle cleanup | CPU raycasts; removal, hiding, reparenting, unregister, disconnect, callback mutation and disposal tests |
| Native example | Compact controls, tools selection/history, shared inspector and ZeroState | Desktop and narrow widget layouts; macOS Metal and Pixel Vulkan presentation |
| Gesture arbitration | Shared InputRouter; gizmos before objects before navigation; second-touch takeover | Both attachment orders, real orbit controls, parent-scroll arena loss, existing pinch and trackpad suite |
| Keyboard focus | Ordered object traversal, Shift-Tab, Enter/Space activation, Escape and focus loss | Dart lifecycle tests, real SceneView keyboard adapter, native macOS keyboard flow |
| Semantics | Stable object identity, labels, explicit order, activation and visible focus marker | Widget semantics actions and native macOS accessibility tree/action checks |
| Anchored labels | Current camera and logical viewport projection, transforms, layers, clipping and optional triangle occlusion | Resize, DPR, camera replacement, hidden/detached/behind-camera anchors and occlusion tests |
| Widget surfaces | Flutter screen overlays with owned focus scope and input blocking | Widget and native text-entry tests; anchor removal, unmount, focus and gesture cleanup |

## Source audit and decisions

- InputSource is a broadcast observation stream. InputRouter now settles ownership
  before a registered consumer handles a press. Equal priorities use stable IDs,
  so plugin attachment order does not decide whether the camera moves.
- The transform gizmo claims first, registered objects claim primary presses next,
  and orbit/environment navigation handle the remaining presses and scrolling.
  A second touch cancels the earlier tool/object sequence before navigation takes
  it over. Overlay focus or an active overlay press cancels and blocks scene input.
- Raycaster.captureFromCamera supplies clipping, layers, visibility, transforms
  and triangle hits. The closest geometric surface occludes objects behind it,
  including when that surface has no registered handler.
- SceneObjectFocus is separate from tools selection. SceneView owns OS focus;
  optional FocusInputSource reports loss even when no key is held. Application
  shortcuts remain outside the renderer.
- SceneAnchorProjector allocates no native resources. Widget surfaces are ordinary
  Flutter screen overlays, not textures on meshes. Their IDs preserve Flutter
  state while their anchors remain visible and attached.
- The Dart packages depend on public core contracts. Flutter adaptation lives in
  packages/flutter_zyren_interaction. Rendering stays native Metal/Vulkan/DX12;
  no browser or WebGL fallback was added.

## Public ownership

SceneInteractionRouter owns handlers and pointer state for one scene. Its camera
and viewport getters read current host values. SceneInteractionPlugin borrows the
router and connects input for its attachment lifetime. Hosts dispose the router
when the scene owner ends; neither router nor plugin owns scene objects or tools.

Capture remains exclusive per pointer and continues outside the viewport. Hover
follows the actual surface. Touch hover ends on up; call clearHover from the host's
viewport-exit callback for a mouse. Cancel reaches a pressed target even when its
handler did not capture. Handler errors reach the supplied callback or Dart zone.

Flutter overlays borrow the controller and router. A widget surface owns its focus
scope and input-blocking registration. You retain ownership of controllers supplied
to its child widgets. Hidden, clipped and detached anchors unmount their surfaces.

Shared changes were recorded before editing and checked against current owners:
core input contracts and orbit/environment adapters, the transform gizmo adapter,
FlutterInputAdapter, optional devtools transport files and workspace registration.
The active declarative owner's files and facade were preserved. Shared edits,
resolution and Git staging used /tmp/zyren-plugin-expansion.lock.

## Shared agent contract

This workstream owns packages/zyren_agents, viewport queries and the optional
existing devtools adapter. Other plugin owners implement their own providers.

AgentProvider declares id, version, instanceId, revision, tools, capabilities,
resources and invoke(tool, arguments, context). AgentTool supplies argument/result
schemas, read/write classification, host scopes and byte limits. Registration
returns a core Registration. Discovery is paginated; payloads and calls are bounded.

Mutations require expectedRevision and idempotencyKey. Exact retries share a result;
conflicting keys fail. Retired keys remain tombstoned across provider reattachment
within a registry session. The ledger does not evict accepted keys to make room.
Persistence across a host process restart belongs to its domain command store.

Viewport context identifies scene, document, viewport, camera and known presented
frame. Picking supports logical pixels, normalized coordinates, host-supplied
window origins and frame-matched image mappings with letterbox metadata. Rich hits
include source/runtime identity, geometry, approved provenance, action references
and projected mesh bounds. Bounds report layer/section decisions and their method.

The native example registers viewport, interaction and existing inspector providers.
Selection, transforms and history use SceneToolsPlugin; undo/redo report the actual
history target. Host state reports focus, selection, hover, pointer and UI overlays.

The existing authenticated loopback/CLI/MCP bridge exposes discovery, reads and
host-scoped commands. Long work uses bounded job start/status/cancel/release tools,
progress and a change cursor. At most 16 jobs and 128 change events are retained;
cooperative cancellation is requested after five minutes and on bridge disposal.
MCP resource list/read/subscribe/unsubscribe exposes zyren://agents/changes. The
subscription polls the same protected endpoint every 500 ms, notifies on changes
and stops on unsubscribe or EOF. Default diagnostics remain read-only.

## Verified evidence

All commands used the repository-pinned Flutter 3.47.5 SDK.

- 149 Dart tests passed across interaction, agents, all tools/devtools tests and
  orbit/environment plugin tests. Three existing native-gated devtools tests were
  skipped. The later resource-subscription slice passed its 12 relevant tests.
- Five owned Flutter tests passed, including 1200x800 and 360x640 layouts, the
  public input adapter, semantics actions, focus indicators, text entry and parent
  scroll cancellation. The renderer in widget tests is substituted.
- Seventeen existing Flutter input, pinch, trackpad and keyboard tests passed.
- Scoped analysis of agents, devtools, interaction, the Flutter adapter and shared
  input/controls files passed. Owned diffs passed whitespace checks.
- The final package-boundary and Apple ABI header check passed.
- Native macOS integration passed on Apple M3 Max: Metal nativeView presentation,
  zero readback bytes, hover/capture/drag, agent undo/pick, focus, widget text entry,
  orbit and teardown. See packages/zyren_interaction/qualification/macos-interaction.json.
- Pixel 9 Pro integration passed: Vulkan on Mali-G715, sharedTexture presentation,
  zero readback bytes and the same interaction flow. See
  packages/zyren_interaction/qualification/android-interaction.json.
- The Android runner requires API 29, matching native GPU presentation. The final
  arm64 debug APK build passed after the native owner resolved a concurrent
  Rust field-visibility error. Other Android ABIs were not rechecked.
- A live external CLI MCP process verified the native macOS host: discovery,
  preserved read-only annotations, rich picking, selection, exact retry, stale
  rejection, coordinate conversion, projected bounds, jobs, change cursors and
  resource subscribe/notify/read/unsubscribe through the real CLI transport.
  Credential-free evidence is in qualification/macos-metal-mcp.json.
- The running macOS app was inspected through CUA. Its native accessibility tree
  exposed Orange/Blue object buttons; activation selected an object. Pointer drag
  moved the box, Tab/Enter selected the next object, and the anchored editor
  accepted text. The preview was closed after inspection.
- Android, iOS and Windows runners were added. The iOS app compiled and signed.
  The first iPhone launch was stopped when other workstreams targeted that device.
  The idle iPad run built successfully but could not discover its wireless VM
  service and exited after 615 seconds. Flutter reported the local-network
  permission or USB connection requirement.

## Remaining qualification and capability limits

- Live iOS verification is pending the device connection/permission step. Windows
  and DX12 need a Windows host. Neither is inferred from the generated runner or
  passing macOS/Android checks.
- Native mobile input tests inject Flutter events on physical devices. They do
  not establish human touch ergonomics, every soft keyboard or full VoiceOver/
  TalkBack traversal. macOS accessibility actions and keyboard traversal were
  checked directly; screen-reader-specific qualification remains separate.
- CPU picks and projected bounds leave rendered pixel visibility unknown. Alpha
  masks, transparent compositing, custom displacement and line/point footprints
  need matching renderer or plugin queries. Native GPU object/depth and exact
  frame-image capture are explicitly unsupported by this provider. Host-supplied
  image mappings require real frame correlation; current FrameStats does not
  supply captured scene/camera revisions, so the example leaves it unknown.
- No package publication, push or merge was performed. Provider retrofits in other
  plugin packages remain their owners' responsibility.

## Local commits

- 5ddc7ea: initial shared agent contract and viewport queries.
- 828955b and a9b1b9c: initial object interaction/native example and evidence.
- 7a92f7d: shared gesture routing, object focus, semantics, labels and widget surfaces.
- 2a37386: bounded agent jobs, coordinate evidence and session retry tombstones.
- 3a5bb6e: MCP resource discovery, reads and change subscriptions.

The final qualification commit also records cancellation without capture, layer-aware
anchors, visible focus, mobile runners, MCP resources and the qualification files.
