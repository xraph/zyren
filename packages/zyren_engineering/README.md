# zyren_engineering

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
provide multi-process locking. Use a conditional-write session store for shared
reviews; do not use the file adapter as a collaborative service.

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
`zyren.engineering` in their dependencies. Cancel your `changes` subscription when
its consumer closes. The workbench shows metadata editing, native annotation pins,
isolation and application-support storage. The package-local model example
connects the glTF loader to source-ID review bindings. Shared sessions use a host-configured service.

## Import and reload

You can pass a complete `EngineeringImport` snapshot to `rebindImport`. Each
entry pairs an `EngineeringObject` source key with an attached scene object.
Validation finishes before bindings or isolation change. Missing parts keep
their records and annotations, but lose their live bindings. Imported metadata
replaces metadata for matching source keys. Annotations keep their local anchors.

For glTF/GLB exports, use `EngineeringImport.fromSidecar` and the workflow in
`example/model_review.dart`. The exporter supplies a sidecar for the exact model
version and instantiated scene hierarchy:

```json
{
  "schemaVersion": 1,
  "modelVersion": "export-17",
  "entries": [
    {"id": "cad-part-guid", "label": "Housing", "properties": {}, "path": [0]}
  ]
}
```

The path walks child indices from the instantiated root. It locates a runtime
node, while `id` carries the persistent identity. You must pin the matching model
and sidecar together and retain the source keys when exporting a new version.
The adapter checks the supplied version string; it does not verify a content hash.
A changed hierarchy needs a new sidecar. Do not derive source keys from these
paths, display names or inspector IDs. Load and bind the replacement before
removing the old root if you want existing anchors to remain available.

The local parser supports glTF/GLB, including CAD models converted to that format.
STEP, IGES, IFC and native vendor CAD files need a parser or conversion backend.
This adapter does not parse them.

## Shared reviews

Implement `EngineeringSessionStore` with authenticated reads and atomic
`compareAndWrite`, or use the optional `http_session_store.dart` adapter. Your
service endpoint must support GET and PUT of the existing review JSON, return a
strong ETag on both, and atomically enforce `If-Match` on PUT. Return HTTP 409 or
412 when another writer has changed the version. The host supplies credentials
through the headers callback, owns the HTTP client and enforces document access.
HTTPS is required outside loopback. Redirects are rejected.

```dart
var base = await session.read();
final result = await review.synchronize(session, base: base);
if (result.written) {
  base = result.revision;
} else {
  // Present result.conflicts and keep the previous base until you resolve them.
}
```

Use the last acknowledged document as the base. Whole-record three-way merge
combines independent edits and identical changes. Different changes to the same
record, edit versus deletion, and object deletion that strands a concurrent note
produce explicit conflicts. Each conflict includes the base, local and remote
JSON, with null for absence. Nothing is written while conflicts remain. Pass
explicit decisions back to `synchronize`:

```dart
final resolved = await review.synchronize(session, base: base, resolutions: [
  EngineeringConflictResolution(
    result.conflicts.first,
    EngineeringConflictChoice.local,
  ),
]);
if (resolved.written) base = resolved.revision;
```

Choose base, local or remote for each conflict you have reviewed. Decisions match
the exact conflict values, so another remote edit produces a fresh conflict
instead of silently reusing your earlier choice. Retain the previous base while
resolving conflicts. A deleted object required by a concurrent note must be
retained, or you must remove that note before retrying. `EngineeringMerge` also
lets your host inspect merge results outside the attached plugin.

Edits during the remote read reject the stale operation. Edits during a successful
write stay local and dirty; retain the returned committed revision as the next
base so a retry merges them correctly. A failed conditional write leaves local
work untouched. File operations and session operations share the plugin's busy
lock. Scene transforms, isolation and selection stay outside review JSON.

## Run a local review service

You can run the optional loopback service with your host's authentication token:

```sh
# Set ZYREN_REVIEW_TOKEN through your host's secret configuration first.
dart --packages=.dart_tool/package_config.json \
  packages/zyren_engineering/example/review_service.dart \
  /absolute/path/review-session.json review-id
```

Run this from the workspace with its matching Dart SDK after `flutter pub get`.
The process prints its loopback endpoint and accepts GET and conditional PUT for
one configured review. It creates an empty review if the session file is missing.
Restarting preserves both the review and its revision token. SIGINT or SIGTERM
closes the service. The example token grants read and write access to that review;
you can replace it with your application's session checks through the server API.
The process does not generate or print credentials.

```dart
final server = await EngineeringReviewServer.start(
  store: repository,
  authorize: (request, write) => host.authorizeReview(
    request,
    documentId: 'review-id',
    write: write,
  ),
);
```

Import `review_server.dart` for the server and `file_session_store.dart` for
`FileEngineeringSessionStore`. Your authorization callback decides read and write
access separately and must validate the caller against the configured document.
Denied access returns 403. Authorization failures return 500 and leave storage
untouched. Missing write preconditions return 428, stale versions return 412,
and malformed reviews or another document ID return 400. Oversized bodies return
413; the configurable body deadline returns 408. Error responses close the
connection without waiting for an unread upload.

The file adapter stores a version envelope around the existing review JSON.
Use a separate session file from `FileEngineeringStore`, which writes plain review
JSON. Conditional writes serialize in the owning isolate and acquire an advisory
lock on a stable sibling `.lock` file before checking and replacing the session.
Use one owning isolate per process for each session file. Other processes can
participate through the same adapter, but every writer must respect the lock.
Keep the lock file in place while services run. Direct file writes and multiple
owning isolates in one process bypass this contract.

You choose the directory and its filesystem permissions. The adapter rejects
corrupted envelopes and another review ID without overwriting the file, and
cleans up its staging directory after writes. A version token changes with each
successful write and remains valid after restart. Native scene state still stays
outside the review document.

The service binds only to IPv4 loopback. Hosted access still needs your service
configuration, TLS transport and application identity integration. Reconnect your
client after restarting the local service; a closed pooled connection can fail
the first request. Automatic write retries are deliberately left to the host,
which must read and merge again after a version conflict.

## Integration status

| Workflow | Implemented | Verified |
| --- | --- | --- |
| Source-ID rebinding and version-pinned sidecar | Yes | Package tests, real glTF decode and replacement instances |
| Bounded review JSON and local file persistence | Yes | Package tests |
| Three-way merge and local edit protection | Yes | Package tests |
| Authenticated HTTP and conditional-write client | Yes | Loopback HTTP service tests, denial and version conflicts |
| Persistent loopback shared review service | Yes | macOS: two plugins, conflict decisions, restart, request rejection and file-lock races |
| Hosted shared review service and access policy | Host supplied | No hosted endpoint or credentials configured |
| STEP, IGES, IFC or vendor CAD parsing | No | Conversion/parser backend required |
| Native rendered import review | Existing renderer integration | This workflow has no new native visual qualification |

Linux and Windows service/file-lock qualification remain unverified.

Shared review deployment remains unverified until you configure a real service
and exercise its atomic writes, authentication and access boundaries.
