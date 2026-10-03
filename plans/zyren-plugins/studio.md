# Studio workstream

You can follow the editor work here. This checkpoint owns `packages/zyren_studio`
and `examples/studio`. It does not change the declarative Flutter API.

## Current status, 2026-10-03

The remaining Studio implementation now includes source-map reimport, asset
checks and its actual disk-library agent provider, imported-instance selection,
editable clips, durable collaboration/recovery, shared registered onboarding,
submitted-frame correlation and Android/iOS runners. The package README, example
and changelog describe schema 2. The historical checkpoints below are retained
as an implementation record; use this status and the qualification file for the
current result.

The combined Studio/example/rendering regression suite passes 30 tests. Scoped
analysis and package boundaries pass. macOS Metal plus external MCP and physical
Pixel Vulkan native flows pass. Three preview cycles preserve the document and
tracked GPU allocations. The unsigned iOS build passes, but physical launch is
blocked by Xcode account/provisioning. Direct desktop visual/accessibility review
is blocked by the locked Mac. Publication is blocked by the project license
choice and five path dependencies. Remote guarded agent writes remain limited
by the collaboration transport contract; review notes remain local.

See `packages/zyren_studio/qualification.md` for exact device, memory-counter and
release limits. No cross-platform or public-release completion is claimed.

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

## Completion work, 2026-10-03

The full remaining roadmap is now requested. Keep the checked editor running
while adding these vertical increments and commit each checked increment.

1. Introduce schema version 2 with a version-1 reader, asset reference payloads,
   prefab definitions and explicit instance overrides, supported material values,
   and bounded authored transform clips. Validate references and expansion before
   replacing the current document. Preserve review/source identities on reimport.
2. Add an injected asset resolver and bounded template lifetime, then connect the
   host to `PipelineAssetReference`, `PipelineAssetLibrary` and `FilePipelineCache`.
   Pipeline already depends on Studio for document bundling. Studio must not
   depend on Pipeline; keep the adapter in the example and save the shared
   descriptor unchanged. Missing, mismatched, failed and cancelled loads must
   remain distinct, with a retry path that retains the working scene.
3. Add authoring history around the existing tools/gizmos, plus compact asset,
   prefab, material, animation and review controls. Reuse the shared timeline for
   deterministic playback. Preview a reconstructed document with independent
   resources so cancellation never alters authored poses.
4. Integrate the existing collaboration client, durable authority, offline queue,
   presence and conditional undo. Use host grants and explicit conflict decisions.
   Engineering notes continue through its existing document/session APIs.
5. Close the shared idle-timeline request, inspect current presenter correlation
   APIs, and verify provider discovery, guarded authoring commands and real native
   MCP flows. Keep any unavailable pixel evidence explicit.
6. Add Android/iOS runners and a real registered walkthrough, qualify available
   hardware, and prepare release validation. Publication also requires released
   dependency versions and publisher access; record the actual outcome.

Shared dependency resolution for new Studio dependencies will use the existing
lock. No shared source change is requested until its exact API gap is confirmed.

## Original acceptance criteria

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
- `d166196cc839eba4abc85b21c32b60a9cc286c73`: native MCP qualification, gizmo
  command guards, idle camera previews, lifecycle checks and updated runbook.

No push or merge was performed.

## Version 2 document increment

You can now round-trip pinned asset descriptors, nested prefab definitions,
instance overrides, supported material properties and bounded transform clips.
Version 1 files remain readable. Reconstruction expands stable instance paths,
keeps imported source IDs separate, and requires an explicit loaded asset scope.
Missing or different pins fail before replacement. Closing a cancelled load
releases every completed template.

The runtime saves prefab edits as overrides and rejects unregistered imported
hierarchy or material changes. Asset loading is injected to preserve the existing
Pipeline to Studio dependency direction. The editor controls and Pipeline host
adapter are the next increment; this document change does not qualify those flows.

Checks: scoped analysis passes. All 13 package/widget tests pass, including v1
migration, nested prefab/material round trips, malformed definitions, immutable
asset pins and cancelled scope cleanup. Native authoring checks remain pending.

## Shared authoring API request

Studio needs `SceneEngineeringPlugin.replaceDocument(next, expected: current)` in
`packages/zyren_engineering/lib/zyren_engineering.dart`. It should validate the
same document ID, size and current identity, reject a storage operation in flight,
restore isolation and remove bindings whose records disappeared before replacing
review data. This lets document undo restore annotations synchronously without
creating a second engineering merge protocol. Existing load and synchronization
behavior stays intact.

