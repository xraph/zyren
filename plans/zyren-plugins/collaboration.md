# Collaboration

You can follow the scene collaboration work here. This chat owns
`packages/zyren_collaboration` and its examples. Work stays on `main` and uses
`/tmp/zyren-plugin-expansion.lock` for shared edits, dependency resolution and
Git operations.

## Source audit

The engineering review protocol already covers these workflows:

- `lib/src/document.dart` stores source object IDs and anchored review notes.
- `lib/src/merge.dart` provides whole-record three-way merges. A conflict choice
  applies only to the exact base, local and remote values you reviewed.
- `EngineeringSessionStore.compareAndWrite` rejects stale revision tokens.
- `FileEngineeringSessionStore` queues writes, locks across processes and
  replaces the saved envelope atomically. `FileEngineeringStore` alone does
  not coordinate shared writers.
- `HttpEngineeringSessionStore` sends conditional writes with strong ETags.
  `EngineeringReviewServer` enforces host authorization, bounds bodies and
  supports HTTPS. Existing engineering tests cover these services.
- `EngineeringImport` and its sidecars bind source IDs after import. Display
  names and `Object3D.id` cannot serve as persistent IDs.

The core exports immutable `Vec3` and `Quat`, `Object3D` transform/visibility
setters, `ScenePlugin`, attachment scopes and frame invalidation. Collaboration
can use those APIs without changing the renderer or importing engineering into
the general-purpose core.

## Decisions

The first slice edits transforms and visibility on an existing object set.
You supply stable `(source, key)` IDs and a scene session epoch. The epoch must
change whenever you discard the operation history or replace the source model.
Each operation carries schema version 1, scene identity, epoch, operation ID,
target ID and the field revision observed when you prepared the edit.

One authority serializes accepted operations. Revisions are tracked per field,
so independent edits survive concurrent submission. Conflicting edits return
the proposed operation and current state. Keeping a local edit creates a new
operation against the exact reported field revision; another intervening edit
must conflict again. We do not silently pick a winner.

The host supplies read and write permission callbacks and binds authenticated
principals to transports. Credentials never enter the scene document. A bounded
receipt table remembers accepted operation IDs for retries after lost replies.
It rejects new operations when full; dropping old receipts would allow a retry
to execute twice. Durable receipt retention belongs to the persistence phase.

Engineering review documents keep their existing merge and storage protocol.
Scene operations do not encode annotations or replace that HTTP service. A
future host can run both services with the same source identity mapping and
authorization provider. Collaborative editing does not own physics ticks,
prediction, rollback or authoritative multiplayer simulation.

## Phases and acceptance

1. Implement versioned scene operations and the local authority. Check stable
   identity, strict finite transforms, bounded codecs, independent edits,
   same-field conflicts, exact retry identity, read/write denial, revoked
   permissions, async races and full receipt capacity.
2. Add a client with retained pending operations after transport failure and a
   scene plugin that applies acknowledged snapshots. Run two clients with real
   Zyren scene graphs. Check lost replies, retry, explicit conflict resolution,
   stale replies, reload binding and detach during an in-flight request.
3. Add durable snapshots and operation receipts through a transactional host
   store. Validate restart recovery, multi-process conditional writes, schema
   migration, history retention and crash boundaries. Reuse engineering review
   storage for review data. Do not create a second review protocol.
4. Add HTTPS and WebSocket transport adapters with host-owned credentials,
   reconnect, deadlines, payload limits and backpressure. Verify two processes,
   TLS, denied access, interrupted replies and retry against the durable store.
5. Add presence and shared cameras as expiring session data. Check disconnect
   expiry, sequence ordering, rate limits and opt-in camera following. Camera
   updates must not produce persistent object-edit revisions.
6. Add durable offline queues and reconciliation. Pin the scene epoch and
   source versions, surface deleted or remapped objects, retain rejected edits
   for inspection and require fresh decisions when conflicts change.
7. Extend scene edits to creation, deletion, reparenting and material changes
   after Studio and pipeline contracts exist. Add resource ownership checks,
   undo as conditional inverse operations and permissions per action. Verify
   desktop and narrow native UI before claiming a complete shared editor.

## Required runtime agent access

Agent integration is part of completion. Follow `agent-runtime.md` and the
interaction owner's versioned `zyren_agents` contract. This package will expose
scene and field revisions, pending edits and conflicts, paginated accepted
operation history, presence coverage and host-permitted actions. Presence must
report unavailable until an actual presence service exists.

The optional engineering provider will call the existing review APIs for object
records, notes, isolation and shared synchronization. It must preserve host
property filtering, authorization and exact engineering version checks. It will
not create another review server or copy the merge implementation.

The shared registry signatures are available in `zyren_agents`. Optional
`agent_provider.dart` and `engineering_agent_provider.dart` entry points now
use them for registration, schemas, cancellation and stale-target checks. Discovery through a private
helper does not count as shared agent support. Correlate source IDs with
runtime objects through explicit bindings; the shared viewport provider owns
camera, logical-coordinate, pixel-ratio and presented-frame evidence. This
package makes no rendered-pixel claims.

Acceptance requires actual discovery and calls through the common registry,
authorized edits and undo through normal commands, explicit denial and stale
results, bounded history, target cleanup, and optional engineering coverage.
Native point-to-object checks remain separate from CPU geometry and the live
MCP transport check below. Shared undo still needs a command-history adapter.

## Dependencies and shared changes

