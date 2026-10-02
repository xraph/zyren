# Zyren collaboration

You can share transform and visibility edits between scene clients, resolve
conflicts explicitly and retry a lost reply without applying the edit twice.
This package uses the public Dart scene API. It does not start a network service.

Run the local example from the workspace with the pinned Flutter SDK's Dart:

```sh
.fvm/flutter_sdk/bin/dart --packages=.dart_tool/package_config.json \
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
shared agent provider and engineering review adapter are tracked in
[the workstream plan](../../plans/zyren-plugins/collaboration.md).

Engineering annotations, three-way review merges and review persistence remain
in `zyren_engineering`. This package edits scene state and does not run physics
simulation. Durable operation history, presence, shared cameras, network
adapters, offline queues and a native shared-editor UI remain in the backlog.
