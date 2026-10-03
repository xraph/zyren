# Zyren collaboration

You can share transform and visibility edits between scene clients, resolve
conflicts explicitly and retry a lost reply without applying the edit twice.
This package uses the public Dart scene API. Your host can attach a durable
authority and explicitly start its HTTP or WebSocket service.

Run the local example from the workspace with the pinned Flutter SDK's Dart:

```sh
fvm dart --packages=.dart_tool/package_config.json \
  packages/zyren_collaboration/example/two_clients.dart
```

The example creates two scene graphs, loses a reply after committing an edit,
retries it, resolves a competing move and checks that both graphs agree. It runs
without a renderer. The native example and network tests provide separate runtime checks.

## Connect a scene

You supply a `SceneSnapshot`, stable `SceneObjectId(source:, key:)` values, and
read/write permission callbacks to `LocalSceneAuthority`. After your host
identifies a principal, `connect` returns its transport. `SceneCollaborationClient`
reads that transport and prepares one pending edit at a time.

```dart
await client.refresh();
client.setTransform(id, SceneTransform(position: const Vec3(2, 0, 0)));
final result = await client.flush();
if (result is SceneOperationConflict) {
  // Present result.operation and result.current for an explicit decision.
  client.keepLocal();
  await client.flush();
}
```

Use `acceptRemote()` to discard a confirmed conflicting edit. A transport error
leaves the exact pending operation intact because the server might have committed
it before the reply disappeared. Retry `flush()` to find out. You cannot discard
an ambiguous edit with `acceptRemote()`.

Attach `SceneCollaborationPlugin(client)` to your engine, then call
`plugin.binding.rebind({id: object})` after reading the snapshot. A headless host
can use `SceneCollaborationBinding` directly. Bindings apply acknowledged state,
invalidate changed scenes and stop applying after disposal. You own the client
and transport lifetimes.

Source keys survive reloads. Names and runtime object IDs do not. Rebinding
validates every replacement before changing the mapping; removed or reparented
objects become unbound until you provide a new mapping. Local transforms assume
the same imported parent layout on every client. Cameras use the separate presence
sharing channel and cannot bind as editable objects here.

## Conflicts, permissions and limits

Each field stores the revision of its last accepted edit. Two clients can change
different fields independently. Competing changes to the same field return a
conflict even if the requested values happen to match. Keeping a local value
creates a new operation against the exact revision you reviewed, so a further
intervening edit produces another conflict.

The host supplies unique operation IDs and a scene epoch. Change the epoch when
you discard history or replace source assets. Permissions run again at commit,
including duplicate retries. The local authority serializes async policy checks;
your callback must not reenter the same authority. Permission callbacks have
a five-second timeout by default, so a stalled callback releases the queue
without committing. You can configure a positive timeout up to one minute.

Snapshots allow 10,000 objects and 4 MiB of JSON characters. Operations allow
4,096 characters. The authority retains up to 4,096 receipts by default and
rejects new edits when full. It keeps existing receipts so old retries remain
safe. The local authority keeps these in memory. Use `DurableSceneAuthority` with
`FileSceneDocumentStore` to retain the ledger and receipts across restarts.

`SceneCollaborationQueries` exposes revision-pinned history pages and permission
previews for concrete operations. A preview never grants a later write. The
optional providers below expose these queries through the shared agent registry.

Engineering annotations, three-way review merges and review persistence remain
in `zyren_engineering`. This package edits scene state and does not run physics
simulation. Creation, deletion, reparenting and material changes remain separate work.


## Runtime agents

Import `package:zyren_collaboration/agent_provider.dart` to register
`CollaborationAgentProvider`. In an engine, attach
`SceneCollaborationAgentPlugin` after `SceneCollaborationPlugin`; the attachment
scope removes discovery and cancels pending calls when the view detaches.
You supply the registry, instance ID and document ID.

The provider exposes these tools through `zyren_agents`:

| Tool | Behavior |
| --- | --- |
| `state`, `objects` | Read acknowledged revisions, stable IDs, current bindings, pending edits and conflicts. State also reports the authority revision. |
| `history` | Read accepted operations in revision-pinned pages of up to 50 entries. |
| `presence` | Read current leased sessions and shared camera poses when the host supplies a presence service. |
| `undo` | Prepare your conditional inverse, then use the normal guarded commit path. |
| `offline_state`, `reconcile` | Inspect or retry a host-supplied durable outbox. Reconciliation stops at a conflict. |
| `offline_keep_local`, `offline_accept_remote` | Resolve an outbox conflict pinned to the reviewed operation and scene/field revisions. |
| `follow_camera`, `stop_following` | Explicitly follow or release a leased camera with `collaboration.camera` scope. |
| `check_operation` | Ask the host whether an exact proposed operation is allowed. |
| `set_transform`, `set_visibility` | Use the ordinary collaboration client and authority checks. |
| `refresh` | Read shared state and apply it to the bound scene, preserving a pending edit. |
| `retry_pending` | Retry the exact operation retained after failure. |
| `keep_local`, `accept_remote` | Resolve a confirmed conflict explicitly. |

You grant `collaboration.read` for queries and both `collaboration.read` and
`collaboration.write` for actions. The authority still checks its own current
permissions. Provider revisions include local pending-state and binding changes;
the shared scene revision is reported separately. Pass the discovered provider
revision and a unique idempotency key when calling an action.

