# zyren_studio

Build and save an authored Zyren scene with stable object IDs, imported asset
pins, prefab instances, supported materials, transform clips and engineering
notes. The package is Dart-only. The Flutter editor lives in `examples/studio`.

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

## Documents and edits

Schema 2 reads schema 1 files and writes the current format. You get groups,
boxes, imported instances, nested prefabs with explicit overrides, perspective
cameras and the existing `EngineeringDocument` format. Names and runtime IDs
are never persistence keys. Imported source keys remain separate from authored
instance IDs, so a picked part can keep its review identity while its gizmo moves
the saved instance.

Documents validate finite transforms, nonsingular scales, references, cycles,
depth, prefab expansion and ordered clip keys. Limits include 1,000 authored
nodes, 10,000 expanded nodes, depth 64, 32 assets, 64 prefabs and 64 clips. Unknown
versions and unsupported edits fail before replacing the active scene.

Use `StudioAuthoring` to construct the next immutable document, then pass it to
`StudioScene.apply`. Use `scene.edit` for a synchronous tools operation or
`recordEdit` around a gizmo gesture. Structure, poses, materials, review and clips
share one history, bounded to 64 entries and 32 MiB. Camera navigation does not
invalidate it. Untracked authored changes do.

Materials support diffuse, unlit and standard shading. Imported texture maps
survive supported material overrides. `animation.dart` builds the existing
`SceneTimelinePlugin` from saved transform clips. Key removal and retiming reject
collisions; reducing duration cannot silently discard a key.

## Assets and ownership

Inject a `StudioAssetResolver`, load a `StudioAssetScope`, and give it to the
scene. Studio stores the resolver's versioned descriptor unchanged. The example
uses the Pipeline library and its disk cache for exact bundle/source/hash pins.
Studio cannot depend on Pipeline because Pipeline can bundle Studio documents.

Keep templates for the current document and undo history. Release the renderer
before closing its asset scope. A preview needs its own scope and scene. The
example does this and waits for disposal before releasing templates.

Source maps bind stable source keys to node indices in one exact import. Reimport
requires an explicit replacement map when bindings exist. Missing mappings keep
review records unbound; indices are never assumed to identify the same part in a
new model. Capture rejects edits inside imported subtrees rather than silently
losing them when the asset is reconstructed.

Register helper ownership with `registerHelper(gizmo.owns)` so attached gizmos
stay out of saves. Capture also rejects unknown scene content, external geometry
replacement and active review isolation. Lighting, effects and arbitrary shader
graphs are outside this authoring format.

## Storage, collaboration and agents

`FileStudioStore` in `io.dart` writes through a sibling staging file and serializes
writes per store instance. Missing files return null; invalid data and filesystem
failures propagate. It does not coordinate multiple local writers.

The Flutter host adapts the shared collaboration service to Studio IDs. Durable
sessions support transform and visibility edits, conditional inverse history,
explicit conflicts, leased presence, camera following and persisted offline
operations. Joining clears local undo history. Close the session before changing
structure or materials; those changes establish a different structural epoch.
Engineering notes retain the existing document format. They are saved locally;
this host does not synchronize review annotations through the transform session.

Register `StudioAgentProvider` from `agents.dart` and
`StudioAuthoringAgentProvider` from `authoring_agents.dart` in the shared registry.
Mutations require host grants, expected revisions and retry keys. The host blocks
ordinary edits during saves, reloads, previews, modals and gizmo drags. Agents use
the same authoring operations and history as the UI.

The example also registers viewport, diagnostics, timeline and engineering review
providers, plus collaboration while attached. Engineering annotation disclosure
and mutation remain denied to agents. Remote collaboration agent writes that
require an atomic cancellation guard remain unavailable; the authenticated
remote UI uses the service's ordinary conditional operation protocol.

Presented-frame metadata identifies the submitted scene, camera and viewport.
It does not establish pixel visibility or display scanout. CPU picks do not
evaluate texture alpha or custom shader displacement. Unknown measurements stay
unknown.

See [qualification](qualification.md) for checks, device evidence and release
blockers. This package remains private and uses workspace path dependencies.
