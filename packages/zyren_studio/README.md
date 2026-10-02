# zyren_studio

You can reconstruct an authored scene, edit it through `zyren_tools`, and save it
as a versioned JSON document. The package is Dart-only. `examples/studio` supplies
the Flutter editor, native viewport, inspector and camera preview.

```dart
final document = StudioDocument(
  id: 'assembly-study',
  title: 'Assembly study',
  nodes: [StudioNode(id: 'block', label: 'Block')],
);
final studio = StudioScene(document);
// Attach studio.tools and studio.engineering to your scene engine.
// After each attachment, call studio.bindReview().
final saved = studio.capture().encode();
final restored = StudioScene(StudioDocument.decode(saved));
```

Version 1 stores groups, diffuse boxes, local transforms, visibility, hierarchy,
perspective cameras and the existing `EngineeringDocument` format. Authored IDs
survive reconstruction. `sourceId` links a node to an engineering source record;
object names and runtime IDs are never persistence keys. Document IDs use the
shared registry's 96-character identifier format. Node and source IDs retain
separate 256-character bounds.

You get validation for finite poses, nonsingular scale, duplicate IDs, missing
parents, cycles, hierarchy depth and source bindings. The format permits at most
1,000 nodes and 64 hierarchy levels. Input is bounded to 4 Mi characters. Unknown
schema versions and node recipes fail before you replace your current scene.

`FileStudioStore`, imported from `package:zyren_studio/io.dart`, serializes writes
per store instance and replaces the saved file through a sibling staging file.
A missing save returns null. Invalid documents and filesystem errors propagate.
Use it for one local editor; it does not coordinate multiple writers or replace
the collaboration service. The host chooses the directory and document ID.

Capture includes registered content only. Register helper ownership with `registerHelper(gizmo.owns)` so helpers stay out of
the file even when the gizmo attaches inside an authored group.
External additions, removed objects, geometry/material replacement and active
review isolation cause capture to fail. This checkpoint does not serialize
imported assets, prefabs, material edits, authored animation, lighting or effects.

## Runtime agent access

Import `package:zyren_studio/agents.dart` for `StudioAgentProvider` and
`package:zyren_studio/commands.dart` for its normal command adapter. Register the
provider in your host's `AgentRegistry`. Studio does not create a transport.

The provider declares `state`, paginated `nodes`, `select`, `transform`, `undo`
and `redo`. Reads expose document identity, current transforms, stable and runtime
IDs, source references, selection, history and host screen context. Each node
page contains at most 50 entries. Imported labels remain untrusted scene data.

Mutations require `studio.select` or `studio.edit`, an expected provider revision
and an idempotency key. The host also supplies command availability and permission
callbacks, so you can block edits during preview, save/reload or modal dialogs.
Transform commands enter the same undo history as gizmo edits. Reused command
keys cannot apply an edit twice. A full retry ledger rejects new commands until
you deliberately start another session. Dispose registrations and commands when
the editor closes or replaces its scene.

The example registers the shared viewport provider beside Studio. It reports
camera and viewport dimensions, DPR, active panel, pointer, geometric hover,
selection, tool mode, blocking overlays and known presenter timing. Triangle hits
carry Studio IDs and source provenance. Rendered pixel visibility and the scene
revision of a presented frame remain unknown. Read each hit's coverage before
using it; CPU triangles do not evaluate texture alpha or custom shader displacement.

The example can opt into the shared devtools bridge for an external MCP client.
An external CLI test covers discovery and a transform over authenticated loopback
with a CPU fixture. Direct registry tests and native checks are recorded in
[the workstream plan](../../plans/zyren-plugins/studio.md). The plan also tracks
asset authoring, prefabs, materials, animation and broader device qualification.
