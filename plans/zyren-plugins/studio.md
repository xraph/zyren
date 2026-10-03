# Studio workstream

You can follow the editor work here. This checkpoint owns `packages/zyren_studio`
and `examples/studio`. It does not change the declarative Flutter API.

## Source audit and decisions

- `SceneToolsPlugin` already provides selection, bounded undo/redo and transform
  sessions. `TransformGizmoPlugin` supplies native translation, rotation and scale
  handles. Studio composes them with `SceneOutlinePlugin` and orbit controls.
- `SceneInspector` supplies the hierarchy, renderer statistics and issue view.
  Flutter exports a shared illustrated `ZeroState`. No registered onboarding
  provider or Studio walkthrough exists in this checkout, so no tour is exposed.
- `SceneTimelinePlugin` supports transform/camera tracks and clip mixing. The first
  preview uses its camera track; authored animation remains a later milestone.
- `EngineeringDocument`, `SceneEngineeringPlugin` and engineering session stores
  already preserve source records and annotations. Studio embeds that document
  unchanged and binds its source records to saved node IDs. Review synchronization
  remains the engineering service's responsibility.
- `Object3D.name` is immutable and runtime identities do not survive reconstruction.
  The first document stores stable IDs, parent IDs, group/box recipes, local pose,
  visibility, diffuse color, perspective camera and optional source record IDs.
  Unsupported schema versions and recipes fail before the active scene changes.
- The package stays Dart-only. The example owns Flutter composition and native
  presentation. No geospatial dependency or browser renderer is introduced.

## Schema coordination

Collaboration can adapt to `documentId` and each node's stable `id`/`parentId`.
`sourceId` references `EngineeringDocument.objects`, preserving imported identity
separately from an authored instance ID. Poses use local position and scale XYZ,
rotation quaternion XYZW, and visibility. `schemaVersion: 1` describes the file
format, not a server revision or collaboration operation clock. Keep adapters
small until the collaboration operation contract settles. Studio does not define
a second review merge or authorization protocol.

The collaboration plan now uses `(source, key)` references and a session epoch.
The adapter will map authored instances to `(document.id, node.id)` and retain
`sourceId` as importer provenance. A rebuilt editor starts a new session epoch.

## Mandatory runtime agent access

The shared contract belongs to `packages/zyren_agents` in the interaction chat.
Studio must register its real provider in the host, using that registry and the
existing devtools transport. Completion requires discovery/schema/action tests,
cleanup, stale target checks and a native plus MCP flow. A local command helper
alone does not meet this requirement.

The implemented typed command adapter uses tools selection/transform/undo/redo,
host permission callbacks, session-scoped expected revisions and bounded retry
receipts. Reads expose document identity, selection and history availability.
The Flutter host exposes active viewport/panel, hover, tool mode, pointer and
blocking overlays, logical rectangle, DPR, camera, current revision and the
latest presented frame. Studio and viewport providers register in the shared
registry. The optional debug bridge uses the existing devtools MCP transport. Presented scene revision remains unknown unless the
presenter supplies it. CPU triangle hits are approximate geometry evidence with
explicit texture alpha, shader displacement and line/point limits.

Keep reads passive. Revoke access on disposal and disable edit commands during
save/reload, preview or a gizmo drag. Assemble other attached plugin providers only as their
shared adapters become available. The host registers the actual engineering review and timeline providers.
Engineering reads expose only origin, tag and material properties; annotations
and mutations remain denied by host policy. Timeline commands require
`timeline.playback` and use the host's reversible preview state. Asset provider
coverage remains pending asset import.

## Shared mutation request

Register `packages/zyren_studio` and `examples/studio` in root `pubspec.yaml`, then
resolve dependencies under `/tmp/zyren-plugin-expansion.lock`. Preserve entries
from other chats. No shared source API changes are required for this checkpoint.

