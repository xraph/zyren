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

## Editing

Pick an object in the viewport or inspector. Its native gizmo moves, rotates or
scales it; `X +0.25` provides a precise local edit. Imported meshes select their
saved instance while retaining the clicked part's source identity for review.

The Authoring menu adds boxes and pinned GLB/bundle imports, creates prefab
instances, edits materials and engineering notes, records poses, manages clip
keys and opens independent previews. Clip keys can be retimed or removed.
Reducing a clip's duration cannot discard keys. Local authoring shares one
bounded undo history. The host supplies identical directional and hemisphere
preview lighting in the editor and clip previews. These helper lights are not
authored scene data.

Imports are decoded before their bundle is pinned. Enter stable source keys and
model node indices in the source-map dialog, or leave it blank for instance-level
review. On reimport, check the mapping against the new model. Notes for removed
mappings remain saved but unbound. Asset diagnostics checks the actual saved pins,
decodes each available model and validates its source map. Failed checks, missing
resources and cancellation have distinct results; Retry checks runs them again.

Save writes `studio-scene.json` in the application's support directory. Hover
Save to see its path. Reload asks before discarding unsaved changes and prepares
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
Without the edit flag, mutations remain denied. Treat the token as a credential.

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
