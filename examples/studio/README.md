# Zyren Studio example

Open the native editor with the pinned Flutter SDK:

```sh
cd examples/studio
fvm flutter run -d macos
```

The Android and iOS runners use the same editor. Select a connected device with
`-d`. Android requires API 29 or later. iOS device builds need your Xcode account
and a development profile for `dev.zyren.zyrenStudioExample`.
There is no browser renderer.

## Workspace

The default editor uses the compact dockable workspace from the design study,
with GoLand-style inset panels, two tool rails and a document tab above the
viewport. Scene and Assets start at the upper left; Animation sits at the bottom
left and opens the bottom panel. Properties, Agent, Plugins and Diagnostics start
on the right. Most text is 11–12 logical pixels;
panel headers are 32 pixels high. Light and dark themes share the same density.
Both rails have upper and lower groups separated by a horizontal line. Agent
and Properties start in separate right-hand panels. Drag the shared gutter to
change the split; hiding either panel gives the other the full column.

Drag a rail icon into another group or before another icon to move and reorder
it. You can also drag a panel header to a corner or use its docking menu. The
bottom-left group opens panels below the workspace. Blue marks every open tool,
including while you work in the viewport. Panel gutters stay clear and retain
their resize targets. Close a panel to give the viewport more room, then use its
rail button to restore it. Reset layout restores the defaults.

The native viewport keeps the scene world color in both interface themes. Its
depth-tested world grid and colored axes follow the camera, stay outside saved
content and do not intercept object picks.

Docking preserves the native viewport and agent conversation. You can search
the scene tree, edit position, XYZ rotation in degrees and scale in Properties, adjust materials,
or record a pose. Transform edits share the existing undo history. Diagnostics
keeps renderer details and the complete runtime hierarchy in its own panel.
Narrow windows use a horizontal panel switcher and one bottom panel. Studio settings includes appearance, saved scene lighting and background, camera
FOV and clipping, grid visibility, gizmo size, coordinate space and snapping.
Layout and tool preferences last for the open editor session.

The Plugins panel lists the actual registry and each provider's available tools.
Imported glTF instances publish node and clip inspection automatically. Reimport,
undo and redo retire obsolete model registrations and bind the current instances.

## Plugin panel and placement configuration

Pass optional editor contributions to `StudioEditor.editorContributions`.
A registered `StudioEditorPanel` can set `defaultDock`, `initiallyOpen` and `order`.
The workspace uses those preferences on attachment and preserves your subsequent
panel moves. See `flutter_zyren_studio` for the contribution lifecycle.

`geospatial_placement.dart` provides an opt-in WGS84 placement contribution:

```dart
editorContributions: [
  geospatialPlacementContribution(
    origin: Geodetic.degrees(-87.63, 41.88, 180),
  ),
],
```

Use your project's saved origin here. The adapter maps east/up/south scene axes
to an east/north/up frame, accounts for parent transforms, and edits longitude,
latitude and ellipsoid altitude through the existing undo history. Invalid
latitude and longitude values are rejected. Removing the contribution restores
XYZ controls. This adapter does not load map tiles or persist a project origin;
your geospatial plugin owns those workflows.

## Editing

Pick an object in the viewport or inspector. Its native gizmo moves, rotates or
scales it. Choose the rotation tool in the viewport toolbar, then drag a colored
ring. Studio handles draw and receive pointer input through object surfaces, so
occluded axes remain usable. `X +0.25` provides a precise local edit. Imported
meshes select their saved instance while retaining the clicked part's source
identity for review.

The Authoring menu adds boxes and pinned GLB/bundle imports, creates prefab
instances, edits materials and engineering notes, records poses, manages clip
keys and opens independent previews. Clip keys can be retimed or removed.
Reducing a clip's duration cannot discard keys. Local authoring shares one
bounded undo history. Scene lighting and background are saved with your document and used by both the
editor and clip previews. Gizmos fit the projected selection bounds, with a
minimum handle size and a configurable maximum, and update as the camera moves.