The diagnostics adapter initially failed schema registration. The interaction
owner's schema fix landed during verification. The latest widget tests discover
Studio, viewport, diagnostics, timeline and engineering review providers with an
empty `screen.agentProviderGaps`. Studio keeps that explicit gap report if a
future optional diagnostics adapter cannot register.

The native idle check exposed unconditional `_notify()` from
`packages/zyren_timeline/lib/src/timeline_actions.dart::_syncActionDemand`, called
by the paused timeline's frame hook. The requested shared fix is to avoid
invalidating when an idle tick changes nothing, while retaining notifications
for explicit action changes and completed fades. The characters/navigation owner
has active edits in that file and `lib/zyren_timeline.dart`; Studio leaves them
untouched. Its camera-only timeline skips the frame hook while paused. Seek,
play and pause still use the shared timeline methods. Remove this host guard
after the shared idle behavior is fixed and qualified. Authored action clocks
remain outside this preview's scope.

## Phases and acceptance

1. Saved document and reconstruction. Validate bounded input, unique IDs, parent
   references, acyclic hierarchy, finite transforms, camera and source bindings.
   Save/reload must reconstruct hierarchy, appearance, poses and annotations.
   File replacement must be atomic; failure must leave the old save intact.
2. Compact native editor. Use tools, native gizmos and inspector; select, manipulate,
   undo, save and reload. Separate loading, missing files and errors. A camera
   preview must use the timeline service and release its frame demand on stop.
   Check desktop and narrow layouts, then exercise the real native renderer when
   a device is available. CPU tests do not qualify native presentation.
3. Assets and prefabs. Integrate the pipeline's settled asset descriptor through an
   optional adapter, retain URI/version/source IDs, validate missing resources,
   and add prefab instancing with explicit overrides and resource scope disposal.
   Acceptance: reimport preserves source links and reports stale/missing assets.
4. Material and animation authoring. Add supported material property controls,
   versioned clip/keyframe data, deterministic sampling and timeline edit history.
   Acceptance: save/reload reproduces authored materials and animation poses.
5. Diagnostics and live previews. Compose `SceneDiagnostics`, asset diagnostics,
   preview isolation and cancellation, plus collaboration operations and presence
   after their contracts settle. Acceptance includes conflict, permission denial,
   disconnected recovery and resources returning to baseline after repeated previews.
6. Broader native qualification and onboarding. Verify macOS, Android and iOS
   independently; register a real walkthrough only when the shared provider exists.

## Checkpoint evidence

Implemented checkpoint:

- Dart document validation, reconstruction, stable instance/source bindings,
  engineering review round trips and atomic local file replacement.
- Flutter editor with shared inspector and ZeroState, native gizmos, selection,
  transform history, save/reload with discard confirmation, and timeline camera
  preview. The macOS runner and native integration test are included.
- Shared-registry Studio, viewport, diagnostics, timeline and engineering review
  providers, guarded ordinary commands,
  bounded node pages, retries, stale-target checks, and disposal. The host reports
  viewport coordinates/DPR, camera, selected/hovered items, active panel/tool,
  blocking overlays, storage state and known presented-frame timing.
- Explicit helper ownership prevents gizmos inside authored groups from entering
  saves or invalidating authored revision guards. A regression test uses the real
  transform gizmo and captures after selection/editing.
- Opt-in existing devtools bridge with read-only diagnostics intact. Debug flags
  `ZYREN_AI_DX` and `ZYREN_AGENT_EDIT` independently enable transport and edit scopes.

Automated evidence on 2026-10-02:

- `dart analyze packages/zyren_studio examples/studio`: no issues.
- Pinned Flutter 3.47.5: `flutter test --no-pub packages/zyren_studio/test
  examples/studio/test`: 9 passing tests. Coverage includes malformed schemas,
  cyclic/missing hierarchy, source identity, poses, history, rejected unsupported
  edits, file failures, shared-provider schema checks, permissions, retry identity,
  stale/removed targets, cleanup, all five host provider registrations, empty
  provider-gap reports and 1200x800 / 396x844 widget layouts.