The first slice depends on `zyren` and the existing `test` dependency. Optional
agent entry points now add `zyren_agents` and `zyren_engineering` dependencies;
the collaboration facade does not import either adapter.
It does not depend on unfinished pipeline, Studio or interaction APIs.

Requested shared edits: add `packages/zyren_collaboration` to root
`pubspec.yaml`, refresh dependency resolution, and add the package's public
import allowlist to `tool/check_package_boundaries.dart`. These are additive
workspace registration changes with no public API impact. Check other plans
and current file contents while holding the lock before applying them.

No core, native, Flutter or engineering API change is required. The optional
providers use the shared contract introduced in `5ddc7ea`. A test-only
`zyren_devtools` dependency exercises its existing bridge and CLI.

## Current evidence

The scene-operation slice is implemented: schema-1 payloads, stable IDs, field
revisions, serialized host permissions, exact retry receipts, paginated history,
retained pending edits, explicit conflicts and acknowledged scene bindings.
The local example runs two scene graphs with a lost reply and conflict.

Both optional providers register through the shared `zyren_agents` interface.
Collaboration tools inspect scene state, permissions and history, apply edits,
refresh and resolve conflicts. They check cancellation at the local authority's
commit point. Engineering tools inspect host-filtered records, edit annotations,
isolate objects and synchronize through the existing review protocol. Provider
registration follows plugin attachment cleanup. The shared viewport enrichment
uses stable and runtime IDs and reports CPU geometry coverage honestly.

Checks run on 2026-10-02 with the repository's Flutter 3.47.5 Dart SDK:

- `dart test packages/zyren_collaboration/test --reporter expanded` passed all
  36 tests, including 19 operation/recovery tests, provider integration and
  the MCP subprocess test.
- The MCP test passed. It launches the actual `zyren_devtools` stdio CLI,
  initializes MCP, discovers both providers, reads a CPU triangle hit, verifies
  read-only command denial, executes an authorized edit and retries it without a
  second scene revision. Original diagnostics descriptors and inspection still
  work. No credentials appear in the fixture output.
- The engineering integration starts `EngineeringReviewServer` on loopback,
  writes through `HttpEngineeringSessionStore` and reads the result through a
  fresh `FileEngineeringSessionStore`. This verifies the existing review service
  integration. It does not establish durable scene-operation storage.
- `two_clients.dart` reports a duplicate retry at revision 1, a conflict and both
  scene graphs at x=2 and revision 2. `agent_scene.dart` discovers two providers,
  returns the housing source ID from a CPU pick, commits scene revision 1 and
  reports an empty geometry query after hiding that object.
- `dart analyze packages/zyren_collaboration` reports no issues. Formatting and
  owned diff checks pass. `dart tool/check_package_boundaries.dart` now passes,
  including Apple ABI header consistency. An earlier run caught the concurrent
  devtools allowance update before that owner finished it.

The MCP test uses `TestRenderer` and asserts zero render calls. No native
presentation or device check has run here. The examples are headless scene hosts,
so there is no desktop/narrow UI claim. No package was published or pushed.

## Remaining scope and blockers

The first local scene-operation and runtime-provider checkpoints are usable.
The full plugin is incomplete. Presence reports unavailable and shared cameras
remain unsupported. Durable scene snapshots and receipts, HTTPS/WebSocket scene
transports, offline queues, conditional shared undo, creation/deletion/reparenting,
material edits and native shared-editor UI remain in phases 3 through 7.

Review conflict resolution continues through the existing host engineering
workflow. A provider tool for explicit filtered review decisions and integration
with a shared command/undo stack remain to be designed. The local guard cannot
cancel a remote engineering write once the store has sent it.

Native point-to-object-to-action evidence is still required. The shared MCP
transport is exercised with actual subprocess I/O, but it has not been connected
to a live native viewport in this workstream.

Commits: `45da7bd` contains the checked scene-operation checkpoint and
`486fdfb` adds the shared agent providers, engineering adapter and MCP checks.
`3d83ad8` bounds host permission waits and verifies that a stalled callback
releases the local authority queue without a late commit.

At agent verification time, the interaction owner's devtools MCP adapter was
still uncommitted. The MCP test passed against that working-tree integration;
reproducing it from committed sources requires the owner's transport commit.

## Extension requested on 2026-10-02

We will finish durable scene operations, HTTP and WebSocket clients, leased
presence, explicit camera following, a persistent offline outbox and conditional
shared undo. The interaction owner's devtools adapter is now committed in
`828955b`; the new checks can use committed transport code.

The durable store keeps the initial snapshot and accepted operations with their
host-bound authors. Atomic replacement and a process lock protect the ledger.
Restoring the authority replays and validates that ledger before serving it.
Receipts are retained with the history, and capacity exhaustion rejects writes.
Undo submits an inverse against the exact revision being undone. It uses the
same permission callback and preserves the original operation relationship.

Presence uses bounded, expiring sessions and monotonic sequences. Shared camera
poses travel with presence, never with durable object edits. Following requires
an explicit choice and ends on local navigation, departure or expiry. Network
clients use host-supplied authentication and bounded requests. A persistent
outbox saves exact operations before sending, retains ambiguous results and
stops for explicit decisions on conflicts or a changed scene epoch.

A native Flutter example will exercise the durable server, both transports,
reconciliation, undo and camera following. Native presentation, logical picks,
agent mutations and compact desktop/narrow layouts will be checked separately.
Creation, deletion, reparenting and material editing remain separate work until
their source/resource contracts are available.