Imports are decoded before their bundle is pinned. Enter stable source keys and
model node indices in the source-map dialog, or leave it blank for instance-level
review. On reimport, check the mapping against the new model. Notes for removed
mappings remain saved but unbound. Asset diagnostics checks the actual saved pins,
decodes each available model and validates its source map. Failed checks, missing
resources and cancellation have distinct results; Retry checks runs them again.

Save writes `studio-scene.zyren` in the application's support directory. Existing
JSON saves migrate when you save. Hover Save to see its path. The File menu lets
you create an empty scene, open a scene, save a copy, or export a runtime scene.
Open and New ask you to save or discard outstanding edits. On macOS, select the
containing scene folder when prompted so the sandbox can access companion files. Reload asks before discarding unsaved changes and prepares
the replacement before retiring the current controller. The first launch opens
an assembly fixture when no save exists. Asset pins needed by the saved document
or undo history remain retained. Clear history releases unused history assets.

Preview camera restores your working camera when stopped. Authored clip previews
use separate scene, asset and renderer scopes and cannot save over the editor.
The inspector scrolls within its available space on narrow screens. Tour opens a
registered walkthrough with live viewport, Authoring and Save anchors.

## Shared sessions

Open Shared session to host an authenticated local room or join an existing
HTTPS endpoint. Loopback HTTP is allowed for local development. The host offers
separate editor and viewer credentials. Credentials belong in the connection
form, not the saved scene.

Joining adopts shared transforms and visibility and clears local undo history.
Structural recipes, assets and materials define the session epoch, so close the
session before changing them. Conflicts require Accept remote or Keep local.
History creates a conditional inverse operation rather than overwriting later
changes. Pending writes are journaled before sending. Retry retains their exact
operation ID after restart; offline poses use the shared durable outbox.

Presence is leased. Camera sharing and following are explicit, and Stop following
releases the follower. Closing the session unregisters its provider and leaves
presence. Engineering notes remain in the saved review document and are not
replicated by the transform/visibility session.

## Runtime agents and MCP

`StudioEditorState.agents` exposes the shared registry. The host registers scene,
authoring, viewport, diagnostics, timeline and engineering review providers, plus
asset status when a resolver is configured and collaboration while attached.
The asset provider reads the editor's actual disk-backed library; it does not
create a separate Pipeline job cache.

Mutations require host grants and expected revisions. Pass `agentScopes` when
your host authorizes them. Registration and retry history end with the editor
session. Ordinary editor commands pause during save/reload, previews, modals and
gizmo drags. Annotation disclosure and engineering mutations remain denied to
agents. Remote collaboration agent writes needing an atomic cancellation guard
are unavailable until the service supplies that contract. Authenticated remote
UI edits use its existing conditional protocol.

For the authenticated debug MCP bridge:

```sh
fvm flutter run -d macos --dart-define=ZYREN_AI_DX=true --dart-define=ZYREN_AGENT_EDIT=true
```

The console reports a `ZYREN_STUDIO_AGENTS` endpoint and token. Set these as
`ZYREN_DEVTOOLS_ENDPOINT` and `ZYREN_DEVTOOLS_TOKEN` for your MCP client, then run
`ZYREN_AGENT_TOOLS=1 fvm dart run zyren_devtools:zyren mcp` from the workspace.
The debug bridge starts only when both flags are set. Its clients receive the
host-granted scopes, so keep the endpoint and token private. Built-in chat does
not need either flag and reviews its mutations in the Agent panel.

## Checks

From the workspace root:

```sh
fvm flutter test --no-pub packages/zyren_studio/test examples/studio/test
fvm dart --packages=.dart_tool/package_config.json examples/studio/tool/verify_native_mcp.dart
```

The MCP runner accepts an absolute Flutter executable path as its optional
argument. It opens an isolated temporary document and redacts bridge credentials.
From this example directory, use `fvm flutter test --no-pub -d DEVICE_ID
integration_test/studio_test.dart` for an individual native device.