- An actual external `zyren_devtools` MCP CLI process completed initialization,
  tool discovery, a Studio query and a permitted transform through an authenticated
  loopback server. The fixture uses a test renderer; this is transport evidence,
  not native screen evidence. Original diagnostic read-only annotations passed.

Native evidence and blockers:

- The earlier signing and disk-space failures are resolved. On 2026-10-02 the
  integration test launched on Apple M3 Max with Metal, required `nativeView`
  presentation and recorded zero frame readback bytes.
- Native checks pass for pointer selection, an actual transform-gizmo drag,
  rejection of overlapping agent edits, undo/redo, atomic file save, discard
  confirmation, reload, retired-controller disposal and a new command session.
  The viewport and inspector also pass at 396 logical pixels with no layout
  exception. The app test uses an isolated temporary document.
- The normal desktop app was also launched and visually inspected. The native
  block/base scene, toolbar and side inspector rendered with Metal presentation.
  Narrow-width evidence is from the native integration test above.
- Three camera seek/stop cycles restore the complete working camera pose.
  Editing is unavailable during preview. Pausing an idle timeline preserves
  editing. Native playback advances the clock and presents changed camera poses.
  After Stop preview, the test waits for pending presentation work to settle and
  verifies that frame IDs stop advancing. The camera-only host guard passes this
  check; the shared timeline follow-up above remains open.
- `examples/studio/tool/verify_native_mcp.dart` launches the native test and a
  separate real `zyren_devtools` MCP process. Authenticated loopback checks pass
  for all five providers, a pick retaining `part:block`, the bound engineering
  record, timeline inspection, guarded transformation, exact retry, stale
  rejection, denied review mutation and a later presented frame. The runner
  redacts connection credentials and waits for both processes to exit.
- Source snapshot and presented-frame correlation remain distinct. Native
  presentation confirms the renderer path; the CPU pick still reports unknown
  pixel visibility and unknown scene/frame correlation.
- Android and iOS runners and Studio device checks remain pending. Swift Package
  Manager adoption is still a shared Flutter plugin build warning; CocoaPods
  successfully built this example. This workstream did not change shared files.

Run the complete native plus MCP check from the workspace root:

```sh
fvm dart --packages=.dart_tool/package_config.json examples/studio/tool/verify_native_mcp.dart
```

The runner accepts an absolute Flutter executable path as its only argument.
The final automated run used Flutter 3.47.5 and passed one native integration
scenario plus the external MCP assertions. The nine package/widget tests and
scoped analysis also pass. Input-router and texture-loader changes briefly
interrupted builds during concurrent work; the final native run used their
corrected working-tree versions.

Remaining scope:

- Asset and prefab authoring, pipeline bindings/version pins, material editing,
  saved animation/keyframes and authoring history, and isolated live previews.
- Collaboration authority/epoch adapter and persistence, engineering edit policy
  and review authoring, asset diagnostics, and broader native qualification.
- Rich native pixel evidence/capture correlation. Current hits are CPU triangle
  geometry, and the presenter's submitted scene/camera revision is unknown.
- A registered onboarding provider/walkthrough does not exist here; no inactive
  tour control was added. The initial document supports groups and diffuse boxes.
- The package remains `publish_to: none`. This is a useful first editor checkpoint,
  not a complete plugin or a rollout/publication claim.

Local commits:

- `6b080d8681f568b6538076a2cfff91a3fcfb0e0e`: versioned scenes, editor, saved
  file flow, Studio/viewport agent adapters and authenticated MCP coverage.
- `8a443ae51b97d5f31e9d03580de8989e7f4ed9dc`: actual timeline and engineering
  provider composition, five-provider discovery checks and updated evidence.

No push or merge was performed.
