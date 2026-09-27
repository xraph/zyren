# gpu3d_engineering

Keep engineering records and review notes alongside a native Dart scene. You
supply IDs from your model importer, then bind those IDs to live objects after
each import. Display names and inspector IDs are not persistent keys.

```dart
final review = SceneEngineeringPlugin(
  document: EngineeringDocument(id: 'pump-model-v1', objects: [
    EngineeringObject(id: 'housing', label: 'Housing', properties: {
      'tag': 'P-001',
      'material': 'Cast iron',
    }),
  ]),
);
controller.use(review);
await controller.ready;
review.bind('housing', housingMesh);
review.putAnnotation(EngineeringAnnotation(
  id: 'note-1',
  objectId: 'housing',
  text: 'Check the seal face',
  anchor: review.localAnchor('housing', pickedWorldPoint),
));
final worldPoint = review.worldAnchor('note-1');
review.isolate({'housing'});
review.restoreVisibility();
```

Metadata accepts strings, finite numbers, booleans and null. Records, metadata
maps and annotation coordinates are immutable. `putObject` replaces a record;
`putAnnotation` adds or replaces a note. An annotation must reference a record in
the same document. The core package supplies no UI or pin geometry.

Annotations use local coordinates and follow parent transforms, rotation and
scale. Removing a scene object releases its live binding while retaining the
review record. An unbound annotation returns null from `worldAnchor`; bind the
same source ID to the replacement object when you reload the model.

## Save and reload

Implement `EngineeringStore` for your storage, or import `file_store.dart` and use
`FileEngineeringStore(File(path))`. The file adapter writes a temporary sibling
file before renaming it into place. Your host chooses the directory and access
policy. No storage dependency enters the renderer.

```dart
await review.save(store);
final found = await review.load(store);
```

`load` returns false for a missing file. Malformed JSON, duplicate IDs, unknown
annotation references and another document ID all fail before replacing current
records. The schema version is 1. Review text is limited to two million characters,
with at most 10,000 object records and 10,000 notes. Each object has at most 64
scalar properties and each note has at most 4096 characters.

Watch `hasUnsavedChanges` and `isBusy`. A failed save leaves the review unsaved.
Edits made during a save also remain unsaved; edits made during a load reject that
stale read. Storage operations are serialized per plugin instance. Files do not
provide multi-process locking, collaborative merge or conflict resolution.

## Visibility and lifecycle

Isolation captures the current hierarchy, reveals paths to the chosen objects
and preserves visibility inside their subtrees. Supply `excludeFromIsolation`
for editor helpers. Reapply isolation after adding or reparenting unrelated
objects. Removing an isolated target restores visibility automatically.

Restoring writes only values still owned by isolation, so later visibility edits
take precedence. Detach restores visibility and releases live bindings, while
the immutable review document remains available. Isolation, scene transforms,
selection and geometry are not saved in the review file.

Use the `sceneEngineering` service key from dependent plugins and declare
`gpu3d.engineering` in their dependencies. Cancel your `changes` subscription when
its consumer closes. The workbench shows metadata editing, native annotation pins,
isolation and application-support storage. CAD import and shared review sessions
remain separate work.
