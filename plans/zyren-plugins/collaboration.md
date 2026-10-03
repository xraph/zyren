# Collaboration workstream

Chat `01a0fe60-c9e1-71f1-b206-f8683e4ee508` owns
`packages/zyren_collaboration` and this plan. Work stays on `main`, preserves
concurrent edits and uses `/tmp/zyren-plugin-expansion.lock` for shared changes,
dependency resolution and Git operations. No push, merge or publication occurred.

## Source audit and decisions

Engineering already provides source IDs, annotation records, exact three-way
review merges, conditional session storage and authenticated HTTP review
services. Collaboration reuses those through its optional engineering provider.
It does not introduce another review protocol. Durable scene operations use a
separate ledger because transform/visibility revisions and retry receipts are
not engineering annotation records.

Scene bindings use the public Zyren graph, immutable vectors, attachment scopes
and invalidation. Stable `(source, key)` IDs and a host-owned scene epoch survive
reload. Display names and runtime IDs cannot identify saved objects. Replacing
source assets or discarding history requires a new epoch and an explicit host
migration decision.

One authority serializes field replacements, current permission checks, retry
receipts and operation history. Independent fields can commit independently.
Conflicting edits return their exact current field revision. A new decision gets
a new operation ID; retries keep the original ID and bytes.

## Implemented behavior

- `LocalSceneAuthority` supports serialized, bounded authorization, field
  revisions, exact receipts, revision-pinned history and permission previews.
- `DurableSceneAuthority` replays a versioned ledger within a transactional store.
  `FileSceneDocumentStore` uses an isolate queue, a process advisory lock and
  flushed staged replacement. The ledger retains authors, undo relationships
  and all accepted receipts up to configured capacity. Unknown schemas and
  invalid histories fail closed.
- Shared undo prepares and submits a conditional inverse. The same author and
  ordinary write permissions are required. Intervening field changes conflict.
  Undoing an inverse supports conditional redo.
- HTTP and WebSocket services bind authenticated principals and reauthorize each
  message. They require TLS outside loopback and bound requests, socket counts
  and pending work. Clients own credential callbacks, deadlines and cleanup.
  Socket invalidations are coalesced; reconnect occurs on the next request.
- Presence uses expiring sessions, monotonic sequences, bounded capacity and rate
  limits. Camera poses include perspective/orthographic projection state and
  never increment the durable scene revision. Following is explicit and ends
  on expiry, departure or local navigation.
- The persistent offline outbox pins principal identity and scene epoch. It
  saves exact operations before sending, retains ambiguous results and stops
  at conflicts. Conflict decisions must match the reviewed operation and full
  snapshot, including across queue instances. Denial, epoch change and capacity
  errors remain inspectable. One pending decision per field avoids invented
  offline revisions; the queue holds up to 256 operations.
- Shared runtime providers expose scene state, source/runtime bindings, history,
  permissions, guarded edits, conditional undo, presence, camera following,
  outbox inspection/reconciliation and exact offline conflict decisions. The
  optional engineering adapter keeps its existing host-filtered review workflow.
- The macOS example composes two native viewports, file storage, HTTP edits,
  WebSocket updates, leases, offline conflicts, undo and the shared MCP bridge.
  It uses the shared ZeroState for opening failures and a compact responsive UI.

## Verification

The baseline checkpoints are `45da7bd`, `486fdfb`, `3d83ad8` and `f720d98`.
Durable operations and conditional undo are in `d81a171`. Network sessions,
presence, cameras, persistent outboxes and their agent adapters are in `02de23d2`.
The final native-example commit also tightens reviewed offline decisions.

All 46 Dart tests pass, including separate-process file writers, restart/lost
reply recovery, HTTPS/WSS trust checks, revoked credentials, socket reconnect,
lease expiry and shared agent calls. Analysis and formatting pass. The global
boundary check passed earlier, but its final repeat reports concurrent
`zyren_pointclouds/lib/geospatial_agents.dart` imports of `zyren_geospatial` and
`zyren_3d_tiles` outside the current allowlist. No collaboration violation was
reported. The native Metal integration and external MCP subprocess probe pass
on Apple M3 Max with two native views and zero readback bytes. Visible desktop
and narrow layouts were inspected, including an edit through the native controls.

The previous MCP check depended on an uncommitted adapter. That adapter is now
committed in `828955b8`. The final 46-test suite, native test and external probe
were rerun with `zyren_agents` and `zyren_devtools` exported from that commit,
independent of newer working-tree changes. See
`packages/zyren_collaboration/qualification/2026-10-02.md` and the committed
structured MCP evidence for details and exact qualification limits.

## Remaining scope

The seven requested capabilities are implemented and qualified on macOS as
specified above. The full collaborative editor still lacks creation, deletion,
reparenting and material edits pending source/resource contracts. Engineering
review conflict decisions remain in the existing host workflow.

The file adapter is a bounded local ledger, not a distributed storage service.
One owning isolate per process is required, and power-loss durability is not
claimed. Remote writes cannot be cancelled after dispatch. Other native devices
and backends remain unqualified. Exact presented-frame revision correlation and
rendered-pixel visibility remain unknown rather than inferred from CPU picks.

Current local checkpoints: `d81a1710` (durable ledger and undo), `02de23d2`
(network sessions, leases and outbox), and `2cda8e36` (native example, committed
bridge qualification and exact offline decisions). Owned implementation paths
are clean after those commits. The global point-cloud boundary failures above
remain outside this workstream.