Neither engineering nor timeline has working-tree edits at this check. No other
program plan requests this API. The paused timeline fix can now be limited to an
early return from `_tick` when both the main clock and every action are idle.
Explicit commands still notify, and active fades retain their normal frame path.
Both shared changes need regression checks before the Studio host adopts them.

## Authoring and preview increment

The editor now imports GLB and Pipeline bundles through the native file picker,
loads exact cached pins, and retains templates needed by current undo history.
You can reimport an asset while keeping its root instance and review record.
Imports with explicit subobject source maps require an updated map when their
pin changes; the picker reports that requirement instead of guessing identities.
The CPU template pool stops at 64 entries. Clearing history releases unused
entries, while disk pins retain the saved document and current history.

The authoring menu adds boxes, converts subtrees to prefabs, instances the latest
prefab, edits supported materials, records poses in clips, removes subtrees and
edits engineering notes. One bounded history covers those edits and normal gizmo
transforms. The authoring agent provider exposes the same validated mutations,
with host grants, revision checks and shared-registry retry receipts.

Clip preview reconstructs the document with a separate asset scope, scene and
native controller. Closing it waits for renderer disposal before releasing its
templates. The shared timeline idle fix removes the earlier camera-only guard.
Engineering's expected-document replacement API lets history restore notes while
rejecting stale review data or a storage operation already in flight.

Checks on 2026-10-03:

- Scoped analysis passes. The 17 package/widget tests passed together, followed
  by both agent tests passing after adding the authoring-provider grant, retry,
  stale-revision and shared-history regression.
- All 97 timeline and engineering tests pass with the pinned Dart test runner.
  Their subprocess tests require Dart; running those CLI tests inside Flutter's
  test VM injects VM-service output and produces unrelated subprocess timeouts.
- The macOS native/MCP runner passes on Apple M3 Max, Metal, native-view
  presentation and zero readback bytes. The scenario loads the textured assembly
  GLB, edits material and clip data, samples the clip halfway in three independent
  previews, waits for each preview controller to dispose, verifies unchanged
  authored state, instances a prefab and verifies saved pins, clips and prefabs.
- Existing native pick, real gizmo drag, agent guard/retry/denial, undo/redo,
  idle-frame settling, save/reload and 396-pixel layout checks still pass.

Remaining work includes collaboration sessions and recovery, source-map reimport
controls, editable keyframe removal/retiming, asset diagnostics, registered
onboarding, Android/iOS qualification and release validation. Current native
picks still report unknown pixel visibility and frame correlation.

## Submitted-frame correlation request

Add optional `FrameSource` metadata to `FrameStats` in
`packages/zyren/lib/src/rendering/frame_output.dart`, and preserve output payloads
when replacing their stats. `packages/zyren/lib/src/plugins/engine.dart` should
record scene and camera revisions around its synchronous submission capture,
then attach those values to that submission's returned frame. Leave legacy
renderers and captures that mutate their source uncorrelated.

`packages/flutter_zyren/lib/src/controller/scene_controller.dart` should add the
logical viewport and DPR used for that render before the presenter reports it.
Export the metadata through `packages/zyren/lib/zyren.dart`. This is additive:
existing stats constructors keep null source metadata. Studio can then populate
the existing `AgentPresentedFrame` fields. Matching revisions establish submitted
state correlation only; they do not prove pixel visibility or display scanout.

These paths have no working-tree edits at this check. Other plans record missing
correlation but do not request an overlapping implementation. Regression checks
must cover source mutation during an asynchronous render and preserve native
surface/frame receipts.

## Onboarding provider request

No shared onboarding registry exists in `flutter_zyren`. Add an exported,
optional `OnboardingProvider` in its widgets directory. It registers walkthrough
IDs with actual widget anchors, validates an anchor before starting each step,
and keeps navigation and focus inside a dismissible dialog. Studio will register
its saved-scene walkthrough and expose it from the toolbar and empty state.
Nothing starts automatically. These shared paths have no current edits.

## Package boundary coverage

Add Studio to `tool/check_package_boundaries.dart` with only its five declared
Zyren dependencies. Apply the existing public-import check to it as well. The
checker currently omits this package, so a passing workspace check alone does
not establish Studio's boundary. The shared checker is clean at this request.
