# Zyren collaboration

You can share transform and visibility edits between scene clients, resolve
conflicts explicitly and retry a lost reply without applying the edit twice.
This package uses the public Dart scene API. It does not start a network service.

Run the local example from the workspace with the pinned Flutter SDK's Dart:

```sh
fvm dart --packages=.dart_tool/package_config.json \
  packages/zyren_collaboration/example/two_clients.dart
```

The example creates two scene graphs, loses a reply after committing an edit,
retries it, resolves a competing move and checks that both graphs agree. It runs
without a renderer. Native presentation and multi-process networking need
separate verification.

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
the same imported parent layout on every client. Cameras use a separate future
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
your callback must not reenter the same authority.

Snapshots allow 10,000 objects and 4 MiB of JSON characters. Operations allow
4,096 characters. The authority retains up to 4,096 receipts by default and
rejects new edits when full. It keeps existing receipts so old retries remain
safe. These receipts and scene changes live in memory only.

`SceneCollaborationQueries` exposes revision-pinned history pages and permission
previews for concrete operations. A preview never grants a later write. The
optional providers below expose these queries through the shared agent registry.

Engineering annotations, three-way review merges and review persistence remain
in `zyren_engineering`. This package edits scene state and does not run physics
simulation. Durable operation history, presence, shared cameras, network
adapters, offline queues and a native shared-editor UI remain in the backlog.


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
| `presence` | Report unavailable. The local transport has no presence service. |
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

The tests run a real stdio MCP subprocess through the existing `zyren_devtools`
bridge, plus loopback HTTP/file review persistence. They use a headless test
renderer and do not establish native screen presentation. Presence, shared
cameras, durable scene receipts, network scene transports, offline reconciliation,
shared undo and native editor UI remain in the workstream backlog.