After a failed transport call, inspect state and call `retry_pending` with a new
registry key. The registry retains the original call result for its original
key; the client retains the domain operation ID, so the retry cannot apply that
edit twice. Agent mutations require `GuardedSceneOperationTransport`, which the
local authority implements. It checks cancellation and target consistency after
async permissions and before commit. Other transports report unsupported until
they implement that contract.

You can pass `provider.metadataFor` into the shared `AgentViewportProvider` after
your host authorizes metadata exposure. The resulting CPU triangle hits carry
stable source IDs, runtime IDs and shared revision provenance. The viewport
provider supplies camera, logical coordinates, device pixel ratio and any known
presented frame. Pixel visibility stays unknown without matching native evidence.

Run the direct registry example:

```sh
fvm dart --packages=.dart_tool/package_config.json \
  packages/zyren_collaboration/example/agent_scene.dart
```

It discovers two providers, picks a box, hides it through an authorized command
and verifies the next geometry query is empty. This example has no renderer.

For existing review documents, import
`package:zyren_collaboration/engineering_agent_provider.dart`.
`EngineeringReviewAgentProvider` exposes filtered object inspection, annotation
commands, isolation and optional shared synchronization. You must provide its
per-call authorization callback, property filter and annotation filter.
`EngineeringReviewAgentPlugin` ties registration to the engineering attachment.

Review reads require `engineering.read`. Annotation and synchronization actions
also require `engineering.write`; isolation requires `engineering.view`.
Synchronization uses your existing `EngineeringSessionStore` and acknowledged
`EngineeringRevision`, including its conditional writes and three-way merge.
Conflict results expose IDs only, so private record values cannot leak through
a merge error. You resolve those conflicts through the host engineering workflow.
Cancellation checks before a store write cannot undo a remote write already sent.

The Dart MCP test runs the existing `zyren_devtools` CLI against a headless
host. The separate macOS example connects the same bridge to two native Metal
viewports and checks it through an external MCP process. See
[the native example](example/native_app/README.md) and
[qualification evidence](qualification/2026-10-02.md) for the verified paths,
committed shared dependency check and remaining device limits.

## Durable and network hosts

Import `file_store.dart` for `FileSceneDocumentStore` and `network.dart` for
`SceneCollaborationServer`, `HttpSceneTransport` and `WebSocketSceneTransport`.
The server requires a host authentication callback, rechecks it for each socket
message, and requires TLS outside loopback. Clients take fresh authentication
headers from your callback. They never follow HTTP redirects with credentials.
An optional `HttpClient` lets you configure a private certificate authority.

A durable authority serializes a bounded operation ledger inside the store
transaction. It replays and validates that ledger on read, so this adapter fits
bounded review sessions rather than unbounded event streams. All writers must
use the same file adapter, one owning isolate per process and a local filesystem.
The sibling lock file must remain in place. A staged file is flushed and renamed;
process restarts are supported, but directory fsync and power-loss guarantees
are outside this adapter. Unknown archive schemas and corrupt history fail
closed. There is no lossy receipt pruning or implicit migration.

WebSocket clients emit coalesced invalidations on `changes`. Read again to
obtain authenticated state. A failed socket rejects pending requests; the next
request reconnects with fresh credentials. A host can poll during idle periods
to detect writes from another server process. Each socket admits at most 16
pending requests, and the server limits open sockets. Requests have deadlines
and bodies are bounded. After a timed-out write, retry its exact operation.
Network transports do not claim the in-process cancellation guard: once a
request is dispatched, the remote authority may commit it.

## Offline decisions and shared undo

`OfflineSceneQueue` saves exact operations before dispatch. Give each principal
and asset epoch its own store and `ownerId`; reuse that host-owned ID on restart.
The queue checks that identity before exposing data. It accepts up to 256 edits,
with one outstanding decision per object field. A second edit to that field
requires reconciliation first. This avoids inventing field revisions offline.

`reconcile` retries saved bytes, saves each acknowledgement, and stops at the
first conflict or failure. Read `lastError` for denial, epoch change, capacity
or an uncertain reply. `keepLocal(newId, reviewed: conflict)` uses the exact conflict revision;
`acceptRemote(reviewed: conflict)` discards only that confirmed conflict.
Both reject a decision when another queue owner has changed the reviewed state. Neither method can
discard an uncertain write. Source keys include your asset version and the
scene epoch, so replaced assets require an explicit host migration decision.

`SceneUndoTransport.prepareUndo` returns an inverse of your accepted edit.
Submit it through the ordinary client to retain pending retries and cancellation
checks. `undo` combines preparation and submission. A changed field causes a
conflict; another participant's edits cannot be undone by this author policy.
Undoing an accepted inverse provides conditional redo. History retains the
`undoOfRevision` relationship, and ordinary write permissions apply again.

## Presence and cameras

`ScenePresenceAuthority` keeps bounded leases, sequences and rate limits outside
the durable ledger. Call `publishPresence` periodically with a unique session ID
and a strictly increasing sequence, then `leave` on clean departure. Unexpected
disconnects expire after the configured lease. Reusing a session ID across
principals is denied while its lease or departure tombstone exists.

`SharedSceneCamera` supports perspective and orthographic poses, clipping,
zoom and projection bounds. The receiving viewport keeps its own aspect ratio.
`SharedCameraFollower` follows only after `follow`, rejects old updates, and
stops on departure, expiry or `stop`. Wire local navigation to `stop` and call
`update` after polling or socket invalidation. Its expiry timer also runs when
the network is unavailable. Camera changes never create durable edit revisions.