Widget tests substitute a viewport and do not establish GPU behavior. Native
checks exercise real picking, gizmos, guarded agents, history, save/reload,
imports, previews, collaboration and onboarding. Submitted-frame correlation
describes submitted state; pixel visibility remains unknown. See the
[qualification record](../../packages/zyren_studio/qualification.md) for exact
platform evidence and blocked checks.

## Built-in agent

The Agent tab uses your configured LLM to discover and call attached plugin
tools. Open its Settings control, choose the protocol, enter the base URL and
model ID, and supply an API key if the endpoint requires one. System, Light and
Dark appearance are available in the same dialog. The profile is saved without
credentials; keys stay in memory for the current editor session.

You can ask it to build shapes, assemble a character blockout, edit materials,
record poses and save the scene. Every mutation pauses with its concrete tool
arguments for review. Stop cancels the run; Undo uses Studio's existing history.
The Attached tools control shows what is actually registered.

See [workflow coverage](AGENT_WORKFLOW.md) for plugin bindings, protocol checks,
character limitations and the future morphing extension path. The separate
`lib/mock/main.dart` remains a design study; the integrated workspace and working
agent are in `lib/main.dart`.

## Streamed runtime scenes

Use File > Export runtime scene to write a `.zyren` manifest with relative
`chunks/` and `assets/` companions. Keep those folders beside the manifest when
you move it. Asset bundles carry their original version pins; every referenced
file has a byte limit and SHA-256 check. Authoring saves also retain the original
prefab definitions so you can keep editing instances after reopening.

The lossless export resolves ordinary prefab overrides, drops unused asset
references, and compresses independent root hierarchies into chunks. Scenes with
animation or plugin data stay together to preserve cross-object references.
Required plugin codecs must be registered before their chunks can load.

You can use `ZyrenRuntimeScene` from `lib/runtime_scene.dart` in a Flutter host:

```dart
ZyrenRuntimeScene(
  key: ValueKey(sceneUri),
  uri: sceneUri,
  read: ZyrenFileStore.readBytes,
  onSelection: (object) => selectObject(object),
  onChunkLoaded: (controller, chunk) => installScenePlugins(controller, chunk),
)
```

Supply your selection and plugin handlers here. The example installs orbit and
picking tools and loads roots progressively. Your host owns animation playback,
plugin runtime installation and application-specific interactions. Use a new
widget key when switching files. `onReady` exposes the controller and stream;
`loadChunk` and `unloadChunk` let a host schedule individual roots. Retire render
references before unloading their resource scopes.

The file reader supports local scenes. For Flutter assets or HTTP, provide a
`ZyrenRead` callback that enforces the supplied byte limit during transport and
honors cancellation. Network scheduling and HTTP delivery have not been qualified.

The saved camera, lighting, transforms and materials drive the same native
renderer in Studio and the runtime. Editor grids, selections and gizmos are
editing aids and are excluded. Export does not simplify geometry or lower
texture quality. Flutter release builds compile the host application; `.zyren`
files remain prepared scene data. Export speed, frame-rate gains and large-scene
memory savings have not been benchmarked.

For the minimal native consumer, pass an accessible exported file:

```sh
fvm flutter run -d macos -t lib/runtime_main.dart --dart-define=ZYREN_SCENE=/absolute/path/scene.runtime.zyren
```

The export pixel check runs separately from widget tests, from this example directory:

```sh
RUN_NATIVE_GPU=1 fvm flutter test --no-pub test/native_export_test.dart
```

On 2026-10-03, the native Metal check matched all RGBA pixels for a saved-camera
scene containing diffuse and standard materials. The live macOS editor also
saved a migrated scene, exported it with companion files, and reopened the
export. Tests cover a real GLB transferred to a fresh cache, prefab animation
references, required plugin records, corrupt chunks and cancelled loads. These
checks do not establish device parity or performance at production scene sizes.
